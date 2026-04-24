#!/usr/bin/env bash
# =============================================================================
# 04_redis_benchmark.sh
# Runs Redis-benchmark latency test across three environments.
#
# Metric: Latency (µs) for GET/SET operations and throughput (ops/sec)
# Tests: GET, SET, LPUSH, LPOP with pipeline sizes 1 and 16
# Replicates: Felter et al. (2015), Section II-D, Redis latency benchmark
#
# Usage: sudo bash scripts/benchmarks/04_redis_benchmark.sh
# =============================================================================

set -euo pipefail

RESULTS_DIR="$(cd "$(dirname "$0")/../../results" && pwd)"
VM_IP="${VM_IP:-$(cat /tmp/vm_ip.txt 2>/dev/null || echo '')}"
VM_USER="bench"

REQUESTS=100000
CLIENTS=50
KEYSPACE=1000000
NATIVE_PORT=6380
DOCKER_HOST_PORT=6382
DOCKER_NAT_PORT=6381

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
log()     { echo -e "${GREEN}[REDIS]${NC} $*"; }
section() { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

find_first_command() {
    local candidate
    for candidate in "$@"; do
        if command -v "$candidate" >/dev/null 2>&1; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

REDIS_SERVER_CMD="$(find_first_command redis-server valkey-server)"
REDIS_CLI_CMD="$(find_first_command redis-cli valkey-cli)"
REDIS_BENCH_CMD="$(find_first_command redis-benchmark valkey-benchmark)"

if [[ -z "$REDIS_SERVER_CMD" || -z "$REDIS_CLI_CMD" || -z "$REDIS_BENCH_CMD" ]]; then
    echo "Redis/Valkey server, cli, or benchmark command is missing." >&2
    exit 1
fi

LATENCY_HISTORY_FLAG=()
if "$REDIS_BENCH_CMD" --help 2>&1 | grep -q -- "--latency-history"; then
    LATENCY_HISTORY_FLAG=(--latency-history)
fi

run_redis_bench() {
    local host="${1:-127.0.0.1}"
    local port="${2:-6379}"
    "$REDIS_BENCH_CMD" \
        -h "$host" \
        -p "$port" \
        -n "$REQUESTS" \
        -c "$CLIENTS" \
        -r "$KEYSPACE" \
        -t get,set,lpush,lpop \
        "${LATENCY_HISTORY_FLAG[@]}" \
        -q
}

run_redis_pipeline_bench() {
    local host=$1
    local port=$2
    local pipeline=$3
    "$REDIS_BENCH_CMD" \
        -h "$host" \
        -p "$port" \
        -n "$REQUESTS" \
        -c "$CLIENTS" \
        -t get,set \
        -P "$pipeline" \
        -q
}

mkdir -p "$RESULTS_DIR/native" "$RESULTS_DIR/docker" "$RESULTS_DIR/kvm"

# --------------------------------------------------------------------------- #
# 1. NATIVE
# --------------------------------------------------------------------------- #
section "Native Redis Benchmark"
OUT="$RESULTS_DIR/native/redis.txt"
echo "# Redis Benchmark — Native (Bare Metal)" > "$OUT"
echo "# Date: $(date)" >> "$OUT"
echo "# Requests: $REQUESTS | Clients: $CLIENTS | Keyspace: $KEYSPACE" >> "$OUT"
echo "" >> "$OUT"

log "Starting native Redis/Valkey server..."
"$REDIS_SERVER_CMD" --daemonize yes --port "$NATIVE_PORT" --save "" --appendonly no \
    --logfile /tmp/redis_native.log --pidfile /tmp/redis_native.pid

sleep 1

log "Running native Redis benchmark..."
echo "=== Pipeline depth: 1 ===" >> "$OUT"
run_redis_bench "127.0.0.1" "$NATIVE_PORT" >> "$OUT" 2>&1
echo "" >> "$OUT"

echo "=== Pipeline depth: 16 ===" >> "$OUT"
run_redis_pipeline_bench "127.0.0.1" "$NATIVE_PORT" 16 >> "$OUT" 2>&1

"$REDIS_CLI_CMD" -p "$NATIVE_PORT" shutdown nosave 2>/dev/null || true
log "Native results saved to $OUT"

# --------------------------------------------------------------------------- #
# 2. DOCKER — host networking (optimal)
# --------------------------------------------------------------------------- #
section "Docker Redis Benchmark (host networking)"
OUT="$RESULTS_DIR/docker/redis_host_net.txt"
echo "# Redis Benchmark — Docker (redis:7-alpine, host networking)" > "$OUT"
echo "# Date: $(date)" >> "$OUT"
echo "" >> "$OUT"

docker rm -f redis_bench 2>/dev/null || true
log "Starting Redis container with host networking on port $DOCKER_HOST_PORT..."
docker run -d --name redis_bench --network host \
    redis:7-alpine redis-server --port "$DOCKER_HOST_PORT" --save "" --appendonly no >/dev/null
sleep 2

log "Running Docker+host-net Redis benchmark..."
echo "=== Pipeline depth: 1 ===" >> "$OUT"
run_redis_bench "127.0.0.1" "$DOCKER_HOST_PORT" >> "$OUT" 2>&1
echo "" >> "$OUT"

echo "=== Pipeline depth: 16 ===" >> "$OUT"
run_redis_pipeline_bench "127.0.0.1" "$DOCKER_HOST_PORT" 16 >> "$OUT" 2>&1
log "Docker host-net results saved to $OUT"

# --------------------------------------------------------------------------- #
# 3. DOCKER — NAT networking (default)
# --------------------------------------------------------------------------- #
section "Docker Redis Benchmark (NAT networking)"
OUT="$RESULTS_DIR/docker/redis_nat.txt"
echo "# Redis Benchmark — Docker (redis:7-alpine, NAT networking)" > "$OUT"
echo "# Date: $(date)" >> "$OUT"
echo "" >> "$OUT"

docker rm -f redis_bench_nat 2>/dev/null || true
docker run -d --name redis_bench_nat \
    --network benchmark_net \
    -p "${DOCKER_NAT_PORT}:6379" \
    redis:7-alpine redis-server --save "" --appendonly no >/dev/null

sleep 2

log "Running Docker+NAT Redis benchmark..."
echo "=== Pipeline depth: 1 ===" >> "$OUT"
run_redis_bench "127.0.0.1" "$DOCKER_NAT_PORT" >> "$OUT" 2>&1
echo "" >> "$OUT"

echo "=== Pipeline depth: 16 ===" >> "$OUT"
run_redis_pipeline_bench "127.0.0.1" "$DOCKER_NAT_PORT" 16 >> "$OUT" 2>&1

docker rm -f redis_bench_nat 2>/dev/null || true
log "Docker NAT results saved to $OUT"

# --------------------------------------------------------------------------- #
# 4. KVM
# --------------------------------------------------------------------------- #
section "KVM Redis Benchmark"
OUT="$RESULTS_DIR/kvm/redis.txt"
echo "# Redis Benchmark — KVM (QEMU-KVM, Ubuntu 22.04 guest)" > "$OUT"
echo "# Date: $(date)" >> "$OUT"
echo "" >> "$OUT"

if [[ -z "$VM_IP" ]]; then
    log "WARNING: VM_IP not set. Skipping KVM Redis benchmark."
    echo "# SKIPPED: VM_IP not available." >> "$OUT"
else
    log "Running KVM Redis benchmark (VM: $VM_IP)..."
    ssh -o StrictHostKeyChecking=no "${VM_USER}@${VM_IP}" \
        "redis-benchmark \
            -h 127.0.0.1 \
            -n $REQUESTS \
            -c $CLIENTS \
            -r $KEYSPACE \
            -t get,set,lpush,lpop \
            -q" >> "$OUT" 2>&1
    echo "" >> "$OUT"

    echo "=== Host-to-VM latency (measures KVM network virtualization overhead) ===" >> "$OUT"
    run_redis_bench "$VM_IP" "6379" >> "$OUT" 2>&1
    log "KVM results saved to $OUT"
fi

docker rm -f redis_bench 2>/dev/null || true

log ""
log "=== Redis benchmark complete ==="
