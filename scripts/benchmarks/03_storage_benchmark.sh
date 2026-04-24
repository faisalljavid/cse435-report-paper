#!/usr/bin/env bash
# =============================================================================
# 03_storage_benchmark.sh
# Runs fio storage I/O benchmark across three environments.
#
# Tests:
#   a) Random Read  — 4K block size, direct I/O, 32 queue depth, 4 jobs
#   b) Random Write — 4K block size, direct I/O, 32 queue depth, 4 jobs
#   c) Sequential Read  — 1M block size, direct I/O
#   d) Sequential Write — 1M block size, direct I/O
#
# Metric: IOPS and throughput (MB/s)
# Replicates: Felter et al. (2015), Section II-C, Storage benchmark (fio)
#
# Usage: sudo bash scripts/benchmarks/03_storage_benchmark.sh
# =============================================================================

set -euo pipefail

RESULTS_DIR="$(cd "$(dirname "$0")/../../results" && pwd)"
VM_IP="${VM_IP:-$(cat /tmp/vm_ip.txt 2>/dev/null || echo '')}"
VM_USER="bench"
DEFAULT_TEST_FILE_SIZE_BYTES=$((4 * 1024 * 1024 * 1024))
MIN_TEST_FILE_SIZE_BYTES=$((128 * 1024 * 1024))
FREE_SPACE_USAGE_PERCENT=60
RUNTIME=60

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
log()     { echo -e "${GREEN}[I/O]${NC} $*"; }
section() { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

bytes_to_mib_string() {
    local bytes=$1
    echo "$(( bytes / 1024 / 1024 ))M"
}

calc_safe_size_bytes_for_path() {
    local path=$1
    local numjobs=$2
    local avail_kb avail_bytes safe_bytes

    avail_kb=$(df -Pk "$path" | awk 'NR==2 {print $4}')
    avail_bytes=$(( avail_kb * 1024 ))
    safe_bytes=$(( avail_bytes * FREE_SPACE_USAGE_PERCENT / 100 / numjobs ))

    if (( safe_bytes > DEFAULT_TEST_FILE_SIZE_BYTES )); then
        safe_bytes=$DEFAULT_TEST_FILE_SIZE_BYTES
    fi

    if (( safe_bytes < MIN_TEST_FILE_SIZE_BYTES )); then
        safe_bytes=$MIN_TEST_FILE_SIZE_BYTES
    fi

    echo "$safe_bytes"
}

run_fio_job() {
    local name=$1
    local rw=$2
    local bs=$3
    local numjobs=$4
    local iodepth=$5
    local size_bytes=$6
    local directory=$7

    fio \
        --name="$name" \
        --rw="$rw" \
        --bs="$bs" \
        --direct=1 \
        --numjobs="$numjobs" \
        --iodepth="$iodepth" \
        --size="$(bytes_to_mib_string "$size_bytes")" \
        --runtime="$RUNTIME" \
        --time_based \
        --group_reporting \
        --output-format=normal \
        --directory="$directory"
}

run_fio_docker() {
    local target_dir=$1
    local rw=$2
    local numjobs=$3
    local bs=$4
    local iodepth=$5
    local name=$6
    shift 6

    docker run --rm "$@" ubuntu:22.04 bash -lc "
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null
        apt-get install -qq -y --no-install-recommends fio >/dev/null
        avail_kb=\$(df -Pk '$target_dir' | awk 'NR==2 {print \$4}')
        avail_bytes=\$((avail_kb * 1024))
        size_bytes=\$((avail_bytes * $FREE_SPACE_USAGE_PERCENT / 100 / $numjobs))
        if (( size_bytes > $DEFAULT_TEST_FILE_SIZE_BYTES )); then
            size_bytes=$DEFAULT_TEST_FILE_SIZE_BYTES
        fi
        if (( size_bytes < $MIN_TEST_FILE_SIZE_BYTES )); then
            size_bytes=$MIN_TEST_FILE_SIZE_BYTES
        fi
        fio \
            --name='$name' \
            --rw='$rw' \
            --bs='$bs' \
            --direct=1 \
            --numjobs=$numjobs \
            --iodepth=$iodepth \
            --size=\$((size_bytes / 1024 / 1024))M \
            --runtime=$RUNTIME \
            --time_based \
            --group_reporting \
            --output-format=normal \
            --directory='$target_dir'
    "
}

mkdir -p "$RESULTS_DIR/native" "$RESULTS_DIR/docker" "$RESULTS_DIR/kvm"

# --------------------------------------------------------------------------- #
# 1. NATIVE
# --------------------------------------------------------------------------- #
section "Native Storage I/O Benchmark"
OUT="$RESULTS_DIR/native/storage.txt"
echo "# Storage I/O Benchmark — Native (Bare Metal)" > "$OUT"
echo "# Date: $(date)" >> "$OUT"
echo "# Tool: fio, 4K random RW (direct I/O, qd=32, 4 jobs), 1M sequential RW" >> "$OUT"
echo "" >> "$OUT"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

RAND_SIZE_BYTES=$(calc_safe_size_bytes_for_path "$TMPDIR" 4)
SEQ_SIZE_BYTES=$(calc_safe_size_bytes_for_path "$TMPDIR" 1)

log "Running native random read (${RUNTIME}s) with $(bytes_to_mib_string "$RAND_SIZE_BYTES") per fio job..."
echo "=== Random Read (4K, Direct I/O, QD=32, 4 jobs) ===" >> "$OUT"
run_fio_job "rand_read" "randread" "4k" 4 32 "$RAND_SIZE_BYTES" "$TMPDIR" >> "$OUT" 2>&1
echo "" >> "$OUT"

log "Running native random write (${RUNTIME}s) with $(bytes_to_mib_string "$RAND_SIZE_BYTES") per fio job..."
echo "=== Random Write (4K, Direct I/O, QD=32, 4 jobs) ===" >> "$OUT"
run_fio_job "rand_write" "randwrite" "4k" 4 32 "$RAND_SIZE_BYTES" "$TMPDIR" >> "$OUT" 2>&1
echo "" >> "$OUT"

log "Running native sequential read (${RUNTIME}s) with $(bytes_to_mib_string "$SEQ_SIZE_BYTES")..."
echo "=== Sequential Read (1M, Direct I/O) ===" >> "$OUT"
run_fio_job "seq_read" "read" "1M" 1 8 "$SEQ_SIZE_BYTES" "$TMPDIR" >> "$OUT" 2>&1
echo "" >> "$OUT"

log "Running native sequential write (${RUNTIME}s) with $(bytes_to_mib_string "$SEQ_SIZE_BYTES")..."
echo "=== Sequential Write (1M, Direct I/O) ===" >> "$OUT"
run_fio_job "seq_write" "write" "1M" 1 8 "$SEQ_SIZE_BYTES" "$TMPDIR" >> "$OUT" 2>&1

log "Native results saved to $OUT"

# --------------------------------------------------------------------------- #
# 2. DOCKER — Optimal (Docker volume, bypasses AUFS)
# --------------------------------------------------------------------------- #
section "Docker Storage I/O Benchmark (Volume — optimal)"
OUT="$RESULTS_DIR/docker/storage_volume.txt"
echo "# Storage I/O Benchmark — Docker with Docker Volume (bypass AUFS)" > "$OUT"
echo "# Date: $(date)" >> "$OUT"
echo "" >> "$OUT"

log "Running Docker+volume random read..."
echo "=== Random Read ===" >> "$OUT"
run_fio_docker "/data" "randread" 4 "4k" 32 "rand_read" \
    --volume benchmark_vol:/data \
    --network host >> "$OUT" 2>&1
echo "" >> "$OUT"

log "Running Docker+volume random write..."
echo "=== Random Write ===" >> "$OUT"
run_fio_docker "/data" "randwrite" 4 "4k" 32 "rand_write" \
    --volume benchmark_vol:/data \
    --network host >> "$OUT" 2>&1
log "Docker volume results saved to $OUT"

# --------------------------------------------------------------------------- #
# 3. DOCKER — Default (OverlayFS, writes to container layer)
# --------------------------------------------------------------------------- #
section "Docker Storage I/O Benchmark (OverlayFS — default)"
OUT="$RESULTS_DIR/docker/storage_overlayfs.txt"
echo "# Storage I/O Benchmark — Docker with OverlayFS (default container storage)" > "$OUT"
echo "# Date: $(date)" >> "$OUT"
echo "" >> "$OUT"

log "Running Docker+OverlayFS random read..."
echo "=== Random Read ===" >> "$OUT"
run_fio_docker "/tmp" "randread" 4 "4k" 32 "rand_read" >> "$OUT" 2>&1
echo "" >> "$OUT"

log "Running Docker+OverlayFS random write..."
echo "=== Random Write ===" >> "$OUT"
run_fio_docker "/tmp" "randwrite" 4 "4k" 32 "rand_write" >> "$OUT" 2>&1
log "Docker OverlayFS results saved to $OUT"

# --------------------------------------------------------------------------- #
# 4. KVM
# --------------------------------------------------------------------------- #
section "KVM Storage I/O Benchmark"
OUT="$RESULTS_DIR/kvm/storage.txt"
echo "# Storage I/O Benchmark — KVM (qcow2 disk, virtio-scsi)" > "$OUT"
echo "# Date: $(date)" >> "$OUT"
echo "" >> "$OUT"

if [[ -z "$VM_IP" ]]; then
    log "WARNING: VM_IP not set. Skipping KVM storage benchmark."
    echo "# SKIPPED: VM_IP not available." >> "$OUT"
else
    log "Running KVM random read (VM: $VM_IP)..."
    echo "=== Random Read ===" >> "$OUT"
    ssh -o StrictHostKeyChecking=no "${VM_USER}@${VM_IP}" "
        set -euo pipefail
        avail_kb=\$(df -Pk /tmp | awk 'NR==2 {print \$4}')
        avail_bytes=\$((avail_kb * 1024))
        size_bytes=\$((avail_bytes * $FREE_SPACE_USAGE_PERCENT / 100 / 4))
        if (( size_bytes > $DEFAULT_TEST_FILE_SIZE_BYTES )); then
            size_bytes=$DEFAULT_TEST_FILE_SIZE_BYTES
        fi
        if (( size_bytes < $MIN_TEST_FILE_SIZE_BYTES )); then
            size_bytes=$MIN_TEST_FILE_SIZE_BYTES
        fi
        fio \
            --name=rand_read \
            --rw=randread \
            --bs=4k \
            --direct=1 \
            --numjobs=4 \
            --iodepth=32 \
            --size=\$((size_bytes / 1024 / 1024))M \
            --runtime=$RUNTIME \
            --time_based \
            --group_reporting \
            --output-format=normal \
            --directory=/tmp
    " >> "$OUT" 2>&1
    echo "" >> "$OUT"

    log "Running KVM random write..."
    echo "=== Random Write ===" >> "$OUT"
    ssh -o StrictHostKeyChecking=no "${VM_USER}@${VM_IP}" "
        set -euo pipefail
        avail_kb=\$(df -Pk /tmp | awk 'NR==2 {print \$4}')
        avail_bytes=\$((avail_kb * 1024))
        size_bytes=\$((avail_bytes * $FREE_SPACE_USAGE_PERCENT / 100 / 4))
        if (( size_bytes > $DEFAULT_TEST_FILE_SIZE_BYTES )); then
            size_bytes=$DEFAULT_TEST_FILE_SIZE_BYTES
        fi
        if (( size_bytes < $MIN_TEST_FILE_SIZE_BYTES )); then
            size_bytes=$MIN_TEST_FILE_SIZE_BYTES
        fi
        fio \
            --name=rand_write \
            --rw=randwrite \
            --bs=4k \
            --direct=1 \
            --numjobs=4 \
            --iodepth=32 \
            --size=\$((size_bytes / 1024 / 1024))M \
            --runtime=$RUNTIME \
            --time_based \
            --group_reporting \
            --output-format=normal \
            --directory=/tmp
    " >> "$OUT" 2>&1
    log "KVM results saved to $OUT"
fi

log ""
log "=== Storage I/O benchmark complete ==="
