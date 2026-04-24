#!/usr/bin/env bash
# =============================================================================
# 01_install_dependencies.sh
# Installs all tools needed to run the Container vs. VM benchmark suite.
# Tested on Ubuntu 22.04 LTS / Debian 12 and derivatives (e.g. CachyOS).
#
# Usage: sudo bash scripts/setup/01_install_dependencies.sh
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
# 1. System packages
# --------------------------------------------------------------------------- #
log "Updating package lists..."
refresh_package_index

COMMON_PACKAGES=(
    sysbench
    fio
    wget
    curl
    jq
    numactl
    hwloc
    sysstat
    gcc
    make
)

case "$DISTRO_FAMILY" in
    debian)
        DISTRO_PACKAGES=(
            redis-tools
            redis-server
            default-mysql-server
            default-mysql-client
            qemu-kvm
            libvirt-daemon-system
            libvirt-clients
            virtinst
            virt-manager
            bridge-utils
            cpu-checker
            python3
            python3-pip
            iproute2
            genisoimage
            cloud-image-utils
            openssh-client
            sshpass
        )
        ;;
    fedora|rhel)
        DISTRO_PACKAGES=(
            redis
            mariadb-server
            mariadb
            qemu-kvm
            libvirt
            virt-install
            virt-manager
            bridge-utils
            python3
            python3-pip
            iproute
            genisoimage
            cloud-utils
            openssh-clients
            sshpass
        )
        ;;
    arch)
        DISTRO_PACKAGES=(
            redis
            mariadb
            qemu-full
            libvirt
            virt-install
            virt-manager
            bridge-utils
            python
            python-pip
            iproute2
            cdrkit
            cloud-image-utils
            openssh
            sshpass
        )
        ;;
    suse)
        DISTRO_PACKAGES=(
            redis
            mariadb
            qemu-kvm
            libvirt-daemon
            libvirt-client
            virt-install
            virt-manager
            bridge-utils
            python3
            python3-pip
            iproute2
            genisoimage
            cloud-utils
            openssh-clients
            sshpass
        )
        ;;
esac

log "Installing core benchmark tools..."
install_packages "${COMMON_PACKAGES[@]}" "${DISTRO_PACKAGES[@]}"

# --------------------------------------------------------------------------- #
# 2. STREAM memory benchmark (must compile from source)
# --------------------------------------------------------------------------- #
log "Building STREAM memory bandwidth benchmark..."
STREAM_DIR="/opt/stream"
mkdir -p "$STREAM_DIR"

wget -q -O "$STREAM_DIR/stream.c" \
    "https://www.cs.virginia.edu/stream/FTP/Code/stream.c" || \
    warn "Could not download STREAM — skipping. Get it from https://www.cs.virginia.edu/stream/"

if [[ -f "$STREAM_DIR/stream.c" ]]; then
    gcc -O3 -march=native -fopenmp \
        -DSTREAM_ARRAY_SIZE=10000000 \
        -o "$STREAM_DIR/stream" \
        "$STREAM_DIR/stream.c"
    ln -sf "$STREAM_DIR/stream" /usr/local/bin/stream_benchmark
    log "STREAM built successfully at /usr/local/bin/stream_benchmark"
fi

# --------------------------------------------------------------------------- #
# 3. Python plotting libraries
# --------------------------------------------------------------------------- #
log "Installing Python dependencies for result plotting..."
python3 -m pip install --quiet matplotlib pandas numpy seaborn

# --------------------------------------------------------------------------- #
# 4. Verify KVM support
# --------------------------------------------------------------------------- #
log "Checking KVM hardware support..."
if check_kvm_support; then
    log "KVM acceleration is available."
else
    warn "KVM acceleration not detected. VM benchmarks will run in emulation mode."
    warn "Check BIOS settings: ensure AMD-V (SVM) or Intel VT-x is enabled."
fi

# --------------------------------------------------------------------------- #
# 5. Add current user to required groups
# --------------------------------------------------------------------------- #
REAL_USER="${SUDO_USER:-$USER}"
add_user_to_group_if_present "$REAL_USER" libvirt
add_user_to_group_if_present "$REAL_USER" libvirt-qemu
add_user_to_group_if_present "$REAL_USER" kvm
add_user_to_group_if_present "$REAL_USER" docker
log "Added $REAL_USER to any detected libvirt/kvm/docker groups."
log "You may need to log out and back in for group changes to take effect."

log "=== Dependency installation complete ==="
log "Next step: sudo bash scripts/setup/02_setup_docker.sh"
