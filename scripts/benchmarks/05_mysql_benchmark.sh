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

THREAD_COUNTS=(1 2 4 8 16 32 64 128 256)
DURATION=60
TABLE_SIZE=1000000
TABLES=8
THREAD_RESERVE=20

MYSQL_HOST_NATIVE="127.0.0.1"
MYSQL_PORT_NATIVE=3306
MYSQL_USER="sbtest"
MYSQL_PASS="sbtest"
MYSQL_DB="sbtest"
MYSQL_HOSTNET_PORT=3308
MYSQL_NAT_PORT=3309
MYSQL_ROOT_PASS_DOCKER="root"
MYSQL_DOCKER_VOLUME="mysql_bench_data"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()     { echo -e "${GREEN}[MySQL]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
section() { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

mysql_exec_tcp() {
    local host=$1
    local port=$2
    local user=$3
    local pass=$4
    shift 4
    mysql --protocol=TCP -h "$host" -P "$port" -u "$user" "-p$pass" "$@"
}

prepare_sysbench() {
    local host=$1
    local port=$2
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
    local host=$1
    local port=$2
    local threads=$3
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
    local host=$1
    local port=$2
    sysbench oltp_read_write \
        --db-driver=mysql \
        --mysql-host="$host" \
        --mysql-port="$port" \
        --mysql-user="$MYSQL_USER" \
        --mysql-password="$MYSQL_PASS" \
        --mysql-db="$MYSQL_DB" \
        --tables="$TABLES" \
        cleanup >/dev/null 2>&1 || true
}

start_native_mysql_service() {
    local service
    for service in mysql mariadb mysqld; do
        if systemctl start "$service" >/dev/null 2>&1; then
            echo "$service"
            return 0
        fi
    done
    return 1
}

wait_for_mysql_socket() {
    local attempt
    for attempt in $(seq 1 60); do
        if mysqladmin ping >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

wait_for_mysql_tcp() {
    local host=$1
    local port=$2
    local user=$3
    local pass=$4
    local attempt

    for attempt in $(seq 1 60); do
        if mysqladmin --protocol=TCP -h "$host" -P "$port" -u "$user" "-p$pass" ping --silent >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

get_max_connections() {
    local host=$1
    local port=$2
    local user=$3
    local pass=$4

    mysql_exec_tcp "$host" "$port" "$user" "$pass" -Nse "SHOW VARIABLES LIKE 'max_connections';" 2>/dev/null | awk 'NR==1 {print $2}'
}

filter_thread_counts() {
    local max_connections=$1
    shift
    local usable_max=$(( max_connections - THREAD_RESERVE ))
    local thread
    local selected=()

    if (( usable_max < 1 )); then
        usable_max=1
    fi

    for thread in "$@"; do
        if (( thread <= usable_max )); then
            selected+=("$thread")
        fi
    done

    if (( ${#selected[@]} == 0 )); then
        selected=(1)
    fi

    echo "${selected[*]}"
}

log_thread_plan() {
    local label=$1
    local max_connections=$2
    shift 2
    log "$label max_connections=$max_connections; using thread counts: $*"
}

mkdir -p "$RESULTS_DIR/native" "$RESULTS_DIR/docker" "$RESULTS_DIR/kvm"

# --------------------------------------------------------------------------- #
# 1. NATIVE MySQL
# --------------------------------------------------------------------------- #
section "Native MySQL OLTP Benchmark"
OUT="$RESULTS_DIR/native/mysql.txt"
echo "# MySQL OLTP Benchmark — Native (Bare Metal)" > "$OUT"
echo "# Date: $(date)" >> "$OUT"
echo "# Tables: $TABLES | Rows: $TABLE_SIZE | Duration: ${DURATION}s per run" >> "$OUT"
echo "" >> "$OUT"

MYSQL_SERVICE="$(start_native_mysql_service || true)"
if [[ -z "$MYSQL_SERVICE" ]]; then
    echo "Could not start mysql/mariadb service on the host." >&2
    exit 1
fi

wait_for_mysql_socket
mysql -u root -e "
    CREATE DATABASE IF NOT EXISTS ${MYSQL_DB};
    CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASS}';
    GRANT ALL ON ${MYSQL_DB}.* TO '${MYSQL_USER}'@'%';
    FLUSH PRIVILEGES;
    SET GLOBAL max_connections = 512;
" >/dev/null 2>&1 || true

wait_for_mysql_tcp "$MYSQL_HOST_NATIVE" "$MYSQL_PORT_NATIVE" "$MYSQL_USER" "$MYSQL_PASS"
NATIVE_MAX_CONNECTIONS="$(get_max_connections "$MYSQL_HOST_NATIVE" "$MYSQL_PORT_NATIVE" "$MYSQL_USER" "$MYSQL_PASS")"
if [[ -z "$NATIVE_MAX_CONNECTIONS" ]]; then
    NATIVE_MAX_CONNECTIONS=151
fi
read -r -a NATIVE_THREAD_COUNTS <<< "$(filter_thread_counts "$NATIVE_MAX_CONNECTIONS" "${THREAD_COUNTS[@]}")"
log_thread_plan "Native" "$NATIVE_MAX_CONNECTIONS" "${NATIVE_THREAD_COUNTS[@]}"

prepare_sysbench "$MYSQL_HOST_NATIVE" "$MYSQL_PORT_NATIVE" | tail -5

for t in "${NATIVE_THREAD_COUNTS[@]}"; do
    log "Native MySQL — $t thread(s)..."
    echo "--- Threads: $t ---" >> "$OUT"
    run_oltp "$MYSQL_HOST_NATIVE" "$MYSQL_PORT_NATIVE" "$t" >> "$OUT" 2>&1
    echo "" >> "$OUT"
done

cleanup_sysbench "$MYSQL_HOST_NATIVE" "$MYSQL_PORT_NATIVE"
log "Native results saved to $OUT"

# --------------------------------------------------------------------------- #
# 2. DOCKER MySQL — Optimal (host networking + volume)
# --------------------------------------------------------------------------- #
section "Docker MySQL OLTP Benchmark (host networking + volume)"
OUT="$RESULTS_DIR/docker/mysql_hostnet_volume.txt"
echo "# MySQL OLTP Benchmark — Docker (host networking + Docker volume)" > "$OUT"
echo "# Date: $(date)" >> "$OUT"
echo "" >> "$OUT"

docker rm -f mysql_bench_hostnet 2>/dev/null || true
docker volume rm -f "$MYSQL_DOCKER_VOLUME" >/dev/null 2>&1 || true
docker volume create "$MYSQL_DOCKER_VOLUME" >/dev/null

docker run -d \
    --name mysql_bench_hostnet \
    --network host \
    --volume "${MYSQL_DOCKER_VOLUME}:/var/lib/mysql" \
    -e MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASS_DOCKER" \
    -e MYSQL_DATABASE="$MYSQL_DB" \
    -e MYSQL_USER="$MYSQL_USER" \
    -e MYSQL_PASSWORD="$MYSQL_PASS" \
    mysql:8.0 \
    --innodb-buffer-pool-size=512M \
    --innodb-log-file-size=256M \
    --max-connections=512 \
    --port "$MYSQL_HOSTNET_PORT" >/dev/null

wait_for_mysql_tcp "127.0.0.1" "$MYSQL_HOSTNET_PORT" root "$MYSQL_ROOT_PASS_DOCKER"
DOCKER_HOSTNET_MAX_CONNECTIONS="$(get_max_connections "127.0.0.1" "$MYSQL_HOSTNET_PORT" "$MYSQL_USER" "$MYSQL_PASS")"
if [[ -z "$DOCKER_HOSTNET_MAX_CONNECTIONS" ]]; then
    DOCKER_HOSTNET_MAX_CONNECTIONS=512
fi
read -r -a DOCKER_HOSTNET_THREAD_COUNTS <<< "$(filter_thread_counts "$DOCKER_HOSTNET_MAX_CONNECTIONS" "${THREAD_COUNTS[@]}")"
log_thread_plan "Docker host-net" "$DOCKER_HOSTNET_MAX_CONNECTIONS" "${DOCKER_HOSTNET_THREAD_COUNTS[@]}"

prepare_sysbench "127.0.0.1" "$MYSQL_HOSTNET_PORT" | tail -5

for t in "${DOCKER_HOSTNET_THREAD_COUNTS[@]}"; do
    log "Docker host-net MySQL — $t thread(s)..."
    echo "--- Threads: $t ---" >> "$OUT"
    run_oltp "127.0.0.1" "$MYSQL_HOSTNET_PORT" "$t" >> "$OUT" 2>&1
    echo "" >> "$OUT"
done

cleanup_sysbench "127.0.0.1" "$MYSQL_HOSTNET_PORT"
docker rm -f mysql_bench_hostnet >/dev/null 2>&1 || true
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
    -p "${MYSQL_NAT_PORT}:3306" \
    -e MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASS_DOCKER" \
    -e MYSQL_DATABASE="$MYSQL_DB" \
    -e MYSQL_USER="$MYSQL_USER" \
    -e MYSQL_PASSWORD="$MYSQL_PASS" \
    mysql:8.0 \
    --innodb-buffer-pool-size=512M \
    --max-connections=256 >/dev/null

wait_for_mysql_tcp "127.0.0.1" "$MYSQL_NAT_PORT" root "$MYSQL_ROOT_PASS_DOCKER"
DOCKER_NAT_MAX_CONNECTIONS="$(get_max_connections "127.0.0.1" "$MYSQL_NAT_PORT" "$MYSQL_USER" "$MYSQL_PASS")"
if [[ -z "$DOCKER_NAT_MAX_CONNECTIONS" ]]; then
    DOCKER_NAT_MAX_CONNECTIONS=256
fi
read -r -a DOCKER_NAT_THREAD_COUNTS <<< "$(filter_thread_counts "$DOCKER_NAT_MAX_CONNECTIONS" 1 2 4 8 16 32 64 128)"
log_thread_plan "Docker NAT" "$DOCKER_NAT_MAX_CONNECTIONS" "${DOCKER_NAT_THREAD_COUNTS[@]}"

prepare_sysbench "127.0.0.1" "$MYSQL_NAT_PORT" | tail -5

for t in "${DOCKER_NAT_THREAD_COUNTS[@]}"; do
    log "Docker NAT MySQL — $t thread(s)..."
    echo "--- Threads: $t ---" >> "$OUT"
    run_oltp "127.0.0.1" "$MYSQL_NAT_PORT" "$t" >> "$OUT" 2>&1
    echo "" >> "$OUT"
done

cleanup_sysbench "127.0.0.1" "$MYSQL_NAT_PORT"
docker rm -f mysql_bench_nat >/dev/null 2>&1 || true
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
    ssh -o StrictHostKeyChecking=no "${VM_USER}@${VM_IP}" \
        "sudo mysql -e \"SET GLOBAL max_connections = 512;\" >/dev/null 2>&1 || true"

    KVM_MAX_CONNECTIONS="$(ssh -o StrictHostKeyChecking=no "${VM_USER}@${VM_IP}" \
        "mysql --protocol=TCP -h 127.0.0.1 -u ${MYSQL_USER} -p${MYSQL_PASS} -Nse \"SHOW VARIABLES LIKE 'max_connections';\" 2>/dev/null | awk 'NR==1 {print \$2}'" || true)"
    if [[ -z "$KVM_MAX_CONNECTIONS" ]]; then
        KVM_MAX_CONNECTIONS=151
    fi
    read -r -a KVM_THREAD_COUNTS <<< "$(filter_thread_counts "$KVM_MAX_CONNECTIONS" "${THREAD_COUNTS[@]}")"
    log_thread_plan "KVM" "$KVM_MAX_CONNECTIONS" "${KVM_THREAD_COUNTS[@]}"

    log "Preparing SysBench tables inside KVM guest..."
    ssh -o StrictHostKeyChecking=no "${VM_USER}@${VM_IP}" \
        "sysbench oltp_read_write \
            --db-driver=mysql \
            --mysql-host=127.0.0.1 \
            --mysql-user=${MYSQL_USER} \
            --mysql-password=${MYSQL_PASS} \
            --mysql-db=${MYSQL_DB} \
            --tables=${TABLES} \
            --table-size=${TABLE_SIZE} \
            --threads=8 \
            prepare" | tail -5

    for t in "${KVM_THREAD_COUNTS[@]}"; do
        log "KVM MySQL — $t thread(s) (VM: $VM_IP)..."
        echo "--- Threads: $t ---" >> "$OUT"
        ssh -o StrictHostKeyChecking=no "${VM_USER}@${VM_IP}" \
            "sysbench oltp_read_write \
                --db-driver=mysql \
                --mysql-host=127.0.0.1 \
                --mysql-user=${MYSQL_USER} \
                --mysql-password=${MYSQL_PASS} \
                --mysql-db=${MYSQL_DB} \
                --tables=${TABLES} \
                --table-size=${TABLE_SIZE} \
                --threads=${t} \
                --time=${DURATION} \
                --report-interval=10 \
                run" >> "$OUT" 2>&1
        echo "" >> "$OUT"
    done

    ssh -o StrictHostKeyChecking=no "${VM_USER}@${VM_IP}" \
        "sysbench oltp_read_write \
            --db-driver=mysql \
            --mysql-host=127.0.0.1 \
            --mysql-user=${MYSQL_USER} \
            --mysql-password=${MYSQL_PASS} \
            --mysql-db=${MYSQL_DB} \
            --tables=${TABLES} \
            cleanup" >/dev/null 2>&1 || true

    log "KVM results saved to $OUT"
fi

docker volume rm -f "$MYSQL_DOCKER_VOLUME" >/dev/null 2>&1 || true

log ""
log "=== MySQL OLTP benchmark complete ==="
log "These results replicate Figure 4.1 in the seminar report."
log "Run plot_results.py to generate the throughput vs. concurrency chart."
