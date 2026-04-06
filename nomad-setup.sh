#!/usr/bin/env bash
set -e

### ============================================================
###  GLOBAL VARIABLES
### ============================================================
ROLE=""
SERVER_ADDR=""
NOMAD_VERSION="1.11.3"
NOMAD_DIR="/nomad/${NOMAD_VERSION}"
NOMAD_ZIP="${NOMAD_DIR}/nomad_${NOMAD_VERSION}_linux_amd64.zip"

IS_WSL2=false
CPU_MODEL=""
CPU_CORES=""
RAM_GB=""
GPU_MODEL="none"
HAS_GPU=false
HAS_SELINUX=false
HAS_APPARMOR=false
SELINUX_MODE=""

### ============================================================
###  FUNCTIONS
### ============================================================

detect_os() {
    echo "=== Detecting operating system ==="

    if [[ ! -f /etc/os-release ]]; then
        echo "ERROR: /etc/os-release not found — cannot identify OS"
        exit 1
    fi

    local id_like name id version_id
    id_like=$(grep '^ID_LIKE=' /etc/os-release | cut -d= -f2 | tr -d '"')
    name=$(grep '^NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
    id=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
    version_id=$(grep '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"')

    echo "[INFO] NAME=${name} ID=${id} VERSION_ID=${version_id:-n/a}"

    if [[ "${id_like,,}" != *"opensuse"* ]]; then
        echo "ERROR: ID_LIKE does not contain 'opensuse' — zypper not available"
        echo "ERROR: This script requires an openSUSE-based distribution"
        exit 1
    fi

    echo "[INFO] openSUSE detected in ID_LIKE — zypper available"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --server)
                ROLE="server"
                shift
                ;;
            --worker)
                ROLE="worker"
                shift
                ;;
            --server-ip)
                SERVER_ADDR="$2"
                shift 2
                ;;
            --server-host)
                SERVER_ADDR="$2"
                shift 2
                ;;
            *)
                echo "Unknown argument: $1"
                exit 1
                ;;
        esac
    done

    if [[ -z "$ROLE" ]]; then
        echo "ERROR: You must specify --server or --worker"
        exit 1
    fi

    if [[ "$ROLE" == "worker" && -z "$SERVER_ADDR" ]]; then
        echo "ERROR: Worker mode requires --server-ip or --server-host"
        exit 1
    fi

    echo "=== Nomad role: $ROLE ==="
    [[ "$ROLE" == "worker" ]] && echo "=== Connecting to server: $SERVER_ADDR ==="
}

detect_environment() {
    echo "=== Detecting environment ==="

    # WSL2
    if grep -qi "microsoft" /proc/version; then
        IS_WSL2=true
        echo "[INFO] Running inside WSL2"
    else
        IS_WSL2=false
        echo "[INFO] Running on native Linux"
    fi

    # CPU
    CPU_MODEL=$(lscpu | grep "Model name" | sed 's/Model name:\s*//')
    CPU_CORES=$(nproc)
    echo "[INFO] CPU: $CPU_MODEL ($CPU_CORES cores)"

    # RAM
    RAM_GB=$(free -g | awk '/Mem:/ {print $2}')
    echo "[INFO] RAM: ${RAM_GB}GB"

    # GPU
    if command -v nvidia-smi >/dev/null 2>&1; then
        GPU_MODEL=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)
        HAS_GPU=true
        echo "[INFO] NVIDIA GPU detected: $GPU_MODEL"
    else
        GPU_MODEL="none"
        HAS_GPU=false
        echo "[INFO] No NVIDIA GPU detected"
    fi

    # SELinux
    if command -v getenforce &>/dev/null; then
        SELINUX_MODE=$(getenforce 2>/dev/null || echo "Disabled")
        if [[ "$SELINUX_MODE" == "Enforcing" || "$SELINUX_MODE" == "Permissive" ]]; then
            HAS_SELINUX=true
            echo "[INFO] SELinux is active (mode: $SELINUX_MODE)"
        else
            HAS_SELINUX=false
            echo "[INFO] SELinux is disabled"
        fi
    else
        HAS_SELINUX=false
        echo "[INFO] SELinux not present"
    fi

    # AppArmor
    if [[ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" == "Y" ]]; then
        HAS_APPARMOR=true
        echo "[INFO] AppArmor is active"
    else
        HAS_APPARMOR=false
        echo "[INFO] AppArmor not present or disabled"
    fi
}

remove_conflicting_packages() {
    echo "=== Removing conflicting Docker packages ==="
    for pkg in docker-rootless-extras docker-stable-rootless-extras; do
        if rpm -q "$pkg" &>/dev/null; then
            echo "[INFO] Removing $pkg"
            sudo zypper -n remove "$pkg" || true
        fi
    done
}

install_dependencies() {
    echo "=== Installing dependencies ==="
    local pkgs=()
    for pkg in curl unzip docker nvidia-container-toolkit; do
        if ! rpm -q "$pkg" &>/dev/null; then
            pkgs+=("$pkg")
        else
            echo "[INFO] $pkg already installed, skipping"
        fi
    done
    if [[ ${#pkgs[@]} -gt 0 ]]; then
        sudo zypper -n install "${pkgs[@]}" || true
    fi
}

configure_docker() {
    echo "=== Configuring Docker ==="
    sudo systemctl enable --now docker || true
    sudo nvidia-ctk runtime configure --runtime=docker || true
    sudo systemctl restart docker || true
}

install_nomad() {
    echo "=== Installing Nomad ==="
    sudo mkdir -p "${NOMAD_DIR}"

    if [[ -f "${NOMAD_ZIP}" ]]; then
        echo "[INFO] ${NOMAD_ZIP} already exists, skipping download"
    else
        sudo curl -L -o "${NOMAD_ZIP}" \
            "https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_linux_amd64.zip"
    fi

    sudo unzip -o "${NOMAD_ZIP}" -d "${NOMAD_DIR}"

    if [[ -f /usr/local/bin/nomad ]]; then
        local backup_date backup_dir
        backup_date=$(date +%Y-%m-%d)
        backup_dir="${HOME}/nomad_backup/${backup_date}"
        mkdir -p "${backup_dir}"
        echo "[INFO] /usr/local/bin/nomad already exists, archiving to ${backup_dir}/nomad"
        mv /usr/local/bin/nomad "${backup_dir}/nomad"
    fi

    sudo mv "${NOMAD_DIR}/nomad" /usr/local/bin/
    sudo chmod +x /usr/local/bin/nomad
    sudo mkdir -p /etc/nomad.d /opt/nomad
}

generate_nomad_config() {
    echo "=== Generating Nomad config ==="

    if [[ "$ROLE" == "server" ]]; then
        sudo tee /etc/nomad.d/server.hcl <<EOF > /dev/null
server {
  enabled = true
  bootstrap_expect = 1
}

data_dir = "/opt/nomad"

advertise {
  http = "0.0.0.0:4646"
  rpc  = "0.0.0.0:4647"
  serf = "0.0.0.0:4648"
}
EOF
    else
        sudo tee /etc/nomad.d/client.hcl <<EOF > /dev/null
client {
  enabled = true
  servers = ["$SERVER_ADDR:4647"]

  meta {
    cpu_model = "$CPU_MODEL"
    cpu_cores = "$CPU_CORES"
    ram_gb    = "$RAM_GB"
    gpu_model = "$GPU_MODEL"
    wsl2      = "$IS_WSL2"
  }
}

data_dir = "/opt/nomad"
EOF

        if [[ "$HAS_GPU" == true ]]; then
            sudo tee /etc/nomad.d/gpu.hcl <<EOF > /dev/null
plugin "nvidia" {
  config {
    enabled = true
  }
}
EOF
        fi
    fi
}

apply_linux_tuning() {
    echo "=== Applying Linux tuning ==="

    sudo tee /etc/security/limits.d/99-nomad.conf <<EOF > /dev/null
* soft nofile 1048576
* hard nofile 1048576
EOF

    sudo tee /etc/sysctl.d/99-nomad.conf <<EOF > /dev/null
vm.swappiness=10
net.core.somaxconn=4096
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_tw_reuse=1
EOF

    sudo sysctl --system || true
}

configure_selinux() {
    echo "=== Configuring SELinux for Nomad ==="

    # Ensure required tools are installed
    local pkgs=()
    for pkg in policycoreutils-python-utils checkpolicy; do
        if ! rpm -q "$pkg" &>/dev/null; then
            pkgs+=("$pkg")
        fi
    done
    [[ ${#pkgs[@]} -gt 0 ]] && sudo zypper -n install "${pkgs[@]}" || true

    # File context for binary
    sudo semanage fcontext -a -t bin_t '/usr/local/bin/nomad' 2>/dev/null || \
        sudo semanage fcontext -m -t bin_t '/usr/local/bin/nomad' 2>/dev/null || true
    sudo restorecon -v /usr/local/bin/nomad || true

    # File context for config dir
    sudo semanage fcontext -a -t etc_t '/etc/nomad\.d(/.*)?' 2>/dev/null || \
        sudo semanage fcontext -m -t etc_t '/etc/nomad\.d(/.*)?' 2>/dev/null || true
    sudo restorecon -Rv /etc/nomad.d || true

    # File context for data dir
    sudo semanage fcontext -a -t var_t '/opt/nomad(/.*)?' 2>/dev/null || \
        sudo semanage fcontext -m -t var_t '/opt/nomad(/.*)?' 2>/dev/null || true
    sudo restorecon -Rv /opt/nomad || true

    # Network ports
    for port in 4646 4647 4648; do
        sudo semanage port -a -t http_port_t -p tcp "$port" 2>/dev/null || true
        sudo semanage port -a -t http_port_t -p udp "$port" 2>/dev/null || true
    done

    # Compile and load a minimal policy module
    local tmp
    tmp=$(mktemp -d)
    sudo tee "${tmp}/nomad.te" <<'SEEOF' > /dev/null
module nomad 1.0;

require {
    type unconfined_service_t;
    type bin_t;
    type etc_t;
    type var_t;
    type docker_var_run_t;
    class file { read write execute execute_no_trans open getattr };
    class dir { read write search open getattr add_name remove_name };
    class sock_file { write };
}

allow unconfined_service_t bin_t:file { execute execute_no_trans open getattr };
allow unconfined_service_t etc_t:file { read open getattr };
allow unconfined_service_t etc_t:dir { read search open };
allow unconfined_service_t var_t:dir { read write search open getattr add_name remove_name };
allow unconfined_service_t var_t:file { read write open getattr };
allow unconfined_service_t docker_var_run_t:sock_file { write };
SEEOF

    if command -v checkmodule &>/dev/null && command -v semodule_package &>/dev/null; then
        checkmodule -M -m -o "${tmp}/nomad.mod" "${tmp}/nomad.te" && \
        semodule_package -o "${tmp}/nomad.pp" -m "${tmp}/nomad.mod" && \
        sudo semodule -i "${tmp}/nomad.pp" && \
            echo "[INFO] SELinux policy module loaded" || \
            echo "[WARN] Could not load SELinux module — manual policy tuning may be needed"
    else
        echo "[WARN] checkmodule/semodule_package not found — skipping SELinux module compilation"
        echo "[WARN] Install policycoreutils-devel to compile the policy manually"
    fi

    rm -rf "${tmp}"
}

configure_apparmor() {
    echo "=== Configuring AppArmor for Nomad ==="

    sudo tee /etc/apparmor.d/usr.local.bin.nomad <<'AAEOF' > /dev/null
#include <tunables/global>

/usr/local/bin/nomad {
  #include <abstractions/base>
  #include <abstractions/nameservice>

  capability net_admin,
  capability net_bind_service,
  capability sys_admin,
  capability sys_ptrace,
  capability dac_override,
  capability dac_read_search,
  capability setuid,
  capability setgid,
  capability kill,

  # Binary
  /usr/local/bin/nomad mr,

  # Config
  /etc/nomad.d/ r,
  /etc/nomad.d/** r,

  # Data dir
  /opt/nomad/ rw,
  /opt/nomad/** rw,

  # Temp files and runtime
  /tmp/** rw,
  /run/nomad/ rw,
  /run/nomad/** rw,

  # Logs
  /var/log/nomad/ rw,
  /var/log/nomad/** rw,

  # Docker socket (for Docker task driver)
  /var/run/docker.sock rw,

  # cgroups (required for task isolation)
  /sys/fs/cgroup/ r,
  /sys/fs/cgroup/** rw,

  # Proc
  /proc/*/net/ r,
  /proc/*/net/** r,
  /proc/sys/kernel/hostname r,
  /proc/*/status r,

  # Network
  network tcp,
  network udp,

  # Allow spawning child processes (task drivers, plugins)
  /usr/bin/** Px -> nomad_child,
  /usr/local/bin/** Px -> nomad_child,
  /bin/** Px -> nomad_child,

  profile nomad_child {
    #include <abstractions/base>
    /usr/bin/** mr,
    /usr/local/bin/** mr,
    /bin/** mr,
    /tmp/** rw,
    network tcp,
    network udp,
  }
}
AAEOF

    sudo apparmor_parser -r /etc/apparmor.d/usr.local.bin.nomad && \
        echo "[INFO] AppArmor profile for Nomad loaded" || \
        echo "[WARN] Could not load AppArmor profile"
}

configure_firewall() {
    echo "=== Configuring firewall ==="
    if ! command -v firewall-cmd &>/dev/null || ! sudo systemctl is-active --quiet firewalld 2>/dev/null; then
        echo "[WARN] firewalld not running — skipping firewall configuration"
        if [[ "$ROLE" == "server" ]]; then
            echo "[WARN] Open these ports manually: 4646/tcp (HTTP), 4647/tcp (RPC), 4648/tcp+udp (Serf)"
        else
            echo "[WARN] Open this port manually: 4646/tcp (HTTP API)"
        fi
        return
    fi

    if [[ "$ROLE" == "server" ]]; then
        echo "[INFO] Opening Nomad server ports: 4646/tcp, 4647/tcp, 4648/tcp+udp"
        sudo firewall-cmd --permanent --add-port=4646/tcp
        sudo firewall-cmd --permanent --add-port=4647/tcp
        sudo firewall-cmd --permanent --add-port=4648/tcp
        sudo firewall-cmd --permanent --add-port=4648/udp
    else
        echo "[INFO] Opening Nomad HTTP API port: 4646/tcp"
        sudo firewall-cmd --permanent --add-port=4646/tcp
    fi

    sudo firewall-cmd --reload
    echo "[INFO] Firewall rules applied"
}

create_systemd_service() {
    echo "=== Creating systemd service ==="

    sudo tee /etc/systemd/system/nomad.service <<EOF > /dev/null
[Unit]
Description=Nomad Agent
After=network.target docker.service

[Service]
ExecStart=/usr/local/bin/nomad agent -config=/etc/nomad.d
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now nomad
}

print_summary() {
    echo "=== DONE ==="
    echo "Nomad $ROLE is now configured."
    echo "CPU:  $CPU_MODEL ($CPU_CORES cores)"
    echo "RAM:  ${RAM_GB}GB"
    echo "GPU:  $GPU_MODEL"
    echo "WSL2: $IS_WSL2"
    [[ "$ROLE" == "worker" ]] && echo "Server: $SERVER_ADDR"
}

### ============================================================
###  MAIN
### ============================================================
main() {
    detect_os
    parse_args "$@"
    detect_environment

    remove_conflicting_packages
    install_dependencies
    configure_docker

    install_nomad
    generate_nomad_config
    apply_linux_tuning

    if [[ "$HAS_SELINUX" == true ]]; then
        configure_selinux
    elif [[ "$HAS_APPARMOR" == true ]]; then
        configure_apparmor
    else
        echo "[INFO] No MAC framework (SELinux/AppArmor) detected — skipping security policy configuration"
    fi

    configure_firewall
    create_systemd_service
    print_summary
}

main "$@"
