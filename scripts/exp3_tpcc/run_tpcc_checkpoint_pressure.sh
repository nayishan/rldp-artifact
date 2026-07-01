#!/bin/bash

# ==============================================================================
# Exp3 checkpoint-pressure TPC-C runner.
# Runs sync I/O only and varies checkpoint_timeout with max_wal_size fixed.
# ==============================================================================

OS_USER="jiamingwei"
BASE_DIR="/home/jiamingwei"
PG_INSTALL_ROOT="$BASE_DIR"
PGDATA_ROOT="$BASE_DIR"
BM_DIR="$BASE_DIR/benchmarksql-v5/run"
BM_JAR="$BASE_DIR/benchmarksql-v5/dist/BenchmarkSQL-5.1.jar"
PG_PORT=55437
DB_NAME="tpcc"
WH=1200
WARMUP_MINS=2
RUN_MINS=20
MAX_CONNECTIONS=2000

VERSIONS=("mdonrelease" "mdoffrelease" "chunk")
TERMINALS=(10 50 200 400 800 1200)
CHECKPOINT_TIMEOUTS=("30s" "1min" "2min" "4min")
MAX_WAL_SIZE="40GB"

RESULT_ROOT="$BASE_DIR/exp3/results"
RESULT_FILE="$RESULT_ROOT/tpcc_checkpoint_pressure_summary.csv"
RUN_LOG="$RESULT_ROOT/tpcc_checkpoint_pressure_runner.log"
PID_FILE="$RESULT_ROOT/tpcc_checkpoint_pressure_runner.pid"
SCRIPT_PATH="$(readlink -f "$0")"

usage() {
    cat <<EOF
用法:
  sudo $SCRIPT_PATH              后台运行实验（默认）
  sudo $SCRIPT_PATH --background 后台运行实验
  sudo $SCRIPT_PATH --bg         后台运行实验
  sudo $SCRIPT_PATH --foreground 前台运行实验

后台日志:
  $RUN_LOG

PID 文件:
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

reset_result_root() {
    if [ -z "$RESULT_ROOT" ] || [ "$RESULT_ROOT" = "/" ] || [ "$RESULT_ROOT" = "$BASE_DIR" ]; then
        echo "[错误] RESULT_ROOT 不安全，拒绝删除: $RESULT_ROOT"
        exit 1
    fi

    case "$RESULT_ROOT" in
        "$BASE_DIR"/*)
            ;;
        *)
            echo "[错误] RESULT_ROOT 不在 BASE_DIR 下，拒绝删除: $RESULT_ROOT"
            exit 1
            ;;
    esac

    if [ -d "$RESULT_ROOT" ]; then
        echo "[INFO] 删除之前的结果目录: $RESULT_ROOT"
        rm -rf "$RESULT_ROOT"
    fi
    ensure_result_root
}

start_background() {
    local old_pid=""
    local bg_pid=""

    ensure_result_root
    if [ -f "$PID_FILE" ]; then
        old_pid=$(cat "$PID_FILE" 2>/dev/null)
        if is_pid_running "$old_pid"; then
            echo "[INFO] 实验已经在后台运行，PID: $old_pid"
            echo "[INFO] 主日志: $RUN_LOG"
            exit 0
        fi
        rm -f "$PID_FILE"
    fi

    reset_result_root

    if [ "$(id -u)" = "0" ]; then
        nohup env TPCC_BACKGROUND_RUN=1 TPCC_RESULTS_PREPARED=1 bash "$SCRIPT_PATH" --foreground > "$RUN_LOG" 2>&1 < /dev/null &
    else
        if ! command -v sudo >/dev/null 2>&1; then
            echo "[错误] 后台模式需要 root 权限，但未找到 sudo。请用 root 用户运行。"
            exit 1
        fi
        if ! sudo -n true 2>/dev/null; then
            echo "[错误] 后台模式需要 root 权限。请先执行 sudo -v，或直接运行: sudo $SCRIPT_PATH --background"
            exit 1
        fi
        nohup sudo -n env TPCC_BACKGROUND_RUN=1 TPCC_RESULTS_PREPARED=1 bash "$SCRIPT_PATH" --foreground > "$RUN_LOG" 2>&1 < /dev/null &
    fi

    bg_pid=$!
    echo "$bg_pid" > "$PID_FILE"
    if [ "$(id -u)" = "0" ]; then
        chown "$OS_USER:$OS_USER" "$PID_FILE" "$RUN_LOG" 2>/dev/null || true
    fi

    echo "[INFO] 已后台启动，启动进程 PID: $bg_pid"
    echo "[INFO] 主日志: $RUN_LOG"
    echo "[INFO] 结果文件: $RESULT_FILE"
}

register_background_pid() {
    if [ "${TPCC_BACKGROUND_RUN:-0}" = "1" ]; then
        echo "$$" > "$PID_FILE"
        chown "$OS_USER:$OS_USER" "$PID_FILE" 2>/dev/null || true
        trap 'rm -f "$PID_FILE"' EXIT
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

if [ "$(id -u)" != "0" ]; then
    echo "[错误] 本脚本必须使用 root 用户运行，以便执行 drop_caches 清理内存！"
    exit 1
fi

if [ "${TPCC_RESULTS_PREPARED:-0}" = "1" ]; then
    ensure_result_root
else
    reset_result_root
fi

register_background_pid

if [ ! -d "$BM_DIR" ] || [ ! -x "$BM_DIR/runDatabaseBuild.sh" ] || [ ! -x "$BM_DIR/runBenchmark.sh" ]; then
    echo "[错误] BenchmarkSQL 运行目录不存在或脚本不可执行: $BM_DIR"
    exit 1
fi

if [ ! -r "$BM_JAR" ]; then
    echo "[错误] BenchmarkSQL v5 jar 不存在或不可读: $BM_JAR"
    echo "[提示] 请先在 $BASE_DIR/benchmarksql-v5 下执行: ant"
    exit 1
fi

if ! command -v java >/dev/null 2>&1; then
    echo "[错误] 未找到 java，BenchmarkSQL 无法运行。请先安装 OpenJDK。"
    exit 1
fi

echo "checkpoint_timeout,version,clients,tpmC,new_order_count,wal_bytes,wal_bytes_per_new_order,checkpoint_timed_delta,checkpoint_requested_delta,checkpoint_total_delta,checkpoint_buffers_written_delta,checkpoint_write_time_ms_delta,checkpoint_sync_time_ms_delta,avg_latency_ms,p95_latency_ms,p99_latency_ms" > "$RESULT_FILE"
chown "$OS_USER:$OS_USER" "$RESULT_FILE"

generate_props() {
    local conn_terminals=$1
    local run_mins=${2:-$RUN_MINS}
    local result_dir=${3:-}
    local prop_file="$BM_DIR/props.pg_test"

    cat > "$prop_file" <<EOF
db=postgres
driver=org.postgresql.Driver
conn=jdbc:postgresql://127.0.0.1:$PG_PORT/$DB_NAME
user=$OS_USER
password=$OS_USER
warehouses=$WH
loadWorkers=80
terminals=$conn_terminals
runTxnsPerTerminal=0
runMins=$run_mins
limitTxnsPerMin=0
terminalWarehouseFixed=true
useStoredProcedures=false
newOrderWeight=45
paymentWeight=43
orderStatusWeight=4
deliveryWeight=4
stockLevelWeight=4
EOF
    if [ -n "$result_dir" ]; then
        echo "resultDirectory=$result_dir" >> "$prop_file"
    fi
    chown "$OS_USER:$OS_USER" "$prop_file"
}

calc_latency_csv() {
    local result_csv="$1"
    if [ ! -s "$result_csv" ]; then
        echo "-,-,-"
        return
    fi

    awk -F, 'NR > 1 && $8 == 0 { print $3 + 0 }' "$result_csv" | sort -n | awk '
        {
            n++;
            a[n] = $1;
            sum += $1;
        }
        END {
            if (n == 0) {
                print "-,-,-";
                exit;
            }
            p95 = int(n * 0.95 + 0.999999); if (p95 < 1) p95 = 1; if (p95 > n) p95 = n;
            p99 = int(n * 0.99 + 0.999999); if (p99 < 1) p99 = 1; if (p99 > n) p99 = n;
            printf "%.3f,%.3f,%.3f\n", sum / n, a[p95], a[p99];
        }
    '
}

count_new_order_csv() {
    local result_csv="$1"
    if [ ! -s "$result_csv" ]; then
        echo "-"
        return
    fi

    awk -F, 'NR > 1 && $5 == "NEW_ORDER" && $8 == 0 { n++ } END { print n + 0 }' "$result_csv"
}

calc_wal_per_new_order() {
    local wal_bytes="$1"
    local new_order_count="$2"
    awk -v w="$wal_bytes" -v n="$new_order_count" 'BEGIN { if (n > 0) printf "%.6f", w / n; else print "-" }'
}

read_checkpoint_stats_csv() {
    local pg_bin="$1"
    local stats=""

    stats=$(sudo -u "$OS_USER" bash -c "$pg_bin/psql -X -v ON_ERROR_STOP=1 -p $PG_PORT -d postgres -A -t -F ',' -c \"SELECT num_timed, num_requested, buffers_written, write_time, sync_time FROM pg_stat_checkpointer;\"" 2>/dev/null | tail -1 | tr -d ' ')
    if [ -z "$stats" ]; then
        stats=$(sudo -u "$OS_USER" bash -c "$pg_bin/psql -X -v ON_ERROR_STOP=1 -p $PG_PORT -d postgres -A -t -F ',' -c \"SELECT checkpoints_timed, checkpoints_req, buffers_checkpoint, checkpoint_write_time, checkpoint_sync_time FROM pg_stat_bgwriter;\"" 2>/dev/null | tail -1 | tr -d ' ')
    fi

    if [ -z "$stats" ]; then
        echo "-,-,-,-,-"
    else
        echo "$stats"
    fi
}

calc_checkpoint_delta_csv() {
    local before="$1"
    local after="$2"

    if [ "$before" = "-,-,-,-,-" ] || [ "$after" = "-,-,-,-,-" ]; then
        echo "-,-,-,-,-,-"
        return
    fi

    awk -F, -v before="$before" -v after="$after" '
        BEGIN {
            split(before, b, ",");
            split(after, a, ",");
            timed = a[1] - b[1];
            requested = a[2] - b[2];
            total = timed + requested;
            buffers = a[3] - b[3];
            write_time = a[4] - b[4];
            sync_time = a[5] - b[5];
            printf "%.0f,%.0f,%.0f,%.0f,%.3f,%.3f\n", timed, requested, total, buffers, write_time, sync_time;
        }
    '
}

validate_pg_bin() {
    local ver="$1"
    local pg_bin="$2"
    local missing=0
    local tool=""

    for tool in pg_ctl initdb psql dropdb createdb; do
        if [ ! -x "$pg_bin/$tool" ]; then
            echo "[错误] $ver 缺少可执行文件: $pg_bin/$tool"
            missing=1
        fi
    done

    if [ "$missing" != "0" ]; then
        echo "[提示] 当前脚本固定使用版本目录: $PG_INSTALL_ROOT/$ver"
        exit 1
    fi
}

append_common_pg_conf() {
    local conf_file="$1"
    local ver="$2"
    local fpw="${3:-}"

    sudo -u "$OS_USER" bash -c "cat >> '$conf_file' <<EOF
shared_buffers = 40GB
max_connections = $MAX_CONNECTIONS
listen_addresses = '*'
port = $PG_PORT
io_method = sync
effective_io_concurrency = 0
maintenance_io_concurrency = 0
checkpoint_timeout = 4min
max_wal_size = $MAX_WAL_SIZE
log_checkpoints = on
EOF"

    append_full_page_writes_pg_conf "$conf_file" "$ver" "$fpw"
    append_version_extra_pg_conf "$conf_file" "$ver"
}

version_full_page_writes() {
    local ver="$1"

    if [ "$ver" = "mdoffrelease" ]; then
        echo "off"
    else
        echo "on"
    fi
}

append_full_page_writes_pg_conf() {
    local conf_file="$1"
    local ver="$2"
    local fpw="${3:-}"

    if [ -z "$fpw" ]; then
        fpw="$(version_full_page_writes "$ver")"
    fi

    case "$ver" in
        mdonrelease|mdoffrelease|chunk)
            sudo -u "$OS_USER" bash -c "echo 'full_page_writes = $fpw' >> '$conf_file'"
            ;;
    esac
}

append_version_extra_pg_conf() {
    local conf_file="$1"
    local ver="$2"

    :
}

append_run_pg_conf() {
    local conf_file="$1"
    local checkpoint_timeout="$2"

    sudo -u "$OS_USER" bash -c "cat >> '$conf_file' <<EOF

# Exp3 checkpoint-pressure run override
checkpoint_timeout = $checkpoint_timeout
max_wal_size = $MAX_WAL_SIZE
io_method = sync
effective_io_concurrency = 0
maintenance_io_concurrency = 0
EOF"
}

for ver in "${VERSIONS[@]}"; do
    echo "================================================================="
    echo "开始处理版本: $ver | IO模式: sync | max_wal_size: $MAX_WAL_SIZE"
    echo "================================================================="

    PG_BIN="$PG_INSTALL_ROOT/$ver/bin"
    PG_DATA="$PGDATA_ROOT/exp3/$ver/data"
    PG_DATA_BAK="$BASE_DIR/exp3/pgbackup/$ver/data_bak"

    validate_pg_bin "$ver" "$PG_BIN"

    sudo -u "$OS_USER" bash -c "$PG_BIN/pg_ctl -D '$PG_DATA' stop -m immediate >/dev/null 2>&1"
    pkill -u "$OS_USER" -f "$PG_DATA" 2>/dev/null
    sleep 2

    echo "[INFO] 初始化独立的数据库目录 $PG_DATA ..."
    mkdir -p "$(dirname "$PG_DATA")" "$(dirname "$PG_DATA_BAK")"
    chown "$OS_USER:$OS_USER" "$(dirname "$PG_DATA")" "$(dirname "$PG_DATA_BAK")"
    rm -rf "$PG_DATA" "$PG_DATA_BAK"
    if ! sudo -u "$OS_USER" bash -c "$PG_BIN/initdb -D '$PG_DATA' >/dev/null 2>&1"; then
        echo "[错误] initdb 失败: $PG_BIN/initdb -D $PG_DATA"
        exit 1
    fi

    echo "[INFO] 配置 PostgreSQL 参数 ..."
    CONF_FILE="$PG_DATA/postgresql.conf"
    HBA_FILE="$PG_DATA/pg_hba.conf"
    append_common_pg_conf "$CONF_FILE" "$ver" "off"
    sudo -u "$OS_USER" bash -c "echo 'host all all 127.0.0.1/32 trust' >> '$HBA_FILE'"
    sudo -u "$OS_USER" bash -c "echo 'local all all trust' >> '$HBA_FILE'"

    echo "[INFO] 启动数据库并以 full_page_writes=off 灌入 $WH 仓数据 ..."
    if ! sudo -u "$OS_USER" bash -c "$PG_BIN/pg_ctl -D '$PG_DATA' -l '$PG_DATA/logfile' start >/dev/null 2>&1"; then
        echo "[错误] 数据库启动失败: $PG_DATA"
        tail -n 50 "$PG_DATA/logfile" 2>/dev/null || true
        exit 1
    fi
    sleep 5

    sudo -u "$OS_USER" bash -c "$PG_BIN/psql -p $PG_PORT -c \"CREATE USER $OS_USER WITH PASSWORD '$OS_USER' SUPERUSER;\" postgres >/dev/null 2>&1" || true
    sudo -u "$OS_USER" bash -c "$PG_BIN/dropdb -p $PG_PORT --if-exists $DB_NAME >/dev/null 2>&1"
    if ! sudo -u "$OS_USER" bash -c "$PG_BIN/createdb -p $PG_PORT $DB_NAME -O $OS_USER"; then
        echo "[错误] createdb 失败: $PG_BIN/createdb -p $PG_PORT $DB_NAME -O $OS_USER"
        tail -n 50 "$PG_DATA/logfile" 2>/dev/null || true
        exit 1
    fi

    generate_props 10 "$RUN_MINS"
    if ! sudo -u "$OS_USER" bash -c "cd '$BM_DIR' && ./runDatabaseBuild.sh props.pg_test"; then
        echo "[错误] BenchmarkSQL 灌数失败，停止当前实验。"
        sudo -u "$OS_USER" bash -c "$PG_BIN/pg_ctl -D '$PG_DATA' stop -m immediate >/dev/null 2>&1" || true
        exit 1
    fi

    echo "[INFO] 灌数完成，正在安全关闭数据库 ..."
    sudo -u "$OS_USER" bash -c "$PG_BIN/pg_ctl -D '$PG_DATA' stop -m fast -t 600 >/dev/null 2>&1"

    echo "[INFO] 恢复 $ver 的正式测试 full_page_writes 配置 ..."
    append_full_page_writes_pg_conf "$CONF_FILE" "$ver"

    echo "[INFO] 生成 $WH 仓干净的数据冷备 ..."
    cp -r "$PG_DATA" "$PG_DATA_BAK"
    chown -R "$OS_USER:$OS_USER" "$PG_DATA_BAK"

    for checkpoint_timeout in "${CHECKPOINT_TIMEOUTS[@]}"; do
        checkpoint_label="${checkpoint_timeout//[^a-zA-Z0-9]/}"
        RESULT_DIR="$RESULT_ROOT/$ver/$checkpoint_label"
        mkdir -p "$RESULT_DIR"
        chown -R "$OS_USER:$OS_USER" "$RESULT_ROOT/$ver"

        for term in "${TERMINALS[@]}"; do
            echo "-------------------------------------------------------------"
            echo "[INFO] 当前测试 -> 版本: $ver | checkpoint_timeout: $checkpoint_timeout | 并发数: $term"

            rm -rf "$PG_DATA"
            cp -r "$PG_DATA_BAK" "$PG_DATA"
            chown -R "$OS_USER:$OS_USER" "$PG_DATA"
            append_run_pg_conf "$PG_DATA/postgresql.conf" "$checkpoint_timeout"

            echo "[INFO] 清理系统内存和 Cache ..."
            sync
            echo 3 > /proc/sys/vm/drop_caches

            if ! sudo -u "$OS_USER" bash -c "$PG_BIN/pg_ctl -D '$PG_DATA' -l '$PG_DATA/logfile' start >/dev/null 2>&1"; then
                echo "[错误] 数据库启动失败: $PG_DATA"
                tail -n 50 "$PG_DATA/logfile" 2>/dev/null || true
                exit 1
            fi
            sleep 5

            BMSQL_RESULT_DIR="$RESULT_DIR/${ver}_${checkpoint_label}_${term}_bmsql"
            rm -rf "$BMSQL_RESULT_DIR"

            generate_props "$term" "$WARMUP_MINS"
            WARMUP_LOG_FILE="$RESULT_DIR/tpcc_${ver}_${checkpoint_label}_${term}_warmup.log"
            echo "[INFO] 开始预热 ${WARMUP_MINS} 分钟 (日志: $WARMUP_LOG_FILE) ..."
            sudo -u "$OS_USER" bash -c "cd '$BM_DIR' && ./runBenchmark.sh props.pg_test" > "$WARMUP_LOG_FILE" 2>&1
            WARMUP_RC=$?

            START_LSN=$(sudo -u "$OS_USER" bash -c "$PG_BIN/psql -p $PG_PORT -d postgres -t -c \"SELECT pg_current_wal_insert_lsn();\"" | tr -d ' ')
            CHECKPOINT_STATS_BEFORE=$(read_checkpoint_stats_csv "$PG_BIN")

            generate_props "$term" "$RUN_MINS" "$BMSQL_RESULT_DIR"
            LOG_FILE="$RESULT_DIR/tpcc_${ver}_${checkpoint_label}_${term}.log"
            echo "[INFO] 开始压测 (详细日志: $LOG_FILE) ..."
            sudo -u "$OS_USER" bash -c "cd '$BM_DIR' && ./runBenchmark.sh props.pg_test" > "$LOG_FILE" 2>&1
            RUN_RC=$?

            CHECKPOINT_STATS_AFTER=$(read_checkpoint_stats_csv "$PG_BIN")
            CHECKPOINT_DELTA_CSV=$(calc_checkpoint_delta_csv "$CHECKPOINT_STATS_BEFORE" "$CHECKPOINT_STATS_AFTER")
            END_LSN=$(sudo -u "$OS_USER" bash -c "$PG_BIN/psql -p $PG_PORT -d postgres -t -c \"SELECT pg_current_wal_insert_lsn();\"" | tr -d ' ')
            WAL_BYTES=$(sudo -u "$OS_USER" bash -c "$PG_BIN/psql -p $PG_PORT -d postgres -t -c \"SELECT pg_wal_lsn_diff('$END_LSN', '$START_LSN');\"" | tr -d ' ')

            TPMC=$(grep "Measured tpmC" "$LOG_FILE" | tail -1 | awk -F '=' '{print $2}' | awk '{print $1}' | tr -d ' )')
            LATENCY_CSV=$(calc_latency_csv "$BMSQL_RESULT_DIR/data/result.csv")
            NEW_ORDER_COUNT=$(count_new_order_csv "$BMSQL_RESULT_DIR/data/result.csv")

            if [ -z "$TPMC" ]; then
                TPMC="-"
                NEW_ORDER_COUNT="-"
                WAL_BYTES="-"
                WAL_PER_NEW_ORDER="-"
                LATENCY_CSV="-,-,-"
                echo "[WARN] 未获取到 tpmC！ warmup_rc=$WARMUP_RC run_rc=$RUN_RC"
            else
                if [ "$WARMUP_RC" != "0" ] || [ "$RUN_RC" != "0" ]; then
                    echo "[WARN] BenchmarkSQL 返回非0，但已获取到 tpmC，继续记录结果。 warmup_rc=$WARMUP_RC run_rc=$RUN_RC"
                fi
                WAL_PER_NEW_ORDER=$(calc_wal_per_new_order "$WAL_BYTES" "$NEW_ORDER_COUNT")
            fi

            echo "[INFO] 测试完成! tpmC = $TPMC | NewOrder = $NEW_ORDER_COUNT | 产生WAL = $WAL_BYTES Bytes | WAL/NewOrder = $WAL_PER_NEW_ORDER | checkpoint_delta = $CHECKPOINT_DELTA_CSV"
            echo "$checkpoint_timeout,$ver,$term,$TPMC,$NEW_ORDER_COUNT,$WAL_BYTES,$WAL_PER_NEW_ORDER,$CHECKPOINT_DELTA_CSV,$LATENCY_CSV" >> "$RESULT_FILE"

            if [ -f "$PG_DATA/logfile" ]; then
                cp "$PG_DATA/logfile" "$RESULT_DIR/postgres_${ver}_${checkpoint_label}_${term}.log"
                chown "$OS_USER:$OS_USER" "$RESULT_DIR/postgres_${ver}_${checkpoint_label}_${term}.log" 2>/dev/null || true
            fi

            echo "[INFO] 强制停止数据库，清理现场 ..."
            sudo -u "$OS_USER" bash -c "$PG_BIN/pg_ctl -D '$PG_DATA' stop -m immediate >/dev/null 2>&1"
            pkill -u "$OS_USER" -f "$PG_DATA" 2>/dev/null
            sleep 2
        done
    done

    echo "[INFO] $ver 测试结束，正在删除 data 和 data_bak 目录以释放空间 ..."
    rm -rf "$PG_DATA" "$PG_DATA_BAK"
    echo "[INFO] $ver 版本测试已完成。"
done

echo "================================================================="
echo "全部测试完成。结果文件：$RESULT_FILE"
echo "================================================================="
