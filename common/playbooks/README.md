# Common Playbooks

Shared playbooks used by both the **open5gs** and **srsran** projects. These handle platform validation and base Pi configuration that is identical across both deployments.

## Contents

| Path | Purpose |
|---|---|
| `preflight/main.yml` | Orchestrates all preflight checks (see `preflight/README.md`) |
| `preflight/model.yml` | Reads and displays the Raspberry Pi model from Device Tree |
| `preflight/memory.yml` | Displays total system memory |
| `preflight/os_check.yml` | Asserts Raspberry Pi OS on Debian 13 (Trixie) |
| `preflight/verify_platform.yml` | Master validation -- memory, model, OS checks with dynamic grouping |
| `pi_setup.yml` | Hardens the Pi for headless server use |

## pi_setup.yml

### Position in the Pipeline

This is **Stage 2** (Pi Setup) in both pipelines, running after preflight:

- `open5gs/playbooks/open5gs.yml` imports `../../common/playbooks/pi_setup.yml`
- `srsran/playbooks/srsran.yml` imports `../../common/playbooks/pi_setup.yml`

### What It Does

Configures each Pi for dedicated headless server operation:

1. **Disables onboard Wi-Fi** -- adds `dtoverlay=disable-wifi` (or `disable-wifi-pi5` for Pi 5) to `/boot/firmware/config.txt`
2. **Disables onboard Bluetooth** -- adds `dtoverlay=disable-bt` (or `disable-bt-pi5` for Pi 5)
3. **Reboots** if either overlay was changed (required for dtoverlay changes to take effect)
4. **Disables VNC** via `raspi-config nonint do_vnc 1`
5. **Disables SPI** via `raspi-config nonint do_spi 1`
6. **Disables I2C** via `raspi-config nonint do_i2c 1`
7. **Disables 1-Wire** via `raspi-config nonint do_onewire 1`

### Prerequisites

- Requires the `rpi_model` fact set by `preflight/verify_platform.yml` (used to detect Pi 5 for overlay selection)
- Requires `become: true` (root access)

### Running Standalone

```bash
# Requires preflight to have run first (for rpi_model fact).
# Run the full preflight + pi_setup sequence:
ansible-playbook -i inventory-pi5.ini common/playbooks/preflight/main.yml
ansible-playbook -i inventory-pi5.ini common/playbooks/pi_setup.yml
```

Running `pi_setup.yml` without preflight will still work but the Pi 5 overlay detection will fall back to the generic (non-Pi5) overlays since `rpi_model` won't be set.
