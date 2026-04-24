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

run_memory_native() {
    if [[ -x "$STREAM_BIN" ]]; then
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

run_memory_sysbench() {
    sysbench memory \
        --memory-block-size=1M \
        --memory-total-size=100G \
        --memory-operation=write \
        --threads=4 \
        run
}

run_memory_docker() {
    docker run --rm \
        --network host \
        ubuntu:22.04 \
        bash -lc "set -euo pipefail
                  export DEBIAN_FRONTEND=noninteractive
                  apt-get update -qq >/dev/null
                  apt-get install -qq -y --no-install-recommends sysbench >/dev/null
                  sysbench memory \
                      --memory-block-size=1M \
                      --memory-total-size=100G \
                      --memory-operation=write \
                      --threads=4 \
                      run"
}

mkdir -p "$RESULTS_DIR/native" "$RESULTS_DIR/docker" "$RESULTS_DIR/kvm"

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
run_memory_native >> "$OUT" 2>&1
log "Native results saved to $OUT"

# --------------------------------------------------------------------------- #
# 2. DOCKER
# --------------------------------------------------------------------------- #
section "Docker Memory Benchmark"
OUT="$RESULTS_DIR/docker/memory.txt"
echo "# Memory Bandwidth Benchmark — Docker (ubuntu:22.04)" > "$OUT"
echo "# Date: $(date)" >> "$OUT"
echo "# Tool: sysbench memory (portable container path)" >> "$OUT"
echo "" >> "$OUT"

log "Running Docker memory benchmark..."
run_memory_docker >> "$OUT" 2>&1
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
        "$(declare -f run_memory_sysbench); run_memory_sysbench" >> "$OUT" 2>&1
    log "KVM results saved to $OUT"
fi

log ""
log "=== Memory benchmark complete ==="
