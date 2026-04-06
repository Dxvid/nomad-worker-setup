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
###  INSTALL DEPENDENCIES
### -----------------------------
echo "=== Installing dependencies ==="
zypper -n install curl unzip docker nvidia-container-toolkit || true

systemctl enable --now docker || true

echo "=== Configuring Docker ==="
nvidia-ctk runtime configure --runtime=docker || true
systemctl restart docker || true

### -----------------------------
###  INSTALL NOMAD
### -----------------------------
echo "=== Installing Nomad ==="
NOMAD_VERSION="1.11.3"
curl -LO https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_linux_amd64.zip
unzip -o nomad_${NOMAD_VERSION}_linux_amd64.zip
mv nomad /usr/local/bin/
chmod +x /usr/local/bin/nomad
mkdir -p /etc/nomad.d /opt/nomad

### -----------------------------
###  GENERATE NOMAD CONFIG
### -----------------------------
echo "=== Generating Nomad config ==="

if [[ "$ROLE" == "server" ]]; then

cat >/etc/nomad.d/server.hcl <<EOF
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

cat >/etc/nomad.d/client.hcl <<EOF
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
cat >/etc/nomad.d/gpu.hcl <<EOF
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

cat >/etc/security/limits.d/99-nomad.conf <<EOF
* soft nofile 1048576
* hard nofile 1048576
EOF

cat >/etc/sysctl.d/99-nomad.conf <<EOF
vm.swappiness=10
net.core.somaxconn=4096
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_tw_reuse=1
EOF

sysctl --system || true

### -----------------------------
###  SYSTEMD SERVICE
### -----------------------------
echo "=== Creating systemd service ==="

cat >/etc/systemd/system/nomad.service <<EOF
[Unit]
Description=Nomad Agent
After=network.target docker.service

[Service]
ExecStart=/usr/local/bin/nomad agent -config=/etc/nomad.d
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now nomad

echo "=== DONE ==="
echo "Nomad $ROLE is now configured."
echo "CPU: $CPU_MODEL"
echo "RAM: ${RAM_GB}GB"
echo "GPU: $GPU_MODEL"
echo "WSL2: $IS_WSL2"
[[ "$ROLE" == "worker" ]] && echo "Connected to server: $SERVER_ADDR"