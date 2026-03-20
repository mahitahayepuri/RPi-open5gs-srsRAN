# Open5GS Ansible Playbooks

Ansible automation for deploying a 5G SA core (Open5GS) on Raspberry Pi 4 and Pi 5 units running Raspberry Pi OS based on Debian 13 (Trixie) arm64.

## Directory Structure

```
ansible/
├── inventory-pi4.ini                              # Inventory for Raspberry Pi 4 targets
├── inventory-pi5.ini                              # Inventory for Raspberry Pi 5 targets
├── group_vars/
│   ├── all.yml                                    # Shared variables (timezone, locale, boot, PLMN)
│   ├── core.yml                                   # Open5GS-specific variables
│   ├── gnb.yml                                    # srsRAN-specific variables
│   └── ue.yml                                     # srsUE-specific variables
├── common/                                        # Shared playbooks (used by both open5gs and srsran)
│   └── playbooks/
│       ├── preflight/
│       │   ├── main.yml                           # Imports all preflight checks
│       │   ├── model.yml                          # Reads Device Tree model & architecture
│       │   ├── memory.yml                         # Displays total memory (MB)
│       │   ├── os_check.yml                       # Asserts Raspberry Pi OS on Debian 13 (Trixie)
│       │   └── verify_platform.yml                # Master check: memory, model, OS + dynamic grouping
│       └── pi_setup.yml                           # Harden Pi: disable radios, VNC, SPI, I2C, 1-Wire
└── open5gs/
    ├── tools/
    │   └── check_status.sh                        # Health-check script (deployed to Pi as open5gs_check)
    ├── files/
    │   └── systemd/
    │       ├── open5gs-nrfd-override.conf          # Drop-in: PartOf target (NRF starts first)
    │       └── open5gs-nf-override.conf            # Drop-in: PartOf target + After=NRF (all other NFs)
    └── playbooks/
        ├── open5gs.yml                            # Top-level entrypoint
        └── open5gs_install/
            ├── main.yml                           # Entry point - imports all install sub-plays
            ├── docker.yml                         # Install Docker CE + add pi user to docker group
            ├── mongodb.yml                        # Run MongoDB as a Docker container (image per Pi model)
            ├── tun_setup.yml                      # Persistent ogstun TUN device via systemd-networkd
            ├── install.yml                        # Dispatcher: routes to apt or source tasks
            ├── tasks/
            │   ├── install_apt.yml                # OBS repo setup + apt install open5gs NFs individually
            │   └── install_source.yml             # git clone, meson, ninja, copy service files
            ├── network.yml                        # RAN address, IP forwarding, NAT, config patching
            ├── logging.yml                        # rsyslog-based per-NF log splitting
            ├── services.yml                       # Enable/start selected NF daemons + deploy check tool
            └── webui.yml                          # Deploy Open5GS WebUI as Docker container
```

## Pipeline Stages

The top-level `playbooks/open5gs.yml` runs nine stages in order:

### 1. Preflight (shared from `common/`)

Validates every host in the `[core]` inventory group (part of the `[rpi]` parent group) against three criteria:

- **Memory** -- at least 4 GB RAM
- **Model** -- Raspberry Pi 4 or newer (matched via Device Tree)
- **OS** -- Raspberry Pi OS based on Debian 13 (Trixie) with the official `archive.raspberrypi.com` APT source

Hosts that pass are dynamically grouped as `preflight_pass`, then aliased to `candidate`. Hosts that fail are placed in `preflight_fail` and skipped by all subsequent stages.

### 2. Pi Setup (shared from `common/`)

Hardens each candidate Pi for headless server use in a single play:

- Adds `dtoverlay=disable-wifi` and `dtoverlay=disable-bt` to `/boot/firmware/config.txt` (using Pi 5-specific overlay names where needed), rebooting only if changes were made.
- Disables VNC, SPI, I2C, and 1-Wire via `raspi-config nonint` commands.

### 3. Docker

Installs Docker CE from the official Docker apt repository for Debian arm64. Includes:

- Docker Engine, CLI, containerd, buildx, and compose plugins
- Adds the `pi` user to the `docker` group

### 4. MongoDB

Runs MongoDB as a Docker container. The image is selected automatically based on the Pi model:

| Pi Model | Docker Image | Reason |
|---|---|---|
| Raspberry Pi 4 | `mongodb/mongodb-community-server:4.4.3-ubuntu2004` | Last version that runs on ARMv8.0-A (Cortex-A72) |
| Raspberry Pi 5 | `mongo:7.0` | Supports ARMv8.2-A (Cortex-A76) |

**Note on Pi 4 and MongoDB:** MongoDB 5.0+ uses ARMv8.1-A LSE atomic instructions that cause an `Illegal instruction` crash on the Pi 4's Cortex-A72 (ARMv8.0-A). The official `mongo:4.4` image (4.4.19+) also added an ARMv8.2-A requirement (SERVER-71772). The `mongodb/mongodb-community-server:4.4.3-ubuntu2004` image is the last known build that works on ARMv8.0-A ([docker-library/mongo#485](https://github.com/docker-library/mongo/issues/485), [#510](https://github.com/docker-library/mongo/issues/510)). However, MongoDB 4.4 reached End of Life in February 2024 and receives no further security patches. The Pi 5 does not have this limitation.

Data is persisted via a named Docker volume (`open5gs_mongodb_data`). The container binds to `127.0.0.1:27017` and restarts automatically.

### 5. Open5GS Install

Supports two installation methods, controlled by a single variable:

- **`apt`** (default) -- Pre-built arm64 NF packages installed individually (e.g. `open5gs-amfd`, `open5gs-smfd`) from the OBS repository. Fast, includes systemd units and configs out of the box.
- **`source`** -- Compiles from the official git repository with meson/ninja. Useful for custom patches or unreleased versions.

Both methods end with the same result: NF daemons managed by systemd, configs under `/etc/open5gs/`, and a persistent `ogstun` TUN device.

### 6. Networking

Configures the RAN-facing network so the gNB on the other Pi can reach the core's AMF and UPF:

- **RAN backhaul address** -- Adds `open5gs_ran_addr` (default `10.53.1.1/24`) as a secondary IP on the physical NIC via a persistent systemd oneshot service. This is the address the gNB connects to for N2 (NGAP) and N3 (GTP-U).
- **IP forwarding** -- Enables IPv4 and IPv6 forwarding (`net.ipv4.ip_forward=1`) so UE traffic from the `ogstun` TUN device can be routed to the internet.
- **NAT masquerade** -- Deploys nftables rules that masquerade UE IPv4 traffic (`10.45.0.0/16`) leaving via any interface except `ogstun`.
- **Config patching** -- Modifies the AMF config to bind NGAP on the RAN address (instead of `127.0.0.5`) and the UPF config to bind GTP-U on the RAN address (instead of `127.0.0.7`). SBI and PFCP remain on loopback.

Firewall rules are not deployed by the playbook. See [`FIREWALL.md`](../FIREWALL.md) for recommended nftables rulesets.

### 7. Service Management

All NF services are grouped under a single `open5gs-stack.target` systemd target. The playbook deploys drop-in overrides for each NF service so that:

- `PartOf=open5gs-stack.target` -- stopping or restarting the target propagates to all NFs
- `After=open5gs-nrfd.service` -- NRF starts first (all other NFs register with it)

After deployment, the user can manage the entire stack with standard systemd commands:

```bash
# Stop all Open5GS services:
sudo systemctl stop open5gs-stack.target

# Start all Open5GS services (NRF first, then the rest):
sudo systemctl start open5gs-stack.target

# Restart everything:
sudo systemctl restart open5gs-stack.target

# Check target status:
systemctl status open5gs-stack.target
```

Individual services can still be managed independently:

```bash
sudo systemctl restart open5gs-amfd
```

### 8. Logging

Deploys rsyslog-based per-NF log splitting:

- Patches out the built-in file logger from all 11 NF configs (using `yq`)
- Deploys rsyslog configuration at `/etc/rsyslog.d/30-open5gs.conf` to split logs by NF
- Deploys logrotate configuration at `/etc/logrotate.d/open5gs` for automatic log rotation
- Logs are written to `/var/log/open5gs/<nf>.log` (one file per network function)

This gives operators both real-time streaming via `journalctl -u open5gs-amfd` and persistent per-NF log files for post-mortem analysis. The approach mirrors the srsRAN gNB log pipeline.

### 9. WebUI

Deploys the Open5GS WebUI as a Docker container:

- Clones the Open5GS repository to `open5gs_webui_source_dir` (default `/usr/local/src/open5gs`)
- Builds a Docker image from `docker/webui/Dockerfile`
- Runs the WebUI container with `--network host` on port 9999
- Sets `HOSTNAME=0.0.0.0` so Next.js binds on all interfaces (not just the hostname's loopback)
- Skips the x86_64-only `/wait` binary from the upstream Dockerfile CMD
- Default login credentials: `admin` / `1423`

## Quick Start

### Prerequisites

- Ansible 2.14+ on the control node
- Ansible collections: `community.general`, `ansible.posix` (`ansible-galaxy collection install -r requirements.yml`)
- SSH access to the Pi hosts (user `pi` with sudo)
- Raspberry Pi OS Trixie (arm64) on each target

### Default Run (apt packages)

```bash
ansible-playbook -i inventory-pi5.ini open5gs/playbooks/open5gs.yml
```

This uses the default `open5gs_install_method: "apt"`, which installs pre-built packages from the OBS repository.

### Source Compilation

Override the install method at runtime:

```bash
ansible-playbook -i inventory-pi5.ini open5gs/playbooks/open5gs.yml \
  -e open5gs_install_method=source
```

Or set it permanently in `group_vars/core.yml`:

```yaml
open5gs_install_method: "source"
```

### Pin a Specific Version (source only)

```bash
ansible-playbook -i inventory-pi5.ini open5gs/playbooks/open5gs.yml \
  -e open5gs_install_method=source \
  -e open5gs_source_version=v2.7.7
```

## Configuration Reference

Variables are split across the top-level `group_vars/` directory. Open5GS-specific settings are in `group_vars/core.yml`; shared settings (Docker, pi_user) are in `group_vars/all.yml`. Key settings:

### Docker Settings

| Variable | Default | Description |
|---|---|---|
| `docker_packages` | Docker CE stack + `python3-docker` | APT packages to install |
| `docker_repo_arch` | `"arm64"` | Architecture for the Docker apt repository |
| `pi_user` | `"pi"` | User added to the `docker` group |

### MongoDB Settings

| Variable | Default | Description |
|---|---|---|
| `open5gs_mongo_image_pi4` | `mongodb/mongodb-community-server:4.4.3-ubuntu2004` | Docker image for Pi 4 (ARMv8.0-A; last build without ARMv8.1-A LSE atomics) |
| `open5gs_mongo_image_pi5` | `mongo:7.0` | Docker image for Pi 5 (ARMv8.2-A) |
| `open5gs_mongo_port` | `27017` | Host port published for MongoDB |

### Installation Method

| Variable | Default | Description |
|---|---|---|
| `open5gs_install_method` | `"apt"` | `"apt"` for OBS packages, `"source"` for compilation |

### Apt Settings

| Variable | Default | Description |
|---|---|---|
| `open5gs_obs_key_url` | OBS Raspbian_13 Release.key URL | GPG key for the repository |
| `open5gs_obs_repo_url` | OBS Raspbian_13 URL | APT repository base URL |

### Source Settings

| Variable | Default | Description |
|---|---|---|
| `open5gs_source_repo` | `https://github.com/open5gs/open5gs` | Git repository URL |
| `open5gs_source_version` | `v2.7.7` | Git tag or branch to build |
| `open5gs_source_dir` | `/usr/local/src/open5gs` | Clone destination on the Pi |
| `open5gs_source_prefix` | `/usr/local` | Meson `--prefix` for install paths |

### Common Settings

| Variable | Default | Description |
|---|---|---|
| `open5gs_user` | `"open5gs"` | System user for running NF daemons |
| `open5gs_group` | `"open5gs"` | System group for the above user |
| `open5gs_tun_name` | `"ogstun"` | TUN device interface name |
| `open5gs_tun_addr_v4` | `10.45.0.1/16` | IPv4 address on the TUN device |
| `open5gs_tun_addr_v6` | `2001:db8:cafe::1/48` | IPv6 address on the TUN device |
| `open5gs_nf_services` | 5G SA core set (11 NFs) | List of systemd services to enable/start |

### Networking

| Variable | Default | Description |
|---|---|---|
| `open5gs_ran_addr` | `10.53.1.1` | RAN-facing IP for AMF (NGAP) and UPF (GTP-U) |
| `open5gs_ran_prefix` | `24` | CIDR prefix length for the RAN subnet |
| `open5gs_ue_pool_v4` | `10.45.0.0/16` | UE IPv4 subnet (used in NAT masquerade rule) |

### WebUI Settings

| Variable | Default | Description |
|---|---|---|
| `open5gs_webui_source_dir` | `/usr/local/src/open5gs` | Directory where Open5GS repo is cloned for WebUI Docker build |
| `open5gs_webui_port` | `9999` | Port on which the WebUI Docker container listens |

### NF Services

The default `open5gs_nf_services` list enables the 5G SA core:

```yaml
open5gs_nf_services:
  - open5gs-nrfd
  - open5gs-scpd
  - open5gs-amfd
  - open5gs-smfd
  - open5gs-upfd
  - open5gs-ausfd
  - open5gs-udmd
  - open5gs-udrd
  - open5gs-pcfd
  - open5gs-nssfd
  - open5gs-bsfd
```

To also run 4G EPC functions, add the relevant services:

```yaml
open5gs_nf_services:
  # 5G SA core
  - open5gs-nrfd
  - open5gs-scpd
  - open5gs-amfd
  - open5gs-smfd
  - open5gs-upfd
  - open5gs-ausfd
  - open5gs-udmd
  - open5gs-udrd
  - open5gs-pcfd
  - open5gs-nssfd
  - open5gs-bsfd
  # 4G EPC
  - open5gs-mmed
  - open5gs-sgwcd
  - open5gs-sgwud
  - open5gs-hssd
  - open5gs-pcrfd
```

## Apt vs Source: Comparison

For a detailed analysis of how the two installation methods differ at the
system level (binary paths, service file locations, library paths, config
ownership, switching between methods, and clean removal), see
[`OPEN5GS_INSTALL_METHODS.md`](../OPEN5GS_INSTALL_METHODS.md).

| Factor | Apt Packages | Source Compilation |
|---|---|---|
| Deploy time | Seconds | 20-40+ minutes per Pi |
| Build dependencies | None | ~15 dev libraries + meson/ninja/gcc |
| systemd units | Auto-installed | Copied from build directory |
| Config files | Pre-installed to `/etc/open5gs/` | Installed by `ninja install` |
| TUN device | Handled by this playbook (both methods) | Same |
| Upgrades | `apt upgrade` | Git pull + rebuild |
| Customization | Limited to config changes | Full source-level control |
| Disk footprint | Runtime only | Runtime + build tree |

## Health-Check Tool

The playbook deploys a health-check script to `/usr/local/bin/open5gs_check` on the target Pi. Run it after deployment to verify the entire stack is operational:

```bash
# On the Pi (requires root for Docker and ss):
sudo open5gs_check
```

The script checks:

- **systemd services** -- is each NF (NRF, SCP, AMF, SMF, UPF, AUSF, UDM, UDR, PCF, NSSF, BSF) active?
- **SBI ports** -- is TCP 7777 listening on each NF's loopback address?
- **Non-SBI ports** -- AMF NGAP (SCTP 38412), SMF PFCP (UDP 8805), UPF PFCP + GTP-U (UDP 8805, 2152). NGAP and GTP-U addresses are read from the config files (supports both loopback and RAN-facing addresses).
- **IP forwarding & NAT** -- is IPv4 forwarding enabled? Are the nftables NAT rules loaded?
- **RAN backhaul** -- is the RAN-facing address present on a network interface?
- **MongoDB** -- is the Docker container running and TCP 27017 accepting connections?
- **TUN device** -- is `ogstun` present and up?
- **Grafana stack** -- Telegraf, InfluxDB, and Grafana containers running (only checked if deployed on this host)

Exit code 0 means all checks passed; exit code 1 means one or more failed.

The source script lives at `tools/check_status.sh` in this repository.
