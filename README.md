# Windows and Linux monitoring

Separate metrics-only copy of the existing Telegraph deployment. Telegraf collects the Docker Linux host's CPU, RAM, swap, filesystem, disk I/O, processes and uptime. Prometheus also scrapes the existing native Linux node_exporter and Windows windows_exporter endpoints. Grafana provisions a Prometheus datasource and Infrastructure / Windows and Linux hosts dashboard.

## Transfer to another Linux VM
Copy the entire directory, including the hidden .env file, to /mnt/telegraph-monitoring on the destination VM. For example, run on this server:
  scp -r /mnt/telegraph-monitoring USER@NEW_VM:/tmp/
Then move the directory into /mnt on the destination with sudo.
Install Docker Engine and the Docker Compose plugin on that VM. The destination needs registry access to pull the pinned images and network access to the exporter IPs.
Review prometheus/targets/*.json for the destination network. Update exporter firewalls to allow the NEW VM's IP.
Telegraf monitors the destination Linux VM automatically through its host filesystem mounts.
The .env file contains the generated Grafana password; retain mode 600 and keep it private.

## Start on the destination VM
cd /mnt/telegraph-monitoring
docker compose config --quiet
docker compose up -d

Grafana: http://localhost:3300 (admin; password in .env).
Prometheus: http://localhost:19090.
For remote access: ssh -L 3300:127.0.0.1:3300 USER@MONITORING_SERVER
Then open http://localhost:3300 on your workstation.
To expose Grafana on your LAN, set GRAFANA_BIND to this server's LAN IP in .env and run docker compose up -d.
Restrict access using your host firewall; use a TLS reverse proxy for broader access.

## Add / remove hosts
Edit prometheus/targets/linux.json (port 9100) or windows.json (port 9182).
Prometheus automatically reloads these target files. The existing real IPs were copied; placeholder CENTOS_VM_IP was omitted. Availability is not assumed.
Each remote host needs a native exporter; this central container cannot directly collect remote OS counters.
- Linux: install node_exporter as a system service from https://github.com/prometheus/node_exporter/releases . Run with its default collectors, listening on port 9100.
- Windows: install the MSI from https://github.com/prometheus-community/windows_exporter/releases . Enable cpu, memory, logical_disk, net, os, system collectors. Example in an elevated PowerShell session, using the actual downloaded MSI path:
  msiexec /i C:\Downloads\windows_exporter.msi ENABLED_COLLECTORS="cpu,memory,logical_disk,net,os,system"
- Allow inbound exporter TCP ports only from the monitoring server's IP. Confirm reachability at http://HOST:9100/metrics or http://HOST:9182/metrics.
- Exporter metric names vary by release. The CPU panel supports older and newer Windows CPU names. Check /metrics if a panel is empty.
- Local Telegraf intentionally omits network metrics because its network namespace is isolated. Install node_exporter on this host and add its LAN address to linux.json if host network throughput is needed.

## Operations
docker compose ps
docker compose logs --tail=100
docker compose restart prometheus  # after editing rules or prometheus.yml
docker compose down              # retains stored metrics and dashboards

Retention: 30 days, capped at 10 GB of Prometheus blocks (allow additional disk space for WAL and active data). Named volumes are isolated by project name.
Rules cover exporter availability and disk usage. Alerts appear in Prometheus; email/chat delivery requires an Alertmanager and receiver configuration.
Images are pinned to the exact locally installed digests, not latest tags. These are reproducible baseline versions, not a claim that they are current.
The generated admin password only initializes a new Grafana volume. Change an existing account password through Grafana.
No existing services, credentials, volumes or configuration were modified.

## Review of original deployment
- Telegraf lacked host mounts, so its local OS metrics did not reliably describe the host.
- SNMP configuration contained SWITCH1_IP / SWITCH2_IP and public community placeholders.
- Linux scrape targets included CENTOS_VM_IP.
- Grafana used admin as the initial password; several services followed mutable latest images.
- Metrics-only monitoring does not require the existing Loki, Promtail, Tempo or OTEL services; those remain in the original deployment.
- The existing compose uses fixed container names and ports. This copy uses a separate project, ports 3300/19090, internal-only Telegraf, and separate volumes.

References:
https://github.com/influxdata/telegraf/blob/master/plugins/inputs/disk/README.md
https://github.com/prometheus-community/windows_exporter
https://github.com/prometheus/node_exporter

## Validation performed
Docker Compose configuration validation and promtool configuration/rule checks passed. JSON, YAML and Telegraf TOML parse checks passed. The stack was not deployed; runtime collection, exporter reachability and dashboard rendering must be checked on the destination VM.

## Linux Node Exporter installer
Copy scripts/install-node-exporter.sh to each Ubuntu/Debian Linux VM.
Requires systemd and python3. Run on the VM being monitored:
  sudo bash install-node-exporter.sh NEW_PROMETHEUS_VM_IP

Optional second argument changes port 9100. The installer preserves the supplied
version 1.8.2; to select a newer reviewed release:
  sudo env NODE_EXPORTER_VERSION=1.12.1 bash install-node-exporter.sh NEW_PROMETHEUS_VM_IP

The script checks release SHA256, detects amd64/arm64, backs up replaced files,
uses a root-owned executable and unprivileged service account, restarts on rerun,
and verifies CPU metrics. It adds a source-specific rule only when UFW is active.
It does not enable UFW, remove existing rules, or guarantee exclusive access if
broader rules already exist. Configure the host/cloud firewall appropriately.
The new monitoring VM IP must be supplied explicitly; the old example IP is not assumed.
Add this Linux VM's IP:9100 to prometheus/targets/linux.json afterward.
Script syntax and help were checked; installation has not been executed.

## Windows PowerShell installer
Copy scripts/install-windows-exporter.ps1 to each Windows VM.
Open PowerShell as Administrator and run:
  .\install-windows-exporter.ps1 -PrometheusIP "NEW_PROMETHEUS_VM_IP"

If a downloaded file is blocked, review it and run:
  Unblock-File .\install-windows-exporter.ps1
Follow your organization's PowerShell execution policy.

Optional: -Port 9182. PowerShell 5.1 or newer is required.
The script downloads Windows Exporter 0.32.1 for AMD64 or ARM64, checks its pinned
SHA256, installs the service and MSI firewall exception scoped to the supplied IP,
and verifies CPU, RAM, disk and network metrics. Existing exporter services cause
a stop before changes; upgrades are intentionally left for separate review.
MSI logs remain in the user's TEMP directory. The script never reboots.
Add THIS_WINDOWS_VM_IP:9182 to prometheus/targets/windows.json on the monitoring VM.
No stack restart is required for a target-file update.

The script was reviewed but not executed or parsed with PowerShell: this Linux
environment has no PowerShell runtime. Installation and metrics must be verified
on the destination Windows VM.

Official MSI options and pinned release:
https://github.com/prometheus-community/windows_exporter
https://github.com/prometheus-community/windows_exporter/releases/tag/v0.32.1
# telegraph-monitoring
