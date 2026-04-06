#!/usr/bin/env bash
set -euo pipefail

### ============================================================
###  GLOBAL VARIABLES
### ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${HOME}/nomad_backup/$(date +%Y-%m-%d)"

IS_WSL2=false
VIRT_TYPE=""        # wsl2 | vm | baremetal
VIRT_SYSTEM=""      # hyperv | vmware | kvm | virtualbox | ...

OS_ID=""            # opensuse-leap | opensuse-tumbleweed | opensuse-slowroll | sles
OS_VERSION=""       # 15.6 | 16.0 | Tumbleweed | Slowroll | ...
OS_VERSION_MAJOR=0
OS_MAC_DEFAULT=""   # apparmor | selinux

MAC_ACTIVE=""       # selinux | apparmor | none
MAC_MODE=""         # enforcing | permissive | inactive | none
MAC_FRAMEWORK_APPLIED=""

SKIP_FIREWALLD=false
SKIP_AUDIT=false
SKIP_MAC=false
SKIP_FIPS=false
NEEDS_REBOOT=false

### ============================================================
###  HELPERS
### ============================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-firewalld) SKIP_FIREWALLD=true; shift ;;
            --skip-audit)     SKIP_AUDIT=true;     shift ;;
            --skip-mac)       SKIP_MAC=true;        shift ;;
            --skip-fips)      SKIP_FIPS=true;       shift ;;
            --help)           print_help; exit 0   ;;
            *) echo "Unknown argument: $1"; exit 1 ;;
        esac
    done
}

print_help() {
    cat <<EOF

USAGE
  ./harden-os.sh [OPTIONS]

DESCRIPTION
  Hardens an OpenSUSE-based system. Detects whether the system is running
  in WSL2, a VM, or on bare metal, and selects the appropriate MAC framework
  (AppArmor or SELinux) accordingly.

  MAC framework selection logic:
    WSL2                    → AppArmor enabled automatically (no prompt)
    VM or bare metal,
      already has SELinux   → ensures enforcing mode
      already has AppArmor  → ensures enforce mode
      has neither           → asks user: AppArmor or SELinux
                              (informs about distro defaults)
                              If SELinux chosen but not available,
                              explains why and offers AppArmor as fallback

  OpenSUSE defaults:
    Leap 16+ / SLES 16+     → SELinux is default
    Leap 15.x               → AppArmor is default
    Tumbleweed / Slowroll   → AppArmor is default (SELinux also available)

  Safe to run on a Nomad worker — Docker/Nomad networking is preserved.

OPTIONS
  --skip-firewalld   Skip firewalld setup
  --skip-audit       Skip auditd setup
  --skip-mac         Skip MAC framework setup entirely
  --skip-fips        Skip FIPS setup
  --help             Show this help text

FIPS
  On VM or bare metal the script will ask if you want to install FIPS support
  using patterns-base-fips. This installs the FIPS-validated crypto modules,
  adds fips=1 to the kernel boot parameters, regenerates the initramfs, and
  requires a reboot to take effect.

  FIPS is not possible in WSL2 — the Hyper-V kernel is not FIPS-validated
  and /proc/sys/crypto/fips_enabled is read-only in the WSL2 namespace.

WHAT THIS SCRIPT DOES NOT DO
  FIPS (WSL2)  — requires a FIPS-validated kernel, not possible in WSL2
  Bootloader   — not applicable in WSL2
  Physical     — disk encryption, BIOS password, USB lockdown

EOF
}

backup_file() {
    local dst="$1"
    if [[ -f "$dst" ]]; then
        mkdir -p "${BACKUP_DIR}"
        local backup
        backup="${BACKUP_DIR}/$(basename "$dst").bak"
        sudo cp "$dst" "$backup"
        sudo chown "$(id -un)":"$(id -gn)" "$backup"
        echo "[INFO] Backed up ${dst} → ${backup}"
    fi
}

install_pattern_or_pkgs() {
    # Usage: install_pattern_or_pkgs <pattern-name> <fallback-pkg> [<fallback-pkg> ...]
    # Tries the zypper pattern first (preferred — pulls in all deps and configures
    # future package installs). Falls back to individual packages if the pattern
    # is not available in the current repos.
    local pattern="$1"
    shift
    local fallback_pkgs=("$@")

    if sudo zypper -n install -t pattern "$pattern" 2>/dev/null; then
        echo "[INFO] Installed pattern: ${pattern}"
    else
        echo "[INFO] Pattern '${pattern}' not available — installing individual packages"
        sudo zypper -n install "${fallback_pkgs[@]}"
    fi
}

sysctl_set() {
    local key="$1" val="$2"
    if sudo sysctl -w "${key}=${val}" &>/dev/null; then
        echo "[INFO] sysctl ${key}=${val}"
    else
        echo "[SKIP] sysctl ${key} not available in this kernel"
    fi
}

# resolve_conf <etc-path> [usr-etc-path]
# On usrmerge systems a config may only exist in /usr/etc/ until an admin
# override is created in /etc/. This function returns the path that exists,
# copying the vendor file to /etc/ first if needed so callers can edit it.
resolve_conf() {
    local etc_path="$1"
    local vendor_path="${2:-/usr${etc_path}}"   # e.g. /etc/foo → /usr/etc/foo

    if [[ -f "$etc_path" ]]; then
        echo "$etc_path"
        return
    fi

    if [[ -f "$vendor_path" ]]; then
        sudo mkdir -p "$(dirname "$etc_path")"
        sudo cp "$vendor_path" "$etc_path"
        echo "[INFO] Copied vendor ${vendor_path} → ${etc_path} (usrmerge override)" >&2
        echo "$etc_path"
        return
    fi

    # Neither exists — return the /etc/ path and let the caller handle it
    echo "$etc_path"
}

ask_yes_no() {
    # ask_yes_no "Question?" → returns 0 for yes, 1 for no
    local prompt="$1"
    local answer
    while true; do
        read -rp "${prompt} [y/n]: " answer
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) echo "Please answer y or n" ;;
        esac
    done
}

### ============================================================
###  DETECT ENVIRONMENT
### ============================================================
detect_environment() {
    echo "=== Detecting environment ==="

    # WSL2
    if grep -qi "microsoft" /proc/version 2>/dev/null; then
        IS_WSL2=true
        VIRT_TYPE="wsl2"
        VIRT_SYSTEM="hyperv"
        echo "[INFO] Running inside WSL2"
    else
        IS_WSL2=false
        _detect_virtualization
    fi

    # OS
    _detect_os_version

    # Current MAC status
    _detect_mac_status

    echo "[INFO] Virtualization : ${VIRT_TYPE} (${VIRT_SYSTEM:-none})"
    echo "[INFO] OS             : ${OS_ID} ${OS_VERSION}"
    echo "[INFO] MAC default    : ${OS_MAC_DEFAULT}"
    echo "[INFO] MAC active     : ${MAC_ACTIVE} (${MAC_MODE})"
}

_detect_virtualization() {
    if command -v systemd-detect-virt &>/dev/null; then
        local virt
        virt=$(systemd-detect-virt 2>/dev/null || echo "none")
        if [[ "$virt" == "none" ]]; then
            VIRT_TYPE="baremetal"
        else
            VIRT_TYPE="vm"
            VIRT_SYSTEM="$virt"
        fi
        return
    fi

    # Fallback: check DMI product name
    local dmi
    dmi=$(cat /sys/class/dmi/id/product_name 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "")
    case "$dmi" in
        *vmware*)     VIRT_TYPE="vm";       VIRT_SYSTEM="vmware"     ;;
        *virtualbox*) VIRT_TYPE="vm";       VIRT_SYSTEM="virtualbox" ;;
        *kvm*|*qemu*) VIRT_TYPE="vm";       VIRT_SYSTEM="kvm"        ;;
        *hyper-v*|*hyperv*|*microsoft*)
                      VIRT_TYPE="vm";       VIRT_SYSTEM="hyperv"     ;;
        *)            VIRT_TYPE="baremetal"; VIRT_SYSTEM=""           ;;
    esac
}

_detect_os_version() {
    OS_ID=$(grep '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "unknown")
    OS_VERSION=$(grep '^VERSION_ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "0")

    OS_VERSION_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)
    # Tumbleweed and Slowroll have non-numeric VERSION_IDs
    if ! [[ "$OS_VERSION_MAJOR" =~ ^[0-9]+$ ]]; then
        OS_VERSION_MAJOR=0
    fi

    case "$OS_ID" in
        opensuse-leap|sles|sle-micro)
            if [[ "$OS_VERSION_MAJOR" -ge 16 ]]; then
                OS_MAC_DEFAULT="selinux"
            else
                OS_MAC_DEFAULT="apparmor"
            fi
            ;;
        opensuse-tumbleweed|opensuse-slowroll)
            OS_MAC_DEFAULT="apparmor"
            ;;
        *)
            OS_MAC_DEFAULT="apparmor"
            ;;
    esac
}

_detect_mac_status() {
    # SELinux — check first (takes priority if both somehow installed)
    if command -v getenforce &>/dev/null; then
        local semode
        semode=$(getenforce 2>/dev/null || echo "Disabled")
        case "$semode" in
            Enforcing|Permissive)
                MAC_ACTIVE="selinux"
                MAC_MODE="${semode,,}"
                return
                ;;
        esac
    fi

    # SELinux installed but not yet active (e.g. after install, before reboot)
    if [[ -f /etc/selinux/config ]] && grep -q "^SELINUX=enforcing\|^SELINUX=permissive" /etc/selinux/config 2>/dev/null; then
        MAC_ACTIVE="selinux"
        MAC_MODE="inactive_pending_reboot"
        return
    fi

    # AppArmor kernel support
    local aa_kernel
    aa_kernel=$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null || echo "N")
    if [[ "$aa_kernel" == "Y" ]]; then
        if systemctl is-active --quiet apparmor 2>/dev/null; then
            MAC_ACTIVE="apparmor"
            MAC_MODE="active"
        else
            MAC_ACTIVE="apparmor"
            MAC_MODE="inactive"
        fi
        return
    fi

    MAC_ACTIVE="none"
    MAC_MODE="none"
}

### ============================================================
###  SYSTEM UPDATE
### ============================================================
update_system() {
    echo "=== Updating system packages ==="
    sudo zypper -n refresh
    sudo zypper -n update
    sudo zypper -n patch --with-update || true
    echo "[INFO] System is up to date"
}

### ============================================================
###  REMOVE UNNECESSARY PACKAGES
### ============================================================
remove_unnecessary_packages() {
    echo "=== Removing unnecessary packages ==="
    local pkgs=(telnet rsh rsh-server talk talk-server xinetd ypbind ypserv tftp tftp-server)
    for pkg in "${pkgs[@]}"; do
        if rpm -q "$pkg" &>/dev/null; then
            sudo zypper -n remove "$pkg"
            echo "[INFO] Removed ${pkg}"
        fi
    done
}

### ============================================================
###  INSTALL HARDENING TOOLS
### ============================================================
install_hardening_tools() {
    echo "=== Installing hardening tools ==="
    local pkgs=()
    for pkg in audit pam_pwquality; do
        rpm -q "$pkg" &>/dev/null || pkgs+=("$pkg")
    done
    if [[ ${#pkgs[@]} -gt 0 ]]; then
        sudo zypper -n install "${pkgs[@]}" || true
    fi
}

### ============================================================
###  SYSCTL HARDENING
### ============================================================
harden_sysctl() {
    echo "=== Applying sysctl hardening ==="

    local conf="/etc/sysctl.d/90-harden.conf"
    backup_file "$conf"

    sudo tee "$conf" > /dev/null <<'EOF'
# ---------------------------------------------------------------
# Kernel hardening
# ---------------------------------------------------------------
kernel.randomize_va_space = 2
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
kernel.perf_event_paranoid = 3
kernel.sysrq = 0
fs.suid_dumpable = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2

# ---------------------------------------------------------------
# Network hardening
# ---------------------------------------------------------------
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.log_martians = 1
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0

# NOTE: net.ipv4.ip_forward intentionally NOT disabled — required by Docker/Nomad
EOF

    sudo chmod 644 "$conf"

    while IFS='=' read -r key val; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${key// }" ]] && continue
        sysctl_set "${key// /}" "${val// /}"
    done < <(grep -v '^#' "$conf" | grep -v '^$' | grep '=')

    echo "[INFO] sysctl hardening applied"
}

### ============================================================
###  DISABLE CORE DUMPS
### ============================================================
harden_core_dumps() {
    echo "=== Disabling core dumps ==="

    sudo tee /etc/security/limits.d/90-nodump.conf > /dev/null <<'EOF'
* hard core 0
* soft core 0
EOF

    sudo mkdir -p /etc/systemd/coredump.conf.d
    sudo tee /etc/systemd/coredump.conf.d/nodump.conf > /dev/null <<'EOF'
[Coredump]
Storage=none
ProcessSizeMax=0
EOF
    echo "[INFO] Core dumps disabled"
}

### ============================================================
###  DISABLE UNNECESSARY SERVICES
### ============================================================
harden_services() {
    echo "=== Disabling unnecessary services ==="
    local services=(avahi-daemon cups bluetooth rpcbind nfs-server vsftpd telnet.socket rsh.socket)
    for svc in "${services[@]}"; do
        if systemctl list-unit-files "${svc}" 2>/dev/null | grep -q "${svc}"; then
            sudo systemctl disable --now "${svc}" 2>/dev/null && \
                echo "[INFO] Disabled ${svc}" || true
        fi
    done
}

### ============================================================
###  PAM
### ============================================================
harden_pam() {
    echo "=== Hardening PAM policies ==="

    backup_file /etc/security/faillock.conf
    sudo tee /etc/security/faillock.conf > /dev/null <<'EOF'
deny = 5
fail_interval = 300
unlock_time = 600
even_deny_root
EOF
    echo "[INFO] faillock: 5 attempts → 10 min lockout"

    local login_defs
    login_defs=$(resolve_conf /etc/login.defs)
    if [[ -f "$login_defs" ]]; then
        backup_file "$login_defs"
        sudo sed -i \
            -e 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   90/' \
            -e 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   1/'  \
            -e 's/^PASS_WARN_AGE.*/PASS_WARN_AGE   14/' \
            "$login_defs"
        echo "[INFO] Password aging: max 90 days, warn 14 days before"
    else
        echo "[WARN] login.defs not found in /etc/ or /usr/etc/ — skipping password aging"
    fi

    local pwquality_conf
    pwquality_conf=$(resolve_conf /etc/security/pwquality.conf)
    if [[ -f "$pwquality_conf" ]]; then
        backup_file "$pwquality_conf"
        sudo tee "$pwquality_conf" > /dev/null <<'EOF'
minlen = 12
minclass = 3
usercheck = 1
difok = 5
EOF
        echo "[INFO] pwquality: min 12 chars, 3 character classes"
    else
        echo "[WARN] pwquality.conf not found — skipping password complexity"
    fi
}

### ============================================================
###  AUDIT
### ============================================================
setup_audit() {
    if [[ "$SKIP_AUDIT" == true ]]; then
        echo "[SKIP] auditd (--skip-audit)"
        return
    fi

    echo "=== Setting up auditd ==="

    if [[ "$IS_WSL2" == true ]]; then
        echo "[INFO] WSL2: auditd kernel support varies — attempting"
    fi

    if ! rpm -q audit &>/dev/null; then
        sudo zypper -n install audit || { echo "[WARN] Could not install auditd — skipping"; return; }
    fi

    sudo mkdir -p /etc/audit/rules.d
    sudo tee /etc/audit/rules.d/90-harden.rules > /dev/null <<'EOF'
-D
-b 8192
-f 1

-w /etc/passwd     -p wa -k identity
-w /etc/shadow     -p wa -k identity
-w /etc/group      -p wa -k identity
-w /etc/gshadow    -p wa -k identity
-w /etc/sudoers    -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers
-w /etc/ssh/       -p wa -k sshd
-w /etc/nomad.d/   -p wa -k nomad
-w /etc/cron.d/    -p wa -k cron
-w /etc/crontab    -p wa -k cron
-w /var/spool/cron/ -p wa -k cron
-w /sbin/insmod    -p x  -k modules
-w /sbin/rmmod     -p x  -k modules
-w /sbin/modprobe  -p x  -k modules
-a always,exit -F arch=b64 -S init_module -S delete_module -k modules
-a always,exit -F arch=b64 -S setuid -k setuid
-a always,exit -F arch=b64 -S setgid  -k setgid

# Uncomment when configuration is finalised (immutable — requires reboot to change):
# -e 2
EOF

    sudo chmod 640 /etc/audit/rules.d/90-harden.rules
    sudo systemctl enable --now auditd 2>/dev/null && \
        echo "[INFO] auditd enabled" || \
        echo "[WARN] auditd could not start — kernel may not support it in this environment"
}

### ============================================================
###  MAC FRAMEWORK
### ============================================================
setup_mac_framework() {
    if [[ "$SKIP_MAC" == true ]]; then
        echo "[SKIP] MAC framework (--skip-mac)"
        return
    fi

    echo "=== Setting up MAC framework ==="

    case "$MAC_ACTIVE" in
        selinux)
            if [[ "$MAC_MODE" == "inactive_pending_reboot" ]]; then
                echo "[INFO] SELinux installed but awaiting reboot to activate"
                NEEDS_REBOOT=true
            else
                echo "[INFO] SELinux already active (${MAC_MODE}) — ensuring enforcing mode"
                _mac_enforce_selinux
            fi
            MAC_FRAMEWORK_APPLIED="selinux"
            return
            ;;
        apparmor)
            echo "[INFO] AppArmor already active — ensuring enforce mode on all profiles"
            _mac_enforce_apparmor
            MAC_FRAMEWORK_APPLIED="apparmor"
            return
            ;;
    esac

    # Nothing active — choose what to enable
    if [[ "$VIRT_TYPE" == "wsl2" ]]; then
        _mac_autoselect_wsl2
    else
        _mac_ask_user
    fi
}

_mac_autoselect_wsl2() {
    echo "[INFO] WSL2 detected — enabling AppArmor automatically"
    echo "[INFO] (SELinux and FIPS are not supported in WSL2)"

    local aa_kernel
    aa_kernel=$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null || echo "N")

    if [[ "$aa_kernel" != "Y" ]]; then
        echo "[WARN] AppArmor not available in this WSL2 kernel"
        echo "[INFO] Update WSL2 kernel to 5.15+ for AppArmor support:"
        echo "       Run in PowerShell on Windows host: wsl --update"
        MAC_FRAMEWORK_APPLIED="none"
        return
    fi

    _mac_install_and_enforce_apparmor
    MAC_FRAMEWORK_APPLIED="apparmor"
}

_mac_ask_user() {
    echo ""
    echo "No MAC framework is currently active."
    echo ""
    echo "Choose a Mandatory Access Control framework:"
    echo ""
    echo "  1) AppArmor  — default in OpenSUSE Leap 15.x, Tumbleweed, Slowroll"
    echo "  2) SELinux   — default in OpenSUSE Leap 16+ and SLES 16+"
    echo ""

    case "$OS_MAC_DEFAULT" in
        selinux)  echo "  Recommended for ${OS_ID} ${OS_VERSION}: SELinux  (option 2)" ;;
        apparmor) echo "  Recommended for ${OS_ID} ${OS_VERSION}: AppArmor (option 1)" ;;
    esac
    echo ""

    local choice
    while true; do
        read -rp "Enter 1 or 2: " choice
        [[ "$choice" == "1" || "$choice" == "2" ]] && break
        echo "Please enter 1 or 2"
    done

    if [[ "$choice" == "1" ]]; then
        _mac_install_and_enforce_apparmor
        MAC_FRAMEWORK_APPLIED="apparmor"
    else
        _mac_try_selinux
    fi
}

_mac_try_selinux() {
    local reason
    reason=$(_check_selinux_available)

    case "$reason" in
        available)
            _mac_install_selinux
            MAC_FRAMEWORK_APPLIED="selinux"
            ;;
        no_kernel_support)
            echo ""
            echo "[WARN] SELinux cannot be enabled on this system:"
            echo "       The running kernel does not have SELinux support compiled in"
            echo "       (CONFIG_SECURITY_SELINUX is not set in kernel config)."
            echo ""
            echo "       To use SELinux you need a kernel built with SELinux support."
            echo "       On Leap 16+ or SLES 16+, reinstall the OS and select SELinux"
            echo "       in the installer. On older versions, SELinux is not officially"
            echo "       supported."
            echo ""
            _mac_offer_apparmor_fallback
            ;;
        no_packages)
            echo ""
            echo "[WARN] SELinux cannot be enabled on this system:"
            echo "       The required SELinux packages (selinux-policy, selinux-tools)"
            echo "       are not available in the configured zypper repositories."
            echo ""
            echo "       SELinux packages are shipped by default in Leap 16+ and SLES 16+."
            echo "       On older versions or Tumbleweed, they may need additional repos."
            echo ""
            _mac_offer_apparmor_fallback
            ;;
    esac
}

_mac_offer_apparmor_fallback() {
    if ask_yes_no "Install AppArmor instead?"; then
        _mac_install_and_enforce_apparmor
        MAC_FRAMEWORK_APPLIED="apparmor"
    else
        echo "[INFO] Skipping MAC framework — no Mandatory Access Control will be active"
        MAC_FRAMEWORK_APPLIED="none"
    fi
}

_check_selinux_available() {
    # Check kernel support
    local kconfig
    kconfig="/boot/config-$(uname -r)"
    if [[ -f "$kconfig" ]]; then
        if ! grep -q "CONFIG_SECURITY_SELINUX=y" "$kconfig"; then
            echo "no_kernel_support"; return
        fi
    elif [[ -f /proc/config.gz ]]; then
        if ! zcat /proc/config.gz | grep -q "CONFIG_SECURITY_SELINUX=y"; then
            echo "no_kernel_support"; return
        fi
    else
        # Can't read kernel config — check if selinuxfs is a known filesystem type
        if ! grep -q "selinuxfs" /proc/filesystems 2>/dev/null; then
            echo "no_kernel_support"; return
        fi
    fi

    # Check packages available in repos
    if ! sudo zypper search -x selinux-policy &>/dev/null | grep -q "selinux-policy"; then
        echo "no_packages"; return
    fi

    echo "available"
}

_mac_install_selinux() {
    echo "=== Installing SELinux ==="
    install_pattern_or_pkgs "patterns-base-selinux" \
        selinux-tools \
        selinux-policy \
        selinux-policy-targeted \
        policycoreutils \
        policycoreutils-python-utils \
        || { echo "ERROR: Failed to install SELinux packages"; exit 1; }

    # Write SELinux config — start in permissive so the system boots
    # and relabels before switching to enforcing
    sudo mkdir -p /etc/selinux
    sudo tee /etc/selinux/config > /dev/null <<'EOF'
# Start in permissive mode — switch to enforcing after filesystem relabel
SELINUX=permissive
SELINUXTYPE=targeted
EOF

    # Enable SELinux in GRUB
    if [[ -f /etc/default/grub ]]; then
        if ! grep -q "security=selinux" /etc/default/grub; then
            sudo sed -i \
                's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 security=selinux selinux=1"/' \
                /etc/default/grub
            sudo grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || \
                sudo grub-mkconfig  -o /boot/grub/grub.cfg  2>/dev/null || \
                echo "[WARN] Could not update GRUB — update manually"
        fi
    fi

    # Schedule filesystem relabel on next boot
    sudo touch /.autorelabel

    echo "[INFO] SELinux installed in permissive mode"
    echo "[INFO] A reboot is required to relabel the filesystem"
    echo "[INFO] After reboot, switch to enforcing:"
    echo "         sudo setenforce 1"
    echo "         sudo sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config"
    NEEDS_REBOOT=true
}

_mac_enforce_selinux() {
    local mode
    mode=$(getenforce 2>/dev/null || echo "Disabled")
    if [[ "$mode" == "Permissive" ]]; then
        sudo setenforce 1 && \
            sudo sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config && \
            echo "[INFO] SELinux switched to enforcing mode" || \
            echo "[WARN] Could not switch SELinux to enforcing — check audit log"
    elif [[ "$mode" == "Enforcing" ]]; then
        echo "[INFO] SELinux already in enforcing mode"
    fi
}

_mac_install_and_enforce_apparmor() {
    if ! rpm -q apparmor-utils &>/dev/null; then
        install_pattern_or_pkgs "patterns-base-apparmor" \
            apparmor apparmor-utils apparmor-profiles apparmor-parser
    fi
    sudo systemctl enable --now apparmor
    _mac_enforce_apparmor
}

_mac_enforce_apparmor() {
    if ! command -v aa-enforce &>/dev/null; then
        install_pattern_or_pkgs "patterns-base-apparmor" \
            apparmor apparmor-utils apparmor-profiles apparmor-parser
    fi

    local count=0
    for profile in /etc/apparmor.d/usr.*; do
        [[ -f "$profile" ]] || continue
        sudo aa-enforce "$profile" 2>/dev/null && (( count++ )) || true
    done

    echo "[INFO] AppArmor enabled — ${count} profile(s) set to enforce mode"
    echo "[INFO] Run 'sudo aa-status' to see active profiles"
}

### ============================================================
###  FIPS
### ============================================================
setup_fips() {
    if [[ "$SKIP_FIPS" == true ]]; then
        echo "[SKIP] FIPS (--skip-fips)"
        return
    fi

    if [[ "$VIRT_TYPE" == "wsl2" ]]; then
        echo "[INFO] WSL2 detected — skipping FIPS"
        echo "[INFO] The Hyper-V kernel is not FIPS-validated and"
        echo "[INFO] /proc/sys/crypto/fips_enabled is read-only in WSL2"
        return
    fi

    echo "=== FIPS setup ==="

    # Already enabled?
    local fips_enabled
    fips_enabled=$(cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo "0")
    if [[ "$fips_enabled" == "1" ]]; then
        echo "[INFO] FIPS is already enabled on this system"
        return
    fi

    echo ""
    echo "FIPS 140 enforces the use of validated cryptographic modules system-wide."
    echo "It requires a reboot and can affect software that uses non-approved algorithms."
    echo ""
    if ! ask_yes_no "Install FIPS support (patterns-base-fips)?"; then
        echo "[INFO] Skipping FIPS"
        return
    fi

    install_pattern_or_pkgs "patterns-base-fips" \
        dracut-fips \
        openssl \
        libgcrypt20-hmac \
        libssl3-hmac

    # Add fips=1 to kernel boot parameters
    if [[ -f /etc/default/grub ]]; then
        if ! grep -q "fips=1" /etc/default/grub; then
            sudo sed -i \
                's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 fips=1"/' \
                /etc/default/grub
            echo "[INFO] Added fips=1 to GRUB_CMDLINE_LINUX_DEFAULT"
        else
            echo "[INFO] fips=1 already present in GRUB config"
        fi

        sudo grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || \
            sudo grub-mkconfig  -o /boot/grub/grub.cfg  2>/dev/null || \
            echo "[WARN] Could not update GRUB automatically — add fips=1 manually"
    else
        echo "[WARN] /etc/default/grub not found — add fips=1 to kernel cmdline manually"
    fi

    # Regenerate initramfs so dracut-fips hooks are included
    echo "[INFO] Regenerating initramfs..."
    sudo dracut --regenerate-all --force 2>/dev/null || \
        sudo mkinitrd 2>/dev/null || \
        echo "[WARN] Could not regenerate initramfs — run 'sudo dracut --regenerate-all --force' manually"

    echo "[INFO] FIPS support installed — reboot required to activate"
    NEEDS_REBOOT=true
}

### ============================================================
###  FIREWALLD
### ============================================================
setup_firewalld() {
    if [[ "$SKIP_FIREWALLD" == true ]]; then
        echo "[SKIP] firewalld (--skip-firewalld)"
        return
    fi

    # WSL2: Hyper-V and Windows Firewall handle external traffic.
    # Running firewalld inside WSL2 adds no real protection and risks
    # conflicting with the Windows-side rules we set up in wsl-firewall-setup.ps1.
    if [[ "$VIRT_TYPE" == "wsl2" ]]; then
        echo "[INFO] WSL2 detected — skipping firewalld"
        echo "[INFO] Network filtering is handled by Windows Firewall (wsl-firewall-setup.ps1)"
        return
    fi

    echo "=== Setting up firewalld ==="

    # If firewalld is already running, don't reinstall — just add rules
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        echo "[INFO] firewalld is already running"
    else
        if ! rpm -q firewalld &>/dev/null; then
            sudo zypper -n install firewalld
        fi

        # Ask about SSH before enabling the firewall so the user doesn't get locked out.
        # Default answer is yes — it is almost always the right choice.
        echo ""
        echo "[IMPORTANT] firewalld will be enabled with default zone 'drop'."
        echo "            This blocks ALL inbound connections unless explicitly allowed."
        echo ""
        if ask_yes_no "Open SSH port now to avoid being locked out of this machine?"; then
            _FIREWALLD_OPEN_SSH=true
        else
            _FIREWALLD_OPEN_SSH=false
            echo "[WARN] SSH port will NOT be opened. Make sure you have another way in."
        fi

        sudo systemctl enable --now firewalld
    fi

    sudo firewall-cmd --set-default-zone=drop 2>/dev/null || \
        sudo firewall-cmd --set-default-zone=public

    if [[ "${_FIREWALLD_OPEN_SSH:-true}" == true ]]; then
        sudo firewall-cmd --permanent --add-service=ssh
        echo "[INFO] SSH port opened"
    fi

    sudo firewall-cmd --permanent --add-port=4646/tcp
    sudo firewall-cmd --permanent --add-port=4647/tcp
    sudo firewall-cmd --permanent --add-port=4648/tcp
    sudo firewall-cmd --permanent --add-port=4648/udp
    sudo firewall-cmd --reload

    echo "[INFO] firewalld enabled — default zone: drop"
    echo "[INFO] Allowed: 4646/tcp, 4647/tcp, 4648/tcp+udp (Nomad)"
}

### ============================================================
###  LOGIN BANNER
### ============================================================
set_login_banner() {
    echo "=== Setting login banner ==="
    local banner="############################################################
#  Authorised access only. All activity may be monitored.  #
############################################################"
    echo "$banner" | sudo tee /etc/issue     > /dev/null
    echo "$banner" | sudo tee /etc/issue.net > /dev/null
    echo "$banner" | sudo tee /etc/motd      > /dev/null

    if grep -q "^Banner" /etc/ssh/sshd_config 2>/dev/null; then
        sudo sed -i 's|^Banner.*|Banner /etc/issue.net|' /etc/ssh/sshd_config
    else
        echo "Banner /etc/issue.net" | sudo tee -a /etc/ssh/sshd_config > /dev/null
    fi
    echo "[INFO] Login banners set"
}

### ============================================================
###  RESTRICT CRON AND AT
### ============================================================
harden_cron() {
    echo "=== Restricting cron and at access ==="
    sudo rm -f /etc/cron.deny /etc/at.deny
    echo "root" | sudo tee /etc/cron.allow > /dev/null
    echo "root" | sudo tee /etc/at.allow   > /dev/null
    sudo chmod 600 /etc/cron.allow /etc/at.allow
    echo "[INFO] cron and at restricted to root"
    echo "[INFO] Add usernames to /etc/cron.allow to grant access"
}

### ============================================================
###  FILE PERMISSIONS
### ============================================================
harden_permissions() {
    echo "=== Hardening file permissions ==="

    local -A file_modes=(
        ["/etc/passwd"]="644"
        ["/etc/shadow"]="640"
        ["/etc/group"]="644"
        ["/etc/gshadow"]="640"
        ["/etc/ssh/sshd_config"]="600"
        ["/boot"]="700"
    )
    for path in "${!file_modes[@]}"; do
        if [[ -e "$path" ]]; then
            sudo chmod "${file_modes[$path]}" "$path"
            echo "[INFO] chmod ${file_modes[$path]} ${path}"
        fi
    done

    echo "[INFO] Scanning for world-writable files..."
    local ww_files
    ww_files=$(sudo find / \
        -path /proc -prune -o -path /sys  -prune -o \
        -path /dev  -prune -o -path /run  -prune -o \
        -perm -002 -not -type l -print 2>/dev/null || true)

    if [[ -n "$ww_files" ]]; then
        echo "[WARN] World-writable files found — review manually:"
        echo "$ww_files" | while read -r f; do echo "       $f"; done
    else
        echo "[INFO] No unexpected world-writable files found"
    fi
}

### ============================================================
###  SUMMARY
### ============================================================
print_summary() {
    echo ""
    echo "=== Hardening complete ==="
    echo ""
    echo "System   : ${OS_ID} ${OS_VERSION} (${VIRT_TYPE})"
    echo ""
    echo "Applied:"
    echo "  + System updated"
    echo "  + Unnecessary packages removed"
    echo "  + sysctl: ASLR, ptrace, network hardening"
    echo "  + Core dumps disabled"
    echo "  + Unnecessary services disabled"
    echo "  + PAM: account lockout + password policy"
    echo "  + Login banners"
    echo "  + cron/at restricted to root"
    echo "  + File permissions"
    [[ "$SKIP_AUDIT"    != true ]] && echo "  + auditd"
    if [[ "$SKIP_FIREWALLD" != true ]]; then
        if [[ "$VIRT_TYPE" == "wsl2" ]]; then
            echo "  - firewalld skipped (WSL2 — handled by Windows Firewall)"
        else
            echo "  + firewalld"
        fi
    fi

    if [[ "$SKIP_MAC" != true ]]; then
        case "$MAC_FRAMEWORK_APPLIED" in
            selinux)  echo "  + SELinux" ;;
            apparmor) echo "  + AppArmor" ;;
            none)     echo "  ! MAC framework: none (see warnings above)" ;;
        esac
    fi
    if [[ "$SKIP_FIPS" != true ]]; then
        local fips_on
        fips_on=$(cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo "0")
        if [[ "$fips_on" == "1" ]]; then
            echo "  + FIPS (already active)"
        elif [[ "$VIRT_TYPE" == "wsl2" ]]; then
            echo "  - FIPS skipped (WSL2)"
        fi
    fi

    if [[ "$IS_WSL2" == true ]]; then
        echo ""
        echo "WSL2 limitations (not applied):"
        echo "  - FIPS mode  — requires kernel-level enforcement, not possible in WSL2"
        echo "  - Bootloader — not applicable in WSL2"
    fi

    if [[ "$NEEDS_REBOOT" == true ]]; then
        echo ""
        echo "*** REBOOT REQUIRED ***"
        echo "  SELinux was installed and needs a reboot to relabel the filesystem."
        echo "  After reboot, switch to enforcing mode:"
        echo "    sudo setenforce 1"
        echo "    sudo sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config"
    fi

    echo ""
    echo "Next steps:"
    echo "  1. Review any world-writable files reported above"
    echo "  2. Run ssh-setup.sh if not already done"
    echo "  3. When stable, uncomment '-e 2' in /etc/audit/rules.d/90-harden.rules"
    echo ""
}

### ============================================================
###  MAIN
### ============================================================
main() {
    parse_args "$@"
    detect_environment

    update_system
    remove_unnecessary_packages
    install_hardening_tools
    harden_sysctl
    harden_core_dumps
    harden_services
    harden_pam
    setup_audit
    setup_mac_framework
    setup_fips
    setup_firewalld
    set_login_banner
    harden_cron
    harden_permissions
    print_summary
}

main "$@"
