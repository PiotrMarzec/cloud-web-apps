# Cloud Web Apps — Implementation Plan

## Overview

This document outlines the architecture and implementation plan for a cloud setup
that hosts multiple Docker-based web apps, with a dedicated management VM running
a full observability stack.

---

## Architecture

```
Internet
   │
   ├──► App VM (single IP, future: behind LB)
   │        ├── Caddy (reverse proxy, HTTPS, HTTP/3)
   │        ├── Docker app containers (N apps)
   │        ├── Grafana Alloy (log/metric collector)
   │        └── Node Exporter / cAdvisor (metrics)
   │
   └──► Management VM (predefined domain)
            ├── Caddy "caddy-mgmt" (HTTPS for observability UI)
            ├── Grafana (dashboards, alerts)
            ├── Grafana Alloy (local log/metric collector)
            ├── Loki (log aggregation)
            ├── Prometheus (metrics)
            ├── Alertmanager (alert routing)
            └── Node Exporter / cAdvisor (metrics)
```

---

## Technology Choices

| Concern | Tool |
|---|---|
| Reverse proxy / HTTPS | Caddy |
| Container runtime | Docker + Docker Compose |
| Container image registry | GitHub Container Registry (GHCR) |
| CI/CD | GitHub Actions |
| Log aggregation | Grafana Loki |
| Metrics collection | Prometheus |
| Telemetry collector (both VMs) | Grafana Alloy |
| Visualization & alerting | Grafana |
| Alert routing | Alertmanager |
| VM-level metrics | Node Exporter |
| Container metrics | cAdvisor |
| Dependency vulnerability scanning | GitHub Dependabot + `docker scout` |
| VM security auditing | Lynis |
| Unattended OS security updates | `unattended-upgrades` (Debian/Ubuntu) |
| Log-based threat detection | Grafana Loki alert rules + Prometheus Alertmanager |
| Future WAF | Cloudflare WAF (proxied DNS) |

---

## Repository Structure

```
cloud-web-apps/
├── docs/
│   ├── requirements.md
│   └── plan.md
│
├── infrastructure/
│   ├── vms.yaml                        # Canonical VM definitions (name, ip, role, region)
│   │
│   ├── app-vm/
│   │   ├── Caddyfile                   # Reverse proxy rules per app + maintenance page
│   │   ├── docker-compose.yml          # Caddy + Alloy + Node Exporter + cAdvisor
│   │   ├── static/
│   │   │   └── maintenance/
│   │   │       └── index.html          # Maintenance page served on 502/503/504
│   │   └── alloy/
│   │       └── config.alloy            # Alloy pipeline: collect logs/metrics → push to mgmt VM
│   │
│   └── management-vm/
│       ├── Caddyfile                   # Exposes Grafana on predefined domain
│       ├── docker-compose.yml          # Caddy-mgmt + Grafana + Loki + Prometheus + Alertmanager + Alloy + exporters
│       ├── grafana/
│       │   ├── provisioning/
│       │   │   ├── datasources/        # Auto-provision Loki + Prometheus + Alertmanager sources
│       │   │   └── dashboards/         # Dashboard provisioning config
│       │   └── dashboards/             # 7 pre-built JSON dashboards
│       ├── loki/
│       │   ├── config.yaml
│       │   └── rules/
│       │       └── security.yaml       # Loki ruler alert rules (security + reliability)
│       ├── prometheus/
│       │   ├── prometheus.yml          # Self-scrape + remote-write receiver
│       │   └── rules/
│       │       └── alerts.yml          # Infrastructure + container alert rules
│       ├── alloy/
│       │   └── config.alloy            # Local log/metric collection for mgmt VM services
│       └── alertmanager/
│           └── alertmanager.yml        # Alert routing (critical, security, info, default)
│
├── scripts/
│   ├── provision-app-vm.sh             # Bootstrap Docker, configure firewall, pull compose
│   └── provision-management-vm.sh      # Bootstrap Docker, configure firewall, install Lynis, pull compose
│
└── .github/
    └── workflows/
        ├── deploy-app-vm.yml           # Triggered on push: re-deploys infra on app VM
        ├── deploy-management-vm.yml    # Triggered on push: re-deploys mgmt VM stack
        └── security-audit.yml          # Weekly Lynis audit on both VMs
```

---

## VM Definitions (`infrastructure/vms.yaml`)

Each VM is declared here so the repo is the single source of truth:

```yaml
vms:
  - name: app-vm-1
    role: app
    provider: hetzner
    region: eu-central
    ssh_secret: APP_VM_1_SSH_KEY
    ip_secret: APP_VM_1_IP

  - name: management-vm
    role: management
    provider: hetzner
    region: eu-central
    ssh_secret: MGMT_VM_SSH_KEY
    ip_secret: MGMT_VM_IP
```

---

## GitHub Secrets

| Secret | Used By | Purpose |
|---|---|---|
| `APP_VM_1_SSH_KEY` | deploy-app-vm workflow | SSH private key to app VM |
| `APP_VM_1_IP` | deploy-app-vm workflow | IP of app VM |
| `MGMT_VM_SSH_KEY` | deploy-management-vm workflow | SSH private key to mgmt VM |
| `MGMT_VM_IP` | deploy-management-vm workflow | IP of mgmt VM |
| `LOKI_PUSH_URL` | Alloy config on app VM | Loki endpoint on mgmt VM |
| `PROMETHEUS_REMOTE_WRITE_URL` | Alloy config on app VM | Prometheus remote-write endpoint on mgmt VM |
| `GRAFANA_ADMIN_PASSWORD` | mgmt VM compose | Grafana admin password |
| `OBSERVABILITY_DOMAIN` | mgmt VM Caddyfile | Domain for Grafana UI |
| `APP_<NAME>_STORAGE_PATH` | per-app workflows | Host path for app storage (e.g. DB) |

---

## Unified Log Format

All components emit **structured JSON logs**:

- **Caddy**: configured with `log { format json }` in Caddyfile
- **Docker apps**: apps write JSON to stdout/stderr; Docker captures them
- **Grafana Alloy**: discovers Docker containers, reads log files, applies multiline
  merging (for stack traces), parses JSON, extracts labels (`request.method`,
  `request.proto`, `status`, `level`, `logger`), promotes all top-level JSON fields
  to structured metadata, adds static labels (`job`, `host`, `env`), and ships to Loki
- **Prometheus exporters**: expose metrics in standard Prometheus format

Mandatory log labels: `job`, `app`, `host`, `level`

---

## App VM Stack

### Networks
Two Docker networks isolate traffic:
- **`proxy`**: Caddy and app containers
- **`monitoring`**: Node Exporter, cAdvisor, Alloy

### Caddy
- Automatic TLS via Let's Encrypt with HTTP/3 support
- Per-app virtual host blocks with reverse proxy to app containers
- Currently configured apps:
  - `data-collection.piotrmarzec.info` → `dc-app:9666`
  - `regie.kapibara.cloud` → `regie:3000`
- JSON logging to stdout (picked up by Alloy)
- **Maintenance page**: error handler for 502/503/504 serves a static HTML page
  (`/srv/maintenance/index.html`) so users see a professional maintenance UI
  instead of raw error codes

### Docker Apps
- Pulled from GHCR on deploy
- Each app defined in its own `docker-compose.override.yml` or managed via an
  apps registry
- Storage paths injected as environment variables from GitHub secrets, mounted
  as bind-mount volumes

### Grafana Alloy (collector)
- **Log pipeline**: Docker discovery → relabel (extract app name, image) →
  multiline processing (merge stack traces) → JSON parsing → label promotion →
  static labels (`job`, `host`, `env`) → push to Loki on management VM
- **Metrics pipeline**: scrapes Node Exporter (`:9100`) and cAdvisor (`:8080`)
  at 15s intervals → adds `host` label → remote-writes to Prometheus on management VM
- Single config file: `infrastructure/app-vm/alloy/config.alloy`

---

## Management VM Stack

### Network
Single `observability` Docker network connects all services.

### Loki
- Receives logs from Alloy on all app VMs and from local Alloy
- TSDB store with filesystem backend (v13 schema, from 2024-01-01)
- Retention: 30 days with compaction-based deletion (2h delete delay)
- Ingestion limits: 16 MB/s sustained, 32 MB/s burst
- Ruler enabled with Alertmanager integration at `http://alertmanager:9093`

### Prometheus
- Self-scrapes at `localhost:9090`
- **Remote-write receiver enabled** — app VMs push metrics via Alloy remote-write
  (no direct scrape of app VM exporters)
- 30-day retention
- Alert rules loaded from `/etc/prometheus/rules/*.yml`
- Connected to Alertmanager at `alertmanager:9093`
- Global labels: `env: production`; 15s evaluation interval

### Alertmanager
- **Routing hierarchy**:
  - Critical alerts → `critical` receiver (1h repeat interval)
  - Security alerts (BruteForce, High4xx, PortScan, SshLoginNewIp) → `security` receiver (2h repeat)
  - Info alerts → `info-channel` receiver (24h repeat)
  - Default → `default` receiver (4h repeat)
- Grouping: by `alertname`, `host`, `app`; 30s group wait, 5m group interval
- Inhibition: suppresses warning alerts when critical exists for same host
- Receiver templates provided for Slack/email/PagerDuty (to be configured)

### Grafana Alloy (local collector)
- Collects Docker container logs from management VM services → pushes to local Loki
- Scrapes local Node Exporter + cAdvisor → remote-writes to local Prometheus
- Provides self-observability for the management VM stack itself

### Grafana
- Pre-provisioned datasources: Loki, Prometheus, Alertmanager
- 7 pre-built dashboards:
  1. **Infrastructure Overview** — CPU, RAM, disk per VM
  2. **Container Metrics** — per-app resource usage via cAdvisor
  3. **Caddy Traffic** — requests/s, error rate, latency (overview)
  4. **Caddy App** — app-VM Caddy detailed dashboard
  5. **Caddy Mgmt** — management-VM Caddy detailed dashboard
  6. **App Logs** — application logs explorer (Loki-powered)
  7. **Security** — requests by country/IP, auth failures, top offending IPs

### Caddy (on management VM)
- Container named `caddy-mgmt` to distinguish from app VM's `caddy` in logs
- Exposes Grafana on `${OBSERVABILITY_DOMAIN}` with HTTPS (domain injected via env)

---

## GitHub Actions Workflows

### `deploy-app-vm.yml`
Triggered on: push to `main` affecting `infrastructure/app-vm/**`

Steps:
1. Validate required secrets (`APP_VM_1_IP`, `APP_VM_1_SSH_KEY`, `LOKI_PUSH_URL`, `PROMETHEUS_REMOTE_WRITE_URL`)
2. SSH into app VM as deploy user
3. `git pull` latest repo into `/opt/cloud-web-apps`
4. Write `.env` file with Loki/Prometheus push URLs
5. `docker compose pull && docker compose up -d`
6. Restart Caddy container (full restart instead of reload for reliability)

### `deploy-management-vm.yml`
Triggered on: push to `main` affecting `infrastructure/management-vm/**`

Steps:
1. Validate required secrets (`MGMT_VM_IP`, `MGMT_VM_SSH_KEY`, `GRAFANA_ADMIN_PASSWORD`, `OBSERVABILITY_DOMAIN`)
2. SSH into management VM as deploy user
3. `git pull` latest repo into `/opt/cloud-web-apps`
4. Write `.env` file with local Loki/Prometheus URLs, Grafana password, observability domain
5. `envsubst` Caddyfile to inject `OBSERVABILITY_DOMAIN`
6. `docker compose pull && docker compose up -d`
7. Reload Prometheus configuration

### `security-audit.yml`
Triggered on: weekly cron (Sunday 02:00 UTC) + manual dispatch

Steps (per VM):
1. SSH into VM, install/update Lynis
2. Run `lynis audit system --quiet`
3. Extract hardening index; alert if score < 65
4. Upload report as GitHub Actions artifact (90-day retention)

---

## Web App Deployment (per-app repos)

Each web app lives in its own GitHub repo with this workflow:

```yaml
# .github/workflows/deploy.yml  (in each app repo)
on:
  push:
    branches: [main]

jobs:
  build-and-deploy:
    steps:
      - Build Docker image
      - Push to GHCR (ghcr.io/<org>/<app>:<sha>)
      - SSH into app VM
      - docker pull ghcr.io/<org>/<app>:<sha>
      - docker compose up -d --no-deps <app>
```

Storage paths (e.g. PostgreSQL data dir) are passed as environment variables
set in the GitHub secrets of each app repo (`APP_<NAME>_STORAGE_PATH`), then
injected into the Docker Compose file as bind-mount volumes.

---

## Alert Rules

### Prometheus Alert Rules (`prometheus/rules/alerts.yml`)

**Infrastructure alerts:**
| Rule | Condition | Severity |
|---|---|---|
| `HighCpuUsage` | >85% for 5 min | warning |
| `HighMemoryUsage` | >90% for 5 min | warning |
| `DiskSpaceLow` | >85% usage for 5 min | warning |
| `InstanceDown` | Scrape target down for 1 min | critical |

**Container alerts:**
| Rule | Condition | Severity |
|---|---|---|
| `ContainerRestarting` | 2+ restarts in 10 min | warning |
| `ContainerHighCpu` | >80% for 5 min | warning |
| `ContainerHighMemory` | >90% of limit for 5 min | warning |

### Loki Security Rules (`loki/rules/security.yaml`)

| Rule | Signal | Severity |
|---|---|---|
| `High4xxRate` | >50 req/min returning 401/403 from single IP | warning |
| `BruteForceAttempt` | >20 failed auth events/min from IP | critical |
| `PossiblePortScan` | >100 404s/min from single IP | warning |
| `SshLoginNewIp` | Any SSH login detected | info |
| `High5xxRate` | >5% error rate over 5 min | warning |

Alerts route through Alertmanager to configured notification channels.

---

## Security

### 1. Source Code & Dependency Vulnerability Monitoring

Each web app repo enables:
- **GitHub Dependabot**: automatically opens PRs for outdated/vulnerable dependencies
  (language packages, Docker base images)
- **GitHub Code Scanning** (CodeQL): static analysis on every push to `main`
- **`docker scout` in CI**: added as a step in the per-app deploy workflow to scan
  the built image for known CVEs before pushing to GHCR; the workflow fails on
  critical/high severity findings

```yaml
# Added to per-app .github/workflows/deploy.yml
- name: Scan image for vulnerabilities
  run: docker scout cves ghcr.io/<org>/<app>:${{ github.sha }} --exit-code --only-severity critical,high
```

### 2. VM Security Auditing & OS Patching

**Automated OS patching** — configured during VM provisioning:
- `unattended-upgrades` installed on both VMs, scoped to security updates only
- Automatic reboot at 03:00 UTC for kernel updates

**Periodic security audits** — `security-audit.yml` (weekly cron, Sunday 02:00 UTC):
1. SSH into each VM
2. Run **Lynis** (`lynis audit system --quiet`) and upload the report as a
   GitHub Actions artifact (90-day retention)
3. Alert if the Lynis hardening index drops below 65

### 3. Log-Based Threat & Attack Monitoring

See [Alert Rules → Loki Security Rules](#loki-security-rules-lokirulessecurityyaml) above.

A dedicated **Security** dashboard in Grafana visualises:
- Requests by country/IP (using Caddy geo fields)
- Auth failure timeline per app
- Top offending IPs

### 4. Network Hardening

- **App VM**: UFW firewall allows only ports 80, 443 (incl. HTTP/3 UDP), and SSH inbound;
  SSH restricted to GitHub Actions runner IPs (or a bastion/VPN)
- **Management VM**: UFW firewall allows ports 80, 443, and SSH; Loki (3100) and
  Prometheus (9090) ports to be restricted to app VM IPs only
- Docker network isolation: app VM uses separate `proxy` and `monitoring` networks;
  management VM uses a single `observability` network
- Inter-VM communication (Alloy → Loki, Alloy → Prometheus) via push model
  (remote-write / Loki push API)

### 5. Future — Cloudflare WAF

When web apps are placed behind Cloudflare:
- DNS records switch from `A → VM IP` to `A → Cloudflare proxy` (orange cloud)
- Cloudflare WAF managed ruleset enabled per app zone
- Caddy on the app VM configured to **only accept traffic from Cloudflare IP ranges**
  (enforced via firewall rules updated from Cloudflare's published IP list)
- DDoS protection and bot management handled at the Cloudflare layer before
  traffic reaches the app VM

---

## Future: Multiple App VMs + Load Balancer

The architecture is designed to scale horizontally:

1. Add new VM entry to `infrastructure/vms.yaml`
2. GitHub Actions provisions it and deploys the app stack
3. All app VMs point to the same Loki + Prometheus on the management VM
4. A load balancer (e.g. Hetzner LB, AWS ALB) is added in front; DNS switches
   from single VM IP to LB IP
5. Caddy continues to run on each app VM (or moves to the LB layer)

---

## Implementation Phases

### Phase 1 — Infrastructure Foundation ✅
- [x] Set up GitHub repo structure
- [x] Write `vms.yaml` schema
- [x] Write provisioning scripts (`provision-app-vm.sh`, `provision-management-vm.sh`)
- [x] Create GitHub Actions workflow for app VM deployment
- [x] Create GitHub Actions workflow for management VM deployment

### Phase 2 — App VM: Caddy + Docker Apps ✅
- [x] Write `Caddyfile` with per-app virtual host blocks (data-collection, regie)
- [x] Write `docker-compose.yml` for app VM (Caddy, Node Exporter, cAdvisor)
- [x] Define per-app Docker Compose structure with storage path injection
- [x] Add maintenance page (static HTML served on 502/503/504 errors)
- [x] Configure dual networks (proxy + monitoring)

### Phase 3 — Telemetry Collection ✅
- [x] Install and configure Grafana Alloy on app VM
- [x] Configure Docker log collection → multiline merging → JSON parsing → Loki labels → push to management VM
- [x] Configure metrics remote-write → Prometheus on management VM
- [x] Validate log format unification across Caddy + apps
- [x] Install and configure Grafana Alloy on management VM (self-observability)

### Phase 4 — Management VM: Observability Stack ✅
- [x] Write `docker-compose.yml` for Loki, Prometheus, Alertmanager, Grafana, Alloy, exporters
- [x] Provision Grafana datasources (Loki + Prometheus + Alertmanager)
- [x] Configure Prometheus with remote-write receiver (push model from app VMs)
- [x] Set up Alertmanager with routing hierarchy (critical, security, info, default)
- [x] Expose Grafana via Caddy (`caddy-mgmt`) on `${OBSERVABILITY_DOMAIN}`
- [x] Build 7 Grafana dashboards (infrastructure, containers, caddy-traffic, caddy-app, caddy-mgmt, app-logs, security)

### Phase 5 — App Deployment Pipeline (partial)
- [x] Document per-app repo workflow template
- [x] Deploy apps end-to-end (data-collection and regie running on app VM)
- [x] Validate logs appear in Loki and metrics in Prometheus
- [ ] Add `docker scout` CVE scan step to per-app deploy workflow

### Phase 6 — Security & Hardening ✅
- [x] Firewall rules: app VM exposes only 80/443; management VM exposes only 443
- [x] Enable `unattended-upgrades` for security patches in provisioning scripts (auto-reboot 03:00 UTC)
- [x] Set up `security-audit.yml` scheduled workflow (weekly Lynis run, hardening threshold < 65)
- [x] Configure Loki ruler alert rules for brute-force, 4xx/5xx spikes, port scans, SSH logins
- [x] Configure Prometheus alert rules for CPU, memory, disk, instance down, container restarts
- [x] Add Security dashboard in Grafana (auth failures, top offending IPs, country/IP breakdown)
- [ ] Restrict SSH access to GitHub Actions runner IPs on both VMs
- [ ] Enable GitHub Dependabot and Code Scanning (CodeQL) on all app repos
- [ ] Secret rotation procedure documented
- [ ] Runbook for adding a new app
- [ ] Runbook for adding a new VM (future scale-out)
- [ ] Document Cloudflare WAF migration steps (DNS proxy + Caddy IP allowlist)
