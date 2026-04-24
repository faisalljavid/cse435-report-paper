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
TEST_FILE_SIZE="4G"     # Size of test file — adjust if disk space is limited
RUNTIME=60              # Seconds per fio job

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
log()     { echo -e "${GREEN}[I/O]${NC} $*"; }
section() { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

FIO_RAND_READ="fio \
    --name=rand_read \
    --rw=randread \
    --bs=4k \
    --direct=1 \
    --numjobs=4 \
    --iodepth=32 \
    --size=$TEST_FILE_SIZE \
    --runtime=$RUNTIME \
    --time_based \
    --group_reporting \
    --output-format=normal"

FIO_RAND_WRITE="fio \
    --name=rand_write \
    --rw=randwrite \
    --bs=4k \
    --direct=1 \
    --numjobs=4 \
    --iodepth=32 \
    --size=$TEST_FILE_SIZE \
    --runtime=$RUNTIME \
    --time_based \
    --group_reporting \
    --output-format=normal"

FIO_SEQ_READ="fio \
    --name=seq_read \
    --rw=read \
    --bs=1M \
    --direct=1 \
    --numjobs=1 \
    --iodepth=8 \
    --size=$TEST_FILE_SIZE \
    --runtime=$RUNTIME \
    --time_based \
    --group_reporting \
    --output-format=normal"

FIO_SEQ_WRITE="fio \
    --name=seq_write \
    --rw=write \
    --bs=1M \
    --direct=1 \
    --numjobs=1 \
    --iodepth=8 \
    --size=$TEST_FILE_SIZE \
    --runtime=$RUNTIME \
    --time_based \
    --group_reporting \
    --output-format=normal"

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
log "Running native random read (${RUNTIME}s)..."
echo "=== Random Read (4K, Direct I/O, QD=32, 4 jobs) ===" >> "$OUT"
eval "$FIO_RAND_READ --directory=$TMPDIR" 2>&1 >> "$OUT"
echo "" >> "$OUT"

log "Running native random write (${RUNTIME}s)..."
echo "=== Random Write (4K, Direct I/O, QD=32, 4 jobs) ===" >> "$OUT"
eval "$FIO_RAND_WRITE --directory=$TMPDIR" 2>&1 >> "$OUT"
echo "" >> "$OUT"

log "Running native sequential read (${RUNTIME}s)..."
echo "=== Sequential Read (1M, Direct I/O) ===" >> "$OUT"
eval "$FIO_SEQ_READ --directory=$TMPDIR" 2>&1 >> "$OUT"
echo "" >> "$OUT"

log "Running native sequential write (${RUNTIME}s)..."
echo "=== Sequential Write (1M, Direct I/O) ===" >> "$OUT"
eval "$FIO_SEQ_WRITE --directory=$TMPDIR" 2>&1 >> "$OUT"

rm -rf "$TMPDIR"
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
docker run --rm \
    --volume benchmark_vol:/data \
    --network host \
    ubuntu:22.04 \
    bash -c "apt-get install -qq -y fio > /dev/null 2>&1 && \
             $FIO_RAND_READ --directory=/data" 2>&1 >> "$OUT"
echo "" >> "$OUT"

log "Running Docker+volume random write..."
echo "=== Random Write ===" >> "$OUT"
docker run --rm \
    --volume benchmark_vol:/data \
    --network host \
    ubuntu:22.04 \
    bash -c "apt-get install -qq -y fio > /dev/null 2>&1 && \
             $FIO_RAND_WRITE --directory=/data" 2>&1 >> "$OUT"
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
docker run --rm ubuntu:22.04 \
    bash -c "apt-get install -qq -y fio > /dev/null 2>&1 && \
             $FIO_RAND_READ --directory=/tmp" 2>&1 >> "$OUT"
echo "" >> "$OUT"

log "Running Docker+OverlayFS random write..."
echo "=== Random Write ===" >> "$OUT"
docker run --rm ubuntu:22.04 \
    bash -c "apt-get install -qq -y fio > /dev/null 2>&1 && \
             $FIO_RAND_WRITE --directory=/tmp" 2>&1 >> "$OUT"
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
    ssh -o StrictHostKeyChecking=no "${VM_USER}@${VM_IP}" \
        "$FIO_RAND_READ --directory=/tmp" 2>&1 >> "$OUT"
    echo "" >> "$OUT"

    log "Running KVM random write..."
    echo "=== Random Write ===" >> "$OUT"
    ssh -o StrictHostKeyChecking=no "${VM_USER}@${VM_IP}" \
        "$FIO_RAND_WRITE --directory=/tmp" 2>&1 >> "$OUT"
    log "KVM results saved to $OUT"
fi

log ""
log "=== Storage I/O benchmark complete ==="
