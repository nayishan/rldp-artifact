#!/bin/bash

# Exp2 chunk strict runner: run C2 torn-target recovery first, then run C3
# checkpoint-crossing remap publication through the exposed PostgreSQL
# interfaces.  Development regression tests are separate from this paper
# experiment evidence path.

OS_USER="${OS_USER:-jiamingwei}"
BASE_DIR="${BASE_DIR:-/home/jiamingwei}"
RESULT_DIR="$BASE_DIR/exp2/results"
RESULT_FILE="$RESULT_DIR/exp2_c2_c3_chunk_summary.csv"

C2_PORT="${C2_PORT:-55438}"
C2_DB_NAME="${C2_DB_NAME:-exp2_crash}"
C2_VERSION_LIST="${C2_VERSION_LIST:-chunk}"
read -r -a C2_VERSIONS <<< "$C2_VERSION_LIST"
C2_RESULT_FILE="$RESULT_DIR/exp2_torn_page_summary.csv"
C2_REMAP_FACTS="$RESULT_DIR/remap_facts.csv"
C2_TABLE_ROWS="${C2_TABLE_ROWS:-20000}"
C2_TARGET_BLOCKS="${C2_TARGET_BLOCKS:-16}"
C2_ROWS_PER_BLOCK="${C2_ROWS_PER_BLOCK:-1}"
C2_PAYLOAD_BYTES="${C2_PAYLOAD_BYTES:-200}"
C2_DAMAGE_BYTES="${C2_DAMAGE_BYTES:-4096}"
C2_BLKSZ="${C2_BLKSZ:-8192}"
C2_SEG_BLOCKS="${C2_SEG_BLOCKS:-131072}"
C2_UMBRA_CHUNK_PAIRED_PAGES="${C2_UMBRA_CHUNK_PAIRED_PAGES:-32}"
C2_UMBRA_CHUNK_ACTIVE_SLOTS="${C2_UMBRA_CHUNK_ACTIVE_SLOTS:-3}"
C2_SHARED_BUFFERS="${C2_SHARED_BUFFERS:-1GB}"
C2_MAX_CONNECTIONS="${C2_MAX_CONNECTIONS:-100}"
C2_CHECKPOINT_TIMEOUT="${C2_CHECKPOINT_TIMEOUT:-1d}"
C2_MAX_WAL_SIZE="${C2_MAX_WAL_SIZE:-8GB}"
C2_MIN_WAL_SIZE="${C2_MIN_WAL_SIZE:-1GB}"
C2_WAL_KEEP_SIZE="${C2_WAL_KEEP_SIZE:-1GB}"

C3_VERSION="${C3_VERSION:-chunk}"
C3_PORT="${C3_PORT:-55439}"
C3_DB_NAME="${C3_DB_NAME:-exp2_c3}"
C3_PG_BIN="$BASE_DIR/$C3_VERSION/bin"
C3_PG_DATA="$BASE_DIR/exp2/c3_$C3_VERSION/data"
C3_RESULT_FILE="$RESULT_DIR/exp2_c3_checkpoint_publication.csv"
C3_PAUSE_MARKER="umbra_exp2_c3_pause_entered"
C3_RELEASE_MARKER="umbra_exp2_c3_release"
C3_WAIT_TIMEOUT=30
C3_STEP_TIMEOUT=120
C3_TABLE_ROWS="${C3_TABLE_ROWS:-20000}"
C3_TARGET_BLOCKS="${C3_TARGET_BLOCKS:-5}"
C3_PAYLOAD_BYTES="${C3_PAYLOAD_BYTES:-200}"

if [ "$(id -u)" != "0" ]; then
   echo "[错误] 本脚本必须使用 root 用户运行，因为 C2 runner 需要清理 PGDATA 并切换到 $OS_USER。"
   exit 1
fi

echo "[CONFIG] OS_USER=$OS_USER"
echo "[CONFIG] BASE_DIR=$BASE_DIR"
echo "[CONFIG] C2_VERSION_LIST=$C2_VERSION_LIST"
echo "[CONFIG] C2_TABLE_ROWS=$C2_TABLE_ROWS"
echo "[CONFIG] C2_TARGET_BLOCKS=$C2_TARGET_BLOCKS"
echo "[CONFIG] C3_VERSION=$C3_VERSION"
echo "[CONFIG] C3_TABLE_ROWS=$C3_TABLE_ROWS"
echo "[CONFIG] C3_TARGET_BLOCKS=$C3_TARGET_BLOCKS"
echo "[CONFIG] RESULT_DIR=$RESULT_DIR"

mkdir -p "$RESULT_DIR"
chown "$OS_USER:$OS_USER" "$RESULT_DIR"

echo "case,step,result,details_csv,notes" > "$RESULT_FILE"
echo "version,case,target_blocks,damage_facts,updated_rows,damaged_pblks,hash_changed_pblks,post_hash_checked_pblks,post_hash_not_damaged_pblks,post_hash_equals_before_pblks,damage_bytes,damage_target,recovery_ok,total_rows,bad_updated_rows,bad_untouched_rows,table_before_hash,table_after_hash,table_compare_equal,result" > "$C2_RESULT_FILE"
echo "case,pause_entered,checkpoint_waited,checkpoint_blocked_while_paused,update_completed,checkpoint_completed,recovery_ok,signature_equal,updated_rows,result" > "$C3_RESULT_FILE"
chown "$OS_USER:$OS_USER" "$RESULT_FILE"
chown "$OS_USER:$OS_USER" "$C2_RESULT_FILE"
chown "$OS_USER:$OS_USER" "$C3_RESULT_FILE"

record_summary() {
    local case_id="$1"
    local step="$2"
    local result="$3"
    local details_csv="$4"
    local notes="$5"

    echo "$case_id,$step,$result,$details_csv,$notes" >> "$RESULT_FILE"
    chown "$OS_USER:$OS_USER" "$RESULT_FILE"
}

run_step() {
    local case_id="$1"
    local step="$2"
    local log_file="$3"
    shift 3

    echo "[$case_id] $*"
    "$@" > "$log_file" 2>&1
    local rc=$?
    chown "$OS_USER:$OS_USER" "$log_file"

    if [ "$rc" -eq 0 ]; then
        record_summary "$case_id" "$step" "PASS" "$log_file" "ok"
        return 0
    fi

    record_summary "$case_id" "$step" "FAIL" "$log_file" "rc_$rc"
    return "$rc"
}

block_step() {
    local case_id="$1"
    local reason="$2"

    record_summary "$case_id" "blocked" "BLOCKED" "" "$reason"
    echo "[$case_id] BLOCKED: $reason"
}

c2_as_pg() {
    sudo -u "$OS_USER" env LD_LIBRARY_PATH="$c2_pg_bin/../lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$@"
}

c2_stop_pg() {
    c2_as_pg "$c2_pg_bin/pg_ctl" -D "$c2_pg_data" stop -m immediate >/dev/null 2>&1
    pkill -u "$OS_USER" -f "$c2_pg_data" 2>/dev/null
    sleep 2
}

c2_psql_db() {
    c2_as_pg "$c2_pg_bin/psql" -h 127.0.0.1 -p "$C2_PORT" -d "$C2_DB_NAME" -v ON_ERROR_STOP=1 "$@"
}

c2_psql_postgres() {
    c2_as_pg "$c2_pg_bin/psql" -h 127.0.0.1 -p "$C2_PORT" -d postgres -v ON_ERROR_STOP=1 "$@"
}

c2_dump_table_result() {
    local dump_file="$1"

    c2_psql_db -At -F ',' -c "SELECT id, payload FROM exp2_t ORDER BY id;" > "$dump_file"
    chown "$OS_USER:$OS_USER" "$dump_file"
}

c2_collect_remap_facts() {
    local start_lsn="$1"
    local end_lsn="$2"

    echo "logical_blk,old_pblk,new_pblk" > "$C2_REMAP_FACTS"
    c2_as_pg "$c2_pg_bin/pg_waldump" -b -p "$c2_pg_data/pg_wal" -s "$start_lsn" -e "$end_lsn" 2> "$RESULT_DIR/waldump.err" \
        > "$RESULT_DIR/waldump.out"

    awk -v target_file="$RESULT_DIR/target_blocks.txt" \
        -v chunk_pages="$C2_UMBRA_CHUNK_PAIRED_PAGES" \
        -v active_slots="$C2_UMBRA_CHUNK_ACTIVE_SLOTS" '
        function chunk_pblk(logical_blk, active_slot, chunk_id, offset) {
            chunk_id = int(logical_blk / chunk_pages);
            offset = logical_blk % chunk_pages;
            return chunk_id * (active_slots * chunk_pages) + active_slot * chunk_pages + offset;
        }
        BEGIN {
            while ((getline b < target_file) > 0)
                target[b] = 1;
            close(target_file);
        }
        /blkref #[0-9]+:/ && / fork main blk / && / remap: / {
            logical_blk = "";
            old_pblk = "";
            new_pblk = "";
            for (i = 1; i <= NF; i++) {
                if ($i == "blk")
                    logical_blk = $(i + 1);
                if ($i == "old_pblk")
                    old_pblk = $(i + 1);
                if ($i == "new_pblk")
                    new_pblk = $(i + 1);
            }
            gsub(/;/, "", logical_blk);
            gsub(/;/, "", old_pblk);
            gsub(/;/, "", new_pblk);
            if (logical_blk != "" && old_pblk != "" && new_pblk != "" && target[logical_blk] == 1)
                print logical_blk "," old_pblk "," new_pblk;
        }
        /blkref #[0-9]+:/ && / fork main blk / && / shift: / {
            logical_blk = "";
            source_slot = "";
            target_slot = "";
            for (i = 1; i <= NF; i++) {
                if ($i == "blk")
                    logical_blk = $(i + 1);
                if ($i == "source_slot")
                    source_slot = $(i + 1);
                if ($i == "target_slot")
                    target_slot = $(i + 1);
            }
            gsub(/;/, "", logical_blk);
            gsub(/;/, "", source_slot);
            gsub(/;/, "", target_slot);
            if (logical_blk != "" && source_slot != "" && target_slot != "" && target[logical_blk] == 1)
                printf "%d,%d,%d\n", logical_blk, chunk_pblk(logical_blk, source_slot), chunk_pblk(logical_blk, target_slot);
        }
    ' "$RESULT_DIR/waldump.out" | sort -t, -k1,1n > "$RESULT_DIR/remap_facts.tmp"
    awk -F, '!seen[$1]++' "$RESULT_DIR/remap_facts.tmp" >> "$C2_REMAP_FACTS"
    chown "$OS_USER:$OS_USER" "$C2_REMAP_FACTS" "$RESULT_DIR/waldump.out" "$RESULT_DIR/waldump.err" "$RESULT_DIR/remap_facts.tmp"
}

c2_damage_remap_new_pblks() {
    local relpath="$1"
    local damaged_blocks=0
    local hash_changed_blocks=0
    local logical_blk old_pblk new_pblk seg offblk file offset before_hash after_hash hash_changed file_size

    tail -n +2 "$C2_REMAP_FACTS" | while IFS=, read logical_blk old_pblk new_pblk; do
        [ -n "$new_pblk" ] || continue

        seg=$((new_pblk / C2_SEG_BLOCKS))
        offblk=$((new_pblk % C2_SEG_BLOCKS))
        if [ "$seg" -eq 0 ]; then
            file="$c2_pg_data/$relpath"
        else
            file="$c2_pg_data/$relpath.$seg"
        fi
        offset=$((offblk * C2_BLKSZ))

        if [ ! -f "$file" ]; then
            echo "[ERROR] 目标 heap 文件不存在: $file"
            continue
        fi

        file_size=$(wc -c < "$file" | tr -d ' ')
        if [ "$file_size" -lt $((offset + C2_DAMAGE_BYTES)) ]; then
            echo "[ERROR] 目标物理页超出 heap 文件范围: file=$file offset=$offset size=$file_size"
            continue
        fi

        before_hash=$(dd if="$file" bs=1 skip="$offset" count="$C2_DAMAGE_BYTES" 2>/dev/null | sha256sum | awk '{print $1}')
        dd if=/dev/urandom of="$file" bs="$C2_DAMAGE_BYTES" seek=$((offblk * 2)) count=1 conv=notrunc >/dev/null 2>&1
        after_hash=$(dd if="$file" bs=1 skip="$offset" count="$C2_DAMAGE_BYTES" 2>/dev/null | sha256sum | awk '{print $1}')

        if [ "$before_hash" != "$after_hash" ]; then
            hash_changed="yes"
            hash_changed_blocks=$((hash_changed_blocks + 1))
        else
            hash_changed="no"
        fi

        damaged_blocks=$((damaged_blocks + 1))
        echo "$logical_blk,$old_pblk,$new_pblk,$file,$offset,$before_hash,$after_hash,$hash_changed,-,-,-" >> "$c2_damage_log"
        echo "$damaged_blocks $hash_changed_blocks" > "$RESULT_DIR/damage_counts.tmp"
    done

    if [ -s "$RESULT_DIR/damage_counts.tmp" ]; then
        damaged_blocks=$(awk '{d=$1} END {print d + 0}' "$RESULT_DIR/damage_counts.tmp")
        hash_changed_blocks=$(awk '{h=$2} END {print h + 0}' "$RESULT_DIR/damage_counts.tmp")
    fi
    c2_damaged_blocks="$damaged_blocks"
    c2_hash_changed_blocks="$hash_changed_blocks"
}

c2_collect_post_recovery_hashes() {
    local tmp_log="$RESULT_DIR/damaged_blocks_post_hash.tmp"
    local rows_file="$RESULT_DIR/damaged_blocks_rows.tmp"
    local logical_blk old_pblk new_pblk file offset before_hash after_hash hash_changed
    local post_hash post_not_damaged post_equals_before
    local checked_blocks=0
    local not_damaged_blocks=0
    local equals_before_blocks=0

    echo "logical_blk,old_pblk,new_pblk,file,offset,before_hash,after_hash,hash_changed,post_recovery_hash,post_not_damaged,post_equals_before" > "$tmp_log"
    tail -n +2 "$c2_damage_log" > "$rows_file"

    while IFS=, read logical_blk old_pblk new_pblk file offset before_hash after_hash hash_changed _ _ _; do
        [ -n "$file" ] || continue

        post_hash=$(dd if="$file" bs=1 skip="$offset" count="$C2_DAMAGE_BYTES" 2>/dev/null | sha256sum | awk '{print $1}')

        post_not_damaged="no"
        if [ "$post_hash" != "$after_hash" ]; then
            post_not_damaged="yes"
            not_damaged_blocks=$((not_damaged_blocks + 1))
        fi

        post_equals_before="no"
        if [ "$post_hash" = "$before_hash" ]; then
            post_equals_before="yes"
            equals_before_blocks=$((equals_before_blocks + 1))
        fi

        checked_blocks=$((checked_blocks + 1))
        echo "$logical_blk,$old_pblk,$new_pblk,$file,$offset,$before_hash,$after_hash,$hash_changed,$post_hash,$post_not_damaged,$post_equals_before" >> "$tmp_log"
    done < "$rows_file"

    mv "$tmp_log" "$c2_damage_log"
    chown "$OS_USER:$OS_USER" "$c2_damage_log"
    c2_post_hash_checked_blocks="$checked_blocks"
    c2_post_hash_not_damaged_blocks="$not_damaged_blocks"
    c2_post_hash_equals_before_blocks="$equals_before_blocks"
}

run_c2_torn_page() {
    local all_pass="yes"

    for c2_ver in "${C2_VERSIONS[@]}"; do
        local target_count remap_count updated_rows start_lsn end_lsn relpath
        local recovery_ok total_rows bad_updated_rows bad_untouched_rows
        local table_before_hash table_after_hash table_compare_equal result
        local conf_file hba_file
        local c2_before_table_dump c2_after_table_dump

        echo "================================================================="
        echo "开始处理 C2 版本: $c2_ver"
        echo "================================================================="

        c2_pg_bin="$BASE_DIR/$c2_ver/bin"
        c2_pg_data="$BASE_DIR/exp2/$c2_ver/data"
        c2_damage_log="$RESULT_DIR/damaged_blocks_${c2_ver}.csv"
        c2_before_table_dump="$RESULT_DIR/table_before_recovery_${c2_ver}.csv"
        c2_after_table_dump="$RESULT_DIR/table_after_recovery_${c2_ver}.csv"

        if [ ! -x "$c2_pg_bin/initdb" ] ||
           [ ! -x "$c2_pg_bin/pg_ctl" ] ||
           [ ! -x "$c2_pg_bin/psql" ] ||
           [ ! -x "$c2_pg_bin/pg_waldump" ]; then
            echo "[错误] PostgreSQL 二进制不存在: $c2_pg_bin"
            all_pass="no"
            continue
        fi

        case "$c2_pg_data" in
            "$BASE_DIR/exp2/$c2_ver/data") ;;
            *)
                echo "[错误] PGDATA 路径异常，拒绝删除: $c2_pg_data"
                all_pass="no"
                continue
                ;;
        esac

        c2_stop_pg

        echo "logical_blk,old_pblk,new_pblk,file,offset,before_hash,after_hash,hash_changed,post_recovery_hash,post_not_damaged,post_equals_before" > "$c2_damage_log"
        chown "$OS_USER:$OS_USER" "$c2_damage_log"

        echo "[INFO] 初始化独立的数据库目录 $c2_pg_data ..."
        mkdir -p "$(dirname "$c2_pg_data")"
        chown "$OS_USER:$OS_USER" "$(dirname "$c2_pg_data")"
        rm -rf "$c2_pg_data"
        c2_as_pg "$c2_pg_bin/initdb" -D "$c2_pg_data" >/dev/null

        echo "[INFO] 配置 PostgreSQL 参数 ..."
        conf_file="$c2_pg_data/postgresql.conf"
        cat >> "$conf_file" <<EOF
listen_addresses = '127.0.0.1'
port = $C2_PORT
max_connections = $C2_MAX_CONNECTIONS
shared_buffers = $C2_SHARED_BUFFERS
checkpoint_timeout = $C2_CHECKPOINT_TIMEOUT
checkpoint_completion_target = 0.9
max_wal_size = $C2_MAX_WAL_SIZE
min_wal_size = $C2_MIN_WAL_SIZE
wal_keep_size = $C2_WAL_KEEP_SIZE
full_page_writes = on
wal_compression = off
fsync = on
synchronous_commit = on
autovacuum = off
track_wal_io_timing = on
log_checkpoints = on
EOF

        hba_file="$c2_pg_data/pg_hba.conf"
        echo "host all all 127.0.0.1/32 trust" >> "$hba_file"
        echo "local all all trust" >> "$hba_file"
        chown "$OS_USER:$OS_USER" "$conf_file" "$hba_file"

        echo "[INFO] 启动数据库 ..."
        : > "$RESULT_DIR/server_c2_${c2_ver}.log"
        chown "$OS_USER:$OS_USER" "$RESULT_DIR/server_c2_${c2_ver}.log"
        c2_as_pg "$c2_pg_bin/pg_ctl" -D "$c2_pg_data" -l "$RESULT_DIR/server_c2_${c2_ver}.log" -w -t 120 start >/dev/null

        c2_psql_postgres -c "DROP DATABASE IF EXISTS $C2_DB_NAME;" >/dev/null
        c2_psql_postgres -c "CREATE DATABASE $C2_DB_NAME;" >/dev/null

        echo "[INFO] 创建 heap 表 rows=$C2_TABLE_ROWS ..."
        c2_psql_db > "$RESULT_DIR/load_c2_${c2_ver}.out" 2> "$RESULT_DIR/load_c2_${c2_ver}.err" <<SQL
CREATE TABLE exp2_t (
    id bigint PRIMARY KEY,
    payload text NOT NULL
) WITH (fillfactor = 70, autovacuum_enabled = false);

INSERT INTO exp2_t
SELECT g, 'before_' || g::text || '_' || repeat('x', $C2_PAYLOAD_BYTES)
FROM generate_series(1, $C2_TABLE_ROWS) AS g;

VACUUM (FREEZE, ANALYZE) exp2_t;
CHECKPOINT;
SQL

        echo "[INFO] 选择目标 heap blocks ..."
        c2_psql_db > "$RESULT_DIR/prepare_targets_c2_${c2_ver}.out" 2> "$RESULT_DIR/prepare_targets_c2_${c2_ver}.err" <<SQL
DROP TABLE IF EXISTS exp2_target_rows;
DROP TABLE IF EXISTS exp2_target_blocks;
DROP TABLE IF EXISTS exp2_updated_ids;

CREATE TABLE exp2_target_rows AS
SELECT id, split_part(trim(both '()' from ctid::text), ',', 1)::bigint AS blk
FROM exp2_t;

CREATE TABLE exp2_target_blocks AS
SELECT blk
FROM exp2_target_rows
GROUP BY blk
HAVING count(*) >= $C2_ROWS_PER_BLOCK
ORDER BY blk
LIMIT $C2_TARGET_BLOCKS;

CREATE TABLE exp2_updated_ids AS
SELECT DISTINCT ON (r.blk) r.id, r.blk
FROM exp2_target_rows r
JOIN exp2_target_blocks b ON b.blk = r.blk
ORDER BY r.blk, r.id;
SQL

        target_count=$(c2_psql_db -At -c "SELECT count(*) FROM exp2_target_blocks;" | tr -d ' ')
        if [ "$target_count" != "$C2_TARGET_BLOCKS" ]; then
            echo "[错误] 目标 heap block 数不足: target_count=$target_count expected=$C2_TARGET_BLOCKS"
            all_pass="no"
            c2_stop_pg
            rm -rf "$c2_pg_data"
            continue
        fi

        c2_psql_db -At -c "SELECT blk FROM exp2_target_blocks ORDER BY blk;" > "$RESULT_DIR/target_blocks.txt"
        c2_psql_db -At -c "SELECT id FROM exp2_updated_ids ORDER BY id;" > "$RESULT_DIR/updated_ids.txt"
        chown "$OS_USER:$OS_USER" "$RESULT_DIR/target_blocks.txt" "$RESULT_DIR/updated_ids.txt"
        relpath=$(c2_psql_db -At -c "SELECT pg_relation_filepath('exp2_t');" | tr -d ' ')

        echo "[INFO] update 目标 rows ..."
        start_lsn=$(c2_psql_postgres -At -c "SELECT pg_current_wal_insert_lsn();" | tr -d ' ')
        c2_psql_db > "$RESULT_DIR/update_c2_${c2_ver}.out" 2> "$RESULT_DIR/update_c2_${c2_ver}.err" <<SQL
WITH u AS (
    UPDATE exp2_t t
    SET payload = 'after_' || t.id::text || '_' || repeat('y', $C2_PAYLOAD_BYTES)
    FROM exp2_updated_ids s
    WHERE t.id = s.id
    RETURNING 1
)
SELECT count(*) AS updated_rows FROM u;
SQL
        updated_rows=$(awk '/^[[:space:]]*[0-9]+[[:space:]]*$/ {v=$1} END {print v}' "$RESULT_DIR/update_c2_${c2_ver}.out")
        [ -n "$updated_rows" ] || updated_rows="0"

        echo "[INFO] 保存 crash 前全表 SQL 输出 ..."
        c2_dump_table_result "$c2_before_table_dump"
        table_before_hash=$(sha256sum "$c2_before_table_dump" | awk '{print $1}')

        end_lsn=$(c2_psql_postgres -At -c "SELECT pg_current_wal_insert_lsn();" | tr -d ' ')

        echo "start_lsn=$start_lsn" > "$RESULT_DIR/wal_window.txt"
        echo "end_lsn=$end_lsn" >> "$RESULT_DIR/wal_window.txt"
        echo "relpath=$relpath" >> "$RESULT_DIR/wal_window.txt"
        chown "$OS_USER:$OS_USER" "$RESULT_DIR/wal_window.txt"

        echo "[INFO] 解析 WAL damage facts，damage 目标取 new_pblk/shift target_slot ..."
        c2_collect_remap_facts "$start_lsn" "$end_lsn"
        remap_count=$(awk 'NR > 1 {n++} END {print n + 0}' "$C2_REMAP_FACTS")

        echo "[INFO] immediate crash ..."
        c2_as_pg "$c2_pg_bin/pg_ctl" -D "$c2_pg_data" stop -m immediate >/dev/null 2>&1
        sleep 2

        echo "[INFO] 数据库停库状态下破坏 WAL damage target pblk ..."
        c2_damaged_blocks=0
        c2_hash_changed_blocks=0
        c2_post_hash_checked_blocks=0
        c2_post_hash_not_damaged_blocks=0
        c2_post_hash_equals_before_blocks=0
        : > "$RESULT_DIR/damage_counts.tmp"
        c2_damage_remap_new_pblks "$relpath"

        echo "[INFO] restart 触发 crash recovery ..."
        recovery_ok="yes"
        if ! c2_as_pg "$c2_pg_bin/pg_ctl" -D "$c2_pg_data" -l "$RESULT_DIR/server_c2_${c2_ver}.log" -w -t 120 start >/dev/null 2>&1; then
            recovery_ok="no"
        fi

        if [ "$recovery_ok" = "yes" ]; then
            echo "[INFO] recovery 完成后停库，记录 post_recovery_hash ..."
            if c2_as_pg "$c2_pg_bin/pg_ctl" -D "$c2_pg_data" stop -m fast -w -t 120 >/dev/null 2>&1; then
                c2_collect_post_recovery_hashes
                echo "[INFO] 重新启动数据库做 SQL oracle ..."
                if ! c2_as_pg "$c2_pg_bin/pg_ctl" -D "$c2_pg_data" -l "$RESULT_DIR/server_c2_${c2_ver}.log" -w -t 120 start >/dev/null 2>&1; then
                    recovery_ok="no"
                fi
            else
                recovery_ok="no"
            fi
        fi

        total_rows="-"
        bad_updated_rows="-"
        bad_untouched_rows="-"
        table_after_hash="-"
        table_compare_equal="no"
        if [ "$recovery_ok" = "yes" ]; then
            echo "[INFO] 保存 recovery 后全表 SQL 输出并对比 ..."
            c2_dump_table_result "$c2_after_table_dump"
            table_after_hash=$(sha256sum "$c2_after_table_dump" | awk '{print $1}')
            if cmp -s "$c2_before_table_dump" "$c2_after_table_dump"; then
                table_compare_equal="yes"
            else
                table_compare_equal="no"
            fi

            total_rows=$(c2_psql_db -At -c "SELECT count(*) FROM exp2_t;" | tr -d ' ')
            bad_updated_rows=$(c2_psql_db -At -c "SELECT count(*) FROM exp2_t t JOIN exp2_updated_ids u ON u.id = t.id WHERE t.payload <> 'after_' || t.id::text || '_' || repeat('y', $C2_PAYLOAD_BYTES);" | tr -d ' ')
            bad_untouched_rows=$(c2_psql_db -At -c "SELECT count(*) FROM exp2_t t WHERE NOT EXISTS (SELECT 1 FROM exp2_updated_ids u WHERE u.id = t.id) AND t.payload <> 'before_' || t.id::text || '_' || repeat('x', $C2_PAYLOAD_BYTES);" | tr -d ' ')
        fi

        result="FAIL"
        if [ "$target_count" = "$C2_TARGET_BLOCKS" ] &&
           [ "$remap_count" = "$C2_TARGET_BLOCKS" ] &&
           [ "$updated_rows" = "$C2_TARGET_BLOCKS" ] &&
           [ "$c2_damaged_blocks" = "$C2_TARGET_BLOCKS" ] &&
           [ "$c2_hash_changed_blocks" = "$C2_TARGET_BLOCKS" ] &&
           [ "$c2_post_hash_checked_blocks" = "$C2_TARGET_BLOCKS" ] &&
           [ "$c2_post_hash_not_damaged_blocks" = "$C2_TARGET_BLOCKS" ] &&
           [ "$recovery_ok" = "yes" ] &&
           [ "$total_rows" = "$C2_TABLE_ROWS" ] &&
           [ "$bad_updated_rows" = "0" ] &&
           [ "$bad_untouched_rows" = "0" ] &&
           [ "$table_compare_equal" = "yes" ]; then
            result="PASS"
        fi

        echo "$c2_ver,C2,$C2_TARGET_BLOCKS,$remap_count,$updated_rows,$c2_damaged_blocks,$c2_hash_changed_blocks,$c2_post_hash_checked_blocks,$c2_post_hash_not_damaged_blocks,$c2_post_hash_equals_before_blocks,$C2_DAMAGE_BYTES,wal_target_pblk,$recovery_ok,$total_rows,$bad_updated_rows,$bad_untouched_rows,$table_before_hash,$table_after_hash,$table_compare_equal,$result" >> "$C2_RESULT_FILE"
        chown "$OS_USER:$OS_USER" "$C2_RESULT_FILE" "$c2_damage_log" "$c2_before_table_dump" "$c2_after_table_dump" 2>/dev/null
        record_summary "C2" "$c2_ver" "$result" "$C2_RESULT_FILE" "target=$C2_TARGET_BLOCKS;remap=$remap_count;updated=$updated_rows;damaged=$c2_damaged_blocks;hash_changed=$c2_hash_changed_blocks;post_checked=$c2_post_hash_checked_blocks;post_not_damaged=$c2_post_hash_not_damaged_blocks;recovery_ok=$recovery_ok;total_rows=$total_rows;bad_updated=$bad_updated_rows;bad_untouched=$bad_untouched_rows;table_equal=$table_compare_equal"

        if [ "$result" != "PASS" ]; then
            all_pass="no"
        fi

        echo "================================================================="
        echo "实验2 Linux C2 torn-page 完成。"
        echo "summary: $C2_RESULT_FILE"
        echo "damage_log: $c2_damage_log"
        cat "$C2_RESULT_FILE"

        c2_stop_pg
        echo "[INFO] 清理数据库目录 $c2_pg_data ..."
        rm -rf "$c2_pg_data"
    done

    if [ "$all_pass" = "yes" ]; then
        return 0
    fi

    return 1
}

as_pg() {
    sudo -u "$OS_USER" env LD_LIBRARY_PATH="$C3_PG_BIN/../lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$@"
}

c3_psql_postgres() {
    as_pg "$C3_PG_BIN/psql" -h 127.0.0.1 -p "$C3_PORT" -d postgres -v ON_ERROR_STOP=1 "$@"
}

c3_psql_db() {
    as_pg "$C3_PG_BIN/psql" -h 127.0.0.1 -p "$C3_PORT" -d "$C3_DB_NAME" -v ON_ERROR_STOP=1 "$@"
}

c3_stop_pg() {
    as_pg "$C3_PG_BIN/pg_ctl" -D "$C3_PG_DATA" stop -m immediate >/dev/null 2>&1
    pkill -u "$OS_USER" -f "$C3_PG_DATA" 2>/dev/null
    sleep 2
}

wait_for_file() {
    local path="$1"
    local timeout_secs="$2"
    local waited=0

    while [ "$waited" -lt "$timeout_secs" ]; do
        if [ -f "$path" ]; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    return 1
}

wait_for_log_marker() {
    local pid="$1"
    local log_file="$2"
    local marker="$3"
    local timeout_secs="$4"
    local waited=0

    while [ "$waited" -lt "$timeout_secs" ]; do
        if grep -q "$marker" "$log_file"; then
            wait "$pid"
            return $?
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid"
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done

    return 124
}

kill_and_wait() {
    local pid="$1"

    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    fi
}

poll_sql_until() {
    local sql="$1"
    local expected="$2"
    local timeout_secs="$3"
    local log_file="$4"
    local waited=0
    local value

    while [ "$waited" -lt "$timeout_secs" ]; do
        value=$(c3_psql_postgres -At -c "$sql" 2>>"$log_file" | tr -d '[:space:]')
        echo "waited=${waited}s value=$value" >> "$log_file"
        if [ "$value" = "$expected" ]; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    return 1
}

record_c3_result() {
    local pause_entered="$1"
    local checkpoint_waited="$2"
    local checkpoint_blocked="$3"
    local update_completed="$4"
    local checkpoint_completed="$5"
    local recovery_ok="$6"
    local signature_equal="$7"
    local updated_rows="$8"
    local result="$9"

    echo "C3,$pause_entered,$checkpoint_waited,$checkpoint_blocked,$update_completed,$checkpoint_completed,$recovery_ok,$signature_equal,$updated_rows,$result" >> "$C3_RESULT_FILE"
    chown "$OS_USER:$OS_USER" "$C3_RESULT_FILE"
    record_summary "C3" "checkpoint_publication" "$result" "$C3_RESULT_FILE" "pause_entered=$pause_entered;checkpoint_waited=$checkpoint_waited;checkpoint_blocked=$checkpoint_blocked;update_completed=$update_completed;checkpoint_completed=$checkpoint_completed;recovery_ok=$recovery_ok;signature_equal=$signature_equal;updated_rows=$updated_rows"
}

run_c3_checkpoint_publication() {
    local server_log="$RESULT_DIR/c3_server.log"
    local setup_log="$RESULT_DIR/c3_setup.log"
    local update_log="$RESULT_DIR/c3_update.log"
    local checkpoint_log="$RESULT_DIR/c3_checkpoint.log"
    local wait_log="$RESULT_DIR/c3_wait_event.log"
    local oracle_log="$RESULT_DIR/c3_oracle.log"
    local pause_marker="$C3_PG_DATA/$C3_PAUSE_MARKER"
    local release_marker="$C3_PG_DATA/$C3_RELEASE_MARKER"
    local pause_entered="no"
    local checkpoint_waited="no"
    local checkpoint_blocked="no"
    local update_completed="no"
    local checkpoint_completed="no"
    local recovery_ok="no"
    local signature_equal="no"
    local updated_rows="-"
    local signature_after_update
    local signature_after_recovery
    local update_pid
    local checkpoint_pid

    echo "[C3] checkpoint publication through PostgreSQL interfaces"

    if [ ! -x "$C3_PG_BIN/initdb" ] ||
       [ ! -x "$C3_PG_BIN/pg_ctl" ] ||
       [ ! -x "$C3_PG_BIN/psql" ]; then
        block_step "C3" "missing chunk PostgreSQL binaries under $C3_PG_BIN"
        record_c3_result "$pause_entered" "$checkpoint_waited" "$checkpoint_blocked" "$update_completed" "$checkpoint_completed" "$recovery_ok" "$signature_equal" "$updated_rows" "BLOCKED"
        return 1
    fi

    case "$C3_PG_DATA" in
        "$BASE_DIR/exp2/c3_"*"/data") ;;
        *)
            block_step "C3" "unsafe C3_PG_DATA path: $C3_PG_DATA"
            record_c3_result "$pause_entered" "$checkpoint_waited" "$checkpoint_blocked" "$update_completed" "$checkpoint_completed" "$recovery_ok" "$signature_equal" "$updated_rows" "BLOCKED"
            return 1
            ;;
    esac

    c3_stop_pg
    mkdir -p "$(dirname "$C3_PG_DATA")"
    chown "$OS_USER:$OS_USER" "$(dirname "$C3_PG_DATA")"
    rm -rf "$C3_PG_DATA"

    if ! as_pg "$C3_PG_BIN/initdb" -D "$C3_PG_DATA" > "$setup_log" 2>&1; then
        chown "$OS_USER:$OS_USER" "$setup_log"
        record_c3_result "$pause_entered" "$checkpoint_waited" "$checkpoint_blocked" "$update_completed" "$checkpoint_completed" "$recovery_ok" "$signature_equal" "$updated_rows" "FAIL"
        return 1
    fi

    cat >> "$C3_PG_DATA/postgresql.conf" <<EOF
listen_addresses = '127.0.0.1'
port = $C3_PORT
wal_level = replica
autovacuum = off
full_page_writes = on
wal_log_hints = off
shared_buffers = '256MB'
max_wal_size = '4GB'
min_wal_size = '1GB'
checkpoint_timeout = '1h'
log_checkpoints = on
fsync = on
synchronous_commit = on
EOF
    echo "host all all 127.0.0.1/32 trust" >> "$C3_PG_DATA/pg_hba.conf"
    echo "local all all trust" >> "$C3_PG_DATA/pg_hba.conf"
    chown "$OS_USER:$OS_USER" "$C3_PG_DATA/postgresql.conf" "$C3_PG_DATA/pg_hba.conf"

    : > "$server_log"
    chown "$OS_USER:$OS_USER" "$server_log"
    if ! as_pg "$C3_PG_BIN/pg_ctl" -D "$C3_PG_DATA" -l "$server_log" -w -t 120 start >> "$setup_log" 2>&1; then
        chown "$OS_USER:$OS_USER" "$setup_log" "$server_log"
        record_c3_result "$pause_entered" "$checkpoint_waited" "$checkpoint_blocked" "$update_completed" "$checkpoint_completed" "$recovery_ok" "$signature_equal" "$updated_rows" "FAIL"
        return 1
    fi

    if ! c3_psql_postgres -At -c "SHOW umbra_exp2_c3_pause;" > "$RESULT_DIR/c3_pause_guc.out" 2> "$RESULT_DIR/c3_pause_guc.err"; then
        chown "$OS_USER:$OS_USER" "$RESULT_DIR/c3_pause_guc.out" "$RESULT_DIR/c3_pause_guc.err"
        block_step "C3" "missing umbra_exp2_c3_pause interface"
        record_c3_result "$pause_entered" "$checkpoint_waited" "$checkpoint_blocked" "$update_completed" "$checkpoint_completed" "$recovery_ok" "$signature_equal" "$updated_rows" "BLOCKED"
        c3_stop_pg
        return 1
    fi

    c3_psql_postgres -c "DROP DATABASE IF EXISTS $C3_DB_NAME;" >> "$setup_log" 2>&1
    c3_psql_postgres -c "CREATE DATABASE $C3_DB_NAME;" >> "$setup_log" 2>&1

    if ! c3_psql_db > "$setup_log.sql" 2>&1 <<SQL
CREATE TABLE umb_c3_t (
    id bigint PRIMARY KEY,
    payload text NOT NULL
) WITH (fillfactor = 70, autovacuum_enabled = false);
INSERT INTO umb_c3_t
SELECT g, 'before_' || g::text || '_' || repeat('x', $C3_PAYLOAD_BYTES)
FROM generate_series(1, $C3_TABLE_ROWS) AS g;
VACUUM (FREEZE, ANALYZE) umb_c3_t;
DROP TABLE IF EXISTS umb_c3_target_rows;
DROP TABLE IF EXISTS umb_c3_target_blocks;
DROP TABLE IF EXISTS umb_c3_updated_ids;
CREATE TABLE umb_c3_target_rows AS
SELECT id, split_part(trim(both '()' from ctid::text), ',', 1)::bigint AS blk
FROM umb_c3_t;
CREATE TABLE umb_c3_target_blocks AS
SELECT blk
FROM umb_c3_target_rows
GROUP BY blk
ORDER BY blk
LIMIT $C3_TARGET_BLOCKS;
CREATE TABLE umb_c3_updated_ids AS
SELECT DISTINCT ON (r.blk) r.id, r.blk
FROM umb_c3_target_rows r
JOIN umb_c3_target_blocks b ON b.blk = r.blk
ORDER BY r.blk, r.id;
CHECKPOINT;
SQL
    then
        chown "$OS_USER:$OS_USER" "$setup_log" "$setup_log.sql"
        record_c3_result "$pause_entered" "$checkpoint_waited" "$checkpoint_blocked" "$update_completed" "$checkpoint_completed" "$recovery_ok" "$signature_equal" "$updated_rows" "FAIL"
        c3_stop_pg
        return 1
    fi

    rm -f "$pause_marker" "$release_marker"

    (
        printf "SET umbra_exp2_c3_pause = on;\n"
        printf "UPDATE umb_c3_t\n"
        printf "SET payload = 'after_' || umb_c3_t.id::text || '_' || repeat('y', $C3_PAYLOAD_BYTES)\n"
        printf "FROM umb_c3_updated_ids s\n"
        printf "WHERE umb_c3_t.id = s.id;\n"
        printf '%s\n' '\echo update_done'
    ) | c3_psql_db > "$update_log" 2>&1 &
    update_pid=$!

    if wait_for_file "$pause_marker" "$C3_WAIT_TIMEOUT"; then
        pause_entered="yes"
    else
        block_step "C3" "pause marker not created: $pause_marker"
        record_c3_result "$pause_entered" "$checkpoint_waited" "$checkpoint_blocked" "$update_completed" "$checkpoint_completed" "$recovery_ok" "$signature_equal" "$updated_rows" "BLOCKED"
        kill_and_wait "$update_pid"
        c3_stop_pg
        return 1
    fi

    (
        printf "CHECKPOINT;\n"
        printf '%s\n' '\echo checkpoint_done'
    ) | c3_psql_postgres > "$checkpoint_log" 2>&1 &
    checkpoint_pid=$!

    if poll_sql_until "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE backend_type = 'checkpointer' AND wait_event = 'CheckpointDelayStart');" "t" "$C3_WAIT_TIMEOUT" "$wait_log"; then
        checkpoint_waited="yes"
    else
        record_c3_result "$pause_entered" "$checkpoint_waited" "$checkpoint_blocked" "$update_completed" "$checkpoint_completed" "$recovery_ok" "$signature_equal" "$updated_rows" "FAIL"
        kill_and_wait "$update_pid"
        kill_and_wait "$checkpoint_pid"
        c3_stop_pg
        return 1
    fi

    sleep 2
    if kill -0 "$checkpoint_pid" 2>/dev/null && ! grep -q "checkpoint_done" "$checkpoint_log"; then
        checkpoint_blocked="yes"
    else
        record_c3_result "$pause_entered" "$checkpoint_waited" "$checkpoint_blocked" "$update_completed" "$checkpoint_completed" "$recovery_ok" "$signature_equal" "$updated_rows" "FAIL"
        kill_and_wait "$update_pid"
        kill_and_wait "$checkpoint_pid"
        c3_stop_pg
        return 1
    fi

    : > "$release_marker"
    chown "$OS_USER:$OS_USER" "$release_marker"

    if wait_for_log_marker "$update_pid" "$update_log" "update_done" "$C3_STEP_TIMEOUT"; then
        update_completed="yes"
    else
        record_c3_result "$pause_entered" "$checkpoint_waited" "$checkpoint_blocked" "$update_completed" "$checkpoint_completed" "$recovery_ok" "$signature_equal" "$updated_rows" "FAIL"
        kill_and_wait "$update_pid"
        kill_and_wait "$checkpoint_pid"
        c3_stop_pg
        return 1
    fi

    signature_after_update=$(c3_psql_db -At -c "SELECT count(*) || '|' || sum(id)::bigint || '|' || md5(string_agg(id::text || ':' || payload, ',' ORDER BY id)) FROM umb_c3_t;" | tr -d '[:space:]')
    echo "$signature_after_update" > "$RESULT_DIR/c3_signature_after_update.txt"
    chown "$OS_USER:$OS_USER" "$RESULT_DIR/c3_signature_after_update.txt"

    if wait_for_log_marker "$checkpoint_pid" "$checkpoint_log" "checkpoint_done" "$C3_STEP_TIMEOUT"; then
        checkpoint_completed="yes"
    else
        record_c3_result "$pause_entered" "$checkpoint_waited" "$checkpoint_blocked" "$update_completed" "$checkpoint_completed" "$recovery_ok" "$signature_equal" "$updated_rows" "FAIL"
        kill_and_wait "$checkpoint_pid"
        c3_stop_pg
        return 1
    fi

    as_pg "$C3_PG_BIN/pg_ctl" -D "$C3_PG_DATA" stop -m immediate >/dev/null 2>&1
    if as_pg "$C3_PG_BIN/pg_ctl" -D "$C3_PG_DATA" -l "$server_log" -w -t 120 start >> "$oracle_log" 2>&1; then
        recovery_ok="yes"
    else
        record_c3_result "$pause_entered" "$checkpoint_waited" "$checkpoint_blocked" "$update_completed" "$checkpoint_completed" "$recovery_ok" "$signature_equal" "$updated_rows" "FAIL"
        c3_stop_pg
        return 1
    fi

    signature_after_recovery=$(c3_psql_db -At -c "SELECT count(*) || '|' || sum(id)::bigint || '|' || md5(string_agg(id::text || ':' || payload, ',' ORDER BY id)) FROM umb_c3_t;" | tr -d '[:space:]')
    echo "$signature_after_recovery" > "$RESULT_DIR/c3_signature_after_recovery.txt"
    updated_rows=$(c3_psql_db -At -c "SELECT count(*) FROM umb_c3_t WHERE payload = 'after_' || id::text || '_' || repeat('y', $C3_PAYLOAD_BYTES);" | tr -d '[:space:]')
    {
        echo "signature_after_update=$signature_after_update"
        echo "signature_after_recovery=$signature_after_recovery"
        echo "updated_rows=$updated_rows"
    } >> "$oracle_log"
    chown "$OS_USER:$OS_USER" "$RESULT_DIR/c3_signature_after_recovery.txt" "$oracle_log"

    if [ "$signature_after_recovery" = "$signature_after_update" ]; then
        signature_equal="yes"
    fi

    if [ "$pause_entered" = "yes" ] &&
       [ "$checkpoint_waited" = "yes" ] &&
       [ "$checkpoint_blocked" = "yes" ] &&
       [ "$update_completed" = "yes" ] &&
       [ "$checkpoint_completed" = "yes" ] &&
       [ "$recovery_ok" = "yes" ] &&
       [ "$signature_equal" = "yes" ] &&
       [ "$updated_rows" = "$C3_TARGET_BLOCKS" ]; then
        record_c3_result "$pause_entered" "$checkpoint_waited" "$checkpoint_blocked" "$update_completed" "$checkpoint_completed" "$recovery_ok" "$signature_equal" "$updated_rows" "PASS"
        c3_stop_pg
        return 0
    fi

    record_c3_result "$pause_entered" "$checkpoint_waited" "$checkpoint_blocked" "$update_completed" "$checkpoint_completed" "$recovery_ok" "$signature_equal" "$updated_rows" "FAIL"
    c3_stop_pg
    return 1
}

if ! run_c2_torn_page 2>&1 | tee "$RESULT_DIR/c2_torn_page.log"; then
    chown "$OS_USER:$OS_USER" "$RESULT_FILE"
    echo "C2 failed; not running C3. Summary: $RESULT_FILE"
    exit 1
fi

if ! run_c3_checkpoint_publication; then
    chown "$OS_USER:$OS_USER" "$RESULT_FILE"
    echo "C3 failed. Summary: $RESULT_FILE"
    exit 1
fi

chown "$OS_USER:$OS_USER" "$RESULT_FILE"
echo "Exp2 C2+C3 chunk run complete. Summary: $RESULT_FILE"
