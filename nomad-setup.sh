#!/usr/bin/env bash
set -e

### -----------------------------
###  PARSE ARGUMENTS
### -----------------------------
ROLE=""
SERVER_ADDR=""

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

### -----------------------------
###  DETECT ENVIRONMENT
### -----------------------------
echo "=== Detecting environment ==="

# Detect WSL2
if grep -qi "microsoft" /proc/version; then
    IS_WSL2=true
    echo "[INFO] Running inside WSL2"
else
    IS_WSL2=false
    echo "[INFO] Running on native Linux"
fi

# Detect CPU model
CPU_MODEL=$(lscpu | grep "Model name" | sed 's/Model name:\s*//')
CPU_CORES=$(nproc)
echo "[INFO] CPU: $CPU_MODEL ($CPU_CORES cores)"

# Detect RAM
RAM_GB=$(free -g | awk '/Mem:/ {print $2}')
echo "[INFO] RAM: ${RAM_GB}GB"

# Detect GPU
if command -v nvidia-smi >/dev/null 2>&1; then
    GPU_MODEL=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)
    HAS_GPU=true
    echo "[INFO] NVIDIA GPU detected: $GPU_MODEL"
else
    GPU_MODEL="none"
    HAS_GPU=false
    echo "[INFO] No NVIDIA GPU detected"
fi

### -----------------------------
###  REMOVE CONFLICTING PACKAGES
### -----------------------------
echo "=== Removing conflicting Docker packages ==="
for pkg in docker-rootless-extras docker-stable-rootless-extras; do
    if rpm -q "$pkg" &>/dev/null; then
        echo "[INFO] Removing $pkg"
        sudo zypper -n remove "$pkg" || true
    fi
done

### -----------------------------
###  INSTALL DEPENDENCIES
### -----------------------------
echo "=== Installing dependencies ==="
PKGS_TO_INSTALL=()
for pkg in curl unzip docker nvidia-container-toolkit; do
    if ! rpm -q "$pkg" &>/dev/null; then
        PKGS_TO_INSTALL+=("$pkg")
    else
        echo "[INFO] $pkg already installed, skipping"
    fi
done
if [[ ${#PKGS_TO_INSTALL[@]} -gt 0 ]]; then
    sudo zypper -n install "${PKGS_TO_INSTALL[@]}" || true
fi

sudo systemctl enable --now docker || true

echo "=== Configuring Docker ==="
sudo nvidia-ctk runtime configure --runtime=docker || true
sudo systemctl restart docker || true

### -----------------------------
###  INSTALL NOMAD
### -----------------------------
echo "=== Installing Nomad ==="
NOMAD_VERSION="1.11.3"
NOMAD_DIR="/nomad/${NOMAD_VERSION}"
NOMAD_ZIP="${NOMAD_DIR}/nomad_${NOMAD_VERSION}_linux_amd64.zip"

sudo mkdir -p "${NOMAD_DIR}"

if [[ -f "${NOMAD_ZIP}" ]]; then
    echo "[INFO] ${NOMAD_ZIP} already exists, skipping download"
else
    sudo curl -L -o "${NOMAD_ZIP}" \
        "https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_linux_amd64.zip"
fi

sudo unzip -o "${NOMAD_ZIP}" -d "${NOMAD_DIR}"

if [[ -f /usr/local/bin/nomad ]]; then
    BACKUP_DATE=$(date +%Y-%m-%d)
    BACKUP_PATH="${HOME}/nomad_backup/${BACKUP_DATE}"
    echo "[INFO] /usr/local/bin/nomad already exists, archiving to ${BACKUP_PATH}"
    mv /usr/local/bin/nomad "${BACKUP_PATH}"
fi

sudo mv "${NOMAD_DIR}/nomad" /usr/local/bin/
sudo chmod +x /usr/local/bin/nomad
sudo mkdir -p /etc/nomad.d /opt/nomad

### -----------------------------
###  GENERATE NOMAD CONFIG
### -----------------------------
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

if [ "$HAS_GPU" = true ]; then
sudo tee /etc/nomad.d/gpu.hcl <<EOF > /dev/null
plugin "nvidia" {
  config {
    enabled = true
  }
}
EOF
fi

fi

### -----------------------------
###  LINUX TUNING
### -----------------------------
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

### -----------------------------
###  SYSTEMD SERVICE
### -----------------------------
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

echo "=== DONE ==="
echo "Nomad $ROLE is now configured."
echo "CPU: $CPU_MODEL"
echo "RAM: ${RAM_GB}GB"
echo "GPU: $GPU_MODEL"
echo "WSL2: $IS_WSL2"
[[ "$ROLE" == "worker" ]] && echo "Connected to server: $SERVER_ADDR"
