#!/bin/bash

# ==============================================================================
# 配置区域：路径风格参考实验5
# ==============================================================================
OS_USER="jiamingwei"
BASE_DIR="/home/jiamingwei"
PG_INSTALL_ROOT="$BASE_DIR"
PGDATA_ROOT="$BASE_DIR"
PG_PORT=5432

VERSIONS=("mdonrelease" "chunk" "mdoffrelease")
CLIENTS=200

DIRTY_PAGES=200000
ROWS_PER_PAGE=64
PAYLOAD_BYTES=200
FILLFACTOR=70

SHARED_BUFFERS="50GB"
MAX_CONNECTIONS=2000
CHECKPOINT_TIMEOUT="1d"
MAX_WAL_SIZE="100GB"
MIN_WAL_SIZE="4GB"
WAL_KEEP_SIZE="64GB"

RESULT_DIR="$BASE_DIR/exp1/results"
RESULT_FILE="$RESULT_DIR/exp1_summary_results.csv"

# ==============================================================================
# 主逻辑
# ==============================================================================

if [ "$(id -u)" != "0" ]; then
   echo "[错误] 本脚本必须使用 root 用户运行，以便清理 PGDATA 和 drop_caches！"
   exit 1
fi

mkdir -p "$RESULT_DIR"
echo "version,label,clients,dirty_pages,updated_rows,elapsed_ms,rows_per_sec,start_lsn,end_lsn,lsn_bytes,update_wal_records,update_wal_fpi,update_wal_bytes,update_wal_fpi_bytes,wal_bytes_per_page,fpi_bytes_per_page,waldump_records,waldump_fpw_mentions,waldump_new_pblk_refs,waldump_shift_refs,remap_facts_file,shift_facts_file,result" > "$RESULT_FILE"
chown $OS_USER:$OS_USER "$RESULT_DIR" "$RESULT_FILE"

as_pg() {
    sudo -u $OS_USER env LD_LIBRARY_PATH="$PG_BIN/../lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$@"
}

psql_exec() {
    as_pg "$PG_BIN/psql" -h 127.0.0.1 -p "$PG_PORT" -d postgres -v ON_ERROR_STOP=1 "$@"
}

psql_scalar() {
    psql_exec -At -c "$1" | tail -n 1 | tr -d '[:space:]'
}

stop_pg() {
    as_pg "$PG_BIN/pg_ctl" -D "$PG_DATA" stop -m immediate >/dev/null 2>&1
    pkill -u $OS_USER -f "$PG_DATA" 2>/dev/null
    sleep 2
}

drop_os_caches() {
    echo "[INFO] 清理系统 page cache ..."
    sync
    echo 3 > /proc/sys/vm/drop_caches
}

resolve_variant() {
    if [ "$ver" = "mdonrelease" ]; then
        LABEL="md_fpw_on"
        FULL_PAGE_WRITES="on"
        EXTRA_CONF=""
    elif [ "$ver" = "chunk" ]; then
        LABEL="umbra_fpw_on"
        FULL_PAGE_WRITES="on"
        EXTRA_CONF=""
    elif [ "$ver" = "mdoffrelease" ]; then
        LABEL="md_fpw_off"
        FULL_PAGE_WRITES="off"
        EXTRA_CONF=""
    else
        echo "[错误] 未知版本目录: $ver"
        exit 1
    fi
}

prepare_table() {
    local rows=$((DIRTY_PAGES * ROWS_PER_PAGE))

    echo "[INFO] 准备 fdbench: rows=$rows dirty_pages=$DIRTY_PAGES ..."
    psql_exec >/dev/null <<SQL
SET client_min_messages TO warning;
DROP TABLE IF EXISTS fdbench_targets;
DROP TABLE IF EXISTS fdbench;
CREATE TABLE fdbench (
    id bigint PRIMARY KEY,
    marker integer NOT NULL DEFAULT 0,
    payload text NOT NULL
) WITH (fillfactor=$FILLFACTOR, autovacuum_enabled=false);
ALTER TABLE fdbench ALTER COLUMN payload SET STORAGE PLAIN;
INSERT INTO fdbench(id, marker, payload)
SELECT g, 0, 'before_' || g::text || '_' || repeat('x', $PAYLOAD_BYTES)
FROM generate_series(1, $rows) AS g;
VACUUM (FREEZE, ANALYZE) fdbench;
SQL

    rebuild_targets
}

rebuild_targets() {
    psql_exec >/dev/null <<SQL
SET client_min_messages TO warning;
DROP TABLE IF EXISTS fdbench_targets;
CREATE TABLE fdbench_targets AS
WITH pages AS (
    SELECT id, split_part(btrim(ctid::text, '()'), ',', 1)::int AS blkno
    FROM fdbench
),
one_per_block AS (
    SELECT DISTINCT ON (blkno) id, blkno
    FROM pages
    ORDER BY blkno, id
)
SELECT row_number() OVER (ORDER BY blkno) AS target_no, id, blkno
FROM one_per_block
ORDER BY blkno
LIMIT $DIRTY_PAGES;
CREATE UNIQUE INDEX fdbench_targets_target_no_idx ON fdbench_targets(target_no);
CREATE UNIQUE INDEX fdbench_targets_id_idx ON fdbench_targets(id);
ANALYZE fdbench_targets;
SQL

    target_count=$(psql_scalar "SELECT count(*) FROM fdbench_targets;")
    if [ "$target_count" -lt "$DIRTY_PAGES" ]; then
        echo "[错误] 目标 heap page 数不足: target_count=$target_count dirty_pages=$DIRTY_PAGES"
        stop_pg
        exit 1
    fi
}

prepare_checkpoint_boundary() {
    psql_exec >/dev/null <<SQL
VACUUM (FREEZE, ANALYZE) fdbench;
CHECKPOINT;
SELECT pg_stat_reset_shared('wal');
SELECT pg_stat_force_next_flush();
SQL
}

run_concurrent_updates() {
    local active="$CLIENTS"
    local base=$((DIRTY_PAGES / active))
    local extra=$((DIRTY_PAGES % active))
    local start=1
    local client count end script pids pid failed

    rm -rf "$RESULT_DIR/${ver}_client_sql"
    mkdir -p "$RESULT_DIR/${ver}_client_sql"
    chown -R $OS_USER:$OS_USER "$RESULT_DIR/${ver}_client_sql"

    pids=""
    for ((client = 1; client <= active; client++)); do
        count="$base"
        if [ "$client" -le "$extra" ]; then
            count=$((count + 1))
        fi
        end=$((start + count - 1))
        script="$RESULT_DIR/${ver}_client_sql/client_${client}.sql"
        cat > "$script" <<SQL
DO \$\$
DECLARE
    v_id bigint;
BEGIN
    FOR v_id IN
        SELECT id FROM fdbench_targets
        WHERE target_no BETWEEN $start AND $end
        ORDER BY target_no
    LOOP
        UPDATE fdbench
        SET marker = marker + 1,
            payload = 'after_' || id::text || '_' || repeat('y', $PAYLOAD_BYTES)
        WHERE id = v_id;
    END LOOP;
END \$\$;
SQL
        chown $OS_USER:$OS_USER "$script"
        as_pg "$PG_BIN/psql" -h 127.0.0.1 -p "$PG_PORT" -d postgres -v ON_ERROR_STOP=1 -f "$script" \
            > "$RESULT_DIR/${ver}_client_sql/client_${client}.out" \
            2> "$RESULT_DIR/${ver}_client_sql/client_${client}.err" &
        pids="$pids $!"
        start=$((end + 1))
    done

    failed=0
    for pid in $pids; do
        if ! wait "$pid"; then
            failed=1
        fi
    done
    chown -R $OS_USER:$OS_USER "$RESULT_DIR/${ver}_client_sql"

    if [ "$failed" != "0" ]; then
        echo "[错误] 并发 update 客户端失败，日志在 $RESULT_DIR/${ver}_client_sql"
        stop_pg
        exit 1
    fi
}

run_waldump_counts() {
    local start_lsn=$1
    local end_lsn=$2
    local out="$RESULT_DIR/${ver}_waldump.out"
    local err="$RESULT_DIR/${ver}_waldump.err"
    local remap_facts="$RESULT_DIR/${ver}_remap_facts.csv"
    local shift_facts="$RESULT_DIR/${ver}_shift_facts.csv"
    local records fpw new_pblk_refs shift_refs

    as_pg "$PG_BIN/pg_waldump" -b -p "$PG_DATA/pg_wal" -s "$start_lsn" -e "$end_lsn" \
        > "$out" 2> "$err"

    records=$(awk '/^rmgr:/ { c++ } END { print c + 0 }' "$out")
    fpw=$(awk '{ n += gsub(/FPW( for WAL verification)?/, "") } END { print n + 0 }' "$out")
    echo "record_lsn,logical_blk,new_pblk" > "$remap_facts"
    awk '
        /^rmgr:/ {
            record_lsn = "";
            for (i = 1; i <= NF; i++) {
                if ($i == "lsn:") {
                    record_lsn = $(i + 1);
                    gsub(/,/, "", record_lsn);
                }
            }
        }
        /blkref #[0-9]+:/ && / fork main blk / && /new_pblk/ {
            logical_blk = "-";
            new_pblk = "-";
            for (i = 1; i <= NF; i++) {
                if ($i == "blk")
                    logical_blk = $(i + 1);
                if ($i == "new_pblk")
                    new_pblk = $(i + 1);
            }
            gsub(/;/, "", logical_blk);
            gsub(/;/, "", new_pblk);
            if (new_pblk != "-")
                print record_lsn "," logical_blk "," new_pblk;
        }
    ' "$out" >> "$remap_facts"
    new_pblk_refs=$(awk 'NR > 1 { n++ } END { print n + 0 }' "$remap_facts")
    echo "record_lsn,logical_blk,source_slot,target_slot,logical_nblocks" > "$shift_facts"
    awk '
        /^rmgr:/ {
            record_lsn = "";
            for (i = 1; i <= NF; i++) {
                if ($i == "lsn:") {
                    record_lsn = $(i + 1);
                    gsub(/,/, "", record_lsn);
                }
            }
        }
        /blkref #[0-9]+:/ && / fork main blk / && /shift: source_slot/ {
            logical_blk = "-";
            source_slot = "-";
            target_slot = "-";
            logical_nblocks = "-";
            for (i = 1; i <= NF; i++) {
                if ($i == "blk")
                    logical_blk = $(i + 1);
                if ($i == "source_slot")
                    source_slot = $(i + 1);
                if ($i == "target_slot")
                    target_slot = $(i + 1);
                if ($i == "logical_nblocks")
                    logical_nblocks = $(i + 1);
            }
            gsub(/;/, "", logical_blk);
            if (source_slot != "-" && target_slot != "-" && logical_nblocks != "-")
                print record_lsn "," logical_blk "," source_slot "," target_slot "," logical_nblocks;
        }
    ' "$out" >> "$shift_facts"
    shift_refs=$(awk 'NR > 1 { n++ } END { print n + 0 }' "$shift_facts")
    chown $OS_USER:$OS_USER "$out" "$err" "$remap_facts" "$shift_facts"

    echo "$records,$fpw,$new_pblk_refs,$shift_refs,$remap_facts,$shift_facts"
}

for ver in "${VERSIONS[@]}"; do
    echo "================================================================="
    echo "开始处理版本: $ver"
    echo "================================================================="

    resolve_variant
    PG_BIN="$PG_INSTALL_ROOT/$ver/bin"
    PG_DATA="$PGDATA_ROOT/exp1/$ver/data"

    if [ ! -x "$PG_BIN/initdb" ] || [ ! -x "$PG_BIN/pg_ctl" ] || [ ! -x "$PG_BIN/psql" ] || [ ! -x "$PG_BIN/pg_waldump" ]; then
        echo "[错误] PostgreSQL 二进制不存在: $PG_BIN"
        exit 1
    fi

    stop_pg

    echo "[INFO] 初始化独立的数据库目录 $PG_DATA ..."
    mkdir -p "$(dirname "$PG_DATA")"
    chown $OS_USER:$OS_USER "$(dirname "$PG_DATA")"
    rm -rf "$PG_DATA"
    as_pg "$PG_BIN/initdb" -D "$PG_DATA" >/dev/null

    echo "[INFO] 配置 PostgreSQL 参数 ..."
    CONF_FILE="$PG_DATA/postgresql.conf"
    cat >> "$CONF_FILE" <<EOF
listen_addresses = '127.0.0.1'
port = $PG_PORT
max_connections = $MAX_CONNECTIONS
shared_buffers = $SHARED_BUFFERS
checkpoint_timeout = $CHECKPOINT_TIMEOUT
checkpoint_completion_target = 0.9
max_wal_size = $MAX_WAL_SIZE
min_wal_size = $MIN_WAL_SIZE
wal_keep_size = $WAL_KEEP_SIZE
full_page_writes = $FULL_PAGE_WRITES
wal_compression = off
fsync = on
synchronous_commit = on
autovacuum = off
track_wal_io_timing = on
log_checkpoints = on
$EXTRA_CONF
EOF

    HBA_FILE="$PG_DATA/pg_hba.conf"
    echo "host all all 127.0.0.1/32 trust" >> "$HBA_FILE"
    echo "local all all trust" >> "$HBA_FILE"
    chown $OS_USER:$OS_USER "$CONF_FILE" "$HBA_FILE"

    drop_os_caches

    echo "[INFO] 启动数据库 ..."
    as_pg "$PG_BIN/pg_ctl" -D "$PG_DATA" -l "$PG_DATA/logfile" -w -t 120 start >/dev/null

    prepare_table
    prepare_checkpoint_boundary
    drop_os_caches

    echo "[INFO] 更新 checkpoint 后 first-dirty pages: clients=$CLIENTS dirty_pages=$DIRTY_PAGES ..."
    start_lsn=$(psql_scalar "SELECT pg_current_wal_insert_lsn();")
    start_ns=$(date +%s%N)
    run_concurrent_updates
    end_ns=$(date +%s%N)
    elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    psql_exec -c "SELECT pg_stat_force_next_flush();" >/dev/null
    end_lsn=$(psql_scalar "SELECT pg_current_wal_insert_lsn();")

    updated_rows=$(psql_scalar "SELECT count(*) FROM fdbench WHERE marker = 1;")
    lsn_bytes=$(psql_scalar "SELECT pg_wal_lsn_diff('$end_lsn', '$start_lsn');")
    wal_line=$(psql_exec -At -F ',' -c "SELECT wal_records, wal_fpi, wal_bytes, wal_fpi_bytes FROM pg_stat_wal;" | tail -n 1)
    IFS=, read -r wal_records wal_fpi wal_bytes wal_fpi_bytes <<< "$wal_line"

    wal_bytes_per_page=$(awk -v a="$wal_bytes" -v b="$DIRTY_PAGES" 'BEGIN { if (b > 0) printf "%.3f", a / b; else print "0" }')
    fpi_bytes_per_page=$(awk -v a="$wal_fpi_bytes" -v b="$DIRTY_PAGES" 'BEGIN { if (b > 0) printf "%.3f", a / b; else print "0" }')
    rows_per_sec=$(awk -v rows="$DIRTY_PAGES" -v ms="$elapsed_ms" 'BEGIN { if (ms > 0) printf "%.3f", rows / (ms / 1000.0); else print "0" }')

    waldump_line=$(run_waldump_counts "$start_lsn" "$end_lsn")
    IFS=, read -r waldump_records waldump_fpw_mentions waldump_new_pblk_refs waldump_shift_refs remap_facts_file shift_facts_file <<< "$waldump_line"

    result="FAIL"
    if [ "$updated_rows" = "$DIRTY_PAGES" ]; then
        if [ "$ver" = "mdonrelease" ] && [ "$wal_fpi" -gt 0 ] && [ "$waldump_fpw_mentions" -gt 0 ]; then
            result="PASS"
        elif [ "$ver" = "chunk" ] && [ "$waldump_shift_refs" -ge "$DIRTY_PAGES" ]; then
            result="PASS"
        elif [ "$ver" = "mdoffrelease" ] && [ "$wal_fpi" = "0" ]; then
            result="CONTROL_PASS"
        fi
    fi

    echo "$ver,$LABEL,$CLIENTS,$DIRTY_PAGES,$updated_rows,$elapsed_ms,$rows_per_sec,$start_lsn,$end_lsn,$lsn_bytes,$wal_records,$wal_fpi,$wal_bytes,$wal_fpi_bytes,$wal_bytes_per_page,$fpi_bytes_per_page,$waldump_records,$waldump_fpw_mentions,$waldump_new_pblk_refs,$waldump_shift_refs,$remap_facts_file,$shift_facts_file,$result" >> "$RESULT_FILE"
    chown $OS_USER:$OS_USER "$RESULT_FILE"

    echo "[INFO] 完成 $ver: wal_bytes_per_page=$wal_bytes_per_page fpi_bytes_per_page=$fpi_bytes_per_page fpw_refs=$waldump_fpw_mentions new_pblk_refs=$waldump_new_pblk_refs shift_refs=$waldump_shift_refs result=$result"

    echo "[INFO] 停止数据库并清理 $PG_DATA ..."
    stop_pg
    rm -rf "$PG_DATA"
done

echo "================================================================="
echo "实验1完成。结果:"
cat "$RESULT_FILE"
