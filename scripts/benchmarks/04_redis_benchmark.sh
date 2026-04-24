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

# Benchmark parameters
REQUESTS=100000
CLIENTS=50
KEYSPACE=1000000

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
log()     { echo -e "${GREEN}[REDIS]${NC} $*"; }
section() { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

run_redis_bench() {
    local host="${1:-127.0.0.1}"
    local port="${2:-6379}"
    redis-benchmark \
        -h "$host" \
        -p "$port" \
        -n "$REQUESTS" \
        -c "$CLIENTS" \
        -r "$KEYSPACE" \
        -t get,set,lpush,lpop \
        --latency-history \
        -q
}

# --------------------------------------------------------------------------- #
# 1. NATIVE
# --------------------------------------------------------------------------- #
section "Native Redis Benchmark"
OUT="$RESULTS_DIR/native/redis.txt"
echo "# Redis Benchmark — Native (Bare Metal)" > "$OUT"
echo "# Date: $(date)" >> "$OUT"
echo "# Requests: $REQUESTS | Clients: $CLIENTS | Keyspace: $KEYSPACE" >> "$OUT"
echo "" >> "$OUT"

# Start a local Redis instance for native testing
log "Starting native Redis server..."
redis-server --daemonize yes --port 6380 --save "" --appendonly no \
    --logfile /tmp/redis_native.log --pidfile /tmp/redis_native.pid

sleep 1  # Wait for Redis to start

log "Running native Redis benchmark..."
echo "=== Pipeline depth: 1 ===" >> "$OUT"
run_redis_bench "127.0.0.1" "6380" 2>&1 >> "$OUT"
echo "" >> "$OUT"

echo "=== Pipeline depth: 16 ===" >> "$OUT"
redis-benchmark -h 127.0.0.1 -p 6380 \
    -n "$REQUESTS" -c "$CLIENTS" \
    -t get,set -P 16 -q 2>&1 >> "$OUT"

# Stop native Redis
redis-cli -p 6380 shutdown nosave 2>/dev/null || true
log "Native results saved to $OUT"

# --------------------------------------------------------------------------- #
# 2. DOCKER — host networking (optimal, eliminates NAT overhead)
# --------------------------------------------------------------------------- #
section "Docker Redis Benchmark (host networking)"
OUT="$RESULTS_DIR/docker/redis_host_net.txt"
echo "# Redis Benchmark — Docker (redis:7-alpine, host networking)" > "$OUT"
echo "# Date: $(date)" >> "$OUT"
echo "" >> "$OUT"

# The redis_bench container is already running with host networking from setup
REDIS_RUNNING=$(docker ps --filter name=redis_bench --format '{{.Names}}' | head -1)
if [[ -z "$REDIS_RUNNING" ]]; then
    log "Starting Redis container with host networking..."
    docker run -d --name redis_bench --network host \
        redis:7-alpine redis-server --save "" --appendonly no
    sleep 2
fi

log "Running Docker+host-net Redis benchmark..."
echo "=== Pipeline depth: 1 ===" >> "$OUT"
run_redis_bench "127.0.0.1" "6379" 2>&1 >> "$OUT"
echo "" >> "$OUT"

echo "=== Pipeline depth: 16 ===" >> "$OUT"
redis-benchmark -h 127.0.0.1 -p 6379 \
    -n "$REQUESTS" -c "$CLIENTS" \
    -t get,set -P 16 -q 2>&1 >> "$OUT"

log "Docker host-net results saved to $OUT"

# --------------------------------------------------------------------------- #
# 3. DOCKER — NAT networking (default, introduces NAT overhead)
# --------------------------------------------------------------------------- #
section "Docker Redis Benchmark (NAT networking)"
OUT="$RESULTS_DIR/docker/redis_nat.txt"
echo "# Redis Benchmark — Docker (redis:7-alpine, NAT networking)" > "$OUT"
echo "# Date: $(date)" >> "$OUT"
echo "" >> "$OUT"

docker rm -f redis_bench_nat 2>/dev/null || true
docker run -d --name redis_bench_nat \
    --network benchmark_net \
    -p 6381:6379 \
    redis:7-alpine redis-server --save "" --appendonly no

sleep 2

log "Running Docker+NAT Redis benchmark..."
echo "=== Pipeline depth: 1 ===" >> "$OUT"
run_redis_bench "127.0.0.1" "6381" 2>&1 >> "$OUT"

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
    # Run redis-benchmark from inside the VM against its local Redis
    ssh -o StrictHostKeyChecking=no "${VM_USER}@${VM_IP}" \
        "redis-benchmark \
            -h 127.0.0.1 \
            -n $REQUESTS \
            -c $CLIENTS \
            -r $KEYSPACE \
            -t get,set,lpush,lpop \
            -q" 2>&1 >> "$OUT"
    echo "" >> "$OUT"

    # Also measure latency from the host to the VM (shows network virtualization overhead)
    echo "=== Host-to-VM latency (measures KVM network virtualization overhead) ===" >> "$OUT"
    run_redis_bench "$VM_IP" "6379" 2>&1 >> "$OUT"
    log "KVM results saved to $OUT"
fi

log ""
log "=== Redis benchmark complete ==="
