#!/usr/bin/env bash
# provision-app-vm.sh
# Bootstrap an app VM: install Docker, configure firewall, and deploy the stack.
# Run as root (or with sudo) on a fresh Debian/Ubuntu VM.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/<org>/cloud-web-apps.git}"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/cloud-web-apps}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. System update & base packages
# ---------------------------------------------------------------------------
log "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y \
  ca-certificates \
  curl \
  git \
  gnupg \
  lsb-release \
  ufw \
  unattended-upgrades \
  apt-listchanges

# ---------------------------------------------------------------------------
# 2. Unattended security upgrades
# ---------------------------------------------------------------------------
log "Configuring unattended-upgrades..."
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# ---------------------------------------------------------------------------
# 3. Install Docker
# ---------------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
  log "Installing Docker..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
else
  log "Docker already installed, skipping."
fi

# ---------------------------------------------------------------------------
# 4. Firewall — allow only 80, 443, and restricted SSH
# ---------------------------------------------------------------------------
log "Configuring UFW firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# Allow HTTP and HTTPS (Caddy)
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp   # HTTP/3

# Restrict SSH to GitHub Actions runner IP ranges.
# Update these CIDRs from: https://api.github.com/meta
# Alternatively, use a bastion/VPN IP instead.
# ufw allow from <GITHUB_RUNNER_CIDR> to any port 22 proto tcp
# For initial setup, temporarily allow SSH from anywhere:
ufw allow 22/tcp comment "SSH — restrict after initial setup"

ufw --force enable
log "Firewall status:"
ufw status verbose

# ---------------------------------------------------------------------------
# 5. Create deploy directory and set ownership
# ---------------------------------------------------------------------------
log "Creating ${DEPLOY_DIR} owned by deploy:docker..."
mkdir -p "${DEPLOY_DIR}"
chown deploy:docker "${DEPLOY_DIR}"

# Add deploy user to docker group so it can run docker commands without sudo
usermod -aG docker deploy

# ---------------------------------------------------------------------------
# 6. Clone or update the repository
# ---------------------------------------------------------------------------
log "Deploying repository to ${DEPLOY_DIR}..."
if [ -d "${DEPLOY_DIR}/.git" ]; then
  git -C "${DEPLOY_DIR}" pull --ff-only
else
  git clone "${REPO_URL}" "${DEPLOY_DIR}"
fi

# ---------------------------------------------------------------------------
# 7. Write environment file (secrets injected at deploy time by CI)
# ---------------------------------------------------------------------------
ENV_FILE="${DEPLOY_DIR}/infrastructure/app-vm/.env"
if [ ! -f "${ENV_FILE}" ]; then
  log "Writing .env template — fill in secrets before starting services."
  cat > "${ENV_FILE}" <<ENVEOF
LOKI_PUSH_URL=http://<MGMT_VM_IP>:3100/loki/api/v1/push
PROMETHEUS_REMOTE_WRITE_URL=http://<MGMT_VM_IP>:9090/api/v1/write
HOSTNAME=$(hostname)
ENVEOF
fi

# ---------------------------------------------------------------------------
# 8. Pull images and start the stack
# ---------------------------------------------------------------------------
log "Starting app-vm Docker Compose stack..."
docker compose -f "${DEPLOY_DIR}/infrastructure/app-vm/docker-compose.yml" pull
docker compose -f "${DEPLOY_DIR}/infrastructure/app-vm/docker-compose.yml" up -d

log "App VM provisioning complete."
docker compose -f "${DEPLOY_DIR}/infrastructure/app-vm/docker-compose.yml" ps
