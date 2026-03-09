#!/usr/bin/env bash
# provision-management-vm.sh
# Bootstrap the management VM: install Docker, configure firewall,
# and deploy the full observability stack.
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
  apt-listchanges \
  lynis

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
# 4. Firewall — expose only port 443 externally; internal ports restricted
# ---------------------------------------------------------------------------
log "Configuring UFW firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# HTTPS for Grafana (via Caddy)
ufw allow 443/tcp
ufw allow 443/udp   # HTTP/3
ufw allow 80/tcp    # HTTP redirect to HTTPS

# Allow Loki and Prometheus push/scrape ONLY from app VM IP ranges.
# Replace <APP_VM_IP> with the actual IP or CIDR of your app VMs.
# ufw allow from <APP_VM_IP> to any port 3100 proto tcp comment "Loki push from app VM"
# ufw allow from <APP_VM_IP> to any port 9090 proto tcp comment "Prometheus remote write"
# ufw allow from <APP_VM_IP> to any port 9100 proto tcp comment "Node Exporter"
# ufw allow from <APP_VM_IP> to any port 8080 proto tcp comment "cAdvisor"

# SSH — restrict to GitHub Actions runner IPs after initial setup
ufw allow 22/tcp comment "SSH — restrict after initial setup"

ufw --force enable
log "Firewall status:"
ufw status verbose

# ---------------------------------------------------------------------------
# 5. Create deploy directory and set ownership
# ---------------------------------------------------------------------------
log "Creating ${DEPLOY_DIR} owned by deploy:deploy..."
mkdir -p "${DEPLOY_DIR}"
chown deploy:deploy "${DEPLOY_DIR}"

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
ENV_FILE="${DEPLOY_DIR}/infrastructure/management-vm/.env"
if [ ! -f "${ENV_FILE}" ]; then
  log "Writing .env template — fill in secrets before starting services."
  cat > "${ENV_FILE}" <<ENVEOF
GRAFANA_ADMIN_PASSWORD=changeme
OBSERVABILITY_DOMAIN=<your-observability-domain>
VM_HOSTNAME=management-vm
LOKI_PUSH_URL=http://loki:3100/loki/api/v1/push
PROMETHEUS_REMOTE_WRITE_URL=http://prometheus:9090/api/v1/write
ENVEOF
fi

# ---------------------------------------------------------------------------
# 8. Pull images and start the observability stack
# ---------------------------------------------------------------------------
log "Starting management-vm Docker Compose stack..."
docker compose -f "${DEPLOY_DIR}/infrastructure/management-vm/docker-compose.yml" pull
docker compose -f "${DEPLOY_DIR}/infrastructure/management-vm/docker-compose.yml" up -d

log "Management VM provisioning complete."
docker compose -f "${DEPLOY_DIR}/infrastructure/management-vm/docker-compose.yml" ps
