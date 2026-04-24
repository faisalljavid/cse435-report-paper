#!/usr/bin/env bash
# =============================================================================
# 02_setup_docker.sh
# Installs Docker CE (if not present) and prepares containers for benchmarking.
# Creates two benchmark container configurations:
#   - "optimal":  host networking + Docker volume  (minimum overhead)
#   - "default":  NAT networking + OverlayFS       (stock Docker defaults)
#
# Usage: sudo bash scripts/setup/02_setup_docker.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

require_root
detect_distro
log "Detected distro: ${DISTRO_ID} ${DISTRO_VERSION_ID} (${DISTRO_FAMILY})"

# --------------------------------------------------------------------------- #
# 1. Install Docker CE if not already present
# --------------------------------------------------------------------------- #
if ! command -v docker &>/dev/null; then
    case "$DISTRO_FAMILY" in
        debian)
            DOCKER_PACKAGES=(docker.io)
            ;;
        fedora|rhel|arch|suse)
            DOCKER_PACKAGES=(docker)
            ;;
    esac

    log "Docker not found. Installing Docker using ${PKG_MANAGER}..."
    refresh_package_index
    install_packages "${DOCKER_PACKAGES[@]}"
else
    log "Docker already installed: $(docker --version)"
fi

enable_service_now docker
log "Docker daemon is running."

REAL_USER="${SUDO_USER:-$USER}"
add_user_to_group_if_present "$REAL_USER" docker

# --------------------------------------------------------------------------- #
# 2. Pull benchmark images
# --------------------------------------------------------------------------- #
log "Pulling benchmark container images..."
docker pull ubuntu:22.04
docker pull redis:7-alpine
docker pull mysql:8.0
log "Images pulled successfully."

# --------------------------------------------------------------------------- #
# 3. Create a persistent Docker volume for I/O benchmark tests
# --------------------------------------------------------------------------- #
docker volume create benchmark_vol 2>/dev/null || true
log "Docker volume 'benchmark_vol' ready."

# --------------------------------------------------------------------------- #
# 4. Create a dedicated benchmark Docker network (for NAT tests)
# --------------------------------------------------------------------------- #
docker network create benchmark_net 2>/dev/null || true
log "Docker network 'benchmark_net' ready."

# --------------------------------------------------------------------------- #
# 5. Pre-start MySQL container (needs time to initialise)
# --------------------------------------------------------------------------- #
log "Starting MySQL container for pre-initialisation..."
docker rm -f mysql_bench 2>/dev/null || true

docker run -d \
    --name mysql_bench \
    --network benchmark_net \
    -p 3306:3306 \
    -e MYSQL_ROOT_PASSWORD=root \
    -e MYSQL_DATABASE=sbtest \
    -e MYSQL_USER=sbtest \
    -e MYSQL_PASSWORD=sbtest \
    mysql:8.0 \
    --innodb-buffer-pool-size=512M \
    --innodb-log-file-size=256M

log "Waiting 30 seconds for MySQL to initialise..."
sleep 30

# Verify MySQL is up
if docker exec mysql_bench mysqladmin ping -u root -proot --silent; then
    log "MySQL container is healthy."
else
    warn "MySQL did not respond in time. It may still be starting."
    warn "Wait a few more seconds before running the MySQL benchmark."
fi

# --------------------------------------------------------------------------- #
# 6. Pre-start Redis container
# --------------------------------------------------------------------------- #
log "Starting Redis container..."
docker rm -f redis_bench 2>/dev/null || true

docker run -d \
    --name redis_bench \
    --network host \
    redis:7-alpine \
    redis-server --save "" --appendonly no

log "Redis container started with host networking."

log "=== Docker setup complete ==="
log "Container summary:"
docker ps --filter "name=mysql_bench" --filter "name=redis_bench" \
    --format "  {{.Names}}\t{{.Status}}\t{{.Ports}}"
log ""
log "Next step: sudo bash scripts/setup/03_setup_kvm.sh"
