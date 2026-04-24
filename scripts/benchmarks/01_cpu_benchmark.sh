#!/usr/bin/env bash
# =============================================================================
# 01_cpu_benchmark.sh
# Runs Sysbench CPU benchmark across three environments:
#   1. Native (bare metal)
#   2. Docker container
#   3. KVM virtual machine (via SSH)
#
# Metric: Sysbench events per second (prime number computation)
# Replicates: Felter et al. (2015), Section II-A, CPU benchmark
#
# Usage: sudo bash scripts/benchmarks/01_cpu_benchmark.sh
# =============================================================================

set -euo pipefail

RESULTS_DIR="$(cd "$(dirname "$0")/../../results" && pwd)"
THREADS=(1 2 4 8)
DURATION=30
VM_IP="${VM_IP:-$(cat /tmp/vm_ip.txt 2>/dev/null || echo '')}"
VM_USER="bench"
HOST_CPU_COUNT="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
log()     { echo -e "${GREEN}[CPU]${NC} $*"; }
section() { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

run_sysbench_cpu() {
    local threads=$1
    sysbench cpu \
        --cpu-max-prime=20000 \
        --threads="$threads" \
        --time="$DURATION" \
        run
}

run_sysbench_cpu_docker() {
    local threads=$1
    local cpus_assigned=$threads

    if (( cpus_assigned > HOST_CPU_COUNT )); then
        cpus_assigned=$HOST_CPU_COUNT
    fi

    docker run --rm \
        --network host \
        --cpuset-cpus="0-$((cpus_assigned - 1))" \
        ubuntu:22.04 \
        bash -lc "set -euo pipefail
                  export DEBIAN_FRONTEND=noninteractive
                  apt-get update -qq >/dev/null
                  apt-get install -qq -y --no-install-recommends sysbench >/dev/null
                  sysbench cpu \
                      --cpu-max-prime=20000 \
                      --threads=$threads \
                      --time=$DURATION \
                      run"
}

mkdir -p "$RESULTS_DIR/native" "$RESULTS_DIR/docker" "$RESULTS_DIR/kvm"

# --------------------------------------------------------------------------- #
# 1. NATIVE
# --------------------------------------------------------------------------- #
section "Native CPU Benchmark"
OUT="$RESULTS_DIR/native/cpu.txt"
echo "# CPU Benchmark — Native (Bare Metal)" > "$OUT"
echo "# Date: $(date)" >> "$OUT"
echo "# Tool: sysbench cpu --cpu-max-prime=20000 --time=${DURATION}s" >> "$OUT"
echo "" >> "$OUT"

for t in "${THREADS[@]}"; do
    log "Native — $t thread(s)..."
    echo "--- Threads: $t ---" >> "$OUT"
    run_sysbench_cpu "$t" >> "$OUT" 2>&1
    echo "" >> "$OUT"
done
log "Native results saved to $OUT"

# --------------------------------------------------------------------------- #
# 2. DOCKER (optimal: host networking)
# --------------------------------------------------------------------------- #
section "Docker CPU Benchmark"
OUT="$RESULTS_DIR/docker/cpu.txt"
echo "# CPU Benchmark — Docker (ubuntu:22.04, host networking)" > "$OUT"
echo "# Date: $(date)" >> "$OUT"
echo "" >> "$OUT"

for t in "${THREADS[@]}"; do
    log "Docker — $t thread(s)..."
    echo "--- Threads: $t ---" >> "$OUT"
    run_sysbench_cpu_docker "$t" >> "$OUT" 2>&1
    echo "" >> "$OUT"
done
log "Docker results saved to $OUT"

# --------------------------------------------------------------------------- #
# 3. KVM (via SSH)
# --------------------------------------------------------------------------- #
section "KVM CPU Benchmark"
OUT="$RESULTS_DIR/kvm/cpu.txt"
echo "# CPU Benchmark — KVM (QEMU-KVM, Ubuntu 22.04 guest)" > "$OUT"
echo "# Date: $(date)" >> "$OUT"
echo "" >> "$OUT"

if [[ -z "$VM_IP" ]]; then
    log "WARNING: VM_IP not set. Skipping KVM CPU benchmark."
    echo "# SKIPPED: VM_IP not available. Set VM_IP env var or run 03_setup_kvm.sh first." >> "$OUT"
else
    for t in "${THREADS[@]}"; do
        log "KVM — $t thread(s) (VM: $VM_IP)..."
        echo "--- Threads: $t ---" >> "$OUT"
        ssh -o StrictHostKeyChecking=no \
            -o ConnectTimeout=10 \
            "${VM_USER}@${VM_IP}" \
            "sysbench cpu \
                --cpu-max-prime=20000 \
                --threads=$t \
                --time=$DURATION \
                run" >> "$OUT" 2>&1
        echo "" >> "$OUT"
    done
    log "KVM results saved to $OUT"
fi

log ""
log "=== CPU benchmark complete ==="
log "Results:"
log "  Native : $RESULTS_DIR/native/cpu.txt"
log "  Docker : $RESULTS_DIR/docker/cpu.txt"
log "  KVM    : $RESULTS_DIR/kvm/cpu.txt"
