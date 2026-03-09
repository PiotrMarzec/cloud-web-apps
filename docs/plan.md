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
   │        ├── Caddy (reverse proxy, HTTPS)
   │        ├── Docker app containers (N apps)
   │        ├── Grafana Alloy (log/metric collector)
   │        └── Node Exporter / cAdvisor (metrics)
   │
   └──► Management VM (predefined domain)
            ├── Caddy (HTTPS for observability UI)
            ├── Grafana (dashboards, alerts)
            ├── Loki (log aggregation)
            ├── Prometheus (metrics)
            └── Alertmanager (alert routing)
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
| Telemetry collector (app VM) | Grafana Alloy |
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
│   │   ├── Caddyfile                   # Reverse proxy rules per app
│   │   ├── docker-compose.yml          # Caddy + Alloy + Node Exporter + cAdvisor
│   │   └── alloy/
│   │       └── config.alloy            # Alloy pipeline: collect logs/metrics → push to mgmt VM
│   │
│   └── management-vm/
│       ├── Caddyfile                   # Exposes Grafana on predefined domain
│       ├── docker-compose.yml          # Grafana + Loki + Prometheus + Alertmanager
│       ├── grafana/
│       │   ├── provisioning/
│       │   │   ├── datasources/        # Auto-provision Loki + Prometheus sources
│       │   │   └── dashboards/         # Pre-built dashboards (infra, caddy, apps)
│       │   └── dashboards/
│       ├── loki/
│       │   └── config.yaml
│       ├── prometheus/
│       │   └── prometheus.yml          # Scrape configs for app VM exporters
│       └── alertmanager/
│           └── alertmanager.yml
│
├── scripts/
│   ├── provision-app-vm.sh             # Bootstrap Docker, configure firewall, pull compose
│   └── provision-management-vm.sh     # Bootstrap Docker, configure firewall, pull compose
│
└── .github/
    └── workflows/
        ├── deploy-app-vm.yml           # Triggered on push: re-deploys infra on app VM
        └── deploy-management-vm.yml   # Triggered on push: re-deploys mgmt VM stack
```

---

## VM Definitions (`infrastructure/vms.yaml`)

Each VM is declared here so the repo is the single source of truth:

```yaml
vms:
  - name: app-vm-1
    role: app
    provider: hetzner          # or aws, gcp, etc.
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
| `GRAFANA_ADMIN_PASSWORD` | mgmt VM compose | Grafana admin password |
| `APP_<NAME>_STORAGE_PATH` | per-app workflows | Host path for app storage (e.g. DB) |

---

## Unified Log Format

All components must emit **structured JSON logs**:

- **Caddy**: configured with `log { format json }` in Caddyfile
- **Docker apps**: apps write JSON to stdout/stderr; Docker captures them
- **Grafana Alloy**: reads Docker log files (via `loki.source.docker`), parses JSON,
  adds labels (`app`, `vm`, `env`), and ships to Loki
- **Prometheus exporters**: expose metrics in standard Prometheus format

Mandatory log labels: `job`, `app`, `host`, `level`

---

## App VM Stack

### Caddy
- Automatic TLS via Let's Encrypt
- Each app gets a `<app>.domain.com` virtual host
- Logs in JSON format, written to stdout (picked up by Alloy)

### Docker Apps
- Pulled from GHCR on deploy
- Each app defined in its own `docker-compose.override.yml` or managed via an
  apps registry (see below)
- Storage paths injected as environment variables from GitHub secrets, mounted
  as bind-mount volumes

### Grafana Alloy (collector)
- Collects Docker container logs → labels → pushes to Loki (management VM)
- Collects Node Exporter + cAdvisor metrics → remote-writes to Prometheus
- Single config file: `infrastructure/app-vm/alloy/config.alloy`

---

## Management VM Stack

### Loki
- Receives logs from Alloy on all app VMs
- Retention configured (e.g. 30 days)

### Prometheus
- Scrapes Node Exporter and cAdvisor on each app VM (IPs from `vms.yaml`)
- Alerting rules defined in `prometheus/rules/`

### Alertmanager
- Routes alerts from Prometheus (email/Slack/PagerDuty)

### Grafana
- Pre-provisioned datasources: Loki + Prometheus
- Pre-built dashboards:
  - Infrastructure overview (CPU, RAM, disk per VM)
  - Container metrics (per-app resource usage via cAdvisor)
  - Caddy traffic (requests/s, error rate, latency)
  - Application logs explorer (Loki-powered)
- Alert rules for: high CPU, high memory, container restarts, 5xx error rate

### Caddy (on management VM)
- Exposes Grafana on `observability.<domain>` with HTTPS

---

## GitHub Actions Workflows

### `deploy-app-vm.yml`
Triggered on: push to `main` affecting `infrastructure/app-vm/**`

Steps:
1. SSH into app VM using `APP_VM_1_SSH_KEY`
2. `git pull` latest repo
3. `docker compose pull && docker compose up -d` for infra services (Caddy, Alloy, exporters)
4. Reload Caddy config if `Caddyfile` changed

### `deploy-management-vm.yml`
Triggered on: push to `main` affecting `infrastructure/management-vm/**`

Steps:
1. SSH into management VM using `MGMT_VM_SSH_KEY`
2. `git pull` latest repo
3. `docker compose pull && docker compose up -d`

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
- Reboot policy set to automatic for kernel updates (configurable)

**Periodic security audits** — run via a scheduled GitHub Actions workflow
(`security-audit.yml`, weekly cron):
1. SSH into each VM
2. Run **Lynis** (`lynis audit system --quiet`) and upload the report as a
   GitHub Actions artifact
3. Alert via Alertmanager if the Lynis hardening score drops below a threshold

Audit reports are stored as workflow artifacts and reviewed manually or trigger
a Grafana alert when anomalies appear.

### 3. Log-Based Threat & Attack Monitoring

Grafana Loki alert rules (via `ruler`) detect suspicious patterns in collected logs:

| Rule | Signal | Severity |
|---|---|---|
| High 4xx rate | >50 req/min returning 401/403 on a single IP | warning |
| Brute-force attempt | >20 failed auth attempts in 1 min | critical |
| Spike in 5xx errors | Error rate >5% over 5 min window | warning |
| Port scan / unexpected paths | High volume of 404s from one IP | warning |
| SSH login from new IP | `sshd` log with unknown source address | info |

Alerts route through Alertmanager to the configured notification channel
(Slack/email/PagerDuty). A dedicated **Security** dashboard in Grafana visualises:
- Requests by country/IP (using Caddy geo fields)
- Auth failure timeline per app
- Top offending IPs

### 4. Network Hardening

- **App VM**: firewall allows only ports 80 and 443 inbound; SSH restricted to
  GitHub Actions runner IPs (or a bastion/VPN)
- **Management VM**: firewall allows only port 443 inbound; SSH restricted similarly
- Inter-VM communication (Alloy → Loki, Alloy → Prometheus) uses internal/private
  network where available, otherwise mTLS via Alloy's built-in TLS support

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

### Phase 1 — Infrastructure Foundation
- [ ] Set up GitHub repo structure
- [ ] Write `vms.yaml` schema
- [ ] Write provisioning scripts (`provision-app-vm.sh`, `provision-management-vm.sh`)
- [ ] Create GitHub Actions workflow for app VM deployment
- [ ] Create GitHub Actions workflow for management VM deployment

### Phase 2 — App VM: Caddy + Docker Apps
- [ ] Write `Caddyfile` template with per-app virtual host blocks
- [ ] Write `docker-compose.yml` for app VM (Caddy, Node Exporter, cAdvisor)
- [ ] Define per-app Docker Compose structure with storage path injection

### Phase 3 — Telemetry Collection
- [ ] Install and configure Grafana Alloy on app VM
- [ ] Configure Docker log collection → Loki labels → push to management VM
- [ ] Configure metrics remote-write → Prometheus on management VM
- [ ] Validate log format unification across Caddy + apps

### Phase 4 — Management VM: Observability Stack
- [ ] Write `docker-compose.yml` for Loki, Prometheus, Alertmanager, Grafana
- [ ] Provision Grafana datasources and base dashboards
- [ ] Configure Prometheus scrape targets from `vms.yaml`
- [ ] Set up Alertmanager with at least one notification channel
- [ ] Expose Grafana via Caddy on `observability.<domain>`

### Phase 5 — App Deployment Pipeline
- [ ] Document per-app repo workflow template
- [ ] Test end-to-end: push to app main → GHCR → app VM → running container
- [ ] Validate logs appear in Loki and metrics in Prometheus

### Phase 6 — Security & Hardening
- [ ] Firewall rules: app VM exposes only 80/443; management VM exposes only 443
- [ ] Restrict SSH access to GitHub Actions runner IPs on both VMs
- [ ] Enable `unattended-upgrades` for security patches in provisioning scripts
- [ ] Add `docker scout` CVE scan step to per-app deploy workflow
- [ ] Enable GitHub Dependabot and Code Scanning (CodeQL) on all app repos
- [ ] Set up `security-audit.yml` scheduled workflow (weekly Lynis run)
- [ ] Configure Loki ruler alert rules for brute-force, 4xx/5xx spikes, port scans
- [ ] Add Security dashboard in Grafana (auth failures, top offending IPs)
- [ ] Secret rotation procedure documented
- [ ] Runbook for adding a new app
- [ ] Runbook for adding a new VM (future scale-out)
- [ ] Document Cloudflare WAF migration steps (DNS proxy + Caddy IP allowlist)
