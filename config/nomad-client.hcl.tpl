client {
  enabled = true
  servers = ["${SERVER_ADDR}:4647"]

  meta {
    cpu_model = "${CPU_MODEL}"
    cpu_cores = "${CPU_CORES}"
    ram_gb    = "${RAM_GB}"
    gpu_model = "${GPU_MODEL}"
    wsl2      = "${IS_WSL2}"
  }
}

data_dir = "/opt/nomad"
