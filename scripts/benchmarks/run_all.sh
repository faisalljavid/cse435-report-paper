#!/usr/bin/env bash
# =============================================================================
# run_all.sh
# Master script — runs the complete benchmark suite in sequence.
# Results are saved to results/native/, results/docker/, results/kvm/
#
# Usage: sudo bash scripts/benchmarks/run_all.sh
# Optional: VM_IP=192.168.x.x sudo bash scripts/benchmarks/run_all.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$(cd "$SCRIPT_DIR/../../results" && pwd)"
LOG_FILE="$RESULTS_DIR/run_all.log"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()     { echo -e "${GREEN}[RUN]${NC} $*" | tee -a "$LOG_FILE"; }
section() { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"
            echo -e "${CYAN}  $*${NC}" | tee -a "$LOG_FILE"
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"; }

START_TIME=$(date +%s)

section "Container vs. VM Benchmark Suite"
log "Start time: $(date)"
log "Results directory: $RESULTS_DIR"
log "Log file: $LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Detect VM IP if not already set
if [[ -z "${VM_IP:-}" ]] && [[ -f /tmp/vm_ip.txt ]]; then
    export VM_IP=$(cat /tmp/vm_ip.txt)
    log "VM_IP detected: $VM_IP"
elif [[ -z "${VM_IP:-}" ]]; then
    echo -e "${YELLOW}[WARN]${NC} VM_IP not set — KVM benchmarks will be skipped." | tee -a "$LOG_FILE"
    echo -e "${YELLOW}[WARN]${NC} Run: sudo bash scripts/setup/03_setup_kvm.sh first." | tee -a "$LOG_FILE"
    echo -e "${YELLOW}[WARN]${NC} Or set: export VM_IP=<your-vm-ip> before running this script." | tee -a "$LOG_FILE"
fi

run_benchmark() {
    local name=$1
    local script=$2
    section "$name"
    if bash "$SCRIPT_DIR/$script" 2>&1 | tee -a "$LOG_FILE"; then
        log "✓ $name completed successfully"
    else
        log "✗ $name failed — check $LOG_FILE for details"
    fi
}

run_benchmark "1/5 — CPU (Sysbench Prime)"       "01_cpu_benchmark.sh"
run_benchmark "2/5 — Memory (STREAM / Sysbench)" "02_memory_benchmark.sh"
run_benchmark "3/5 — Storage I/O (fio)"          "03_storage_benchmark.sh"
run_benchmark "4/5 — Redis Latency"              "04_redis_benchmark.sh"
run_benchmark "5/5 — MySQL OLTP (SysBench)"      "05_mysql_benchmark.sh"

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
ELAPSED_MIN=$(( ELAPSED / 60 ))
ELAPSED_SEC=$(( ELAPSED % 60 ))

section "All Benchmarks Complete"
log "Total time: ${ELAPSED_MIN}m ${ELAPSED_SEC}s"
log ""
log "Results saved in:"
log "  results/native/     — bare metal baseline"
log "  results/docker/     — Docker container runs"
log "  results/kvm/        — KVM virtual machine runs"
log ""
log "To generate charts, run:"
log "  python3 scripts/benchmarks/plot_results.py"
