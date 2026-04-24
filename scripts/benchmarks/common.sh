#!/usr/bin/env bash

set -euo pipefail

VM_USER_DEFAULT="bench"
VM_PASSWORD_DEFAULT="benchpass"

vm_ssh_base_args() {
    printf '%s\n' \
        "-o" "StrictHostKeyChecking=no" \
        "-o" "UserKnownHostsFile=/dev/null" \
        "-o" "ConnectTimeout=10"
}

run_vm_ssh() {
    local vm_ip=$1
    shift

    local vm_user="${VM_USER:-$VM_USER_DEFAULT}"
    local vm_password="${BENCH_VM_PASSWORD:-$VM_PASSWORD_DEFAULT}"
    local -a ssh_args
    mapfile -t ssh_args < <(vm_ssh_base_args)

    if command -v sshpass >/dev/null 2>&1; then
        sshpass -p "$vm_password" ssh "${ssh_args[@]}" "${vm_user}@${vm_ip}" "$@"
    else
        ssh "${ssh_args[@]}" "${vm_user}@${vm_ip}" "$@"
    fi
}

check_vm_ssh_ready() {
    local vm_ip=$1
    if run_vm_ssh "$vm_ip" "true" >/dev/null 2>&1; then
        return 0
    fi

    cat >&2 <<EOF
Unable to authenticate to VM ${VM_USER:-$VM_USER_DEFAULT}@${vm_ip} over SSH.
Recreate the VM with scripts/setup/03_setup_kvm.sh or set BENCH_VM_PASSWORD if you changed the guest password.
EOF
    return 1
}
