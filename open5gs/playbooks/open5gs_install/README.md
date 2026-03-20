# Open5GS Install Playbooks

Sub-playbooks that handle the complete Open5GS 5G core network installation on Raspberry Pi hosts. These are orchestrated by `main.yml` and imported from the top-level `open5gs/playbooks/open5gs.yml` as **Stage 4** of the pipeline.

## Position in the Pipeline

```
open5gs.yml (top-level)
  Stage 1: preflight    (from common/)
  Stage 2: alias        (preflight_pass -> candidate)
  Stage 3: pi_setup     (from common/)
  Stage 4: open5gs_install/main.yml   <-- this directory
             -> docker.yml
             -> mongodb.yml
             -> tun_setup.yml
             -> install.yml
             -> network.yml
             -> logging.yml
             -> services.yml
             -> webui.yml
```

All playbooks in this directory target `candidate:&core` (hosts that passed preflight and are in the `[core]` inventory group).

## Playbook Descriptions

### main.yml

Orchestrator that imports the eight sub-playbooks in order. This is the entry point imported by `open5gs.yml`.

### docker.yml

Installs Docker CE from the official Docker apt repository.

- Adds Docker's GPG key and apt source for Debian Trixie arm64
- Installs `docker-ce`, `docker-ce-cli`, `containerd.io`, and `docker-compose-plugin`
- Adds the `pi_user` to the `docker` group
- Enables and starts the Docker service

### mongodb.yml

Deploys MongoDB as a Docker container (required by Open5GS).

- Selects the MongoDB image version based on Pi model:
  - Pi 4: `mongodb/mongodb-community-server:4.4.3-ubuntu2004` (last build
    without ARMv8.1-A LSE atomics -- see [`open5gs/README.md`](../../README.md)
    for details)
  - Pi 5: `mongo:7.0`
- Runs MongoDB on port 27017 with a persistent Docker volume
- Waits for MongoDB to become responsive before proceeding

### tun_setup.yml

Creates the `ogstun` TUN network interface used by the Open5GS UPF (User Plane Function).

- Creates the TUN device via systemd-networkd (persistent across reboots)
- Assigns IPv4 and IPv6 addresses for the UPF data plane
- Enables and starts systemd-networkd

Note: IP forwarding and NAT/masquerade are handled by `network.yml` (see below).

### install.yml

Installs Open5GS itself, using one of two methods controlled by the `open5gs_install_method` variable:

- **`apt`** (default) -- Installs pre-built arm64 NF packages individually (e.g. `open5gs-amfd`, `open5gs-smfd`) from the OBS repository for Raspbian Trixie. Fast and recommended.
- **`source`** -- Clones the Open5GS git repository, builds from source with meson/ninja, and installs systemd service files. For custom builds or patching.

Uses `include_tasks` (dynamic) to select the install method at runtime from the `tasks/` subdirectory.

### network.yml

Configures the RAN-facing network so the gNB on the other Pi can reach the core:

- Adds the `open5gs_ran_addr` (default `10.53.1.1/24`) as a secondary IP on the physical NIC via a persistent systemd oneshot service
- Enables IPv4 and IPv6 forwarding (sysctl, persistent)
- Deploys nftables NAT/masquerade rules for UE traffic from the `ogstun` subnet
- Patches `/etc/open5gs/nrf.yaml` to set the NRF serving PLMN to match the network's MCC/MNC (default Open5GS uses 999/70, which causes SCP to attempt inter-PLMN routing via a non-existent SEPP)
- Patches `/etc/open5gs/amf.yaml` to bind NGAP on the RAN address (instead of loopback)
- Patches `/etc/open5gs/upf.yaml` to bind GTP-U on the RAN address (instead of loopback)

SBI (inter-NF) and PFCP (SMF to UPF) remain on loopback since both endpoints are on the same Pi.

### logging.yml

Configures rsyslog-based per-NF log splitting:

- Patches all 11 NF configuration files to remove the built-in file logger (using `yq`)
- Deploys rsyslog configuration at `/etc/rsyslog.d/30-open5gs.conf` to route each NF's journal output to a dedicated log file
- Deploys logrotate configuration at `/etc/logrotate.d/open5gs` (daily, 7-day retention, compressed)
- Logs are written to `/var/log/open5gs/<nf>.log` (e.g. `amf.log`, `smf.log`, `upf.log`)

### services.yml

Enables and starts all Open5GS network function services (NRF, SCP, AMF, SMF, UPF, AUSF, UDM, UDR, PCF, NSSF, BSF).

### webui.yml

Deploys the Open5GS WebUI as a Docker container:

- Clones the Open5GS repository to `open5gs_webui_source_dir` (default `/usr/local/src/open5gs`)
- Builds a Docker image from `docker/webui/Dockerfile`
- Runs the WebUI container with `--network host` on port 9999 (controlled by `open5gs_webui_port`)
- Sets `HOSTNAME=0.0.0.0` so Next.js binds on all interfaces
- Skips the x86_64-only `/wait` binary (MongoDB is already verified running by earlier stages)
- Default login credentials: `admin` / `1423`

## Running Standalone

These playbooks depend on the `candidate` group created by preflight. To run the install stage independently:

```bash
# Option 1: Run the full pipeline (recommended)
ansible-playbook -i inventory-pi5.ini open5gs/playbooks/open5gs.yml

# Option 2: Run just the install stage (requires preflight to have run previously
# in the same playbook execution, or manually create the 'candidate' group)
# This will NOT work standalone because 'candidate' is a runtime-only group.
```

To run individual sub-playbooks for debugging or re-running a specific step, you can target the `rpi` group directly by temporarily editing the `hosts:` directive, or by running through the full pipeline with `--start-at-task`:

```bash
# Re-run from a specific task:
ansible-playbook -i inventory-pi5.ini open5gs/playbooks/open5gs.yml \
  --start-at-task="Install Docker CE packages"

# Run just Docker setup (edit hosts: to 'rpi' temporarily, or use --limit):
ansible-playbook -i inventory-pi5.ini open5gs/playbooks/open5gs_install/docker.yml \
  --limit 192.168.2.72
```

## Configuration

Open5GS variables are defined in `group_vars/core.yml`; shared variables (Docker, pi_user) are in `group_vars/all.yml`. Key settings:

- `open5gs_install_method`: `"apt"` or `"source"` (default: `"apt"`)
- `pi_user`: user to add to the Docker group (default: `"pi"`)
- `open5gs_webui_source_dir`: clone destination for WebUI build (default: `"/usr/local/src/open5gs"`)
- `open5gs_webui_port`: WebUI listen port (default: `9999`)
