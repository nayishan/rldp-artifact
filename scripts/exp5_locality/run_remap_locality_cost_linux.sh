#!/bin/bash

# ==============================================================================
# Config: Linux runner, path style follows experiment 5.
# ==============================================================================
OS_USER="jiamingwei"
BASE_DIR="/home/jiamingwei"
PG_INSTALL_ROOT="$BASE_DIR"
PGDATA_ROOT="$BASE_DIR"
PG_PORT=55437
DB_NAME="exp5_locality"

VERSIONS=("mdonrelease" "chunk")
IO_METHOD="sync"

TABLE_ROWS=80000000
PAYLOAD_BYTES=200
FILLFACTOR=100
UPDATE_MODULO=2
UPDATE_REMAINDER=0

SHARED_BUFFERS="50GB"
MAX_CONNECTIONS=200
CHECKPOINT_TIMEOUT="1d"
MAX_WAL_SIZE="100GB"
MIN_WAL_SIZE="4GB"
WAL_KEEP_SIZE="64GB"

RESULT_DIR="$BASE_DIR/exp5/results"
RESULT_FILE="$RESULT_DIR/exp5_remap_locality_results.txt"

MAP_BLCKSZ=8192
MAP_SEG_BLOCKS=131072
# Chunk active-slot bytes start after the same three metadata blocks that
# precede the map payload in the existing offline map reader.
CHUNK_SLOT_META_START_BLOCK=3
CHUNK_SLOT_BITS=2
CHUNK_ACTIVE_SLOTS=3

# ==============================================================================
# Main
# ==============================================================================

if [ "$(id -u)" != "0" ]; then
   echo "[ERROR] run as root, required for PGDATA cleanup and drop_caches."
   exit 1
fi

mkdir -p "$RESULT_DIR"
chown $OS_USER:$OS_USER "$RESULT_DIR"

cat > "$RESULT_FILE" <<EOF
[sync_checkpoint]
version,label,table_rows,table_bytes,table_blocks,target_blocks,updated_rows,updated_block_fraction,post_checkpoint_elapsed_ms,post_checkpoint_buffers_written,post_checkpoint_write_time_ms,post_checkpoint_sync_time_ms,result

[sync_scan]
version,label,phase,wall_ms,execution_time_ms,seqscan_seen,shared_read_blocks,result

[sync_map_compare]
version,label,table_blocks,target_blocks,remapped_blocks,remapped_block_fraction,target_remapped_blocks,target_hit_rate,extra_remapped_blocks,extra_remap_rate,invalid_before,invalid_after

[sync_evidence]
version,label,fs_map_bytes_after,fs_map_allocated_bytes_after,before_map,after_map,target_blocks_file
EOF
chown $OS_USER:$OS_USER "$RESULT_FILE"

as_pg() {
    sudo -u $OS_USER env LD_LIBRARY_PATH="$PG_BIN/../lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$@"
}

psql_db() {
    as_pg "$PG_BIN/psql" -h 127.0.0.1 -p "$PG_PORT" -d "$DB_NAME" -v ON_ERROR_STOP=1 "$@"
}

psql_scalar() {
    psql_db -At -c "$1" | tail -n 1 | tr -d '[:space:]'
}

stop_pg() {
    as_pg "$PG_BIN/pg_ctl" -D "$PG_DATA" stop -m immediate >/dev/null 2>&1
    pkill -u $OS_USER -f "$PG_DATA" 2>/dev/null
    sleep 2
}

drop_os_caches() {
    sync
    echo 3 > /proc/sys/vm/drop_caches
}

insert_before_section() {
    local section="$1"
    local row="$2"

    sed -i "/^\\[$section\\]/i $row" "$RESULT_FILE"
    chown $OS_USER:$OS_USER "$RESULT_FILE"
}

append_checkpoint_row() {
    insert_before_section "sync_scan" "$1"
}

append_scan_row() {
    insert_before_section "sync_map_compare" "$1"
}

append_map_compare_row() {
    insert_before_section "sync_evidence" "$1"
}

append_evidence_row() {
    echo "$1" >> "$RESULT_FILE"
    chown $OS_USER:$OS_USER "$RESULT_FILE"
}

resolve_variant() {
    if [ "$ver" = "mdonrelease" ]; then
        LABEL="md_fpw_on"
        FULL_PAGE_WRITES="on"
        EXTRA_CONF=""
    elif [ "$ver" = "chunk" ]; then
        LABEL="chunk_fpw_on"
        FULL_PAGE_WRITES="on"
        EXTRA_CONF=""
    else
        echo "[ERROR] unknown version: $ver"
        exit 1
    fi
}

checkpoint_stats_line() {
    psql_db -At -F ',' -c "SELECT buffers_written, write_time, sync_time FROM pg_stat_checkpointer;" | tail -n 1
}

diff3() {
    local before="$1"
    local after="$2"
    local b1 b2 b3 a1 a2 a3

    IFS=, read -r b1 b2 b3 <<< "$before"
    IFS=, read -r a1 a2 a3 <<< "$after"

    awk -v a1="$a1" -v b1="$b1" -v a2="$a2" -v b2="$b2" -v a3="$a3" -v b3="$b3" '
        BEGIN { printf "%.0f,%.3f,%.3f", a1 - b1, a2 - b2, a3 - b3 }
    '
}

collect_map_file_sizes() {
    local relpath="$1"
    local parent base path
    local bytes=0
    local allocated=0

    if [ -z "$relpath" ]; then
        echo "0,0"
        return
    fi

    parent="$PG_DATA/$(dirname "$relpath")"
    base="$(basename "$relpath")_map"

    for path in "$parent/$base" "$parent/$base".[0-9]*; do
        if [ -e "$path" ]; then
            bytes=$((bytes + $(stat -c %s "$path")))
            allocated=$((allocated + $(stat -c %b "$path") * 512))
        fi
    done

    echo "$bytes,$allocated"
}

prepare_table_and_targets() {
    echo "[INFO] create table: rows=$TABLE_ROWS fillfactor=$FILLFACTOR ..."
    psql_db >/dev/null <<SQL
SET client_min_messages TO warning;
DROP TABLE IF EXISTS exp5_update_targets;
DROP TABLE IF EXISTS exp5_remap_locality;
CREATE TABLE exp5_remap_locality (
    id bigint PRIMARY KEY,
    marker integer NOT NULL DEFAULT 0,
    payload text NOT NULL
) WITH (fillfactor = $FILLFACTOR, autovacuum_enabled = false);
ALTER TABLE exp5_remap_locality ALTER COLUMN payload SET STORAGE PLAIN;
INSERT INTO exp5_remap_locality(id, marker, payload)
SELECT g, 0, 'before_' || g::text || '_' || repeat('x', $PAYLOAD_BYTES)
FROM generate_series(1, $TABLE_ROWS) AS g;
VACUUM (FREEZE, ANALYZE) exp5_remap_locality;
CREATE UNLOGGED TABLE exp5_update_targets AS
SELECT DISTINCT ON (blk) id, blk
FROM (
    SELECT id, split_part(trim(both '()' from ctid::text), ',', 1)::bigint AS blk
    FROM exp5_remap_locality
) s
WHERE (blk % $UPDATE_MODULO) = $UPDATE_REMAINDER
ORDER BY blk, id;
CREATE UNIQUE INDEX exp5_update_targets_blk_idx ON exp5_update_targets(blk);
CREATE UNIQUE INDEX exp5_update_targets_id_idx ON exp5_update_targets(id);
ANALYZE exp5_update_targets;
CHECKPOINT;
SQL
}

run_scan() {
    local phase="$1"
    local out_file="$RESULT_DIR/${ver}_${io_method}_${phase}_scan.out"
    local err_file="$RESULT_DIR/${ver}_${io_method}_${phase}_scan.err"
    local start_ms end_ms wall_ms execution_time seqscan_seen shared_read_blocks result

    echo "[INFO] $ver $io_method $phase cold seqscan ..."
    as_pg "$PG_BIN/pg_ctl" -D "$PG_DATA" stop -m fast -t 600 >/dev/null
    as_pg "$PG_BIN/pg_ctl" -D "$PG_DATA" -l "$PG_DATA/logfile" -w -t 120 start >/dev/null
    drop_os_caches

    start_ms=$(date +%s%3N)
    psql_db > "$out_file" 2> "$err_file" <<SQL
SET enable_indexscan = off;
SET enable_bitmapscan = off;
SET enable_seqscan = on;
SET synchronize_seqscans = off;
EXPLAIN (ANALYZE, BUFFERS, TIMING, SUMMARY)
SELECT count(*) FROM exp5_remap_locality WHERE payload IS NOT NULL;
SQL
    end_ms=$(date +%s%3N)
    wall_ms=$((end_ms - start_ms))

    execution_time=$(awk '/Execution Time:/ {print $3}' "$out_file" | tail -n 1)
    [ -n "$execution_time" ] || execution_time="-"

    if grep -q "Seq Scan.*exp5_remap_locality" "$out_file"; then
        seqscan_seen="yes"
    else
        seqscan_seen="no"
    fi

    shared_read_blocks=$(awk '
        /Buffers:/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^read=/) {
                    split($i, a, "=");
                    if (a[2] > n) n = a[2];
                }
            }
        }
        END {
            if (n == "") print "-";
            else print n;
        }
    ' "$out_file")

    result="FAIL"
    if [ "$seqscan_seen" = "yes" ] && [ "$execution_time" != "-" ]; then
        result="PASS"
    fi

    append_scan_row "$ver,$LABEL,$phase,$wall_ms,$execution_time,$seqscan_seen,$shared_read_blocks,$result"
    chown $OS_USER:$OS_USER "$out_file" "$err_file"
}

copy_map_snapshot() {
    local phase="$1"
    local relpath map_path copied_map_path path suffix

    relpath=$(psql_scalar "SELECT pg_relation_filepath('exp5_remap_locality');")
    map_path="$PG_DATA/${relpath}_map"
    copied_map_path="$RESULT_DIR/${ver}_${io_method}_${phase}.map"

    echo "[INFO] copy map snapshot: $phase ..."
    as_pg "$PG_BIN/pg_ctl" -D "$PG_DATA" stop -m fast -t 600 >/dev/null

    if [ -s "$map_path" ]; then
        cp "$map_path" "$copied_map_path"
        for path in "$map_path".[0-9]*; do
            if [ -e "$path" ]; then
                suffix="${path##*.}"
                cp "$path" "$copied_map_path.$suffix"
            fi
        done
        chown $OS_USER:$OS_USER "$copied_map_path" "$copied_map_path".[0-9]* 2>/dev/null || true
    else
        copied_map_path="-"
        echo "[WARN] map file missing or empty: $map_path"
    fi

    LAST_COPIED_MAP_PATH="$copied_map_path"
    as_pg "$PG_BIN/pg_ctl" -D "$PG_DATA" -l "$PG_DATA/logfile" -w -t 120 start >/dev/null
}

emit_invalid_entries() {
    local count="$1"

    awk -v n="$count" 'BEGIN { for (i = 0; i < n; i++) print 4294967295 }'
}

emit_zero_slot_values() {
    local count="$1"

    awk -v n="$count" 'BEGIN { for (i = 0; i < n; i++) print 0 }'
}

extract_main_map_values() {
    local map_file="$1"
    local out_file="$2"
    local blksz=$MAP_BLCKSZ
    local entries_per_page=2048
    local main_pages_per_group=8192
    local group_total_pages=8194
    local seg_blocks=$MAP_SEG_BLOCKS
    local warnings_file="$RESULT_DIR/${ver}_${io_method}_map_extract_warnings.log"
    local map_pages page_idx group page_in_group file_block segment segment_block offset
    local remaining take segment_file file_size available read_entries read_bytes missing_entries

    : > "$out_file"
    map_pages=$(( (TABLE_BLOCKS + entries_per_page - 1) / entries_per_page ))

    page_idx=0
    remaining=$TABLE_BLOCKS
    while [ "$page_idx" -lt "$map_pages" ]; do
        group=$(( page_idx / main_pages_per_group ))
        page_in_group=$(( page_idx % main_pages_per_group ))
        file_block=$(( 1 + group * group_total_pages + 2 + page_in_group ))
        segment=$(( file_block / seg_blocks ))
        segment_block=$(( file_block % seg_blocks ))
        offset=$(( segment_block * blksz ))

        if [ "$segment" -eq 0 ]; then
            segment_file="$map_file"
        else
            segment_file="$map_file.$segment"
        fi

        if [ "$remaining" -lt "$entries_per_page" ]; then
            take=$remaining
        else
            take=$entries_per_page
        fi

        if [ ! -f "$segment_file" ]; then
            echo "[WARN] missing map segment: file=$segment_file entries=$take" >> "$warnings_file"
            emit_invalid_entries "$take" >> "$out_file"
        else
            file_size=$(wc -c < "$segment_file" | tr -d ' ')
            if [ "$file_size" -le "$offset" ]; then
                echo "[WARN] short map segment: file=$segment_file offset=$offset size=$file_size entries=$take" >> "$warnings_file"
                emit_invalid_entries "$take" >> "$out_file"
            else
                available=$(( file_size - offset ))
                read_entries=$(( available / 4 ))
                if [ "$read_entries" -gt "$take" ]; then
                    read_entries=$take
                fi
                read_bytes=$(( read_entries * 4 ))

                if [ "$read_bytes" -gt 0 ]; then
                    od -An -v -tu4 -j "$offset" -N "$read_bytes" "$segment_file" \
                        | awk '{ for (i = 1; i <= NF; i++) print $i }' >> "$out_file"
                fi

                if [ "$read_entries" -lt "$take" ]; then
                    missing_entries=$(( take - read_entries ))
                    echo "[WARN] partial map page: file=$segment_file offset=$offset size=$file_size read_entries=$read_entries missing_entries=$missing_entries" >> "$warnings_file"
                    emit_invalid_entries "$missing_entries" >> "$out_file"
                fi
            fi
        fi

        remaining=$(( remaining - take ))
        page_idx=$(( page_idx + 1 ))
    done

    chown $OS_USER:$OS_USER "$out_file" "$warnings_file" 2>/dev/null || true
}

extract_chunk_active_slot_values() {
    local map_file="$1"
    local out_file="$2"
    local blksz=$MAP_BLCKSZ
    local seg_blocks=$MAP_SEG_BLOCKS
    local slot_bits=$CHUNK_SLOT_BITS
    local slots_per_byte=$((8 / CHUNK_SLOT_BITS))
    local segment_bytes=$((MAP_BLCKSZ * MAP_SEG_BLOCKS))
    local warnings_file="$RESULT_DIR/${ver}_${io_method}_chunk_slot_extract_warnings.log"
    local remaining_slots total_bytes remaining_bytes byte_pos segment segment_offset
    local segment_file take_bytes slots_for_take file_size available read_bytes slots_for_read zero_slots

    : > "$out_file"
    : > "$warnings_file"

    remaining_slots=$TABLE_BLOCKS
    total_bytes=$(( (TABLE_BLOCKS + slots_per_byte - 1) / slots_per_byte ))
    remaining_bytes=$total_bytes
    byte_pos=$((CHUNK_SLOT_META_START_BLOCK * blksz))

    while [ "$remaining_slots" -gt 0 ]; do
        segment=$(( byte_pos / segment_bytes ))
        segment_offset=$(( byte_pos % segment_bytes ))
        take_bytes=$(( segment_bytes - segment_offset ))
        if [ "$take_bytes" -gt "$remaining_bytes" ]; then
            take_bytes=$remaining_bytes
        fi

        slots_for_take=$(( take_bytes * slots_per_byte ))
        if [ "$slots_for_take" -gt "$remaining_slots" ]; then
            slots_for_take=$remaining_slots
        fi

        if [ "$segment" -eq 0 ]; then
            segment_file="$map_file"
        else
            segment_file="$map_file.$segment"
        fi

        if [ ! -f "$segment_file" ]; then
            echo "[WARN] missing chunk slot metadata segment; treating as slot 0: file=$segment_file slots=$slots_for_take" >> "$warnings_file"
            emit_zero_slot_values "$slots_for_take" >> "$out_file"
        else
            file_size=$(wc -c < "$segment_file" | tr -d ' ')
            if [ "$file_size" -le "$segment_offset" ]; then
                echo "[WARN] short chunk slot metadata segment; treating tail as slot 0: file=$segment_file offset=$segment_offset size=$file_size slots=$slots_for_take" >> "$warnings_file"
                emit_zero_slot_values "$slots_for_take" >> "$out_file"
            else
                available=$(( file_size - segment_offset ))
                read_bytes=$available
                if [ "$read_bytes" -gt "$take_bytes" ]; then
                    read_bytes=$take_bytes
                fi

                slots_for_read=$(( read_bytes * slots_per_byte ))
                if [ "$slots_for_read" -gt "$slots_for_take" ]; then
                    slots_for_read=$slots_for_take
                fi

                if [ "$read_bytes" -gt 0 ]; then
                    od -An -v -tu1 -j "$segment_offset" -N "$read_bytes" "$segment_file" \
                        | awk -v limit="$slots_for_read" -v slot_bits="$slot_bits" '
                            {
                                for (i = 1; i <= NF && n < limit; i++) {
                                    byte = $i + 0;
                                    divisor = 1;
                                    for (shift = 0; shift < 8 && n < limit; shift += slot_bits) {
                                        print int(byte / divisor) % (2 ^ slot_bits);
                                        divisor *= 2 ^ slot_bits;
                                        n++;
                                    }
                                }
                            }
                        ' >> "$out_file"
                fi

                if [ "$slots_for_read" -lt "$slots_for_take" ]; then
                    zero_slots=$(( slots_for_take - slots_for_read ))
                    echo "[WARN] partial chunk slot metadata segment; treating missing slots as slot 0: file=$segment_file offset=$segment_offset size=$file_size zero_slots=$zero_slots" >> "$warnings_file"
                    emit_zero_slot_values "$zero_slots" >> "$out_file"
                fi
            fi
        fi

        remaining_slots=$(( remaining_slots - slots_for_take ))
        remaining_bytes=$(( remaining_bytes - take_bytes ))
        byte_pos=$(( byte_pos + take_bytes ))
    done

    chown $OS_USER:$OS_USER "$out_file" "$warnings_file" 2>/dev/null || true
}

parse_map_compare() {
    local before_map="$1"
    local after_map="$2"
    local target_blocks_file="$3"
    local before_values after_values map_compare_row map_parser

    if [ ! -s "$before_map" ] || [ ! -s "$after_map" ] || [ ! -s "$target_blocks_file" ]; then
        append_map_compare_row "$ver,$LABEL,$TABLE_BLOCKS,$TARGET_BLOCKS,-,-,-,-,-,-,-,-"
        return
    fi

    if [ "$ver" = "chunk" ]; then
        map_parser="chunk_slot"
        before_values="$RESULT_DIR/${ver}_${io_method}_before_active_slots.txt"
        after_values="$RESULT_DIR/${ver}_${io_method}_after_active_slots.txt"
        extract_chunk_active_slot_values "$before_map" "$before_values"
        extract_chunk_active_slot_values "$after_map" "$after_values"
    else
        map_parser="pblk"
        before_values="$RESULT_DIR/${ver}_${io_method}_before_main_pblks.txt"
        after_values="$RESULT_DIR/${ver}_${io_method}_after_main_pblks.txt"
        extract_main_map_values "$before_map" "$before_values"
        extract_main_map_values "$after_map" "$after_values"
    fi

    map_compare_row=$(awk -v ver="$ver" \
        -v label="$LABEL" \
        -v table_blocks="$TABLE_BLOCKS" \
        -v target_blocks="$TARGET_BLOCKS" \
        -v target_file="$target_blocks_file" \
        -v parser="$map_parser" \
        -v active_slots="$CHUNK_ACTIVE_SLOTS" '
        function valid_value(v) {
            if (v !~ /^[0-9]+$/)
                return 0;
            if (parser == "chunk_slot")
                return (v + 0) >= 0 && (v + 0) < active_slots;
            return (v + 0) != 4294967295;
        }
        FILENAME == target_file {
            target[$1] = 1;
            next;
        }
        FILENAME == before_file {
            before[FNR - 1] = $1;
            next;
        }
        FILENAME == after_file {
            lblk = FNR - 1;
            if (lblk >= table_blocks)
                next;
            if (!(lblk in before)) {
                invalid_before++;
                next;
            }
            b = before[lblk];
            a = $1;
            valid_before = valid_value(b);
            valid_after = valid_value(a);
            if (!valid_before)
                invalid_before++;
            if (!valid_after)
                invalid_after++;
            if (valid_before && valid_after && b != a) {
                remapped++;
                if (lblk in target)
                    target_remapped++;
                else
                    extra_remapped++;
            }
            next;
        }
        END {
            remapped += 0;
            target_remapped += 0;
            extra_remapped += 0;
            invalid_before += 0;
            invalid_after += 0;
            remap_fraction = table_blocks > 0 ? sprintf("%.6f", remapped / table_blocks) : "-";
            target_hit_rate = target_blocks > 0 ? sprintf("%.6f", target_remapped / target_blocks) : "-";
            extra_remap_rate = table_blocks > 0 ? sprintf("%.6f", extra_remapped / table_blocks) : "-";
            printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n",
                ver, label, table_blocks, target_blocks,
                remapped, remap_fraction,
                target_remapped, target_hit_rate,
                extra_remapped, extra_remap_rate,
                invalid_before, invalid_after;
        }
    ' before_file="$before_values" after_file="$after_values" "$target_blocks_file" "$before_values" "$after_values")

    append_map_compare_row "$map_compare_row"
}

run_update() {
    local out_file="$RESULT_DIR/${ver}_${io_method}_update.out"
    local err_file="$RESULT_DIR/${ver}_${io_method}_update.err"

    echo "[INFO] update one tuple per target block ..."
    psql_db -At > "$out_file" 2> "$err_file" <<SQL
WITH u AS (
    UPDATE exp5_remap_locality t
    SET marker = marker + 1,
        payload = 'after_' || t.id::text || '_' || repeat('y', $PAYLOAD_BYTES)
    FROM exp5_update_targets s
    WHERE t.id = s.id
    RETURNING 1
)
SELECT count(*) FROM u;
SQL

    UPDATED_ROWS=$(awk '/^[[:space:]]*[0-9]+[[:space:]]*$/ { v = $1 } END { print v }' "$out_file")
    [ -n "$UPDATED_ROWS" ] || UPDATED_ROWS="-"
    chown $OS_USER:$OS_USER "$out_file" "$err_file"
}

write_postgresql_conf() {
    CONF_FILE="$PG_DATA/postgresql.conf"
    HBA_FILE="$PG_DATA/pg_hba.conf"

    cat >> "$CONF_FILE" <<EOF
listen_addresses = '127.0.0.1'
port = $PG_PORT
max_connections = $MAX_CONNECTIONS
shared_buffers = $SHARED_BUFFERS
checkpoint_timeout = '$CHECKPOINT_TIMEOUT'
checkpoint_completion_target = 0.9
max_wal_size = '$MAX_WAL_SIZE'
min_wal_size = '$MIN_WAL_SIZE'
wal_keep_size = '$WAL_KEEP_SIZE'
full_page_writes = $FULL_PAGE_WRITES
wal_compression = off
fsync = on
synchronous_commit = on
autovacuum = off
track_io_timing = on
track_wal_io_timing = on
log_checkpoints = on
io_method = '$io_method'
effective_io_concurrency = 0
maintenance_io_concurrency = 0
seq_page_cost = 1.0
random_page_cost = 4.0
$EXTRA_CONF
EOF

    echo "host all all 127.0.0.1/32 trust" >> "$HBA_FILE"
    echo "local all all trust" >> "$HBA_FILE"
    chown $OS_USER:$OS_USER "$CONF_FILE" "$HBA_FILE"
}

io_method="$IO_METHOD"
for ver in "${VERSIONS[@]}"; do
    echo "================================================================="
    echo "version=$ver io_method=$io_method"
    echo "================================================================="

    resolve_variant
    PG_BIN="$PG_INSTALL_ROOT/$ver/bin"
    PG_DATA="$PGDATA_ROOT/exp5/$ver/data"

    if [ ! -x "$PG_BIN/initdb" ] || [ ! -x "$PG_BIN/pg_ctl" ] || [ ! -x "$PG_BIN/psql" ]; then
        echo "[ERROR] PostgreSQL binaries not found: $PG_BIN"
        exit 1
    fi

    case "$PG_DATA" in
        "$PGDATA_ROOT/exp5/$ver/data") ;;
        *)
            echo "[ERROR] unsafe PG_DATA path: $PG_DATA"
            exit 1
            ;;
    esac

    stop_pg
    echo "[INFO] initdb: $PG_DATA ..."
    mkdir -p "$(dirname "$PG_DATA")"
    chown $OS_USER:$OS_USER "$(dirname "$PG_DATA")"
    rm -rf "$PG_DATA"
    as_pg "$PG_BIN/initdb" -D "$PG_DATA" >/dev/null
    write_postgresql_conf

    drop_os_caches
    echo "[INFO] start PostgreSQL ..."
    as_pg "$PG_BIN/pg_ctl" -D "$PG_DATA" -l "$PG_DATA/logfile" -w -t 120 start >/dev/null

    as_pg "$PG_BIN/dropdb" -h 127.0.0.1 -p "$PG_PORT" --if-exists "$DB_NAME" >/dev/null 2>&1
    as_pg "$PG_BIN/createdb" -h 127.0.0.1 -p "$PG_PORT" "$DB_NAME"

    prepare_table_and_targets

    TABLE_BYTES=$(psql_scalar "SELECT pg_relation_size('exp5_remap_locality');")
    TABLE_BLOCKS=$(psql_scalar "SELECT pg_relation_size('exp5_remap_locality') / current_setting('block_size')::int;")
    TARGET_BLOCKS=$(psql_scalar "SELECT count(*) FROM exp5_update_targets;")
    TARGET_BLOCKS_FILE="$RESULT_DIR/${ver}_${io_method}_target_blocks.txt"
    psql_db -At -c "SELECT blk FROM exp5_update_targets ORDER BY blk;" > "$TARGET_BLOCKS_FILE"
    chown $OS_USER:$OS_USER "$TARGET_BLOCKS_FILE"

    run_scan "baseline"

    echo "[INFO] clean checkpoint boundary before update ..."
    psql_db -c "CHECKPOINT;" >/dev/null
    copy_map_snapshot "before_update"
    BEFORE_MAP="$LAST_COPIED_MAP_PATH"

    psql_db >/dev/null <<SQL
SELECT pg_stat_reset_shared('wal');
SELECT pg_stat_reset_shared('checkpointer');
SELECT pg_stat_force_next_flush();
SQL

    run_update

    UPDATED_BLOCK_FRACTION=$(awk -v a="$TARGET_BLOCKS" -v b="$TABLE_BLOCKS" 'BEGIN { if (b > 0) printf "%.6f", a / b; else print "-" }')
    update_result="FAIL"
    if [ "$UPDATED_ROWS" = "$TARGET_BLOCKS" ]; then
        update_result="PASS"
    fi

    relpath=$(psql_scalar "SELECT pg_relation_filepath('exp5_remap_locality');")
    checkpoint_before=$(checkpoint_stats_line)

    echo "[INFO] post-update checkpoint ..."
    checkpoint_start_ms=$(date +%s%3N)
    psql_db -c "CHECKPOINT;" >/dev/null
    checkpoint_end_ms=$(date +%s%3N)
    post_checkpoint_elapsed_ms=$((checkpoint_end_ms - checkpoint_start_ms))

    checkpoint_after=$(checkpoint_stats_line)
    checkpoint_delta=$(diff3 "$checkpoint_before" "$checkpoint_after")
    IFS=, read -r post_checkpoint_buffers_written post_checkpoint_write_time_ms post_checkpoint_sync_time_ms <<< "$checkpoint_delta"
    map_sizes=$(collect_map_file_sizes "$relpath")
    IFS=, read -r fs_map_bytes_after fs_map_allocated_bytes_after <<< "$map_sizes"

    checkpoint_result="FAIL"
    if [ "$update_result" = "PASS" ] && [ "$post_checkpoint_buffers_written" != "-" ] && [ "$post_checkpoint_buffers_written" -gt 0 ]; then
        checkpoint_result="PASS"
    fi
    append_checkpoint_row "$ver,$LABEL,$TABLE_ROWS,$TABLE_BYTES,$TABLE_BLOCKS,$TARGET_BLOCKS,$UPDATED_ROWS,$UPDATED_BLOCK_FRACTION,$post_checkpoint_elapsed_ms,$post_checkpoint_buffers_written,$post_checkpoint_write_time_ms,$post_checkpoint_sync_time_ms,$checkpoint_result"

    copy_map_snapshot "after_update"
    AFTER_MAP="$LAST_COPIED_MAP_PATH"
    append_evidence_row "$ver,$LABEL,$fs_map_bytes_after,$fs_map_allocated_bytes_after,$BEFORE_MAP,$AFTER_MAP,$TARGET_BLOCKS_FILE"
    parse_map_compare "$BEFORE_MAP" "$AFTER_MAP" "$TARGET_BLOCKS_FILE"

    run_scan "post_remap"

    echo "[INFO] cleanup $PG_DATA ..."
    stop_pg
    rm -rf "$PG_DATA"
    chown -R $OS_USER:$OS_USER "$RESULT_DIR"
done

echo "================================================================="
echo "Experiment 5 remap locality cost done."
echo "summary: $RESULT_FILE"
