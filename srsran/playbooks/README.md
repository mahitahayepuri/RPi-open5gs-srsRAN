# srsRAN Playbooks

Top-level Ansible playbooks for building and deploying the srsRAN Project gNB (5G base station) on Raspberry Pi 4/5, with an optional Grafana metrics dashboard.

## Entry Point

```bash
ansible-playbook -i inventory-pi5.ini srsran/playbooks/srsran.yml
```

## Pipeline Stages

`srsran.yml` orchestrates the full deployment in four stages:

| Stage | Playbook | Hosts | Description |
|---|---|---|---|
| 1 | `../../common/playbooks/preflight/main.yml` | `rpi` | Validates Pi model (>= Pi 4), memory (>= 4 GB), and OS (Trixie). Groups passing hosts into `preflight_pass`. |
| 2 | *(inline play)* | `preflight_pass` | Aliases `preflight_pass` to `candidate` for downstream plays |
| 3 | `../../common/playbooks/pi_setup.yml` | `rpi` | Disables Wi-Fi, Bluetooth, VNC, SPI, I2C, 1-Wire for headless operation |
| 4 | `srsran_install/main.yml` | `candidate` / `grafana` | Full srsRAN build, install, and metrics deployment (see `srsran_install/README.md`) |

Stage 4 breaks down further into:

| Sub-stage | Playbook | Hosts | What it does |
|---|---|---|---|
| 4a | `build_deps.yml` | `candidate` | Installs build dependencies + UHD firmware |
| 4b | `compile.yml` | `candidate` | Clones and compiles srsRAN with ZMQ + UHD support |
| 4c | `install.yml` | `candidate` | Installs binaries, deploys gNB config, performance tuning, systemd service |
| 4d | `network.yml` | `candidate` | Assigns RAN backhaul secondary IP (`10.53.1.2/24`) on the physical NIC |
| 4e | `grafana.yml` | `grafana` | Deploys metrics stack via Docker CLI (**currently disabled** — needs rework for 24_10_1) |

## Configuration

srsRAN variables are in `group_vars/gnb.yml`; shared variables are in `group_vars/all.yml`. Key settings:

| Variable | Default | Description |
|---|---|---|
| `srsran_rf_driver` | `"zmq"` | RF driver to use at runtime (`"zmq"` or `"uhd"`) |
| `srsran_source_version` | `"release_24_10_1"` | Git branch/tag to build (see [`VERSION_PINNING.md`](../../VERSION_PINNING.md)) |
| `srsran_cell_band` | `3` | NR operating band |
| `srsran_cell_bandwidth_mhz` | `10` | Channel bandwidth in MHz |
| `srsran_amf_addr` | `"10.53.1.1"` | Open5GS AMF IP on the RAN backhaul subnet |
| `srsran_gnb_bind_addr` | `"10.53.1.2"` | gNB IP on the RAN backhaul subnet |
| `srsran_ran_prefix` | `24` | CIDR prefix for the RAN backhaul subnet |
| `srsran_metrics_enable` | `true` | Enable JSON metrics endpoint on gNB |
| `srsran_grafana_port` | `3300` | Grafana web UI port |

Both ZMQ and UHD drivers are always compiled in. Switching between them is a runtime-only config change -- no recompile needed.

## Inventory Groups

The inventory file (e.g. `inventory-pi5.ini`) defines groups used by srsRAN:

- `[gnb]` -- gNB Raspberry Pi (target for build/install)
- `[core]` -- Open5GS core Pi
- `[rpi:children]` -- parent group containing `core` and `gnb`
- `[grafana:children]` -- contains `core` (Grafana metrics stack runs on the Open5GS Pi)

## Prerequisites

- Raspberry Pi 4 or 5 running Raspberry Pi OS (Debian 13 Trixie)
- SSH access configured in `inventory-pi5.ini` (or `inventory-pi4.ini`)
- `ansible.posix` Ansible collection installed (for `sysctl` module in networking)
- Docker installed on the `[grafana]` host (handled by the Open5GS pipeline if running on the same Pi)

## Directory Structure

```
srsran/playbooks/
  srsran.yml                   # Top-level entry point
  srsran_install/
    main.yml                   # Install pipeline orchestrator
    build_deps.yml             # Build dependency installation
    compile.yml                # Clone + cmake + compile
    install.yml                # Install, config, tuning, systemd
    network.yml                # RAN backhaul secondary IP assignment
    grafana.yml                # Grafana metrics stack deployment
    README.md                  # Detailed sub-playbook docs
```
