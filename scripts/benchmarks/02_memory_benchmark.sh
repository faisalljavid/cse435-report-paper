#!/usr/bin/env bash
# =============================================================================
# 02_memory_benchmark.sh
# Runs STREAM memory bandwidth benchmark across three environments.
#
# Metrics: Copy, Scale, Add, Triad throughput (GB/s)
# Replicates: Felter et al. (2015), Section II-B, Memory benchmark
#
# Usage: sudo bash scripts/benchmarks/02_memory_benchmark.sh
# =============================================================================

set -euo pipefail

RESULTS_DIR="$(cd "$(dirname "$0")/../../results" && pwd)"
VM_IP="${VM_IP:-$(cat /tmp/vm_ip.txt 2>/dev/null || echo '')}"
VM_USER="bench"
STREAM_BIN="/usr/local/bin/stream_benchmark"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
log()     { echo -e "${GREEN}[MEM]${NC} $*"; }
section() { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

# Fall back to sysbench memory if STREAM binary is unavailable
run_memory() {
    if command -v "$STREAM_BIN" &>/dev/null; then
        "$STREAM_BIN"
    else
        log "STREAM binary not found, using sysbench memory as fallback..."
        sysbench memory \
            --memory-block-size=1M \
            --memory-total-size=100G \
            --memory-operation=write \
            --threads=4 \
            run
    fi
}

# --------------------------------------------------------------------------- #
# 1. NATIVE
# --------------------------------------------------------------------------- #
section "Native Memory Benchmark"
OUT="$RESULTS_DIR/native/memory.txt"
echo "# Memory Bandwidth Benchmark — Native (Bare Metal)" > "$OUT"
echo "# Date: $(date)" >> "$OUT"
echo "# Tool: STREAM (array size 10M doubles) or sysbench memory fallback" >> "$OUT"
echo "" >> "$OUT"

log "Running native memory benchmark..."
run_memory 2>&1 >> "$OUT"
log "Native results saved to $OUT"

# --------------------------------------------------------------------------- #
# 2. DOCKER
# --------------------------------------------------------------------------- #
section "Docker Memory Benchmark"
OUT="$RESULTS_DIR/docker/memory.txt"
echo "# Memory Bandwidth Benchmark — Docker (ubuntu:22.04)" > "$OUT"
echo "# Date: $(date)" >> "$OUT"
echo "" >> "$OUT"

log "Running Docker memory benchmark..."
if command -v "$STREAM_BIN" &>/dev/null; then
    # Copy the pre-built STREAM binary into a transient container and run it
    docker run --rm \
        --network host \
        --volume "$STREAM_BIN:/usr/local/bin/stream_benchmark:ro" \
        ubuntu:22.04 \
        /usr/local/bin/stream_benchmark 2>&1 >> "$OUT"
else
    docker run --rm \
        --network host \
        ubuntu:22.04 \
        bash -c "apt-get install -qq -y sysbench > /dev/null 2>&1 && \
                 sysbench memory \
                     --memory-block-size=1M \
                     --memory-total-size=100G \
                     --memory-operation=write \
                     --threads=4 \
                     run" 2>&1 >> "$OUT"
fi
log "Docker results saved to $OUT"

# --------------------------------------------------------------------------- #
# 3. KVM
# --------------------------------------------------------------------------- #
section "KVM Memory Benchmark"
OUT="$RESULTS_DIR/kvm/memory.txt"
echo "# Memory Bandwidth Benchmark — KVM (QEMU-KVM, Ubuntu 22.04 guest)" > "$OUT"
echo "# Date: $(date)" >> "$OUT"
echo "" >> "$OUT"

if [[ -z "$VM_IP" ]]; then
    log "WARNING: VM_IP not set. Skipping KVM memory benchmark."
    echo "# SKIPPED: VM_IP not available." >> "$OUT"
else
    log "Running KVM memory benchmark (VM: $VM_IP)..."
    ssh -o StrictHostKeyChecking=no \
        "${VM_USER}@${VM_IP}" \
        "sysbench memory \
            --memory-block-size=1M \
            --memory-total-size=100G \
            --memory-operation=write \
            --threads=4 \
            run" 2>&1 >> "$OUT"
    log "KVM results saved to $OUT"
fi

log ""
log "=== Memory benchmark complete ==="
