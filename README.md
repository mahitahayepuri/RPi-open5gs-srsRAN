# 5G SA Network on Raspberry Pi

Ansible automation for deploying a private 5G Standalone (SA) network on
Raspberry Pi 4 and Pi 5 hardware running Raspberry Pi OS (Debian 13 Trixie,
arm64).

The project deploys two components across two Pis:

- **Open5GS** -- 5G SA core network (AMF, SMF, UPF, NRF, and 8 other network functions)
- **srsRAN Project** -- 5G gNB (base station) with ZMQ and UHD RF driver support

## How it works

[Ansible](https://docs.ansible.com/ansible/latest/index.html) is a
configuration-management tool that automates tasks on remote machines over
SSH. You run Ansible commands on your own computer (the **control node**)
and it connects to the Raspberry Pis (the **targets**) to install software,
copy files, and configure services. You never need to log in to the Pis
manually -- Ansible does everything for you.

```
┌──────────────┐         SSH         ┌──────────────────────────┐
│ Your computer│─────────────────────│  Raspberry Pi #1 (core)  │
│ (control     │                     │  Open5GS 5G Core         │
│  node)       │         SSH         ├──────────────────────────┤
│              │─────────────────────│  Raspberry Pi #2 (gnb)   │
│ Ansible runs │                     │  srsRAN gNB              │
│ here         │                     │                          │
└──────────────┘                     └──────────────────────────┘
```

After deployment, the two Pis communicate over a dedicated RAN backhaul
subnet (default addresses shown; see note below):

```
┌─────────────────────────┐   N2/N3 (10.53.x.0/24)  ┌─────────────────────────┐
│    Raspberry Pi #1      │◄──────────────────────►│    Raspberry Pi #2      │
│    10.53.x.1            │      NGAP + GTP-U       │    10.53.x.2            │
│                         │                        │                         │
│  Open5GS 5G Core        │                        │  srsRAN gNB             │
│  ├─ 11 NF services      │                        │  ├─ gnb binary          │
│  ├─ MongoDB (Docker)    │                        │  └─ ZMQ or UHD RF       │
│  ├─ WebUI (Docker :9999)│                        │                         │
│  ├─ ogstun TUN device   │                        │                         │
│  │  └─ NAT (nftables)   │                        │                         │
│  └─ Grafana metrics     │◄── JSON :55555 ──────│  (metrics source)       │
│     ├─ metrics_server   │                        │                         │
│     ├─ InfluxDB 2       │                        │                         │
│     └─ Grafana :3300     │                        │                         │
└─────────────────────────┘                        └─────────────────────────┘
```

> **RAN subnet addresses:** The default RAN backhaul subnet is `10.53.1.0/24`
> (defined in `group_vars/`).  The provided inventory files override these
> per Pi model to prevent IP conflicts when multiple pairs share the same LAN:
> `inventory-pi4.ini` uses `10.53.4.x`, `inventory-pi5.ini` uses `10.53.5.x`.

## What you need

| Item | Notes |
|---|---|
| 2x Raspberry Pi 4 or 5 | 4 GB RAM minimum, 8 GB recommended |
| 2x microSD cards | 32 GB or larger |
| 2x Ethernet cables | Wi-Fi is disabled by the playbooks |
| A network switch or router | Both Pis and your computer on the same LAN |
| Power supplies | USB-C: 5V/3A (Pi 4), 5V/5A (Pi 5) |
| Active cooling | Fan + heatsink on each Pi (essential for srsRAN) |
| Your computer | Linux, macOS, or Windows (WSL) -- this is where Ansible runs |

## Step 1: Prepare the Raspberry Pis

Each Pi needs Raspberry Pi OS Trixie (64-bit) flashed to its SD card,
with SSH enabled and the `pi` user account created. Both Pis must be
connected to your network via Ethernet.

See **[`PISETUP.md`](PISETUP.md)** for the full walkthrough: flashing the
OS, configuring headless access, and finding IP addresses.

## Step 2: Set up your computer (the Ansible control node)

All `ansible` commands are run on **your computer**, not on the Pis. Ansible
connects to the Pis over SSH to do the work.

### Install Ansible

```bash
pip install ansible          # Python (any OS)
# or
sudo apt install ansible     # Debian/Ubuntu
# or
brew install ansible         # macOS
```

Verify:

```bash
ansible --version            # should show 2.14 or newer
```

### Install required Ansible collections

```bash
ansible-galaxy collection install -r requirements.yml
```

This installs:

- `community.general` -- real-time scheduling capabilities
- `ansible.posix` -- sysctl for IP forwarding

### Set up SSH key access to the Pis

Ansible needs passwordless SSH to the Pis. On your computer:

```bash
# Generate a key pair (skip if you already have ~/.ssh/id_ed25519):
ssh-keygen -t ed25519

# Copy your public key to each Pi:
ssh-copy-id pi@<core-pi-ip>
ssh-copy-id pi@<gnb-pi-ip>
```

### Edit the inventory file

The inventory file tells Ansible which Pi is the core and which is the gNB.
Edit `inventory-pi4.ini` or `inventory-pi5.ini` and replace the IP addresses
with your own:

```ini
[core]
192.168.2.72 ansible_user=pi      # <-- your core Pi's IP

[gnb]
192.168.2.55 ansible_user=pi      # <-- your gNB Pi's IP

[ue:children]
gnb

[rpi:children]
core
gnb

[grafana:children]
core
```

### Test connectivity

```bash
ansible -i inventory-pi5.ini all -m ping
```

You should see green `SUCCESS` for both hosts:

```
192.168.2.72 | SUCCESS => { "ping": "pong" }
192.168.2.55 | SUCCESS => { "ping": "pong" }
```

If you see failures, check that:

- The IP addresses in the inventory match your Pis
- SSH key authentication works: `ssh pi@<ip> hostname` (should print the hostname with no password prompt)
- The Pis are powered on and connected to the network

## Step 3: Deploy

Run these commands on your computer. Deploy the core first -- the srsRAN
pipeline's Grafana stage requires Docker, which is installed by the Open5GS
pipeline.

### Deploy the 5G Core (Open5GS)

```bash
ansible-playbook -i inventory-pi5.ini open5gs/playbooks/open5gs.yml
```

### Deploy the gNB (srsRAN)

```bash
ansible-playbook -i inventory-pi5.ini srsran/playbooks/srsran.yml
```

> **Note:** The srsRAN compilation takes 15-30 minutes on a Pi 5 and
> 30-60+ minutes on a Pi 4. The playbook uses `async` polling so your
> SSH connection won't time out -- just wait for it to finish.

### Verify

SSH into each Pi and run the health-check scripts:

```bash
# On the Open5GS Pi:
sudo open5gs_check

# On the gNB Pi:
sudo srsran_check
```

### Start the gNB

The gNB service is enabled but not started by the playbook (it needs the
AMF to be running first):

```bash
# On the gNB Pi:
sudo systemctl start srsran-gnb
```

### (Optional) Deploy srsUE for ZMQ testing

To test the network end-to-end without radio hardware, deploy the software
UE. This compiles srsUE on the gNB Pi and provisions a test subscriber in
Open5GS:

```bash
ansible-playbook -i inventory-pi5.ini srsue/playbooks/srsue.yml
```

Then follow [`SRSUE.md`](SRSUE.md) to run srsUE and verify the data path.

### (Optional) Automated end-to-end test

After deploying srsUE, run the automated data-path verification:

```bash
ansible-playbook -i inventory-pi5.ini e2e-test-srsue.yml
```

This starts the gNB, attaches srsUE, pings the core Pi through the 5G
network, and reports pass/fail. See [`E2ETEST-SRSUE.md`](E2ETEST-SRSUE.md)
for details and troubleshooting.

## Resetting for a clean re-deploy

To tear down all Open5GS, srsRAN, and srsUE artifacts and return the Pis
to a state where the deployment playbooks can be re-run from scratch:

```bash
ansible-playbook -i inventory-pi5.ini nuke-from-orbit.yml
```

This removes services, packages, configs, Docker containers/volumes/images,
log files, TUN devices, NAT rules, and resets kernel parameters.  It
preserves Pi common setup (boot overlays, pi-monitor, yq), the Docker
engine itself, and build dependencies (gcc, cmake, lib\*-dev) to speed up
re-deployment.

The playbook is idempotent — running it twice is harmless.

## Service Management

Open5GS NFs are grouped under a systemd target for easy control:

```bash
sudo systemctl stop open5gs-stack.target
sudo systemctl start open5gs-stack.target
sudo systemctl restart open5gs-stack.target
```

## Open5GS WebUI

The Open5GS WebUI is deployed as a Docker container on port 9999:

```
http://<core-pi-ip>:9999
```

**Default credentials:** `admin` / `1423`

Use the WebUI to manage subscribers (IMSI, keys), view network status, and configure QoS policies. See [`open5gs/README.md`](open5gs/README.md) for deployment details.

## Logging

Both Pis produce per-component log files via rsyslog:

- **gNB Pi:** `/var/log/srsran/cucp.log`, `cuup.log`, `du.log`, `gnb.log`
- **Core Pi:** `/var/log/open5gs/amf.log`, `smf.log`, `upf.log`, and 8 more NF logs

See [`LOGGING.md`](LOGGING.md) for viewing commands, debugging recipes, and architecture details.

## Changing the PLMN or TAC

The PLMN (MCC + MNC) and TAC must match between the core and gNB. The
defaults are MCC=001, MNC=01, TAC=7 (a standard test network identity).

To change them on a running system without re-running the full pipelines:

```bash
ansible-playbook -i inventory-pi5.ini reconfigure-plmn.yml \
  -e open5gs_mcc=001 -e open5gs_mnc=01 -e open5gs_tac=1
```

This patches `/etc/open5gs/amf.yaml` on the core Pi, `/etc/srsran/gnb.yml`
on the gNB Pi, and (if srsUE has been deployed) the UE config and MongoDB
subscriber record, then restarts the affected services.
Without `-e` overrides it uses the values from `group_vars/all.yml`.

## Changing the RF Band or Bandwidth (UHD only)

When using a real SDR (UHD mode), you can switch the operating band and
bandwidth without re-running the full pipeline:

```bash
# Switch to band n78 (TDD, 3.5 GHz) with 20 MHz bandwidth:
ansible-playbook -i inventory-pi5.ini reconfigure-rf.yml \
  -e rf_band=78 -e rf_bandwidth_mhz=20
```

The playbook auto-calculates the DL ARFCN, subcarrier spacing (15 kHz for
FDD, 30 kHz for TDD), and sample rate. Supported bands:

| Band | Duplex | Frequency | SCS |
|---|---|---|---|
| n3 | FDD | 1805-1880 MHz | 15 kHz |
| n7 | FDD | 2620-2690 MHz | 15 kHz |
| n41 | TDD | 2496-2690 MHz | 30 kHz |
| n77 | TDD | 3300-4200 MHz | 30 kHz |
| n78 | TDD | 3300-3800 MHz | 30 kHz |

### ARFCN and GSCN alignment

5G UEs only scan for cells at **GSCN-aligned frequencies** (3GPP TS 38.104
Table 5.4.3.1-1). The playbook automatically snaps the DL ARFCN to the
nearest valid GSCN position — a non-aligned ARFCN will not be detected by
the UE during cell search.

Three ways to specify the carrier frequency (highest to lowest priority):

```bash
# 1. Exact ARFCN — used as-is, no snapping
ansible-playbook -i inventory-pi5.ini reconfigure-rf.yml \
  -e rf_band=3 -e rf_bandwidth_mhz=10 -e rf_dl_arfcn=368450

# 2. Approximate center frequency in MHz — snapped to nearest GSCN
ansible-playbook -i inventory-pi5.ini reconfigure-rf.yml \
  -e rf_band=3 -e rf_bandwidth_mhz=10 -e rf_center_mhz=1850

# 3. Omit both — uses band center frequency, snapped to nearest GSCN
ansible-playbook -i inventory-pi5.ini reconfigure-rf.yml \
  -e rf_band=3 -e rf_bandwidth_mhz=10
```

The playbook output always shows the final ARFCN and its source, including
the original value when snapping occurred.

This is for UHD mode only -- ZMQ mode uses fixed RF parameters. See
[`RFHARDWARE.md`](RFHARDWARE.md) for SDR setup instructions.

## Directory Structure

```
ansible/
├── ansible.cfg                   # Ansible settings (SSH pipelining, host key checking)
├── inventory-pi4.ini             # Inventory for Raspberry Pi 4 pair
├── inventory-pi5.ini             # Inventory for Raspberry Pi 5 pair
├── group_vars/
│   ├── all.yml                   # Shared variables (locale, boot config, Grafana, PLMN)
│   ├── core.yml                  # Open5GS variables (applied to [core] hosts)
│   ├── gnb.yml                   # srsRAN variables (applied to [gnb] hosts)
│   └── ue.yml                    # srsUE variables (applied to [ue] hosts)
├── requirements.yml              # Ansible Galaxy collection dependencies
├── reconfigure-plmn.yml          # Change PLMN/TAC on a running system
├── reconfigure-rf.yml            # Change RF band/bandwidth/frequency (UHD only)
├── e2e-test-srsue.yml            # Automated end-to-end data-path test (ZMQ + srsUE)
├── nuke-from-orbit.yml           # Reset Pis by removing all deployment artifacts
├── PISETUP.md                    # Raspberry Pi preparation guide
├── GLOSSARY.md                   # Glossary of 5G, networking, and Ansible terms
├── SRSUE.md                      # Setting up srsUE for ZMQ testing
├── E2ETEST-SRSUE.md              # End-to-end test documentation and troubleshooting
├── LOGGING.md                    # Log files, monitoring, and debugging guide
├── RFHARDWARE.md                 # SDR hardware guide (USRP, filters, circulators, safety)
├── SRSRAN_PERFORMANCE.md         # Why we don't use the upstream srsran_performance script
├── SRSRAN_EDITS.md               # Post-deployment source patches (FFTW, ZMQ hang)
├── PRIVATE_SRSRAN_REPO.md        # Deploying from a custom srsRAN fork
├── BE_THE_UE.md                  # Interactive UE testing guide (namespace, iperf, shutdown)
├── CODING_STANDARDS.md           # Project coding and documentation conventions
├── PI_MONITOR.md                 # Raspberry Pi monitoring tool
├── OPEN5GS_INSTALL_METHODS.md    # APT vs source compilation: differences and trade-offs
├── VERSION_PINNING.md            # srsRAN version pins: rationale, overrides, compat matrix
├── FIREWALL.md                   # Firewall port reference & recommended nftables rules
├── common/                       # Shared playbooks (preflight checks, Pi hardening)
│   └── playbooks/
│       ├── preflight/            # Platform validation (model, memory, OS)
│       └── pi_setup.yml          # Disable Wi-Fi, BT, VNC, SPI, I2C, 1-Wire
├── open5gs/                      # Open5GS 5G core deployment
│   ├── files/systemd/            # systemd target + drop-in overrides
│   ├── tools/                    # Health-check script (open5gs_check)
│   └── playbooks/
├── srsran/                       # srsRAN gNB build and deployment
│   ├── tools/                    # Health-check script (srsran_check)
│   └── playbooks/
└── srsue/                        # srsUE software UE for ZMQ testing
    ├── tools/                    # E2E test script (srsue_e2e_test)
    └── playbooks/
```

## Further Reading

| Topic | Location |
|---|---|
| Raspberry Pi preparation (flashing, SSH, networking) | [`PISETUP.md`](PISETUP.md) |
| Glossary of 5G, networking, and Ansible terms | [`GLOSSARY.md`](GLOSSARY.md) |
| Setting up srsUE for ZMQ end-to-end testing | [`SRSUE.md`](SRSUE.md) |
| Automated end-to-end data-path test | [`E2ETEST-SRSUE.md`](E2ETEST-SRSUE.md) |
| Log files, monitoring, and debugging | [`LOGGING.md`](LOGGING.md) |
| SDR hardware, RF safety, filters, and circulators | [`RFHARDWARE.md`](RFHARDWARE.md) |
| srsRAN performance tuning (vs upstream script) | [`SRSRAN_PERFORMANCE.md`](SRSRAN_PERFORMANCE.md) |
| Open5GS APT vs source install paths | [`OPEN5GS_INSTALL_METHODS.md`](OPEN5GS_INSTALL_METHODS.md) |
| Open5GS configuration, install methods, NF services | [`open5gs/README.md`](open5gs/README.md) |
| srsRAN build settings, RF driver switching, performance tuning | [`srsran/README.md`](srsran/README.md) |
| Preflight validation details | [`common/playbooks/preflight/README.md`](common/playbooks/preflight/README.md) |
| Open5GS playbook internals | [`open5gs/playbooks/open5gs_install/README.md`](open5gs/playbooks/open5gs_install/README.md) |
| srsRAN playbook internals | [`srsran/playbooks/srsran_install/README.md`](srsran/playbooks/srsran_install/README.md) |
| srsRAN/srsUE version pins, compatibility, overrides | [`VERSION_PINNING.md`](VERSION_PINNING.md) |
| Firewall ports & recommended nftables rules | [`FIREWALL.md`](FIREWALL.md) |
| Interactive UE testing (namespace, iperf, shutdown) | [`BE_THE_UE.md`](BE_THE_UE.md) |
| Post-deployment source patches (FFTW, ZMQ hang) | [`SRSRAN_EDITS.md`](SRSRAN_EDITS.md) |
| Deploying from a custom srsRAN fork | [`PRIVATE_SRSRAN_REPO.md`](PRIVATE_SRSRAN_REPO.md) |
| Project coding and documentation conventions | [`CODING_STANDARDS.md`](CODING_STANDARDS.md) |
| Raspberry Pi monitoring tool | [`PI_MONITOR.md`](PI_MONITOR.md) |
