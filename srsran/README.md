# srsRAN Ansible Playbooks

Ansible automation for building and deploying a 5G gNB (srsRAN Project) on Raspberry Pi 4 and Pi 5 units running Raspberry Pi OS based on Debian 13 (Trixie) arm64.

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
└── srsran/
    ├── tools/
    │   └── check_status.sh                        # Health-check script (deployed to Pi as srsran_check)
    └── playbooks/
        ├── srsran.yml                             # Top-level entrypoint
        └── srsran_install/
            ├── main.yml                           # Entry point - imports all install sub-plays
            ├── build_deps.yml                     # Install build dependencies via apt
            ├── compile.yml                        # Clone repo, cmake configure, compile (async)
            ├── install.yml                        # Install binaries, deploy config + systemd service
            ├── network.yml                        # RAN backhaul secondary IP assignment
            └── grafana.yml                        # Deploy Grafana metrics stack on [grafana] host
```

## Pipeline Stages

The top-level `playbooks/srsran.yml` runs six stages in order:

### 1. Preflight (shared from `common/`)

Validates every host in the `[gnb]` inventory group (part of the `[rpi]` parent group) against three criteria:

- **Memory** -- at least 4 GB RAM (8 GB strongly recommended for srsRAN)
- **Model** -- Raspberry Pi 4 or newer (matched via Device Tree)
- **OS** -- Raspberry Pi OS based on Debian 13 (Trixie) with the official `archive.raspberrypi.com` APT source

Hosts that pass are dynamically grouped as `preflight_pass`, then aliased to `candidate`. Hosts that fail are skipped.

### 2. Pi Setup (shared from `common/`)

Hardens each candidate Pi for headless server use:

- Adds `dtoverlay=disable-wifi` and `dtoverlay=disable-bt` to `/boot/firmware/config.txt`, rebooting only if changes were made.
- Disables VNC, SPI, I2C, and 1-Wire via `raspi-config nonint` commands.

### 3. Build Dependencies

Installs all packages required for compilation, including both ZMQ and UHD libraries so that both RF drivers are always available at runtime:

- **Required:** cmake, gcc/g++, libfftw3-dev, libmbedtls-dev, libsctp-dev, libyaml-cpp-dev, libgtest-dev, libzmq3-dev, libuhd-dev, uhd-host, linux-cpupower
- **Optional:** ninja-build, ccache, libpcap-dev
- Runs `uhd_images_downloader` to fetch USRP FPGA/firmware images

### 4. Compile and Install

- Clones the srsRAN Project repository
- Configures with cmake (auto-selects `-DMTUNE=cortex-a72` for Pi 4, `-DMTUNE=cortex-a76` for Pi 5)
- **Both ZMQ and UHD drivers are always compiled in** -- switching RF driver is a runtime config change (no recompile)
- Compiles with `async` + `poll` to handle the long build (30-60 min on Pi 4, 15-30 min on Pi 5)
- Installs binaries to the configured prefix
- Deploys udev rules for USB SDR devices (Ettus B200/B210)
- Sets `cap_sys_nice` on the `gnb` binary for real-time scheduling without root
- Applies performance tuning from the upstream `scripts/srsran_performance` script:
  - Deploys a systemd oneshot service (`cpupower-governor.service`) that sets CPU governor to `performance` via `cpupower frequency-set -g performance`
  - Disables DRM KMS polling (reduces CPU overhead from GPU display polling)
  - Optionally tunes network buffers to 32 MB (for Ethernet-connected USRPs)
- Deploys a gNB configuration file and a systemd service (`srsran-gnb`)
- Enables the service but does **not** start it (requires AMF connectivity)

### 5. Networking

Configures the RAN backhaul address so the gNB can reach the Open5GS core over a dedicated point-to-point subnet (`10.53.1.0/24`):

- Deploys a persistent systemd oneshot service that adds `srsran_gnb_bind_addr` (default `10.53.1.2/24`) as a secondary IP on the physical NIC
- The gNB uses this address for N2 (NGAP/SCTP to AMF) and N3 (GTP-U to UPF)

> **Note:** Firewall rules are documented in [`FIREWALL.md`](../FIREWALL.md) at the repository root but not enforced by the playbooks, allowing operators to adapt them to their environment.

### 6. Grafana Metrics Dashboard

> **Note:** The Grafana stack is currently disabled pending rework for
> `release_24_10_1`'s metrics architecture.  See `main.yml` TODO comment.

Deploys the upstream srsRAN Grafana metrics stack on the `[grafana]` host (typically the Open5GS Pi):

- Clones the srsRAN repository to get the `docker/` directory (Dockerfiles, dashboards, metrics configs)
- In `release_24_10_1`: the gNB exposes a JSON metrics endpoint on TCP port 55555; a `metrics_server` container connects to it and writes to InfluxDB 2.7
- In `release_25_10`+: the gNB exposes a WebSocket on port 8001 and Telegraf connects to it, writing to InfluxDB 3
- Grafana serves pre-provisioned dashboards on port 3300

## Quick Start

### Prerequisites

- Ansible 2.14+ on the control node
- Ansible collections: `community.general`, `ansible.posix` (`ansible-galaxy collection install -r requirements.yml`)
- SSH access to the Pi hosts (user `pi` with sudo)
- Raspberry Pi OS Trixie (arm64) on each target
- A running 5G core (Open5GS) with AMF reachable from the gNB Pi

### Default Run (ZMQ testing mode)

```bash
ansible-playbook -i inventory-pi5.ini srsran/playbooks/srsran.yml
```

This builds srsRAN with both ZMQ and UHD drivers. The default config uses ZeroMQ for testing without SDR hardware.

### Switch to UHD (USB SDR like B200/B210)

No recompile needed -- just change the RF driver variable:

```bash
ansible-playbook -i inventory-pi5.ini srsran/playbooks/srsran.yml \
  -e srsran_rf_driver=uhd
```

This redeploys the gNB config to use UHD. You can also set UHD-specific parameters:

```bash
ansible-playbook -i inventory-pi5.ini srsran/playbooks/srsran.yml \
  -e srsran_rf_driver=uhd \
  -e srsran_uhd_device_args=type=b200 \
  -e srsran_uhd_tx_gain=50 \
  -e srsran_uhd_rx_gain=60
```

### Switch back to ZMQ

```bash
ansible-playbook -i inventory-pi5.ini srsran/playbooks/srsran.yml \
  -e srsran_rf_driver=zmq
```

### Pin a specific version

```bash
ansible-playbook -i inventory-pi5.ini srsran/playbooks/srsran.yml \
  -e srsran_source_version=release_24_10
```

### Start the gNB after deployment

The playbook enables but does not start the gNB service (it needs an AMF to connect to). Once your Open5GS core is running:

```bash
# On the Pi:
sudo systemctl start srsran-gnb

# Or via Ansible:
ansible -i inventory-pi5.ini gnb -b -m systemd -a "name=srsran-gnb state=started"
```

## Configuration Reference

Variables are split across the top-level `group_vars/` directory. srsRAN-specific settings are in `group_vars/gnb.yml`; shared settings are in `group_vars/all.yml`.

### Build Settings

| Variable | Default | Description |
|---|---|---|
| `srsran_source_repo` | `https://github.com/srsRAN/srsRAN_Project.git` | Git repository URL |
| `srsran_source_version` | `main` | Git tag or branch to build |
| `srsran_source_dir` | `/usr/local/src/srsRAN_Project` | Clone destination on the Pi |
| `srsran_install_prefix` | `/usr/local` | CMake install prefix |
| `srsran_cmake_build_type` | `Release` | CMake build type |
| `srsran_build_jobs` | `0` (auto/nproc) | Parallel jobs for make |
| `srsran_build_timeout` | `7200` | Async timeout in seconds (2 hours) |
| `srsran_cmake_extra_flags` | `""` | Extra flags appended to cmake command |

### Performance Tuning

| Variable | Default | Description |
|---|---|---|
| `srsran_set_realtime_cap` | `true` | Set `cap_sys_nice` on the gnb binary |
| `srsran_cpu_governor` | `performance` | CPU scaling governor for real-time use |
| `srsran_disable_kms_polling` | `true` | Disable DRM KMS polling to save CPU |
| `srsran_tune_network_buffers` | `false` | Set 32 MB network buffers (for Ethernet USRPs) |

### gNB Configuration

| Variable | Default | Description |
|---|---|---|
| `srsran_gnb_id` | `1` | gNB ID |
| `srsran_gnb_name` | `srsgnb01` | RAN node name |
| `srsran_amf_addr` | `10.53.1.1` | AMF IP address (Open5GS) |
| `srsran_gnb_bind_addr` | `10.53.1.2` | gNB bind address for N2/N3 interfaces |
| `srsran_ran_prefix` | `24` | CIDR prefix for the RAN backhaul subnet |
| `srsran_rf_driver` | `zmq` | RF driver (`zmq` or `uhd`) |
| `srsran_cell_dl_arfcn` | `368500` | Downlink ARFCN (~1.8 GHz, band n3) |
| `srsran_cell_band` | `3` | NR band |
| `srsran_cell_bandwidth_mhz` | `10` | Channel bandwidth in MHz |
| `srsran_cell_common_scs` | `15` | Common subcarrier spacing (kHz) |
| `srsran_cell_plmn` | `00101` | PLMN identity (derived from `open5gs_mcc` + `open5gs_mnc` in `group_vars/all.yml`) |
| `srsran_cell_tac` | `7` | Tracking Area Code (derived from `open5gs_tac` in `group_vars/all.yml`) |

### RF Driver Settings

Both ZMQ and UHD drivers are always compiled in. Set `srsran_rf_driver` to switch between them at runtime (no recompile).

#### ZMQ settings (used when `srsran_rf_driver == "zmq"`)

| Variable | Default | Description |
|---|---|---|
| `srsran_zmq_tx_port` | `tcp://127.0.0.1:2000` | ZMQ TX port |
| `srsran_zmq_rx_port` | `tcp://127.0.0.1:2001` | ZMQ RX port |

#### UHD settings (used when `srsran_rf_driver == "uhd"`)

| Variable | Default | Description |
|---|---|---|
| `srsran_uhd_device_args` | `""` (auto-detect) | UHD device args (e.g. `type=b200`) |
| `srsran_uhd_clock` | `internal` | Clock source: `internal`, `external`, `gpsdo` |
| `srsran_uhd_sync` | `internal` | Time source: `internal`, `external`, `gpsdo` |
| `srsran_uhd_otw_format` | `sc12` | Over-the-wire format (`sc12` saves USB bandwidth) |
| `srsran_uhd_tx_gain` | `50` | TX gain |
| `srsran_uhd_rx_gain` | `60` | RX gain |
| `srsran_uhd_srate` | `23.04` | Sample rate in MHz |

### Metrics & Grafana

| Variable | Default | Description |
|---|---|---|
| `srsran_metrics_enable` | `true` | Enable JSON metrics endpoint on the gNB |
| `srsran_metrics_bind_addr` | `0.0.0.0` | gNB metrics bind address |
| `srsran_metrics_port` | `55555` | TCP port for JSON metrics |
| `srsran_grafana_source_dir` | `/opt/srsran-metrics` | Clone destination for docker/ on the Grafana host |
| `srsran_grafana_gnb_addr` | `10.53.1.2` | gNB RAN backhaul IP (metrics_server connects here) |
| `srsran_grafana_port` | `3300` | Grafana UI port on the host |

## Raspberry Pi Performance Notes

| Factor | Raspberry Pi 4 | Raspberry Pi 5 |
|---|---|---|
| CPU | Cortex-A72 4x1.8 GHz | Cortex-A76 4x2.4 GHz |
| Build time | 30-60+ minutes | 15-30 minutes |
| Realistic bandwidth | Up to ~10 MHz | Up to ~10-20 MHz |
| RAM recommendation | 8 GB | 4 GB minimum, 8 GB preferred |
| Compiler flags | `-DMTUNE=cortex-a72` (auto) | `-DMTUNE=cortex-a76` (auto) |
| NEON SIMD | Yes (automatic) | Yes (automatic) |

**Important:** Active cooling (fan + heatsink) is essential for sustained PHY processing. An uncooled Pi will thermal-throttle.

## Health-Check Tool

The playbook deploys a health-check script to `/usr/local/bin/srsran_check` on the gNB Pi. Run it after deployment to verify the system is ready:

```bash
# On the Pi:
sudo srsran_check
```

The script checks:

- **gNB service** -- systemd unit status (enabled/active)
- **gNB binary** -- exists at the install prefix and has `cap_sys_nice` set
- **Configuration** -- gNB config file present, detects RF driver and AMF address
- **Performance tuning** -- CPU governor set to `performance`, DRM KMS polling disabled, network buffer sizes
- **RF driver** -- if UHD: firmware images present, USB SDR detected (`uhd_find_devices`), udev rules deployed; if ZMQ: library present
- **AMF connectivity** -- ping reachability and NGAP port (SCTP 38412) on the configured AMF address
- **Metrics endpoint** -- port 55555 listening (when gNB is running)

Exit code 0 means all checks passed; exit code 1 means one or more failed. Warnings (yellow) indicate non-critical items like the gNB not yet started or network buffers at default values.

The source script lives at `tools/check_status.sh` in this repository.
