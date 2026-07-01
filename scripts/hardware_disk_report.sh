#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(pwd)"
TEST_SIZE="16G"
TEST_RUNTIME=300
ALL_MOUNTS=0
NO_BENCH=0
ORIGINAL_ARG_COUNT=$#
ORIGINAL_ARGS=()
if [[ "$ORIGINAL_ARG_COUNT" -gt 0 ]]; then
  ORIGINAL_ARGS=("$@")
fi
GENERATED_DATA_FILES=()
GENERATED_DATA_FILE_COUNT=0

usage() {
  cat <<'EOF'
Usage:
  ./hardware_disk_report.sh [options]

Options:
  -d, --dir PATH       Directory used for disk benchmark files. Default: current directory.
  -s, --size SIZE      fio working set size, or dd test file size. Default: 16G.
                       Examples: 4G, 16G, 64G.
  -r, --runtime SEC    fio runtime per benchmark job. Default: 300 seconds.
  --all-mounts         Run benchmarks on every writable local filesystem mount.
  --no-bench           Only print hardware and filesystem information; skip performance tests.
  -h, --help           Show this help.

Notes:
  - The script automatically saves output to hardware_disk_report.txt and overwrites it on each run.
  - Output is intentionally concise and avoids hostnames, user names, serial numbers, and full benchmark paths.
  - It reports CPU, memory, the experiment filesystem's block-device chain,
    and disk read/write summaries.
  - Benchmarks are non-destructive and use temporary files under the test directory.
  - Run as root. The script exits with an error otherwise.
  - If fio is installed, the script runs sequential read/write and random read/write tests.
  - If fio is unavailable, it falls back to basic dd sequential write/read tests.
  - fio tests run for the configured runtime; size controls the per-job working set.
  - Results can be affected by OS cache, current load, filesystem, mount options, and test size.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--dir)
      TEST_DIR="${2:-}"
      shift 2
      ;;
    -s|--size)
      TEST_SIZE="${2:-}"
      shift 2
      ;;
    -r|--runtime)
      TEST_RUNTIME="${2:-}"
      shift 2
      ;;
    --all-mounts)
      ALL_MOUNTS=1
      shift
      ;;
    --no-bench)
      NO_BENCH=1
      shift
      ;;
    --keep-files)
      echo "WARNING: --keep-files is ignored; benchmark .data files are always removed." >&2
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

REPORT_FILE="hardware_disk_report.txt"
if [[ "${HARDWARE_DISK_REPORT_LOGGING:-0}" != "1" ]]; then
  if [[ $EUID -ne 0 ]]; then
    echo "ERROR: please run as root, for example: sudo $0" >&2
    exit 1
  fi
  export HARDWARE_DISK_REPORT_LOGGING=1
  set +e
  {
    echo "Report file : $REPORT_FILE"
    echo
    if [[ "$ORIGINAL_ARG_COUNT" -gt 0 ]]; then
      "${BASH:-bash}" "$0" "${ORIGINAL_ARGS[@]}"
    else
      "${BASH:-bash}" "$0"
    fi
  } 2>&1 | tee "$REPORT_FILE"
  status=${PIPESTATUS[0]}
  set -e
  exit "$status"
fi

cleanup_generated_data_files() {
  local file
  [[ "$GENERATED_DATA_FILE_COUNT" -gt 0 ]] || return
  for file in "${GENERATED_DATA_FILES[@]}"; do
    [[ -n "$file" ]] || continue
    rm -f -- "$file" "$file".*
  done
}

trap cleanup_generated_data_files EXIT

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "ERROR: please run as root, for example: sudo $0" >&2
    exit 1
  fi
}

section() {

  printf '\n========== %s ==========\n' "$1"
}

size_to_mib() {
  local value="$1"
  local number unit

  if [[ "$value" =~ ^([0-9]+)([KkMmGgTt]?)$ ]]; then
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    case "$unit" in
      K|k) echo $(( (number + 1023) / 1024 )) ;;
      M|m|"") echo "$number" ;;
      G|g) echo $(( number * 1024 )) ;;
      T|t) echo $(( number * 1024 * 1024 )) ;;
    esac
  else
    echo "Invalid size: $value" >&2
    exit 2
  fi
}

print_header() {
  section "Report"
  echo "Generated at : $(date -Is)"
  echo "Kernel       : $(uname -srmo)"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "OS           : ${PRETTY_NAME:-unknown}"
  fi
}

print_hardware() {
  section "CPU Summary"
  if command -v lscpu >/dev/null 2>&1; then
    lscpu | awk -F: '
      function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
      $1 == "Architecture" { arch=trim($2) }
      $1 == "Vendor ID" { vendor=trim($2) }
      $1 == "Model name" { model=trim($2) }
      $1 == "Socket(s)" { sockets=trim($2) }
      $1 == "Core(s) per socket" { cores=trim($2) }
      $1 == "Thread(s) per core" { threads=trim($2) }
      $1 == "CPU(s)" { cpus=trim($2) }
      $1 == "CPU max MHz" { maxmhz=trim($2) }
      END {
        if (model != "") printf "  Model        : %s\n", model
        if (vendor != "") printf "  Vendor       : %s\n", vendor
        if (arch != "") printf "  Architecture : %s\n", arch
        if (cpus != "") printf "  CPUs         : %s\n", cpus
        if (sockets != "") printf "  Sockets      : %s\n", sockets
        if (cores != "") printf "  Cores/socket : %s\n", cores
        if (threads != "") printf "  Threads/core : %s\n", threads
        if (maxmhz != "") printf "  Max MHz      : %s\n", maxmhz
      }'
  else
    echo "  lscpu: not installed"
  fi

  section "Memory Summary"
  if command -v free >/dev/null 2>&1; then
    free -h | awk '
      /^Mem:/ { printf "  Memory : total=%s used=%s available=%s\n", $2, $3, $7 }
      /^Swap:/ { printf "  Swap   : total=%s used=%s free=%s\n", $2, $3, $4 }'
  else
    echo "  free: not installed"
  fi

  if command -v dmidecode >/dev/null 2>&1; then
    local memory_modules
    memory_modules="$(
      dmidecode -t memory 2>/dev/null | awk -F: '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        function emit() {
          if (size == "" || size ~ /No Module Installed/) return
          if (locator == "") locator="-"
          if (speed == "") speed="-"
          if (manufacturer == "") manufacturer="-"
          if (part == "") part="-"
          printf "  %-18s %-12s %-14s %-22s %s\n", locator, size, speed, manufacturer, part
        }
        /^Memory Device$/ {
          if (in_device) emit()
          in_device=1
          size=locator=speed=manufacturer=part=""
          next
        }
        in_device && /^[ \t]+Locator:/ { locator=trim($2); next }
        in_device && /^[ \t]+Size:/ { size=trim($2); next }
        in_device && /^[ \t]+Manufacturer:/ { manufacturer=trim($2); next }
        in_device && /^[ \t]+Part Number:/ { part=trim($2); next }
        in_device && /^[ \t]+Configured Memory Speed:/ { speed=trim($2); next }
        in_device && speed == "" && /^[ \t]+Speed:/ { speed=trim($2); next }
        END {
          if (in_device) emit()
        }'
    )"
    if [[ -n "$memory_modules" ]]; then
      printf '  %-18s %-12s %-14s %-22s %s\n' "Slot" "Size" "Speed" "Manufacturer" "Part"
      printf '%s\n' "$memory_modules"
    else
      echo "  DIMM details: no populated module details found"
    fi
  else
    echo "  dmidecode: not installed; DIMM brand/part details unavailable"
  fi

}

print_experiment_storage() {
  local dir="$1"
  local target source fstype

  section "Experiment Storage"
  echo "Benchmark path: <redacted>"

  if command -v findmnt >/dev/null 2>&1; then
    target="$(findmnt -T "$dir" -n -o TARGET 2>/dev/null || true)"
    source="$(findmnt -T "$dir" -n -o SOURCE 2>/dev/null || true)"
    fstype="$(findmnt -T "$dir" -n -o FSTYPE 2>/dev/null || true)"

    if [[ -n "$target" ]]; then
      echo "Mount point : $target"
    fi
    if [[ -n "$source" ]]; then
      echo "Source      : $source"
    fi
    if [[ -n "$fstype" ]]; then
      echo "Filesystem  : $fstype"
    fi
  else
    source=""
    echo "findmnt: not installed"
  fi

  echo
  echo "Filesystem capacity:"
  df -hT "$dir" || true

  echo
  echo "Block-device chain for benchmark filesystem:"
  if [[ -n "$source" ]] && command -v lsblk >/dev/null 2>&1; then
    if ! lsblk -s -o NAME,TYPE,SIZE,TRAN,MODEL,MOUNTPOINT "$source" 2>/dev/null; then
      lsblk -o NAME,TYPE,SIZE,TRAN,MODEL,MOUNTPOINT "$source" 2>/dev/null || true
    fi
  elif command -v lsblk >/dev/null 2>&1; then
    echo "  source device unavailable"
  else
    echo "  lsblk: not installed"
  fi
}

mounts_for_benchmark() {
  if [[ "$ALL_MOUNTS" -eq 0 ]]; then
    printf '%s\n' "$TEST_DIR"
    return
  fi

  findmnt -rn -t nosquashfs,nodevtmpfs,notmpfs -o TARGET,OPTIONS 2>/dev/null \
    | awk '$2 !~ /(^|,)ro(,|$)/ {print $1}' \
    | while read -r mountpoint; do
        [[ -w "$mountpoint" ]] && printf '%s\n' "$mountpoint"
      done
}

drop_caches_if_root() {
  sync
  if [[ -w /proc/sys/vm/drop_caches ]]; then
    echo 3 > /proc/sys/vm/drop_caches || true
  fi
}

print_fio_summary() {
  local output_file="$1"

  if ! awk '
    /^[[:space:]]+(READ|WRITE):/ {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      print "  " line
      found=1
    }
    END { exit found ? 0 : 1 }' "$output_file"; then
    echo "  fio completed, but no compact summary was found; last output lines:"
    tail -n 20 "$output_file" | sed 's/^/  /'
  fi
}

run_fio_summary() {
  local label="$1"
  shift
  local output_file

  output_file="$(mktemp "${TMPDIR:-/tmp}/hardware-disk-report-fio.XXXXXX")"
  echo "$label"
  if fio "$@" --eta=never --output-format=normal --output="$output_file"; then
    print_fio_summary "$output_file"
  else
    echo "  fio failed; last output lines:"
    tail -n 30 "$output_file" | sed 's/^/  /'
    rm -f "$output_file"
    return 1
  fi
  rm -f "$output_file"
}

benchmark_with_fio() {
  local dir="$1"
  local name="hardware-disk-report-$$"
  local file="$dir/$name.data"

  GENERATED_DATA_FILES+=("$file")
  GENERATED_DATA_FILE_COUNT=${#GENERATED_DATA_FILES[@]}

  echo "Tool: fio, size=$TEST_SIZE, runtime=${TEST_RUNTIME}s"
  run_fio_summary "Sequential write" \
    --name="$name-seq-write" \
    --directory="$dir" \
    --filename="$name.data" \
    --size="$TEST_SIZE" \
    --rw=write \
    --bs=1M \
    --iodepth=16 \
    --numjobs=1 \
    --direct=1 \
    --invalidate=1 \
    --randrepeat=0 \
    --refill_buffers=1 \
    --runtime="$TEST_RUNTIME" \
    --time_based=1 \
    --group_reporting

  drop_caches_if_root

  run_fio_summary "Sequential read" \
    --name="$name-seq-read" \
    --directory="$dir" \
    --filename="$name.data" \
    --size="$TEST_SIZE" \
    --rw=read \
    --bs=1M \
    --iodepth=16 \
    --numjobs=1 \
    --direct=1 \
    --invalidate=1 \
    --randrepeat=0 \
    --refill_buffers=1 \
    --runtime="$TEST_RUNTIME" \
    --time_based=1 \
    --group_reporting

  drop_caches_if_root

  run_fio_summary "Random read/write 70/30, 4K" \
    --name="$name-rand-readwrite" \
    --directory="$dir" \
    --filename="$name.data" \
    --size="$TEST_SIZE" \
    --rw=randrw \
    --rwmixread=70 \
    --bs=4k \
    --iodepth=32 \
    --numjobs=4 \
    --direct=1 \
    --invalidate=1 \
    --randrepeat=0 \
    --refill_buffers=1 \
    --runtime="$TEST_RUNTIME" \
    --time_based=1 \
    --group_reporting

  cleanup_generated_data_files
  GENERATED_DATA_FILES=()
  GENERATED_DATA_FILE_COUNT=0
}

format_mibs_per_second() {
  local mib="$1"
  local elapsed_ns="$2"

  awk -v mib="$mib" -v elapsed_ns="$elapsed_ns" '
    BEGIN {
      if (elapsed_ns <= 0) {
        print "unknown"
      } else {
        printf "%.1f MiB/s", mib / (elapsed_ns / 1000000000)
      }
    }'
}

benchmark_with_dd() {
  local dir="$1"
  local mib
  local file="$dir/hardware-disk-report-$$.data"
  local start_ns end_ns elapsed_ns rate

  GENERATED_DATA_FILES+=("$file")
  GENERATED_DATA_FILE_COUNT=${#GENERATED_DATA_FILES[@]}

  mib="$(size_to_mib "$TEST_SIZE")"
  if [[ "$mib" -lt 1 ]]; then
    mib=1
  fi

  echo "Tool: dd fallback, size=${mib}MiB"
  echo "Sequential write"
  start_ns="$(date +%s%N)"
  dd if=/dev/zero of="$file" bs=1M count="$mib" conv=fdatasync status=none
  end_ns="$(date +%s%N)"
  elapsed_ns=$((end_ns - start_ns))
  rate="$(format_mibs_per_second "$mib" "$elapsed_ns")"
  echo "  WRITE: bw=$rate, size=${mib}MiB"

  drop_caches_if_root

  echo "Sequential read"
  start_ns="$(date +%s%N)"
  dd if="$file" of=/dev/null bs=1M status=none
  end_ns="$(date +%s%N)"
  elapsed_ns=$((end_ns - start_ns))
  rate="$(format_mibs_per_second "$mib" "$elapsed_ns")"
  echo "  READ: bw=$rate, size=${mib}MiB"

  cleanup_generated_data_files
  GENERATED_DATA_FILES=()
  GENERATED_DATA_FILE_COUNT=0
}

benchmark_dir() {
  local dir="$1"

  if [[ ! -d "$dir" ]]; then
    echo "Skip $dir: not a directory"
    return
  fi
  if [[ ! -w "$dir" ]]; then
    echo "Skip $dir: not writable"
    return
  fi

  section "Disk Benchmark"
  if command -v fio >/dev/null 2>&1; then
    benchmark_with_fio "$dir"
  else
    echo "fio is not installed; using dd fallback."
    benchmark_with_dd "$dir"
  fi
}

main() {
  require_root "$@"
  print_header
  print_hardware
  print_experiment_storage "$TEST_DIR"

  if [[ "$NO_BENCH" -eq 1 ]]; then
    section "Disk Benchmark"
    echo "Skipped by --no-bench"
    return
  fi

  while read -r dir; do
    [[ -n "$dir" ]] || continue
    benchmark_dir "$dir"
  done < <(mounts_for_benchmark)
}

main "$@"
