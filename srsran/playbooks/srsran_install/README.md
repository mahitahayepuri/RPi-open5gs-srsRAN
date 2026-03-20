# srsRAN Install Playbooks

Sub-playbooks that handle the complete srsRAN Project gNB build, installation, configuration, and Grafana metrics deployment. These are orchestrated by `main.yml` and imported from the top-level `srsran/playbooks/srsran.yml` as **Stage 4** of the pipeline.

## Position in the Pipeline

```
srsran.yml (top-level)
  Stage 1: preflight         (from common/)
  Stage 2: alias             (preflight_pass -> candidate)
  Stage 3: pi_setup          (from common/)
  Stage 4: srsran_install/main.yml   <-- this directory
             -> build_deps.yml        [hosts: candidate:&gnb]
             -> compile.yml           [hosts: candidate:&gnb]
             -> install.yml           [hosts: candidate:&gnb]
             -> network.yml           [hosts: candidate:&gnb]
             -> grafana.yml           [hosts: grafana]
```

## Playbook Descriptions

### main.yml

Orchestrator that imports the five sub-playbooks in order. This is the entry point imported by `srsran.yml`.

### build_deps.yml

**Hosts:** `candidate:&gnb` (gNB Pi)

Installs all build dependencies via apt:

- Required: cmake, gcc/g++, libfftw3-dev, libmbedtls-dev, libsctp-dev, libyaml-cpp-dev, libgtest-dev, libzmq3-dev, libuhd-dev, uhd-host, linux-cpupower
- Optional: ninja-build, ccache, libpcap-dev
- Downloads UHD FPGA/firmware images via `uhd_images_downloader`

Both ZMQ and UHD libraries are always installed so that switching RF drivers is a runtime config change.

### compile.yml

**Hosts:** `candidate:&gnb` (gNB Pi)

Clones and compiles srsRAN Project from source:

- Shallow-clones the git repository
- Detects Pi model and selects the appropriate `-DMTUNE` cmake variable (`cortex-a72` for Pi 4, `cortex-a76` for Pi 5)
- Configures with cmake -- both ZMQ and UHD drivers are always enabled (`-DENABLE_ZEROMQ=ON -DENABLE_UHD=ON`)
- Compiles with `async` + `poll` to handle long builds without SSH timeouts (30-60 min on Pi 4, 15-30 min on Pi 5)

### install.yml

**Hosts:** `candidate:&gnb` (gNB Pi)

Installs and configures the gNB:

- Runs `make install` and `ldconfig`
- Deploys udev rules for USB SDR devices (Ettus B200/B210)
- Sets `cap_sys_nice` on the `gnb` binary for real-time scheduling
- Applies performance tuning (mirrors upstream `scripts/srsran_performance`):
  - Deploys a systemd oneshot service (`cpupower-governor.service`) that sets CPU governor to `performance` via `cpupower frequency-set -g performance`
  - DRM KMS polling disabled
  - Network buffer tuning (optional, for Ethernet USRPs)
- Deploys the gNB configuration file (`/etc/srsran/gnb.yml`) with:
  - AMF connection settings
  - RF driver config (ZMQ or UHD, selected by `srsran_rf_driver`)
  - Cell parameters (ARFCN, band, bandwidth, PLMN, TAC)
  - Metrics endpoint (JSON-over-TCP on port 55555 for `release_24_10_1`)
- Deploys a systemd service (`srsran-gnb`) -- enabled but not started

### network.yml

**Hosts:** `candidate:&gnb` (gNB Pi)

Configures the RAN-facing network address so the gNB can reach the Open5GS core:

- Adds `srsran_gnb_bind_addr` (default `10.53.1.2/24`) as a secondary IP on the physical NIC via a persistent systemd oneshot service
- The gNB binds on this address for N2 (NGAP/SCTP to AMF) and N3 (GTP-U to UPF)

### grafana.yml

**Hosts:** `grafana` (Open5GS Pi -- separate from the gNB Pi)

Deploys the upstream srsRAN Grafana metrics stack as Docker containers:

- Clones the srsRAN repository on the Grafana host to get the `docker/` directory (Dockerfiles, pre-built dashboards, Telegraf config)
- Templates a `.env` file pointing Telegraf's WebSocket URL at the gNB Pi's IP address
- Builds and starts three containers via Docker CLI commands:
  - **Telegraf** -- connects to the gNB's metrics WebSocket, parses JSON metrics
  - **InfluxDB 3 Core** -- in-memory time-series database
  - **Grafana** -- pre-provisioned dashboards (home, CU-CP, NGAP, RRC, OFH, performance) on port 3300

## Running Standalone

### Full pipeline (recommended)

```bash
ansible-playbook -i inventory-pi5.ini srsran/playbooks/srsran.yml
```

### Individual sub-playbooks

The `build_deps.yml`, `compile.yml`, and `install.yml` playbooks target the `candidate` group, which is created at runtime by preflight. They cannot be run standalone without first running the preflight stage.

To re-run from a specific point:

```bash
# Re-run from compile step onwards:
ansible-playbook -i inventory-pi5.ini srsran/playbooks/srsran.yml \
  --start-at-task="Clone srsRAN Project repository"
```

### Grafana standalone

The `grafana.yml` playbook targets the `[grafana]` inventory group (not `candidate`), so it **can** be run independently:

```bash
ansible-playbook -i inventory-pi5.ini srsran/playbooks/srsran_install/grafana.yml
```

This is useful for redeploying or updating the Grafana stack without rebuilding srsRAN.

### Switch RF driver without recompile

Since both ZMQ and UHD are always compiled in, switching drivers only requires redeploying the config:

```bash
# Switch to UHD:
ansible-playbook -i inventory-pi5.ini srsran/playbooks/srsran.yml \
  -e srsran_rf_driver=uhd

# Switch back to ZMQ:
ansible-playbook -i inventory-pi5.ini srsran/playbooks/srsran.yml \
  -e srsran_rf_driver=zmq
```

## Configuration

All variables are defined in `group_vars/gnb.yml` (srsRAN-specific) and `group_vars/all.yml` (shared). See the project-level `srsran/README.md` for the full variable reference.
