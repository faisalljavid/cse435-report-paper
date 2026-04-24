#!/usr/bin/env bash
# =============================================================================
# 03_setup_kvm.sh
# Creates a KVM virtual machine configured for benchmark testing.
#
# VM Specification:
#   - 4 vCPUs (host-passthrough model for maximum performance)
#   - 4 GB RAM with 1 GB hugepages
#   - 20 GB qcow2 disk image (virtio-scsi)
#   - Virtio network adapter (NAT via default libvirt network)
#   - Guest OS: Ubuntu Server 22.04 LTS (cloud image)
#
# The script installs sysbench, fio, redis-server, and mysql-server inside
# the VM automatically using cloud-init user-data.
#
# Usage: sudo bash scripts/setup/03_setup_kvm.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()   { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

require_root
detect_distro
log "Detected distro: ${DISTRO_ID} ${DISTRO_VERSION_ID} (${DISTRO_FAMILY})"

VM_NAME="bench-vm"
VM_RAM_MB=4096
VM_VCPUS=4
VM_DISK_GB=20
IMAGE_DIR="/var/lib/libvirt/images"
CLOUD_IMAGE_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
CLOUD_IMAGE="$IMAGE_DIR/ubuntu-22.04-cloud.img"
VM_DISK="$IMAGE_DIR/${VM_NAME}.qcow2"
SEED_ISO="$IMAGE_DIR/${VM_NAME}-seed.iso"
VM_BENCH_USER="bench"
VM_BENCH_PASSWORD="${BENCH_VM_PASSWORD:-benchpass}"

if [[ -r "/home/${SUDO_USER:-$USER}/.ssh/id_ed25519.pub" ]]; then
    VM_SSH_PUBLIC_KEY="$(<"/home/${SUDO_USER:-$USER}/.ssh/id_ed25519.pub")"
elif [[ -r "/home/${SUDO_USER:-$USER}/.ssh/id_rsa.pub" ]]; then
    VM_SSH_PUBLIC_KEY="$(<"/home/${SUDO_USER:-$USER}/.ssh/id_rsa.pub")"
else
    VM_SSH_PUBLIC_KEY=""
fi

vm_ssh_ready() {
    local vm_ip=$1

    if command -v sshpass >/dev/null 2>&1; then
        sshpass -p "$VM_BENCH_PASSWORD" ssh \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 \
            "${VM_BENCH_USER}@${vm_ip}" \
            "test -f /tmp/setup_done && command -v sysbench >/dev/null && command -v fio >/dev/null && command -v redis-benchmark >/dev/null" \
            >/dev/null 2>&1
    else
        ssh \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 \
            "${VM_BENCH_USER}@${vm_ip}" \
            "test -f /tmp/setup_done && command -v sysbench >/dev/null && command -v fio >/dev/null && command -v redis-benchmark >/dev/null" \
            >/dev/null 2>&1
    fi
}

# --------------------------------------------------------------------------- #
# 1. Check KVM availability
# --------------------------------------------------------------------------- #
log "Checking KVM support..."
if ! check_kvm_support; then
    error "KVM is not available on this system. Check that AMD-V/Intel VT-x is enabled in BIOS."
fi
log "KVM support confirmed."

require_commands virsh qemu-img virt-install wget

# --------------------------------------------------------------------------- #
# 2. Ensure libvirt default network is active
# --------------------------------------------------------------------------- #
virsh net-start default 2>/dev/null || true
virsh net-autostart default 2>/dev/null || true
log "libvirt default NAT network is active."

# --------------------------------------------------------------------------- #
# 3. Download Ubuntu Cloud Image
# --------------------------------------------------------------------------- #
if [[ ! -f "$CLOUD_IMAGE" ]]; then
    log "Downloading Ubuntu 22.04 cloud image (~600 MB)..."
    wget -q --show-progress -O "$CLOUD_IMAGE" "$CLOUD_IMAGE_URL"
else
    log "Cloud image already present at $CLOUD_IMAGE"
fi

# --------------------------------------------------------------------------- #
# 4. Create VM disk from cloud image
# --------------------------------------------------------------------------- #
log "Creating VM disk image (${VM_DISK_GB}G qcow2)..."
qemu-img create -f qcow2 -b "$CLOUD_IMAGE" -F qcow2 "$VM_DISK" "${VM_DISK_GB}G"
log "VM disk created at $VM_DISK"

# --------------------------------------------------------------------------- #
# 5. Create cloud-init seed ISO (auto-configures the VM on first boot)
# --------------------------------------------------------------------------- #
log "Creating cloud-init seed ISO..."

# user-data: installs all benchmark tools automatically
cat > /tmp/user-data <<USERDATA
#cloud-config
hostname: bench-vm
ssh_pwauth: true
users:
  - name: ${VM_BENCH_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: ${VM_BENCH_PASSWORD}
$(if [[ -n "$VM_SSH_PUBLIC_KEY" ]]; then printf '    ssh_authorized_keys:\n      - %s\n' "$VM_SSH_PUBLIC_KEY"; else printf '    ssh_authorized_keys: []\n'; fi)

chpasswd:
  expire: false
  list:
    - ${VM_BENCH_USER}:${VM_BENCH_PASSWORD}

package_update: true
package_upgrade: false

packages:
  - sysbench
  - fio
  - redis-server
  - redis-tools
  - mysql-server
  - mysql-client
  - wget
  - curl
  - python3
  - sysstat

runcmd:
  # Configure MySQL for benchmarking
  - mysql -e "CREATE DATABASE IF NOT EXISTS sbtest;"
  - mysql -e "CREATE USER IF NOT EXISTS 'sbtest'@'%' IDENTIFIED BY 'sbtest';"
  - mysql -e "GRANT ALL ON sbtest.* TO 'sbtest'@'%';"
  - mysql -e "FLUSH PRIVILEGES;"
  # Tune MySQL buffer pool
  - echo "[mysqld]" >> /etc/mysql/mysql.conf.d/benchmarks.cnf
  - echo "innodb_buffer_pool_size = 512M" >> /etc/mysql/mysql.conf.d/benchmarks.cnf
  - echo "innodb_log_file_size = 256M" >> /etc/mysql/mysql.conf.d/benchmarks.cnf
  - systemctl restart mysql
  # Enable Redis without persistence (pure memory mode)
  - sed -i 's/^save /#save /' /etc/redis/redis.conf
  - systemctl restart redis-server
  - echo "cloud-init benchmark setup complete" > /tmp/setup_done

final_message: "Benchmark VM is ready after \$UPTIME seconds."
USERDATA

cat > /tmp/meta-data <<METADATA
instance-id: bench-vm-001
local-hostname: bench-vm
METADATA

# Package into a seed ISO
if command -v cloud-localds >/dev/null 2>&1; then
    cloud-localds "$SEED_ISO" /tmp/user-data /tmp/meta-data
elif command -v genisoimage >/dev/null 2>&1; then
    genisoimage -output "$SEED_ISO" \
        -volid cidata -joliet -rock \
        /tmp/user-data /tmp/meta-data >/dev/null 2>&1
else
    error "Neither cloud-localds nor genisoimage is installed. Run 01_install_dependencies.sh first."
fi
log "Seed ISO created at $SEED_ISO"

# --------------------------------------------------------------------------- #
# 6. Define and start the VM
# --------------------------------------------------------------------------- #
log "Defining KVM virtual machine: $VM_NAME"

# Remove existing VM if present
virsh destroy "$VM_NAME" 2>/dev/null || true
virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true

virt-install \
    --name "$VM_NAME" \
    --ram "$VM_RAM_MB" \
    --vcpus "$VM_VCPUS" \
    --cpu host-passthrough \
    --os-variant ubuntu22.04 \
    --disk path="$VM_DISK",format=qcow2,bus=virtio,cache=none \
    --disk path="$SEED_ISO",device=cdrom \
    --network network=default,model=virtio \
    --graphics none \
    --console pty,target_type=serial \
    --import \
    --noautoconsole

log "VM '$VM_NAME' started. Waiting for cloud-init to complete (~3 minutes)..."

# --------------------------------------------------------------------------- #
# 7. Wait for VM to be ready and get its IP
# --------------------------------------------------------------------------- #
log "Polling for VM IP address..."
VM_IP=""
for i in $(seq 1 60); do
    VM_IP=$(virsh domifaddr "$VM_NAME" 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1 || true)
    if [[ -n "$VM_IP" ]]; then
        break
    fi
    sleep 5
done

if [[ -z "$VM_IP" ]]; then
    warn "Could not determine VM IP automatically."
    warn "Use: virsh domifaddr $VM_NAME  to get the IP after the VM fully boots."
else
    log "VM IP address: $VM_IP"
    echo "$VM_IP" > /tmp/vm_ip.txt
    log "IP saved to /tmp/vm_ip.txt for use by benchmark scripts."

    log "Waiting for cloud-init and benchmark packages inside the VM..."
    VM_READY=0
    for i in $(seq 1 60); do
        if vm_ssh_ready "$VM_IP"; then
            VM_READY=1
            break
        fi
        sleep 10
    done

    if [[ "$VM_READY" -eq 1 ]]; then
        log "VM provisioning completed successfully."
    else
        warn "VM is reachable, but cloud-init/setup may still be running."
        warn "Wait a bit longer or check with: ssh ${VM_BENCH_USER}@${VM_IP} 'cat /tmp/setup_done'"
    fi
fi

log ""
log "=== KVM VM setup initiated ==="
log "VM Name  : $VM_NAME"
log "vCPUs    : $VM_VCPUS (host-passthrough)"
log "RAM      : ${VM_RAM_MB} MB"
log "Disk     : $VM_DISK (${VM_DISK_GB}G qcow2)"
log "Network  : virtio (NAT)"
log ""
log "VM setup waits for cloud-init, package installation, and /tmp/setup_done before reporting ready."
log "VM login user : ${VM_BENCH_USER}"
log "VM login pass : ${VM_BENCH_PASSWORD}"
log "You can monitor progress with: sudo virsh console $VM_NAME"
log ""
log "Next step: sudo bash scripts/benchmarks/run_all.sh"
