#!/usr/bin/env bash
set -euo pipefail

### ============================================================
###  GLOBAL VARIABLES
### ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SSH_PORT=22
SSH_USER="${USER}"
PUBKEY=""
PUBKEY_FILE=""
KEYS_DIR="${SCRIPT_DIR}/keys"

# Populated by detect_ssh_dirs():
#   SSH_ADMIN_DIR  — where admin config is written (/etc/ssh, always)
#   SSH_VENDOR_DIR — where vendor defaults live (/usr/etc/ssh on usrmerge,
#                    same as SSH_ADMIN_DIR on older systems)
SSH_ADMIN_DIR="/etc/ssh"
SSH_VENDOR_DIR=""

### ============================================================
###  HELPERS
### ============================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port)
                SSH_PORT="$2"
                shift 2
                ;;
            --user)
                SSH_USER="$2"
                shift 2
                ;;
            --pubkey)
                PUBKEY="$2"
                shift 2
                ;;
            --pubkey-file)
                PUBKEY_FILE="$2"
                shift 2
                ;;
            --keys-dir)
                KEYS_DIR="$2"
                shift 2
                ;;
            --help)
                print_help
                exit 0
                ;;
            *)
                echo "Unknown argument: $1"
                exit 1
                ;;
        esac
    done
}

print_help() {
    cat <<EOF

USAGE
  ./ssh-setup.sh [OPTIONS]

DESCRIPTION
  Installs and configures sshd with:
    - ed25519 host key only (RSA/DSA/ECDSA removed)
    - Public key authentication only (passwords disabled)
    - Strong ciphers, KexAlgorithms and MACs only
    - sshd enabled as a systemd service (starts on WSL2 boot)
    - Firewall port opened if firewalld or ufw is active

PUBLIC KEYS
  Public keys are safe to commit to a public GitHub repo — only the
  private key must be kept secret. Add keys to the repo like this:

    keys/alice.pub
    keys/bob.pub

  The script adds all *.pub files from --keys-dir to authorized_keys.
  You can also pass a key directly with --pubkey or --pubkey-file.

OPTIONS
  --port <n>          SSH port (default: 22)
  --user <name>       User to install authorized_keys for (default: current user)
  --pubkey <string>   Add a single public key directly
  --pubkey-file <path> Add public key from a file
  --keys-dir <path>   Directory with *.pub files (default: ./keys/)
  --help              Show this help text

EXAMPLES
  ./ssh-setup.sh
  ./ssh-setup.sh --port 2222
  ./ssh-setup.sh --pubkey "ssh-ed25519 AAAA... user@host"
  ./ssh-setup.sh --pubkey-file ~/.ssh/id_ed25519.pub
  ./ssh-setup.sh --keys-dir /tmp/keys --user nomad

EOF
}

### ============================================================
###  DETECT SSH DIRECTORIES
### ============================================================
detect_ssh_dirs() {
    # Modern OpenSUSE (Tumbleweed, Leap 16+) uses usrmerge:
    #   /usr/etc/ssh/  — vendor defaults shipped by the openssh package (don't edit)
    #   /etc/ssh/      — admin overrides, takes precedence (always write here)
    #
    # Older systems have everything in /etc/ssh/.
    if [[ -d /usr/etc/ssh ]]; then
        SSH_VENDOR_DIR="/usr/etc/ssh"
        echo "[INFO] usrmerge layout detected"
        echo "[INFO]   Vendor defaults : ${SSH_VENDOR_DIR}  (managed by package, not modified)"
        echo "[INFO]   Admin config    : ${SSH_ADMIN_DIR}   (written by this script, takes precedence)"
    else
        SSH_VENDOR_DIR="/etc/ssh"
        echo "[INFO] SSH config dir: ${SSH_ADMIN_DIR}"
    fi
    sudo mkdir -p "${SSH_ADMIN_DIR}"
}

### ============================================================
###  CHECK VENDOR CONFIG FOR SETTINGS TO PRESERVE
### ============================================================
check_vendor_sshd_config() {
    # Only relevant on usrmerge systems where vendor and admin dirs differ
    [[ "$SSH_VENDOR_DIR" == "$SSH_ADMIN_DIR" ]] && return
    [[ ! -f "${SSH_VENDOR_DIR}/sshd_config" ]]  && return

    # If an admin config already exists the user has been through this before
    if [[ -f "${SSH_ADMIN_DIR}/sshd_config" ]]; then
        echo "[INFO] Admin config already exists — skipping vendor config review"
        return
    fi

    echo "=== Reviewing vendor sshd_config for settings to preserve ==="
    echo "[INFO] Source: ${SSH_VENDOR_DIR}/sshd_config"

    # Settings our new config always sets — safe to skip without warning
    local -a covered_keys=(
        HostKey Port AddressFamily ListenAddress
        SyslogFacility LogLevel
        LoginGraceTime PermitRootLogin StrictModes MaxAuthTries MaxSessions
        PubkeyAuthentication AuthorizedKeysFile
        PasswordAuthentication PermitEmptyPasswords
        ChallengeResponseAuthentication KbdInteractiveAuthentication
        UsePAM AllowAgentForwarding AllowTcpForwarding
        X11Forwarding PrintMotd AcceptEnv
        KexAlgorithms Ciphers MACs Banner
    )

    local -a uncovered=()
    local in_match_block=false

    while IFS= read -r line; do
        # Skip blank lines and comments
        [[ -z "${line// }" ]]         && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        local key
        key=$(echo "$line" | awk '{print $1}')

        # Track Match blocks — they span multiple lines and need special attention
        if [[ "${key,,}" == "match" ]]; then
            in_match_block=true
            uncovered+=("$line")
            continue
        fi

        # Lines indented under a Match block belong to it
        if [[ "$in_match_block" == true ]]; then
            if [[ "$line" =~ ^[[:space:]] ]]; then
                uncovered+=("  $line")
                continue
            else
                in_match_block=false
            fi
        fi

        # Check if key is handled by our new config
        local covered=false
        for s in "${covered_keys[@]}"; do
            if [[ "${key,,}" == "${s,,}" ]]; then
                covered=true
                break
            fi
        done

        [[ "$covered" == false ]] && uncovered+=("$line")
    done < <(sudo cat "${SSH_VENDOR_DIR}/sshd_config")

    # Also check for Include directives pointing to drop-in files
    local includes
    includes=$(sudo grep -i '^\s*Include' "${SSH_VENDOR_DIR}/sshd_config" 2>/dev/null || true)

    if [[ ${#uncovered[@]} -eq 0 ]] && [[ -z "$includes" ]]; then
        echo "[INFO] No extra settings in vendor config — nothing to preserve"
        return
    fi

    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│  Settings in ${SSH_VENDOR_DIR}/sshd_config NOT covered by the  │"
    echo "│  new admin config. Review before proceeding.                    │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    echo ""

    if [[ ${#uncovered[@]} -gt 0 ]]; then
        for line in "${uncovered[@]}"; do
            echo "  $line"
        done
        echo ""
    fi

    if [[ -n "$includes" ]]; then
        echo "  [NOTE] Vendor config has Include directive(s) — check those files too:"
        echo "$includes" | while read -r inc; do echo "         $inc"; done
        echo ""
    fi

    echo "The new config will be written to ${SSH_ADMIN_DIR}/sshd_config."
    echo "The vendor file is not modified."
    echo ""

    local answer
    while true; do
        read -rp "Proceed? [y/n]: " answer
        case "${answer,,}" in
            y|yes) echo ""; break ;;
            n|no)
                echo "[INFO] Aborted — no changes made"
                exit 0
                ;;
            *) echo "Please answer y or n" ;;
        esac
    done
}

### ============================================================
###  INSTALL SSHD
### ============================================================
install_sshd() {
    echo "=== Installing OpenSSH server ==="
    if rpm -q openssh &>/dev/null && rpm -q openssh-server &>/dev/null; then
        echo "[INFO] openssh-server already installed, skipping"
    else
        sudo zypper -n install openssh openssh-server
    fi
}

### ============================================================
###  HOST KEYS
### ============================================================
generate_host_keys() {
    echo "=== Configuring SSH host keys ==="

    # Remove weak host key types from the admin dir only.
    # Vendor keys in SSH_VENDOR_DIR are owned by the package manager —
    # they won't be used because our sshd_config only references the ed25519 key.
    for keytype in rsa dsa ecdsa; do
        local keyfile="${SSH_ADMIN_DIR}/ssh_host_${keytype}_key"
        if [[ -f "$keyfile" ]]; then
            sudo rm -f "$keyfile" "${keyfile}.pub"
            echo "[INFO] Removed weak host key: ${keyfile}"
        fi
    done

    # Generate ed25519 host key in the admin dir if missing
    local ed25519_key="${SSH_ADMIN_DIR}/ssh_host_ed25519_key"
    if [[ ! -f "$ed25519_key" ]]; then
        sudo ssh-keygen -t ed25519 -f "$ed25519_key" -N "" -C ""
        echo "[INFO] Generated new ed25519 host key: ${ed25519_key}"
    else
        echo "[INFO] ed25519 host key already exists, keeping it"
    fi

    sudo chmod 600 "${ed25519_key}"
    sudo chmod 644 "${ed25519_key}.pub"
}

### ============================================================
###  SSHD CONFIG
### ============================================================
write_sshd_config() {
    echo "=== Writing sshd_config ==="

    local config_file="${SSH_ADMIN_DIR}/sshd_config"
    local backup_file
    backup_file="${SSH_ADMIN_DIR}/sshd_config.bak.$(date +%Y%m%d-%H%M%S)"

    if [[ -f "$config_file" ]]; then
        sudo cp "$config_file" "$backup_file"
        echo "[INFO] Backed up existing config to ${backup_file}"
    elif [[ -f "${SSH_VENDOR_DIR}/sshd_config" ]]; then
        echo "[INFO] No existing admin config — vendor default is at ${SSH_VENDOR_DIR}/sshd_config"
        echo "[INFO] Writing new admin config to ${config_file} (overrides vendor defaults)"
    fi

    sudo tee "$config_file" > /dev/null <<EOF
# Generated by nomad-worker-setup/ssh-setup.sh on $(date)
# Placed in ${SSH_ADMIN_DIR}/ — takes precedence over ${SSH_VENDOR_DIR}/
# Only ed25519 host key — RSA/DSA/ECDSA removed
HostKey ${SSH_ADMIN_DIR}/ssh_host_ed25519_key

Port ${SSH_PORT}
AddressFamily inet
ListenAddress 0.0.0.0

# Logging
SyslogFacility AUTH
LogLevel VERBOSE

# Authentication
LoginGraceTime 30
PermitRootLogin no
StrictModes yes
MaxAuthTries 3
MaxSessions 5

PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys

# All other authentication methods disabled
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no

# PAM needed for session/account management even with pubkey auth
UsePAM yes

# No forwarding needed for Nomad workers
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
PrintMotd no

AcceptEnv LANG LC_*

# Key exchange: only strong algorithms
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512

# Ciphers: AEAD only (authenticated encryption, no separate MAC needed)
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com

# MACs: encrypt-then-MAC only (not used with AEAD, but required by some clients)
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
EOF

    sudo chmod 644 "$config_file"
    echo "[INFO] sshd_config written"
}

### ============================================================
###  AUTHORIZED KEYS
### ============================================================
install_authorized_keys() {
    echo "=== Installing authorized keys ==="

    local target_home
    target_home=$(getent passwd "${SSH_USER}" | cut -d: -f6)

    if [[ -z "$target_home" ]]; then
        echo "ERROR: User '${SSH_USER}' not found"
        exit 1
    fi

    local ssh_dir="${target_home}/.ssh"
    local auth_keys="${ssh_dir}/authorized_keys"

    sudo mkdir -p "$ssh_dir"
    sudo chmod 700 "$ssh_dir"
    sudo touch "$auth_keys"

    # Collect keys from all sources
    local keys_added=0

    # --pubkey flag
    if [[ -n "$PUBKEY" ]]; then
        if ! sudo grep -qF "$PUBKEY" "$auth_keys" 2>/dev/null; then
            echo "$PUBKEY" | sudo tee -a "$auth_keys" > /dev/null
            echo "[INFO] Added key from --pubkey"
            (( keys_added++ ))
        else
            echo "[INFO] Key from --pubkey already present"
        fi
    fi

    # --pubkey-file flag
    if [[ -n "$PUBKEY_FILE" ]]; then
        if [[ ! -f "$PUBKEY_FILE" ]]; then
            echo "ERROR: --pubkey-file not found: ${PUBKEY_FILE}"
            exit 1
        fi
        local key
        key=$(cat "$PUBKEY_FILE")
        if ! sudo grep -qF "$key" "$auth_keys" 2>/dev/null; then
            cat "$PUBKEY_FILE" | sudo tee -a "$auth_keys" > /dev/null
            echo "[INFO] Added key from ${PUBKEY_FILE}"
            (( keys_added++ ))
        else
            echo "[INFO] Key from ${PUBKEY_FILE} already present"
        fi
    fi

    # All *.pub files in --keys-dir
    if [[ -d "$KEYS_DIR" ]]; then
        local pub_files=("${KEYS_DIR}"/*.pub)
        if [[ -f "${pub_files[0]}" ]]; then
            for pub in "${pub_files[@]}"; do
                local key
                key=$(cat "$pub")
                if ! sudo grep -qF "$key" "$auth_keys" 2>/dev/null; then
                    echo "$key" | sudo tee -a "$auth_keys" > /dev/null
                    echo "[INFO] Added key from $(basename "$pub")"
                    (( keys_added++ ))
                else
                    echo "[INFO] Key from $(basename "$pub") already present"
                fi
            done
        else
            echo "[INFO] No *.pub files found in ${KEYS_DIR}"
        fi
    fi

    if [[ $keys_added -eq 0 ]]; then
        local existing
        # existing=$(sudo wc -l < "$auth_keys")
        existing=$(sudo cat "$auth_keys" | wc -l)
        if [[ "$existing" -eq 0 ]]; then
            echo "[WARN] No authorized keys installed — nobody will be able to log in"
            echo "[WARN] Add *.pub files to ${KEYS_DIR} or use --pubkey / --pubkey-file"
        else
            echo "[INFO] No new keys added (all already present)"
        fi
    fi

    sudo chown -R "${SSH_USER}:${SSH_USER}" "$ssh_dir"
    sudo chmod 600 "$auth_keys"
    echo "[INFO] authorized_keys: $(sudo cat "$auth_keys" | wc -l) key(s) for user ${SSH_USER}"
}

### ============================================================
###  FIREWALL
### ============================================================
configure_firewall() {
    echo "=== Configuring firewall ==="

    if command -v firewall-cmd &>/dev/null && sudo systemctl is-active --quiet firewalld 2>/dev/null; then
        if [[ "$SSH_PORT" -eq 22 ]]; then
            sudo firewall-cmd --permanent --add-service=ssh
        else
            sudo firewall-cmd --permanent --add-port="${SSH_PORT}/tcp"
        fi
        sudo firewall-cmd --reload
        echo "[INFO] firewalld: SSH port ${SSH_PORT} opened"

    elif command -v ufw &>/dev/null && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        sudo ufw allow "${SSH_PORT}/tcp"
        echo "[INFO] ufw: SSH port ${SSH_PORT} opened"

    else
        echo "[INFO] No active firewall detected — no firewall rules needed"
        echo "[INFO] If you add a firewall later, open port ${SSH_PORT}/tcp"
    fi
}

### ============================================================
###  ENABLE SSHD
### ============================================================
enable_sshd() {
    echo "=== Enabling sshd ==="

    # Validate config before starting
    if sudo sshd -t 2>&1; then
        echo "[INFO] sshd_config syntax OK"
    else
        echo "ERROR: sshd_config has errors — aborting"
        exit 1
    fi

    if command -v systemctl &>/dev/null && systemctl is-system-running &>/dev/null; then
        sudo systemctl enable --now sshd
        echo "[INFO] sshd enabled and started via systemd"
        echo "[INFO] sshd will start automatically on WSL2 boot"
    else
        echo "[WARN] systemd not active — starting sshd manually"
        sudo service ssh start || sudo /usr/sbin/sshd
        echo "[WARN] To auto-start sshd on WSL2 boot without systemd,"
        echo "[WARN] add this to /etc/wsl.conf:"
        echo "       [boot]"
        echo "       command = \"service ssh start\""
    fi
}

### ============================================================
###  SUMMARY
### ============================================================
print_summary() {
    echo ""
    echo "=== Done ==="
    echo ""
    echo "SSH server is running on port ${SSH_PORT}"
    echo "Authorized user: ${SSH_USER}"
    echo ""
    echo "Host key fingerprint:"
    sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
    echo ""
    echo "Connect with:"
    echo "  ssh -p ${SSH_PORT} -i ~/.ssh/id_ed25519 ${SSH_USER}@<host-ip>"
    echo ""
    echo "To add more keys later, place *.pub files in:"
    echo "  ${KEYS_DIR}/"
    echo "and re-run this script, or append directly to:"
    echo "  ~/.ssh/authorized_keys"
}

### ============================================================
###  MAIN
### ============================================================
main() {
    parse_args "$@"

    echo "=== SSH Setup ==="
    echo "[INFO] Port: ${SSH_PORT}"
    echo "[INFO] User: ${SSH_USER}"
    echo "[INFO] Keys dir: ${KEYS_DIR}"
    echo ""

    detect_ssh_dirs
    check_vendor_sshd_config
    install_sshd
    generate_host_keys
    write_sshd_config
    install_authorized_keys
    configure_firewall
    enable_sshd
    print_summary
}

main "$@"
