#!/usr/bin/env bash
set -euo pipefail

### ============================================================
###  GLOBAL VARIABLES
### ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"
BACKUP_DIR="${HOME}/nomad_backup/$(date +%Y-%m-%d)"

ROLE=""
SERVER_ADDR=""
TLS_DIR=""
NOMAD_VERSION="1.11.3"
NOMAD_DIR="${HOME}/nomad/${NOMAD_VERSION}"
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
###  HELPERS
### ============================================================

# backup_file <path>
# Copies an existing file to BACKUP_DIR, preserving its basename.
backup_file() {
    local dst="$1"
    if [[ -f "$dst" ]]; then
        mkdir -p "${BACKUP_DIR}"
        local backup="${BACKUP_DIR}/$(basename "$dst")"
        echo "[INFO] Backing up ${dst} → ${backup}"
        sudo cp "$dst" "$backup"
        sudo chown "$(id -un)":"$(id -gn)" "$backup"
    fi
}

# deploy_config <src> <dst> <owner> <mode>
# Backs up dst if it exists, then copies src → dst with given owner and mode.
deploy_config() {
    local src="$1" dst="$2" owner="$3" mode="$4"
    sudo mkdir -p "$(dirname "$dst")"
    backup_file "$dst"
    sudo cp "$src" "$dst"
    sudo chown "$owner" "$dst"
    sudo chmod "$mode" "$dst"
    echo "[INFO] Deployed ${dst} (owner=${owner} mode=${mode})"
}

# deploy_template <src> <dst> <owner> <mode> <var1> [var2 ...]
# Like deploy_config but runs envsubst on src before writing, substituting
# only the listed variables (e.g. '${FOO} ${BAR}').
deploy_template() {
    local src="$1" dst="$2" owner="$3" mode="$4"
    shift 4
    local vars="$*"   # e.g. '${SERVER_ADDR} ${CPU_MODEL}'
    sudo mkdir -p "$(dirname "$dst")"
    backup_file "$dst"
    envsubst "$vars" < "$src" | sudo tee "$dst" > /dev/null
    sudo chown "$owner" "$dst"
    sudo chmod "$mode" "$dst"
    echo "[INFO] Deployed ${dst} from template (owner=${owner} mode=${mode})"
}

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

    if [[ "${id_like,,}" != *"suse"* ]]; then
        echo "ERROR: ID_LIKE does not contain 'suse' — zypper not available"
        echo "ERROR: This script requires an (Open)SUSE-based distribution"
        exit 1
    fi

    echo "[INFO] SUSE detected in ID_LIKE — zypper available"
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
            --tls-dir)
                TLS_DIR="$2"
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

    if [[ "$ROLE" == "worker" && -z "$TLS_DIR" ]]; then
        echo "ERROR: Worker mode requires --tls-dir <path>"
        echo "ERROR: Copy these files from the server's /etc/nomad.d/tls/ to a local directory:"
        echo "         nomad-agent-ca.pem"
        echo "         global-client-nomad.pem"
        echo "         global-client-nomad-key.pem"
        echo "       Then re-run with: --tls-dir <path-to-that-directory>"
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

add_nvidia_repo() {
    echo "=== Adding NVIDIA container toolkit repository ==="
    if sudo zypper lr --uri 2>/dev/null | grep -q 'nvidia.github.io/libnvidia-container'; then
        echo "[INFO] NVIDIA container toolkit repo already present, skipping"
    else
        sudo zypper -n ar \
            https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo
        echo "[INFO] NVIDIA container toolkit repo added"
    fi
    sudo zypper --gpg-auto-import-keys refresh
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
    for pkg in curl unzip docker nvidia-container-toolkit gettext-tools; do
        if ! rpm -q "$pkg" &>/dev/null; then
            pkgs+=("$pkg")
        else
            echo "[INFO] $pkg already installed, skipping"
        fi
    done
    if [[ ${#pkgs[@]} -gt 0 ]]; then
        sudo zypper -n install "${pkgs[@]}"
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
    mkdir -p "${NOMAD_DIR}"

    if [[ -f "${NOMAD_ZIP}" ]]; then
        echo "[INFO] ${NOMAD_ZIP} already exists, skipping download"
    else
        sudo curl -L -o "${NOMAD_ZIP}" \
            "https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_linux_amd64.zip"
    fi

    unzip -o "${NOMAD_ZIP}" -d "${NOMAD_DIR}"

    if [[ -f /usr/local/bin/nomad ]]; then
        mkdir -p "${BACKUP_DIR}"
        echo "[INFO] /usr/local/bin/nomad already exists, archiving to ${BACKUP_DIR}/nomad"
        sudo cp /usr/local/bin/nomad "${BACKUP_DIR}/nomad"
        sudo chown "$(id -un)":"$(id -gn)" "${BACKUP_DIR}/nomad"
    fi

    sudo mv "${NOMAD_DIR}/nomad" /usr/local/bin/
    sudo chown root:root /usr/local/bin/nomad
    sudo chmod 0755 /usr/local/bin/nomad
    sudo mkdir -p /etc/nomad.d /opt/nomad
}

generate_tls_server_certs() {
    echo "=== Generating mTLS certificates ==="
    local tls_dir="/etc/nomad.d/tls"
    sudo mkdir -p "$tls_dir"

    if sudo test -f "${tls_dir}/nomad-agent-ca.pem"; then
        echo "[INFO] CA certificate already exists — skipping cert generation"
        echo "[INFO] To regenerate, remove ${tls_dir} and re-run this script"
        return
    fi

    local tmp
    tmp=$(mktemp -d)
    pushd "$tmp" > /dev/null

    echo "[INFO] Creating CA..."
    nomad tls ca create

    echo "[INFO] Creating server certificate..."
    nomad tls cert create -server -region global

    echo "[INFO] Creating client certificate (for worker nodes)..."
    nomad tls cert create -client -region global

    echo "[INFO] Creating CLI certificate..."
    nomad tls cert create -cli -region global

    popd > /dev/null

    sudo mv "${tmp}"/*.pem "${tls_dir}/"
    rm -rf "$tmp"

    sudo chown -R root:root "$tls_dir"
    sudo chmod 700 "$tls_dir"
    sudo chmod 600 "${tls_dir}"/*-key.pem
    sudo chmod 644 "${tls_dir}/nomad-agent-ca.pem"
    sudo chmod 644 "${tls_dir}/global-server-nomad.pem"
    sudo chmod 644 "${tls_dir}/global-client-nomad.pem"
    sudo chmod 644 "${tls_dir}/global-cli-nomad.pem"

    echo "[INFO] Certificates stored in ${tls_dir}"
    echo ""
    echo "[INFO] Copy the following files to each worker node before running nomad-setup.sh:"
    echo "         scp ${tls_dir}/nomad-agent-ca.pem       user@worker:/tmp/nomad-tls/"
    echo "         scp ${tls_dir}/global-client-nomad.pem  user@worker:/tmp/nomad-tls/"
    echo "         scp ${tls_dir}/global-client-nomad-key.pem user@worker:/tmp/nomad-tls/"
    echo "       Then on the worker:"
    echo "         ./nomad-setup.sh --worker --server-ip <IP> --tls-dir /tmp/nomad-tls"
}

deploy_tls_worker_certs() {
    echo "=== Deploying mTLS certificates ==="
    local tls_dir="/etc/nomad.d/tls"

    for f in nomad-agent-ca.pem global-client-nomad.pem global-client-nomad-key.pem; do
        if [[ ! -f "${TLS_DIR}/${f}" ]]; then
            echo "ERROR: Missing TLS file: ${TLS_DIR}/${f}"
            echo "ERROR: Required files in --tls-dir:"
            echo "         nomad-agent-ca.pem"
            echo "         global-client-nomad.pem"
            echo "         global-client-nomad-key.pem"
            exit 1
        fi
    done

    sudo mkdir -p "$tls_dir"
    sudo cp "${TLS_DIR}/nomad-agent-ca.pem"            "${tls_dir}/"
    sudo cp "${TLS_DIR}/global-client-nomad.pem"       "${tls_dir}/"
    sudo cp "${TLS_DIR}/global-client-nomad-key.pem"   "${tls_dir}/"

    sudo chown root:root "${tls_dir}"/*.pem
    sudo chmod 700 "$tls_dir"
    sudo chmod 644 "${tls_dir}/nomad-agent-ca.pem" "${tls_dir}/global-client-nomad.pem"
    sudo chmod 600 "${tls_dir}/global-client-nomad-key.pem"

    echo "[INFO] TLS certificates deployed to ${tls_dir}"
}

generate_nomad_config() {
    echo "=== Generating Nomad config ==="
    sudo mkdir -p /etc/nomad.d

    if [[ "$ROLE" == "server" ]]; then
        deploy_config \
            "${CONFIG_DIR}/nomad-server.hcl" \
            /etc/nomad.d/server.hcl \
            root:root 0640
    else
        export SERVER_ADDR CPU_MODEL CPU_CORES RAM_GB GPU_MODEL IS_WSL2
        deploy_template \
            "${CONFIG_DIR}/nomad-client.hcl.tpl" \
            /etc/nomad.d/client.hcl \
            root:root 0640 \
            '${SERVER_ADDR} ${CPU_MODEL} ${CPU_CORES} ${RAM_GB} ${GPU_MODEL} ${IS_WSL2}'

        if [[ "$HAS_GPU" == true ]]; then
            deploy_config \
                "${CONFIG_DIR}/nomad-gpu.hcl" \
                /etc/nomad.d/gpu.hcl \
                root:root 0640
        fi
    fi
}

apply_linux_tuning() {
    echo "=== Applying Linux tuning ==="

    deploy_config \
        "${CONFIG_DIR}/limits-99-nomad.conf" \
        /etc/security/limits.d/99-nomad.conf \
        root:root 0644

    deploy_config \
        "${CONFIG_DIR}/sysctl-99-nomad.conf" \
        /etc/sysctl.d/99-nomad.conf \
        root:root 0644

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
    if [[ ${#pkgs[@]} -gt 0 ]]; then
        sudo zypper -n install "${pkgs[@]}" || true
    fi

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

    # Compile and load policy module from config/nomad.te
    local tmp
    tmp=$(mktemp -d)
    cp "${CONFIG_DIR}/nomad.te" "${tmp}/nomad.te"

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

    deploy_config \
        "${CONFIG_DIR}/apparmor-nomad" \
        /etc/apparmor.d/usr.local.bin.nomad \
        root:root 0644

    sudo apparmor_parser -r /etc/apparmor.d/usr.local.bin.nomad && \
        echo "[INFO] AppArmor profile loaded" || \
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

    deploy_config \
        "${CONFIG_DIR}/nomad.service" \
        /etc/systemd/system/nomad.service \
        root:root 0644

    deploy_config \
        "${CONFIG_DIR}/nomad-env.sh" \
        /etc/nomad.d/nomad-env.sh \
        root:root 0644

    sudo systemctl daemon-reload
    sudo systemctl enable --now nomad
}

print_wsl2_hints() {
    echo ""
    echo "=== WSL2 network hints ==="
    echo "Nomad worker is running inside WSL2. For the Nomad server to reach this"
    echo "worker, you may need to adjust networking on the Windows host."
    echo ""
    echo "--- In PowerShell run the script wsl-firewall-setup.ps1 ---"
    echo "To see all options:"
    echo "./wsl-firewall-setup.ps1 -Help"
    echo ""
    echo "To configure a worker node:"
    echo "./wsl-firewall-setup.ps1 -Mode worker"
    echo ""
}

print_summary() {
    echo "=== DONE ==="
    echo "Nomad $ROLE is now configured."
    echo "CPU:  $CPU_MODEL ($CPU_CORES cores)"
    echo "RAM:  ${RAM_GB}GB"
    echo "GPU:  $GPU_MODEL"
    echo "WSL2: $IS_WSL2"
    [[ "$ROLE" == "worker" ]] && echo "Server: $SERVER_ADDR"
    [[ -d "$BACKUP_DIR" ]] && echo "Backups: ${BACKUP_DIR}"
    echo ""
    echo "mTLS is enabled. To use the Nomad CLI:"
    echo "  source /etc/nomad.d/nomad-env.sh"
    echo "  nomad node status"
    [[ "$IS_WSL2" == true ]] && print_wsl2_hints
}

### ============================================================
###  MAIN
### ============================================================
main() {
    detect_os
    parse_args "$@"

    if [[ ! -d "$CONFIG_DIR" ]]; then
        echo "ERROR: Config directory not found: ${CONFIG_DIR}"
        echo "ERROR: Make sure you run this script from the repository root"
        exit 1
    fi

    detect_environment

    add_nvidia_repo
    remove_conflicting_packages
    install_dependencies
    configure_docker

    install_nomad

    if [[ "$ROLE" == "server" ]]; then
        generate_tls_server_certs
    else
        deploy_tls_worker_certs
    fi

    generate_nomad_config
    apply_linux_tuning

    if [[ "$HAS_SELINUX" == true ]]; then
        configure_selinux
    elif [[ "$HAS_APPARMOR" == true ]]; then
        configure_apparmor
    else
        echo "[INFO] No MAC framework (SELinux/AppArmor) detected — skipping security policy"
    fi

    configure_firewall
    create_systemd_service
    print_summary
}

main "$@"
