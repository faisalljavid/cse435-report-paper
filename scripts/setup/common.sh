#!/usr/bin/env bash

set -euo pipefail

DISTRO_ID=""
DISTRO_VERSION_ID=""
DISTRO_FAMILY=""
PKG_MANAGER=""

detect_distro() {
    if [[ ! -r /etc/os-release ]]; then
        echo "Cannot detect Linux distribution: /etc/os-release is missing." >&2
        exit 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    DISTRO_ID="${ID:-unknown}"
    DISTRO_VERSION_ID="${VERSION_ID:-unknown}"

    case "${ID:-}" in
        ubuntu|debian|linuxmint|pop|elementary|zorin|kali)
            DISTRO_FAMILY="debian"
            PKG_MANAGER="apt"
            ;;
        fedora)
            DISTRO_FAMILY="fedora"
            PKG_MANAGER="dnf"
            ;;
        rhel|rocky|almalinux|centos)
            DISTRO_FAMILY="rhel"
            PKG_MANAGER="dnf"
            ;;
        arch|manjaro|endeavouros|cachyos)
            DISTRO_FAMILY="arch"
            PKG_MANAGER="pacman"
            ;;
        opensuse*|sles)
            DISTRO_FAMILY="suse"
            PKG_MANAGER="zypper"
            ;;
        *)
            case " ${ID_LIKE:-} " in
                *" debian "*)
                    DISTRO_FAMILY="debian"
                    PKG_MANAGER="apt"
                    ;;
                *" rhel "*|*" fedora "*)
                    DISTRO_FAMILY="rhel"
                    PKG_MANAGER="dnf"
                    ;;
                *" arch "*)
                    DISTRO_FAMILY="arch"
                    PKG_MANAGER="pacman"
                    ;;
                *" suse "*)
                    DISTRO_FAMILY="suse"
                    PKG_MANAGER="zypper"
                    ;;
                *)
                    echo "Unsupported Linux distribution: ${PRETTY_NAME:-$DISTRO_ID}" >&2
                    exit 1
                    ;;
            esac
            ;;
    esac
}

require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        echo "Run this script as root or via sudo." >&2
        exit 1
    fi
}

refresh_package_index() {
    case "$PKG_MANAGER" in
        apt)
            apt-get update -qq
            ;;
        dnf)
            dnf makecache -q
            ;;
        pacman)
            pacman -Sy --noconfirm
            ;;
        zypper)
            zypper --gpg-auto-import-keys refresh -q
            ;;
    esac
}

install_packages() {
    if [[ $# -eq 0 ]]; then
        return 0
    fi

    case "$PKG_MANAGER" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
            ;;
        dnf)
            dnf install -y "$@"
            ;;
        pacman)
            pacman -S --noconfirm --needed "$@"
            ;;
        zypper)
            zypper install -y "$@"
            ;;
    esac
}

require_commands() {
    local missing=()
    local cmd
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Missing required commands: ${missing[*]}" >&2
        exit 1
    fi
}

check_kvm_support() {
    if command -v kvm-ok >/dev/null 2>&1; then
        kvm-ok >/dev/null 2>&1
        return $?
    fi

    if command -v virt-host-validate >/dev/null 2>&1; then
        virt-host-validate qemu >/dev/null 2>&1
        return $?
    fi

    [[ -c /dev/kvm ]]
}

enable_service_now() {
    local service_name=$1

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now "$service_name"
    fi
}

add_user_to_group_if_present() {
    local user_name=$1
    local group_name=$2

    if getent group "$group_name" >/dev/null 2>&1; then
        usermod -aG "$group_name" "$user_name" 2>/dev/null || true
    fi
}
