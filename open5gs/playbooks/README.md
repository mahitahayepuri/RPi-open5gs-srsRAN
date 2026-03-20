# Open5GS Playbooks

Top-level Ansible playbooks for deploying the Open5GS 5G SA core network on Raspberry Pi 4/5.

## Entry Point

```bash
ansible-playbook -i inventory-pi5.ini open5gs/playbooks/open5gs.yml
```

## Pipeline Stages

`open5gs.yml` orchestrates the full deployment in four stages:

| Stage | Playbook | Hosts | Description |
|---|---|---|---|
| 1 | `../../common/playbooks/preflight/main.yml` | `rpi` | Validates Pi model (>= Pi 4), memory (>= 4 GB), and OS (Trixie). Groups passing hosts into `preflight_pass`. |
| 2 | *(inline play)* | `preflight_pass` | Aliases `preflight_pass` to `candidate` for downstream plays |
| 3 | `../../common/playbooks/pi_setup.yml` | `rpi` | Disables Wi-Fi, Bluetooth, VNC, SPI, I2C, 1-Wire for headless operation |
| 4 | `open5gs_install/main.yml` | `candidate` | Full Open5GS installation (see `open5gs_install/README.md`) |

Stage 4 breaks down further into eight sub-stages:

| Sub-stage | Playbook | What it does |
|---|---|---|
| 4a | `docker.yml` | Installs Docker CE from official repo |
| 4b | `mongodb.yml` | Runs MongoDB in Docker (4.4 on Pi 4, 7.0 on Pi 5) |
| 4c | `tun_setup.yml` | Creates `ogstun` TUN device via systemd-networkd |
| 4d | `install.yml` | Installs Open5GS NF packages individually via apt (OBS repo) or source build |
| 4e | `network.yml` | RAN backhaul address, IP forwarding, NAT masquerade, config patching |
| 4f | `logging.yml` | Deploys rsyslog config for per-NF log splitting to `/var/log/open5gs/<nf>.log` |
| 4g | `services.yml` | Enables and starts all 11 NF services |
| 4h | `webui.yml` | Deploys Open5GS WebUI as Docker container on port 9999 |

## Configuration

Open5GS variables are in `group_vars/core.yml`; shared variables (Docker, pi_user) are in `group_vars/all.yml`. Key settings:

| Variable | Default | Description |
|---|---|---|
| `open5gs_install_method` | `"apt"` | `"apt"` for OBS packages (fast), `"source"` for git build |
| `pi_user` | `"pi"` | User added to the docker group |
| `open5gs_mongo_port` | `27017` | MongoDB listen port |
| `open5gs_tun_addr_v4` | `10.45.0.1/16` | UPF TUN device IPv4 address |
| `open5gs_tun_addr_v6` | `2001:db8:cafe::1/48` | UPF TUN device IPv6 address |
| `open5gs_ran_addr` | `10.53.1.1` | Open5GS RAN backhaul IP (AMF NGAP + UPF GTP-U) |
| `open5gs_ran_prefix` | `24` | CIDR prefix for the RAN backhaul subnet |
| `open5gs_ue_pool_v4` | `10.45.0.0/16` | UE traffic pool (NAT masquerade source) |

## Prerequisites

- Raspberry Pi 4 or 5 running Raspberry Pi OS (Debian 13 Trixie)
- SSH access configured in `inventory-pi5.ini` (or `inventory-pi4.ini`)
- `ansible.posix` Ansible collection installed (for `sysctl` module in networking)

## Directory Structure

```
open5gs/playbooks/
  open5gs.yml                  # Top-level entry point
  open5gs_install/
    main.yml                   # Install pipeline orchestrator
    docker.yml                 # Docker CE installation
    mongodb.yml                # MongoDB container deployment
    tun_setup.yml              # ogstun TUN device setup
    install.yml                # Open5GS install dispatcher (apt/source)
    network.yml                # RAN backhaul, IP forwarding, NAT, config patching
    logging.yml                # rsyslog per-NF log splitting
    services.yml               # NF service enablement
    webui.yml                  # Open5GS WebUI Docker deployment
    tasks/
      install_apt.yml          # APT install path (individual NF packages)
      install_source.yml       # Source build install path
    README.md                  # Detailed sub-playbook docs
```
