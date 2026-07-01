#!/bin/bash

set -euo pipefail

# ==============================================================================
# Exp4: steady-state space / reclaim pressure
# ==============================================================================

OS_USER="jiamingwei"
BASE_DIR="/home/jiamingwei"
PG_INSTALL_ROOT="$BASE_DIR"
PGDATA_ROOT="$BASE_DIR"
PG_PORT=55437
DB_NAME="exp4"

VERSIONS=("mdonrelease" "chunk")
WORKING_SETS=("medium")
CLIENTS=(200)

MEDIUM_ROWS=200000000
LARGE_ROWS=800000000

WARMUP_SECONDS=60
MEASUREMENT_SECONDS=1200
SAMPLE_PERIOD_SECONDS=30
RANDOM_SEED=20260610
MAX_PGBENCH_JOBS=64

SHARED_BUFFERS="50GB"
MAX_CONNECTIONS=1200
CHECKPOINT_TIMEOUT="2min"
CHECKPOINT_COMPLETION_TARGET=0.9
MAX_WAL_SIZE="20GB"
FULL_PAGE_WRITES="on"
AUTOVACUUM="on"

RESULT_ROOT="$BASE_DIR/exp4/results"
RESULT_FILE="$RESULT_ROOT/exp4_summary_results.csv"
DIAGNOSTIC_RESULT_FILE="$RESULT_ROOT/exp4_diagnostic_results.csv"
SAMPLE_WINDOW_RESULT_FILE="$RESULT_ROOT/exp4_sample_windows.csv"
PGDATA_BACKUP_ROOT="$BASE_DIR/exp4/pgbackup"
RUN_MARKER_DIR="$RESULT_ROOT/run_markers"
RUN_LOG="$RESULT_ROOT/exp4_space_reclaim_runner.log"
PID_FILE="$RESULT_ROOT/exp4_space_reclaim_runner.pid"
SCRIPT_PATH="$(readlink -f "$0")"

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage:
  sudo $SCRIPT_PATH              run in background (default)
  sudo $SCRIPT_PATH --background run in background
  sudo $SCRIPT_PATH --bg         run in background
  sudo $SCRIPT_PATH --foreground run in foreground

Background log:
  $RUN_LOG

PID file:
  $PID_FILE
EOF
}

is_pid_running() {
    local pid="$1"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

ensure_result_root() {
    mkdir -p "$RESULT_ROOT"
    if [ "$(id -u)" = "0" ]; then
        chown "$OS_USER:$OS_USER" "$RESULT_ROOT" 2>/dev/null || true
    fi
}

start_background() {
    local old_pid=""
    local bg_pid=""

    ensure_result_root
    if [ -f "$PID_FILE" ]; then
        old_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if is_pid_running "$old_pid"; then
            echo "[INFO] Exp4 is already running in background, PID: $old_pid"
            echo "[INFO] log: $RUN_LOG"
            exit 0
        fi
        rm -f "$PID_FILE"
    fi

    if [ "$(id -u)" = "0" ]; then
        nohup env EXP4_BACKGROUND_RUN=1 bash "$SCRIPT_PATH" --foreground > "$RUN_LOG" 2>&1 < /dev/null &
    else
        if ! command -v sudo >/dev/null 2>&1; then
            echo "[ERROR] background mode needs root, but sudo was not found. Run as root."
            exit 1
        fi
        if ! sudo -n true 2>/dev/null; then
            echo "[ERROR] background mode needs root. Run sudo -v first, or run: sudo $SCRIPT_PATH --background"
            exit 1
        fi
        nohup sudo -n env EXP4_BACKGROUND_RUN=1 bash "$SCRIPT_PATH" --foreground > "$RUN_LOG" 2>&1 < /dev/null &
    fi

    bg_pid=$!
    echo "$bg_pid" > "$PID_FILE"
    if [ "$(id -u)" = "0" ]; then
        chown "$OS_USER:$OS_USER" "$PID_FILE" "$RUN_LOG" 2>/dev/null || true
    fi

    echo "[INFO] started in background, launcher PID: $bg_pid"
    echo "[INFO] log: $RUN_LOG"
    echo "[INFO] summary: $RESULT_FILE"
}

register_background_pid() {
    if [ "${EXP4_BACKGROUND_RUN:-0}" = "1" ]; then
        echo "$$" > "$PID_FILE"
        chown "$OS_USER:$OS_USER" "$PID_FILE" 2>/dev/null || true
        trap "rm -f \"$PID_FILE\"" EXIT
    fi
}

case "${1:-}" in
    --background|--bg)
        shift
        if [ "$#" -ne 0 ]; then
            usage
            exit 1
        fi
        start_background
        exit 0
        ;;
    --foreground)
        shift
        if [ "$#" -ne 0 ]; then
            usage
            exit 1
        fi
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    "")
        start_background
        exit 0
        ;;
    *)
        usage
        exit 1
        ;;
esac

rows_for_working_set() {
    case "$1" in
        medium) echo "$MEDIUM_ROWS" ;;
        large) echo "$LARGE_ROWS" ;;
        *) die "unknown working set: $1" ;;
    esac
}

jobs_for_clients() {
    local clients="$1"
    if [ "$clients" -lt "$MAX_PGBENCH_JOBS" ]; then
        echo "$clients"
    else
        echo "$MAX_PGBENCH_JOBS"
    fi
}

stop_server() {
    local pg_bin="$1"
    local pg_data="$2"
    sudo -u "$OS_USER" "$pg_bin/pg_ctl" -D "$pg_data" stop -m immediate >/dev/null 2>&1 || true
}

psql_exp4() {
    sudo -u "$OS_USER" "$PG_BIN/psql" -h 127.0.0.1 -p "$PG_PORT" -d "$DB_NAME" -v ON_ERROR_STOP=1 "$@"
}

psql_postgres() {
    sudo -u "$OS_USER" "$PG_BIN/psql" -h 127.0.0.1 -p "$PG_PORT" -d postgres -v ON_ERROR_STOP=1 "$@"
}

query_exp4_csv() {
    psql_exp4 -At -F ',' -c "$1"
}

current_wal_lsn() {
    query_exp4_csv "SELECT pg_current_wal_insert_lsn();"
}

wal_lsn_diff_bytes() {
    local start_lsn="$1"
    local end_lsn="$2"

    query_exp4_csv "SELECT pg_wal_lsn_diff('$end_lsn', '$start_lsn')::bigint;"
}

path_kb() {
    local path="$1"
    if [ -e "$path" ]; then
        du -sk "$path" | awk '{print $1}'
    else
        echo 0
    fi
}

pgdata_kb() {
    path_kb "$PG_DATA"
}

base_kb() {
    path_kb "$PG_DATA/base"
}

get_core_stats() {
    query_exp4_csv "
SELECT
  pg_total_relation_size('exp4_tbl'),
  (SELECT COALESCE(sum(write_bytes), 0) FROM pg_stat_io),
  (SELECT COALESCE(sum(extend_bytes), 0) FROM pg_stat_io),
  (SELECT buffers_written FROM pg_stat_checkpointer),
  (SELECT num_done FROM pg_stat_checkpointer),
  (SELECT num_timed FROM pg_stat_checkpointer),
  (SELECT num_requested FROM pg_stat_checkpointer),
  COALESCE((SELECT n_dead_tup FROM pg_stat_all_tables WHERE relid = 'exp4_tbl'::regclass), 0),
  COALESCE((SELECT vacuum_count FROM pg_stat_all_tables WHERE relid = 'exp4_tbl'::regclass), 0),
  COALESCE((SELECT autovacuum_count FROM pg_stat_all_tables WHERE relid = 'exp4_tbl'::regclass), 0);
"
}

sample_stats() {
    local out_file="$1"
    local start_epoch="$2"
    local duration="$3"
    local period="$4"
    local start_wal_lsn="$5"
    local end_epoch=$((start_epoch + duration))
    local now stats cur_pgdata_kb cur_base_kb cur_wal_lsn wal_generated_bytes

    echo "elapsed_sec,epoch,relation_bytes,io_write_bytes_total,io_extend_bytes_total,checkpointer_buffers_written_total,checkpoints_done_total,checkpoints_timed_total,checkpoints_requested_total,n_dead_tup,vacuum_count,autovacuum_count,pgdata_kb,base_kb,wal_lsn,wal_generated_bytes" > "$out_file"

    while true; do
        now="$(date +%s)"
        if [ "$now" -gt "$end_epoch" ]; then
            break
        fi

        stats="$(get_core_stats)"
        cur_pgdata_kb="$(pgdata_kb)"
        cur_base_kb="$(base_kb)"
        cur_wal_lsn="$(current_wal_lsn)"
        wal_generated_bytes="$(wal_lsn_diff_bytes "$start_wal_lsn" "$cur_wal_lsn")"
        echo "$((now - start_epoch)),$now,$stats,$cur_pgdata_kb,$cur_base_kb,$cur_wal_lsn,$wal_generated_bytes" >> "$out_file"
        sleep "$period"
    done
}

make_base_extra_samples() {
    local mdon_sample="$1"
    local variant_sample="$2"
    local out_file="$3"

    echo "elapsed_sec,mdon_epoch,variant_epoch,mdon_base_kb,variant_base_kb,base_extra_vs_mdon_bytes,wal_generated_bytes,wal_minus_base_extra_bytes" > "$out_file"

    if [ ! -s "$mdon_sample" ] || [ ! -s "$variant_sample" ]; then
        return
    fi

    awk -F, -v period="$SAMPLE_PERIOD_SECONDS" '
        FNR == 1 {
            file_index++;
            for (i = 1; i <= NF; i++)
                col[file_index, $i] = i;
            next;
        }
        file_index == 1 {
            elapsed = $col[1, "elapsed_sec"] + 0;
            window = int(elapsed / period);
            mdon_seen[window] = 1;
            mdon_elapsed[window] = elapsed;
            mdon_epoch[window] = $col[1, "epoch"] + 0;
            mdon_base[window] = $col[1, "base_kb"] + 0;
            next;
        }
        file_index == 2 {
            elapsed = $col[2, "elapsed_sec"] + 0;
            window = int((elapsed + period / 2) / period);
            if (window in mdon_seen) {
                variant_base = $col[2, "base_kb"] + 0;
                extra = (variant_base - mdon_base[window]) * 1024;
                if (extra < 0)
                    extra = 0;
                wal = $col[2, "wal_generated_bytes"] + 0;
                printf "%s,%s,%s,%.0f,%.0f,%.0f,%.0f,%.0f\n",
                    (mdon_elapsed[window] + elapsed) / 2,
                    mdon_epoch[window],
                    $col[2, "epoch"],
                    mdon_base[window],
                    variant_base,
                    extra,
                    wal,
                    wal - extra;
            }
        }
    ' "$mdon_sample" "$variant_sample" >> "$out_file"
}

reduce_wal_base_extra_intersection() {
    local base_extra_sample_file="$1"

    awk -F, '
        NR == 1 { next; }
        {
            elapsed = $1 + 0;
            epoch = $3 + 0;
            wal = $7 + 0;
            base_extra = $6 + 0;
            diff = wal - base_extra;
            if (base_extra > 0)
                final_ratio = wal / base_extra;

            if (!found && (wal > 0 || base_extra > 0)) {
                if (diff >= 0) {
                    found = 1;
                    cross_elapsed = elapsed;
                    cross_epoch = epoch;
                } else if (prev_set && prev_diff != diff &&
                           ((prev_diff < 0 && diff > 0) || (prev_diff > 0 && diff < 0))) {
                    frac = (0 - prev_diff) / (diff - prev_diff);
                    found = 1;
                    cross_elapsed = prev_elapsed + frac * (elapsed - prev_elapsed);
                    cross_epoch = prev_epoch + frac * (epoch - prev_epoch);
                }
            }

            prev_set = 1;
            prev_elapsed = elapsed;
            prev_epoch = epoch;
            prev_diff = diff;
        }
        END {
            if (found)
                printf "%.3f,%.3f,%.6f\n", cross_elapsed, cross_epoch, final_ratio + 0;
            else
                printf "-,-,%.6f\n", final_ratio + 0;
        }
    ' "$base_extra_sample_file"
}

summarize_base_extra_samples() {
    local base_extra_sample_file="$1"

    awk -F, '
        NR == 1 { next; }
        END {
            if (NR == 1) {
                print "-,-,-,-,-,-";
                exit;
            }
            printf "%.0f,%.0f,%.0f,%.0f,%.0f,%.0f\n",
                last_mdon_base * 1024,
                last_variant_base * 1024,
                last_extra,
                max_extra,
                last_wal,
                last_wal - last_extra;
        }
        {
            last_mdon_base = $4;
            last_variant_base = $5;
            last_extra = $6;
            last_wal = $7;
            if (seen == 0 || last_extra > max_extra)
                max_extra = last_extra;
            seen = 1;
        }
    ' "$base_extra_sample_file"
}

make_sample_deltas() {
    local in_file="$1"
    local out_file="$2"

    awk -F, '
        NR == 1 {
            for (i = 1; i <= NF; i++)
                col[$i] = i;
            print "elapsed_sec,epoch,relation_bytes,relation_delta_bytes,io_write_extend_delta_bytes,checkpointer_buffers_delta,checkpoints_completed_delta,n_dead_tup,vacuum_count,autovacuum_count,pgdata_kb,pgdata_delta_kb,base_kb,base_delta_kb,wal_generated_bytes,wal_generated_delta_bytes";
            next;
        }
        NR == 2 {
            prev_rel = $col["relation_bytes"];
            prev_io = $col["io_write_bytes_total"] + $col["io_extend_bytes_total"];
            prev_buf = $col["checkpointer_buffers_written_total"];
            prev_ckpt = $col["checkpoints_done_total"];
            prev_pgdata = $col["pgdata_kb"];
            prev_base = $col["base_kb"];
            prev_wal_generated = $col["wal_generated_bytes"];
        }
        NR >= 2 {
            relation_bytes = $col["relation_bytes"];
            cur_io = $col["io_write_bytes_total"] + $col["io_extend_bytes_total"];
            cur_ckpt = $col["checkpoints_done_total"];
            pgdata_kb = $col["pgdata_kb"];
            base_kb = $col["base_kb"];
            wal_generated = $col["wal_generated_bytes"];
            printf "%s,%s,%s,%d,%d,%d,%d,%s,%s,%s,%s,%d,%s,%d,%s,%d\n",
                $col["elapsed_sec"], $col["epoch"], relation_bytes,
                relation_bytes - prev_rel,
                cur_io - prev_io,
                $col["checkpointer_buffers_written_total"] - prev_buf,
                cur_ckpt - prev_ckpt,
                $col["n_dead_tup"], $col["vacuum_count"], $col["autovacuum_count"],
                pgdata_kb, pgdata_kb - prev_pgdata,
                base_kb, base_kb - prev_base,
                wal_generated, wal_generated - prev_wal_generated;
            prev_rel = relation_bytes;
            prev_io = cur_io;
            prev_buf = $col["checkpointer_buffers_written_total"];
            prev_ckpt = cur_ckpt;
            prev_pgdata = pgdata_kb;
            prev_base = base_kb;
            prev_wal_generated = wal_generated;
        }
    ' "$in_file" > "$out_file"
}

reduce_disk_trend() {
    local sample_file="$1"

    awk -F, '
        function update(v, prefix) {
            if (seen == 1 || v < min[prefix]) {
                min[prefix] = v;
                min_t[prefix] = $1;
            }
            if (seen == 1 || v > max[prefix]) {
                max[prefix] = v;
                max_t[prefix] = $1;
            }
        }
        NR == 1 {
            for (i = 1; i <= NF; i++)
                col[$i] = i;
            next;
        }
        NR == 2 {
            start_pgdata = $col["pgdata_kb"] + 0;
            start_base = $col["base_kb"] + 0;
        }
        NR >= 2 {
            seen++;
            pgdata = $col["pgdata_kb"] + 0;
            base = $col["base_kb"] + 0;

            update(pgdata, "pgdata");
            update(base, "base");

            if (seen > 1) {
                if (prev_pgdata - pgdata > max_drop["pgdata"])
                    max_drop["pgdata"] = prev_pgdata - pgdata;
                if (prev_base - base > max_drop["base"])
                    max_drop["base"] = prev_base - base;
            }

            prev_pgdata = pgdata;
            prev_base = base;
            end_pgdata = pgdata;
            end_base = base;
        }
        END {
            if (seen == 0) {
                print "0,0,0,0,0,0,0,0,0,0,0,0";
                exit;
            }
            printf "%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d\n",
                start_pgdata, end_pgdata, min["pgdata"], max["pgdata"],
                max_drop["pgdata"] + 0, max["pgdata"] - end_pgdata,
                start_base, end_base, min["base"], max["base"],
                max_drop["base"] + 0, max["base"] - end_base;
        }
    ' "$sample_file"
}

update_data_space_crossing() {
    local variant="$1"
    local ws="$2"
    local rows="$3"
    local clients="$4"
    local out_file="$RESULT_ROOT/data_space_crossing.csv"
    local mdon_sample="$RESULT_ROOT/mdonrelease_${ws}_${clients}/samples.csv"
    local variant_sample="$RESULT_ROOT/${variant}_${ws}_${clients}/samples.csv"
    local base_extra_sample="$RESULT_ROOT/${variant}_${ws}_${clients}/base_extra_vs_mdon_samples.csv"
    local mdon_done="$RUN_MARKER_DIR/mdonrelease_${ws}_${clients}.done"
    local variant_done="$RUN_MARKER_DIR/${variant}_${ws}_${clients}.done"
    local crossing_csv summary_csv tmp_file

    if [ "$variant" = "mdonrelease" ]; then
        return
    fi

    if [ ! -e "$mdon_done" ] || [ ! -e "$variant_done" ]; then
        return
    fi

    if [ ! -s "$mdon_sample" ] || [ ! -s "$variant_sample" ]; then
        return
    fi

    if [ ! -s "$out_file" ]; then
        echo "variant,working_set,rows,clients,mdon_sample,variant_sample,base_extra_sample,cross_elapsed_sec,cross_variant_epoch,wal_to_base_extra_final_ratio,final_mdon_base_bytes,final_variant_base_bytes,final_base_extra_vs_mdon_bytes,max_base_extra_vs_mdon_bytes,final_variant_wal_generated_bytes,final_wal_minus_base_extra_bytes" > "$out_file"
    fi

    tmp_file="$out_file.tmp.$$"
    awk -F, -v variant="$variant" -v ws="$ws" -v clients="$clients" '
        NR == 1 || !($1 == variant && $2 == ws && $4 == clients)
    ' "$out_file" > "$tmp_file"
    mv "$tmp_file" "$out_file"

    make_base_extra_samples "$mdon_sample" "$variant_sample" "$base_extra_sample"
    crossing_csv="$(reduce_wal_base_extra_intersection "$base_extra_sample")"
    summary_csv="$(summarize_base_extra_samples "$base_extra_sample")"
    echo "$variant,$ws,$rows,$clients,$mdon_sample,$variant_sample,$base_extra_sample,$crossing_csv,$summary_csv" >> "$out_file"
    chown "$OS_USER:$OS_USER" "$out_file"
}

reduce_latency_windows() {
    local log_prefix="$1"
    local start_epoch="$2"
    local duration="$3"
    local period="$4"
    local out_file="$5"
    local logs=("${log_prefix}".*)

    echo "window,txn_count,tps,p50_ms,p95_ms,p99_ms,p999_ms,max_ms" > "$out_file"

    if [ ! -e "${logs[0]}" ]; then
        return
    fi

    awk -v start="$start_epoch" -v duration="$duration" -v period="$period" '
        NF >= 6 {
            epoch = $5;
            if (epoch < start || epoch >= start + duration)
                next;
            window = int((epoch - start) / period);
            printf "%d,%.6f\n", window, $3 / 1000.0;
        }
    ' "${logs[@]}" | sort -t, -k1,1n -k2,2n | awk -F, -v period="$period" '
        function ceil_index(x, n) {
            idx = int(x + 0.999999);
            if (idx < 1) idx = 1;
            if (idx > n) idx = n;
            return idx;
        }
        function flush_window() {
            if (n == 0)
                return;
            p50 = ceil_index(n * 0.50, n);
            p95 = ceil_index(n * 0.95, n);
            p99 = ceil_index(n * 0.99, n);
            p999 = ceil_index(n * 0.999, n);
            printf "%d,%d,%.6f,%.3f,%.3f,%.3f,%.3f,%.3f\n",
                cur_window, n, n / period, a[p50], a[p95], a[p99], a[p999], a[n];
            delete a;
            n = 0;
        }
        {
            if (cur_window == "" || $1 != cur_window) {
                flush_window();
                cur_window = $1;
            }
            n++;
            a[n] = $2;
        }
        END {
            flush_window();
        }
    ' >> "$out_file"
}

reduce_latency_overall() {
    local log_prefix="$1"
    local start_epoch="$2"
    local duration="$3"
    local logs=("${log_prefix}".*)

    if [ ! -e "${logs[0]}" ]; then
        echo "0,0,-,-,-,-,-"
        return
    fi

    awk -v start="$start_epoch" -v duration="$duration" '
        NF >= 6 {
            epoch = $5;
            if (epoch < start || epoch >= start + duration)
                next;
            printf "%.6f\n", $3 / 1000.0;
        }
    ' "${logs[@]}" | sort -n | awk -v duration="$duration" '
        function ceil_index(x, n) {
            idx = int(x + 0.999999);
            if (idx < 1) idx = 1;
            if (idx > n) idx = n;
            return idx;
        }
        {
            n++;
            a[n] = $1;
        }
        END {
            if (n == 0) {
                print "0,0,-,-,-,-,-";
                exit;
            }
            p50 = ceil_index(n * 0.50, n);
            p95 = ceil_index(n * 0.95, n);
            p99 = ceil_index(n * 0.99, n);
            p999 = ceil_index(n * 0.999, n);
            printf "%d,%.6f,%.3f,%.3f,%.3f,%.3f,%.3f\n",
                n, n / duration, a[p50], a[p95], a[p99], a[p999], a[n];
        }
    '
}

append_sample_windows() {
    local ver="$1"
    local ws="$2"
    local rows="$3"
    local clients="$4"
    local period="$5"
    local sample_delta_file="$6"
    local latency_window_file="$7"

    if [ ! -s "$sample_delta_file" ]; then
        return
    fi

    awk -F, -v ver="$ver" -v ws="$ws" -v rows="$rows" -v clients="$clients" -v period="$period" '
        FNR == 1 {
            file_index++;
            for (i = 1; i <= NF; i++)
                col[file_index, $i] = i;
            next;
        }
        file_index == 1 {
            elapsed = $col[1, "elapsed_sec"] + 0;
            window = int((elapsed + period / 2) / period);
            relation_bytes[window] = $col[1, "relation_bytes"];
            relation_delta_bytes[window] = $col[1, "relation_delta_bytes"];
            io_write_extend_delta_bytes[window] = $col[1, "io_write_extend_delta_bytes"];
            checkpointer_buffers_delta[window] = $col[1, "checkpointer_buffers_delta"];
            checkpoints_completed_delta[window] = $col[1, "checkpoints_completed_delta"];
            wal_generated_bytes[window] = $col[1, "wal_generated_bytes"];
            wal_generated_delta_bytes[window] = $col[1, "wal_generated_delta_bytes"];
            seen[window] = 1;
            if (!have_min || window < min_window)
                min_window = window;
            if (!have_max || window > max_window)
                max_window = window;
            have_min = have_max = 1;
            next;
        }
        file_index == 2 {
            window = $col[2, "window"] + 0;
            p95[window] = $col[2, "p95_ms"];
            p99[window] = $col[2, "p99_ms"];
            p999[window] = $col[2, "p999_ms"];
            max_ms[window] = $col[2, "max_ms"];
            next;
        }
        END {
            if (!have_min)
                exit;
            for (window = min_window; window <= max_window; window++) {
                if (!(window in seen))
                    continue;
                printf "%s,%s,%s,%s,%d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n",
                    ver, ws, rows, clients, window,
                    relation_bytes[window],
                    relation_delta_bytes[window],
                    io_write_extend_delta_bytes[window],
                    checkpointer_buffers_delta[window],
                    checkpoints_completed_delta[window],
                    wal_generated_bytes[window],
                    wal_generated_delta_bytes[window],
                    p95[window] == "" ? "-" : p95[window],
                    p99[window] == "" ? "-" : p99[window],
                    p999[window] == "" ? "-" : p999[window],
                    max_ms[window] == "" ? "-" : max_ms[window];
            }
        }
    ' "$sample_delta_file" "$latency_window_file" >> "$SAMPLE_WINDOW_RESULT_FILE"
}

write_pgbench_script() {
    local script_file="$1"
    cat > "$script_file" <<'EOF'
\set id random(1, :row_count)
UPDATE exp4_tbl
SET version = version + 1
WHERE id = :id;
EOF
    chown "$OS_USER:$OS_USER" "$script_file"
}

configure_postgres() {
    local ver="$1"
    local conf_file="$PG_DATA/postgresql.conf"
    local hba_file="$PG_DATA/pg_hba.conf"

    cat >> "$conf_file" <<EOF
port = $PG_PORT
listen_addresses = '127.0.0.1'
checkpoint_timeout = $CHECKPOINT_TIMEOUT
checkpoint_completion_target = $CHECKPOINT_COMPLETION_TARGET
max_wal_size = $MAX_WAL_SIZE
shared_buffers = $SHARED_BUFFERS
max_connections = $MAX_CONNECTIONS
full_page_writes = $FULL_PAGE_WRITES
autovacuum = $AUTOVACUUM
log_checkpoints = on
track_io_timing = on
track_wal_io_timing = on
EOF

    cat >> "$hba_file" <<'EOF'
host all all 127.0.0.1/32 trust
local all all trust
EOF

    chown "$OS_USER:$OS_USER" "$conf_file" "$hba_file"
}

load_working_set() {
    local rows="$1"
    local load_log="$2"

    echo "[INFO] loading exp4_tbl rows=$rows"
    sudo -u "$OS_USER" "$PG_BIN/psql" -h 127.0.0.1 -p "$PG_PORT" -d "$DB_NAME" -v ON_ERROR_STOP=1 > "$load_log" 2>&1 <<SQL
\\timing on
DROP TABLE IF EXISTS exp4_tbl;
CREATE TABLE exp4_tbl (
  id bigint NOT NULL,
  version bigint NOT NULL,
  payload char(84) NOT NULL
) WITH (fillfactor=100);
INSERT INTO exp4_tbl
SELECT g::bigint, 0::bigint, repeat('x', 84)::char(84)
FROM generate_series(1, $rows) AS g;
ALTER TABLE exp4_tbl ADD PRIMARY KEY (id);
VACUUM ANALYZE exp4_tbl;
CHECKPOINT;
SELECT pg_total_relation_size('exp4_tbl') AS loaded_relation_bytes;
SQL

    chown "$OS_USER:$OS_USER" "$load_log"
}

run_pgbench_period() {
    local clients="$1"
    local jobs="$2"
    local seconds="$3"
    local rows="$4"
    local script_file="$5"
    local log_file="$6"
    local log_prefix="${7:-}"

    if [ -n "$log_prefix" ]; then
        sudo -u "$OS_USER" env PGBENCH_RANDOM_SEED="$RANDOM_SEED" \
            "$PG_BIN/pgbench" \
            --random-seed="$RANDOM_SEED" \
            -h 127.0.0.1 \
            -p "$PG_PORT" \
            -d "$DB_NAME" \
            -n \
            -c "$clients" \
            -j "$jobs" \
            -T "$seconds" \
            -P "$SAMPLE_PERIOD_SECONDS" \
            -D "row_count=$rows" \
            -f "$script_file" \
            -l \
            --log-prefix="$log_prefix" \
            > "$log_file" 2>&1
    else
        sudo -u "$OS_USER" env PGBENCH_RANDOM_SEED="$RANDOM_SEED" \
            "$PG_BIN/pgbench" \
            --random-seed="$RANDOM_SEED" \
            -h 127.0.0.1 \
            -p "$PG_PORT" \
            -d "$DB_NAME" \
            -n \
            -c "$clients" \
            -j "$jobs" \
            -T "$seconds" \
            -P "$SAMPLE_PERIOD_SECONDS" \
            -D "row_count=$rows" \
            -f "$script_file" \
            > "$log_file" 2>&1
    fi

    local rc=$?
    chown "$OS_USER:$OS_USER" "$log_file"
    return "$rc"
}

append_summary_row() {
    local row="$1"
    echo "$row" >> "$RESULT_FILE"
}

run_job() {
    local ver="$1"
    local ws="$2"
    local rows="$3"
    local clients="$4"
    local jobs
    local job_dir workload_script warmup_log measure_log sample_file sample_delta_file latency_window_file
    local start_stats end_stats start_rel start_write start_extend start_buf start_done start_timed start_requested
    local start_dead start_vacuum start_autovacuum end_rel end_write end_extend end_buf end_done end_timed end_requested
    local end_dead end_vacuum end_autovacuum start_io end_io io_delta checkpointer_delta checkpoint_delta relation_delta
    local start_wal_lsn end_wal_lsn wal_generated_bytes
    local measurement_start_epoch sampler_pid pgbench_rc warmup_rc latency_csv tx_count tps p50 p95 p99 p999 max_latency
    local disk_trend_csv
    local pgdata_start_kb pgdata_end_kb pgdata_min_kb pgdata_max_kb
    local pgdata_max_sample_drop_kb pgdata_peak_to_end_drop_kb
    local base_start_kb base_end_kb base_min_kb base_max_kb
    local base_max_sample_drop_kb base_peak_to_end_drop_kb

    jobs="$(jobs_for_clients "$clients")"
    job_dir="$RESULT_ROOT/${ver}_${ws}_${clients}"
    workload_script="$job_dir/exp4_update.sql"
    warmup_log="$job_dir/warmup_pgbench.log"
    measure_log="$job_dir/measurement_pgbench.log"
    sample_file="$job_dir/samples.csv"
    sample_delta_file="$job_dir/sample_deltas.csv"
    latency_window_file="$job_dir/latency_windows.csv"

    mkdir -p "$job_dir"
    chown "$OS_USER:$OS_USER" "$job_dir"
    write_pgbench_script "$workload_script"

    echo "-------------------------------------------------------------"
    echo "[INFO] job version=$ver working_set=$ws rows=$rows clients=$clients jobs=$jobs"

    rm -rf "$PG_DATA"
    cp -r "$PG_DATA_BAK" "$PG_DATA"
    chown -R "$OS_USER:$OS_USER" "$PG_DATA"

    echo "[INFO] clearing OS cache"
    sync
    echo 3 > /proc/sys/vm/drop_caches

    sudo -u "$OS_USER" "$PG_BIN/pg_ctl" -D "$PG_DATA" -l "$job_dir/server.log" -w -t 600 start >/dev/null

    echo "[INFO] warmup ${WARMUP_SECONDS}s"
    set +e
    run_pgbench_period "$clients" "$jobs" "$WARMUP_SECONDS" "$rows" "$workload_script" "$warmup_log"
    warmup_rc=$?
    set -e

    start_stats="$(get_core_stats)"
    IFS=',' read -r start_rel start_write start_extend start_buf start_done start_timed start_requested start_dead start_vacuum start_autovacuum <<< "$start_stats"
    start_wal_lsn="$(current_wal_lsn)"
    measurement_start_epoch="$(date +%s)"

    sample_stats "$sample_file" "$measurement_start_epoch" "$MEASUREMENT_SECONDS" "$SAMPLE_PERIOD_SECONDS" "$start_wal_lsn" &
    sampler_pid=$!

    echo "[INFO] measurement ${MEASUREMENT_SECONDS}s"
    set +e
    run_pgbench_period "$clients" "$jobs" "$MEASUREMENT_SECONDS" "$rows" "$workload_script" "$measure_log" "$job_dir/pgbench_tx"
    pgbench_rc=$?
    set -e

    wait "$sampler_pid" || true

    end_stats="$(get_core_stats)"
    IFS=',' read -r end_rel end_write end_extend end_buf end_done end_timed end_requested end_dead end_vacuum end_autovacuum <<< "$end_stats"
    end_wal_lsn="$(current_wal_lsn)"

    make_sample_deltas "$sample_file" "$sample_delta_file"
    reduce_latency_windows "$job_dir/pgbench_tx" "$measurement_start_epoch" "$MEASUREMENT_SECONDS" "$SAMPLE_PERIOD_SECONDS" "$latency_window_file"
    append_sample_windows "$ver" "$ws" "$rows" "$clients" "$SAMPLE_PERIOD_SECONDS" "$sample_delta_file" "$latency_window_file"
    latency_csv="$(reduce_latency_overall "$job_dir/pgbench_tx" "$measurement_start_epoch" "$MEASUREMENT_SECONDS")"
    IFS=',' read -r tx_count tps p50 p95 p99 p999 max_latency <<< "$latency_csv"
    disk_trend_csv="$(reduce_disk_trend "$sample_file")"
    IFS=',' read -r \
        pgdata_start_kb pgdata_end_kb pgdata_min_kb pgdata_max_kb \
        pgdata_max_sample_drop_kb pgdata_peak_to_end_drop_kb \
        base_start_kb base_end_kb base_min_kb base_max_kb \
        base_max_sample_drop_kb base_peak_to_end_drop_kb <<< "$disk_trend_csv"

    start_io=$((start_write + start_extend))
    end_io=$((end_write + end_extend))
    io_delta=$((end_io - start_io))
    checkpointer_delta=$((end_buf - start_buf))
    checkpoint_delta=$((end_done - start_done))
    relation_delta=$((end_rel - start_rel))
    wal_generated_bytes="$(wal_lsn_diff_bytes "$start_wal_lsn" "$end_wal_lsn")"

    append_summary_row "$ver,$ws,$rows,$clients,$jobs,$RANDOM_SEED,$WARMUP_SECONDS,$MEASUREMENT_SECONDS,$start_rel,$end_rel,$relation_delta,$start_wal_lsn,$end_wal_lsn,$wal_generated_bytes,$io_delta,$checkpointer_delta,$checkpoint_delta,$pgdata_max_sample_drop_kb,$pgdata_peak_to_end_drop_kb,$base_start_kb,$base_end_kb,$base_max_kb,$base_max_sample_drop_kb,$base_peak_to_end_drop_kb,$tx_count,$tps,$p95,$p99,$p999,$max_latency,$pgbench_rc,$job_dir"
    echo "$ver,$ws,$rows,$clients,$SAMPLE_PERIOD_SECONDS,$end_dead,$end_vacuum,$end_autovacuum,$pgdata_start_kb,$pgdata_end_kb,$pgdata_min_kb,$pgdata_max_kb,$base_min_kb,$warmup_rc,$p50,$job_dir" >> "$DIAGNOSTIC_RESULT_FILE"

    stop_server "$PG_BIN" "$PG_DATA"

    if [ "$pgbench_rc" = "0" ] && [ -s "$sample_file" ]; then
        touch "$RUN_MARKER_DIR/${ver}_${ws}_${clients}.done"
        chown "$OS_USER:$OS_USER" "$RUN_MARKER_DIR/${ver}_${ws}_${clients}.done"
    fi
    update_data_space_crossing "$ver" "$ws" "$rows" "$clients"
}

if [ "$(id -u)" != "0" ]; then
    die "run as root; the script uses drop_caches and manages PGDATA"
fi

mkdir -p "$RESULT_ROOT"
chown "$OS_USER:$OS_USER" "$RESULT_ROOT"
register_background_pid
mkdir -p "$PGDATA_BACKUP_ROOT"
chown "$OS_USER:$OS_USER" "$PGDATA_BACKUP_ROOT"
rm -rf "$RUN_MARKER_DIR"
mkdir -p "$RUN_MARKER_DIR"
chown "$OS_USER:$OS_USER" "$RUN_MARKER_DIR"

echo "version,working_set,rows,clients,pgbench_jobs,random_seed,warmup_seconds,measurement_seconds,measurement_start_relation_bytes,measurement_end_relation_bytes,measurement_relation_delta_bytes,measurement_start_wal_lsn,measurement_end_wal_lsn,measurement_wal_generated_bytes,pg_internal_write_extend_delta_bytes,checkpointer_buffers_delta,checkpoints_completed_delta,pgdata_max_sample_drop_kb,pgdata_peak_to_end_drop_kb,base_start_kb,base_end_kb,base_max_kb,base_max_sample_drop_kb,base_peak_to_end_drop_kb,measurement_transactions,measurement_tps,latency_p95_ms,latency_p99_ms,latency_p999_ms,latency_max_ms,measurement_rc,job_dir" > "$RESULT_FILE"
chown "$OS_USER:$OS_USER" "$RESULT_FILE"
echo "version,working_set,rows,clients,sample_period_seconds,n_dead_tup_final,vacuum_count_final,autovacuum_count_final,pgdata_start_kb,pgdata_end_kb,pgdata_min_kb,pgdata_max_kb,base_min_kb,warmup_rc,latency_p50_ms,job_dir" > "$DIAGNOSTIC_RESULT_FILE"
chown "$OS_USER:$OS_USER" "$DIAGNOSTIC_RESULT_FILE"
echo "version,working_set,rows,clients,window,relation_bytes,relation_delta_bytes,io_write_extend_delta_bytes,checkpointer_buffers_delta,checkpoints_completed_delta,wal_generated_bytes,wal_generated_delta_bytes,latency_p95_ms,latency_p99_ms,latency_p999_ms,latency_max_ms" > "$SAMPLE_WINDOW_RESULT_FILE"
chown "$OS_USER:$OS_USER" "$SAMPLE_WINDOW_RESULT_FILE"
echo "version,working_set,rows,loaded_relation_bytes" > "$RESULT_ROOT/load_sizes.csv"
chown "$OS_USER:$OS_USER" "$RESULT_ROOT/load_sizes.csv"
echo "variant,working_set,rows,clients,mdon_sample,variant_sample,base_extra_sample,cross_elapsed_sec,cross_variant_epoch,wal_to_base_extra_final_ratio,final_mdon_base_bytes,final_variant_base_bytes,final_base_extra_vs_mdon_bytes,max_base_extra_vs_mdon_bytes,final_variant_wal_generated_bytes,final_wal_minus_base_extra_bytes" > "$RESULT_ROOT/data_space_crossing.csv"
chown "$OS_USER:$OS_USER" "$RESULT_ROOT/data_space_crossing.csv"

for ver in "${VERSIONS[@]}"; do
    PG_BIN="$PG_INSTALL_ROOT/$ver/bin"
    PG_DATA="$PGDATA_ROOT/exp4/$ver/data"
    PG_DATA_BAK="$PGDATA_BACKUP_ROOT/$ver/data_bak"

    [ -x "$PG_BIN/initdb" ] || die "missing initdb: $PG_BIN/initdb"
    [ -x "$PG_BIN/pg_ctl" ] || die "missing pg_ctl: $PG_BIN/pg_ctl"
    [ -x "$PG_BIN/psql" ] || die "missing psql: $PG_BIN/psql"
    [ -x "$PG_BIN/pgbench" ] || die "missing pgbench: $PG_BIN/pgbench"

    for ws in "${WORKING_SETS[@]}"; do
        rows="$(rows_for_working_set "$ws")"
        load_dir="$RESULT_ROOT/${ver}_${ws}_load"
        mkdir -p "$load_dir"
        chown "$OS_USER:$OS_USER" "$load_dir"

        echo "================================================================="
        echo "[INFO] preparing version=$ver working_set=$ws rows=$rows"
        echo "================================================================="

        stop_server "$PG_BIN" "$PG_DATA"
        mkdir -p "$(dirname "$PG_DATA")" "$(dirname "$PG_DATA_BAK")"
        chown "$OS_USER:$OS_USER" "$(dirname "$PG_DATA")" "$(dirname "$PG_DATA_BAK")"
        rm -rf "$PG_DATA" "$PG_DATA_BAK"

        sudo -u "$OS_USER" "$PG_BIN/initdb" -D "$PG_DATA" > "$load_dir/initdb.log" 2>&1
        configure_postgres "$ver"

        sudo -u "$OS_USER" "$PG_BIN/pg_ctl" -D "$PG_DATA" -l "$load_dir/server.log" -w -t 600 start >/dev/null
        psql_postgres -c "DO \$\$BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$OS_USER') THEN CREATE ROLE $OS_USER LOGIN SUPERUSER; END IF; END\$\$;" >/dev/null
        psql_postgres -c "DROP DATABASE IF EXISTS $DB_NAME;" >/dev/null
        psql_postgres -c "CREATE DATABASE $DB_NAME OWNER $OS_USER;" >/dev/null

        load_working_set "$rows" "$load_dir/load.log"
        loaded_relation_bytes="$(query_exp4_csv "SELECT pg_total_relation_size('exp4_tbl');")"
        echo "$ver,$ws,$rows,$loaded_relation_bytes" >> "$RESULT_ROOT/load_sizes.csv"

        echo "[INFO] stopping clean loaded cluster"
        sudo -u "$OS_USER" "$PG_BIN/pg_ctl" -D "$PG_DATA" stop -m fast -t 1800 >/dev/null

        echo "[INFO] creating clean backup $PG_DATA_BAK"
        cp -r "$PG_DATA" "$PG_DATA_BAK"
        chown -R "$OS_USER:$OS_USER" "$PG_DATA_BAK"

        for clients in "${CLIENTS[@]}"; do
            run_job "$ver" "$ws" "$rows" "$clients"
        done

        echo "[INFO] cleanup version=$ver working_set=$ws"
        stop_server "$PG_BIN" "$PG_DATA"
        rm -rf "$PG_DATA" "$PG_DATA_BAK"
    done
done

echo "================================================================="
echo "[INFO] Exp4 complete"
echo "[INFO] summary: $RESULT_FILE"
