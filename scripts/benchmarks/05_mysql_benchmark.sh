#!/usr/bin/env bash
# =============================================================================
# 05_mysql_benchmark.sh
# Runs SysBench OLTP MySQL benchmark across all environments.
# This is the KEY benchmark from Felter et al. (2015) — Fig. 1 in the paper.
#
# Replicates: MySQL throughput (1000 transactions/sec) vs. number of threads
# Tests multiple thread counts to plot the full throughput curve (Figure 4.1)
#
# Configurations tested:
#   1. Native MySQL
#   2. Docker + host networking + Docker volume  (optimal)
#   3. Docker + NAT networking + OverlayFS       (default)
#   4. KVM MySQL (via SSH)
#
# Usage: sudo bash scripts/benchmarks/05_mysql_benchmark.sh
# =============================================================================

set -euo pipefail

RESULTS_DIR="$(cd "$(dirname "$0")/../../results" && pwd)"
VM_IP="${VM_IP:-$(cat /tmp/vm_ip.txt 2>/dev/null || echo '')}"
VM_USER="bench"

# Thread counts to sweep (mirrors Felter et al. Fig 1 x-axis)
THREAD_COUNTS=(1 2 4 8 16 32 64 128 256)
DURATION=60        # seconds per sysbench run
TABLE_SIZE=1000000 # rows per table (keep in-memory for fair comparison)
TABLES=8

MYSQL_HOST_NATIVE="127.0.0.1"
MYSQL_PORT_NATIVE=3307
MYSQL_HOST_DOCKER="127.0.0.1"
MYSQL_PORT_DOCKER=3306
MYSQL_USER="sbtest"
MYSQL_PASS="sbtest"
MYSQL_DB="sbtest"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
log()     { echo -e "${GREEN}[MySQL]${NC} $*"; }
section() { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

prepare_sysbench() {
    local host=$1 port=$2
    log "Preparing SysBench OLTP tables (${TABLES} tables × ${TABLE_SIZE} rows)..."
    sysbench oltp_read_write \
        --db-driver=mysql \
        --mysql-host="$host" \
        --mysql-port="$port" \
        --mysql-user="$MYSQL_USER" \
        --mysql-password="$MYSQL_PASS" \
        --mysql-db="$MYSQL_DB" \
        --tables="$TABLES" \
        --table-size="$TABLE_SIZE" \
        --threads=8 \
        prepare
}

run_oltp() {
    local host=$1 port=$2 threads=$3
    sysbench oltp_read_write \
        --db-driver=mysql \
        --mysql-host="$host" \
        --mysql-port="$port" \
        --mysql-user="$MYSQL_USER" \
        --mysql-password="$MYSQL_PASS" \
        --mysql-db="$MYSQL_DB" \
        --tables="$TABLES" \
        --table-size="$TABLE_SIZE" \
        --threads="$threads" \
        --time="$DURATION" \
        --report-interval=10 \
        run
}

cleanup_sysbench() {
    local host=$1 port=$2
    sysbench oltp_read_write \
        --db-driver=mysql \
        --mysql-host="$host" \
        --mysql-port="$port" \
        --mysql-user="$MYSQL_USER" \
        --mysql-password="$MYSQL_PASS" \
        --mysql-db="$MYSQL_DB" \
        --tables="$TABLES" \
        cleanup 2>/dev/null || true
}

# --------------------------------------------------------------------------- #
# 1. NATIVE MySQL
# --------------------------------------------------------------------------- #
section "Native MySQL OLTP Benchmark"
OUT="$RESULTS_DIR/native/mysql.txt"
echo "# MySQL OLTP Benchmark — Native (Bare Metal)" > "$OUT"
echo "# Date: $(date)" >> "$OUT"
echo "# Tables: $TABLES | Rows: $TABLE_SIZE | Duration: ${DURATION}s per run" >> "$OUT"
echo "" >> "$OUT"

# Start a native MySQL instance on a different port to avoid conflicts
systemctl start mysql 2>/dev/null || true
mysql -u root -e "
    CREATE DATABASE IF NOT EXISTS sbtest;
    CREATE USER IF NOT EXISTS 'sbtest'@'%' IDENTIFIED BY 'sbtest';
    GRANT ALL ON sbtest.* TO 'sbtest'@'%';
    FLUSH PRIVILEGES;
" 2>/dev/null || true

prepare_sysbench "$MYSQL_HOST_NATIVE" "3306" 2>&1 | tail -5

for t in "${THREAD_COUNTS[@]}"; do
    log "Native MySQL — $t thread(s)..."
    echo "--- Threads: $t ---" >> "$OUT"
    run_oltp "$MYSQL_HOST_NATIVE" "3306" "$t" 2>&1 >> "$OUT"
    echo "" >> "$OUT"
done

cleanup_sysbench "$MYSQL_HOST_NATIVE" "3306"
log "Native results saved to $OUT"

# --------------------------------------------------------------------------- #
# 2. DOCKER MySQL — Optimal (host networking + volume)
# --------------------------------------------------------------------------- #
section "Docker MySQL OLTP Benchmark (host networking + volume)"
OUT="$RESULTS_DIR/docker/mysql_hostnet_volume.txt"
echo "# MySQL OLTP Benchmark — Docker (host networking + Docker volume)" > "$OUT"
echo "# Date: $(date)" >> "$OUT"
echo "" >> "$OUT"

# Start Docker MySQL with host networking and a volume
docker rm -f mysql_bench_hostnet 2>/dev/null || true
docker run -d \
    --name mysql_bench_hostnet \
    --network host \
    --volume benchmark_vol:/var/lib/mysql \
    -e MYSQL_ROOT_PASSWORD=root \
    -e MYSQL_DATABASE=sbtest \
    -e MYSQL_USER=sbtest \
    -e MYSQL_PASSWORD=sbtest \
    mysql:8.0 \
    --innodb-buffer-pool-size=512M \
    --innodb-log-file-size=256M \
    --port 3308

log "Waiting for Docker MySQL to start..."
sleep 30

prepare_sysbench "127.0.0.1" "3308" 2>&1 | tail -5

for t in "${THREAD_COUNTS[@]}"; do
    log "Docker host-net MySQL — $t thread(s)..."
    echo "--- Threads: $t ---" >> "$OUT"
    run_oltp "127.0.0.1" "3308" "$t" 2>&1 >> "$OUT"
    echo "" >> "$OUT"
done

cleanup_sysbench "127.0.0.1" "3308"
docker rm -f mysql_bench_hostnet 2>/dev/null || true
log "Docker optimal results saved to $OUT"

# --------------------------------------------------------------------------- #
# 3. DOCKER MySQL — Default (NAT + OverlayFS)
# --------------------------------------------------------------------------- #
section "Docker MySQL OLTP Benchmark (NAT + OverlayFS)"
OUT="$RESULTS_DIR/docker/mysql_nat_overlayfs.txt"
echo "# MySQL OLTP Benchmark — Docker (NAT networking + OverlayFS)" > "$OUT"
echo "# Date: $(date)" >> "$OUT"
echo "" >> "$OUT"

docker rm -f mysql_bench_nat 2>/dev/null || true
docker run -d \
    --name mysql_bench_nat \
    --network benchmark_net \
    -p 3309:3306 \
    -e MYSQL_ROOT_PASSWORD=root \
    -e MYSQL_DATABASE=sbtest \
    -e MYSQL_USER=sbtest \
    -e MYSQL_PASSWORD=sbtest \
    mysql:8.0 \
    --innodb-buffer-pool-size=512M

log "Waiting for Docker MySQL (NAT) to start..."
sleep 30

prepare_sysbench "127.0.0.1" "3309" 2>&1 | tail -5

for t in 1 2 4 8 16 32 64; do  # Fewer points — this config is slow
    log "Docker NAT MySQL — $t thread(s)..."
    echo "--- Threads: $t ---" >> "$OUT"
    run_oltp "127.0.0.1" "3309" "$t" 2>&1 >> "$OUT"
    echo "" >> "$OUT"
done

cleanup_sysbench "127.0.0.1" "3309"
docker rm -f mysql_bench_nat 2>/dev/null || true
log "Docker default results saved to $OUT"

# --------------------------------------------------------------------------- #
# 4. KVM MySQL
# --------------------------------------------------------------------------- #
section "KVM MySQL OLTP Benchmark"
OUT="$RESULTS_DIR/kvm/mysql.txt"
echo "# MySQL OLTP Benchmark — KVM (QEMU-KVM, Ubuntu 22.04 guest)" > "$OUT"
echo "# Date: $(date)" >> "$OUT"
echo "" >> "$OUT"

if [[ -z "$VM_IP" ]]; then
    log "WARNING: VM_IP not set. Skipping KVM MySQL benchmark."
    echo "# SKIPPED: VM_IP not available." >> "$OUT"
else
    log "Preparing SysBench tables inside KVM guest..."
    ssh -o StrictHostKeyChecking=no "${VM_USER}@${VM_IP}" \
        "sysbench oltp_read_write \
            --db-driver=mysql \
            --mysql-host=127.0.0.1 \
            --mysql-user=sbtest \
            --mysql-password=sbtest \
            --mysql-db=sbtest \
            --tables=$TABLES \
            --table-size=$TABLE_SIZE \
            --threads=8 \
            prepare" 2>&1 | tail -5

    for t in "${THREAD_COUNTS[@]}"; do
        log "KVM MySQL — $t thread(s) (VM: $VM_IP)..."
        echo "--- Threads: $t ---" >> "$OUT"
        ssh -o StrictHostKeyChecking=no "${VM_USER}@${VM_IP}" \
            "sysbench oltp_read_write \
                --db-driver=mysql \
                --mysql-host=127.0.0.1 \
                --mysql-user=sbtest \
                --mysql-password=sbtest \
                --mysql-db=sbtest \
                --tables=$TABLES \
                --table-size=$TABLE_SIZE \
                --threads=$t \
                --time=$DURATION \
                --report-interval=10 \
                run" 2>&1 >> "$OUT"
        echo "" >> "$OUT"
    done

    log "KVM results saved to $OUT"
fi

log ""
log "=== MySQL OLTP benchmark complete ==="
log "These results replicate Figure 4.1 in the seminar report."
log "Run plot_results.py to generate the throughput vs. concurrency chart."
