# Preflight Checks

Shared preflight validation playbooks used by both the **open5gs** and **srsran** projects to verify that target Raspberry Pi hosts meet minimum requirements before any software is installed.

## Position in the Pipeline

This is **Stage 1** in both pipelines:

- `open5gs/playbooks/open5gs.yml` imports `../../common/playbooks/preflight/main.yml`
- `srsran/playbooks/srsran.yml` imports `../../common/playbooks/preflight/main.yml`

## What It Does

`main.yml` imports four sub-playbooks in order, all targeting the `[rpi]` inventory group:

| Playbook | Purpose |
|---|---|
| `model.yml` | Reads the Device Tree model string and displays the Pi model and CPU architecture |
| `memory.yml` | Displays total system memory in MB |
| `os_check.yml` | Asserts the host is running Raspberry Pi OS based on Debian 13 (Trixie) by checking `/etc/os-release` and APT source files |
| `verify_platform.yml` | Master check -- validates memory >= 4 GB, Pi model is 4 or newer, and OS is Trixie. Computes a `preflight_ok` boolean and dynamically groups hosts into `preflight_pass` or `preflight_fail` |

Hosts that pass all checks are placed in the `preflight_pass` group. Downstream playbooks alias this to `candidate` and only operate on those hosts.

## Key Facts Published

After preflight completes, the following host facts are available for later plays:

- `rpi_model` -- normalized Device Tree model string (e.g. "Raspberry Pi 5 Model B Rev 1.0")
- `preflight_ok` -- boolean, true if all checks passed
- Group membership in `preflight_pass` or `preflight_fail`

## Running Standalone

You can run preflight independently against any inventory to validate hosts without installing anything:

```bash
# Using the Pi 5 inventory:
ansible-playbook -i inventory-pi5.ini common/playbooks/preflight/main.yml

# Or using the Pi 4 inventory:
ansible-playbook -i inventory-pi4.ini common/playbooks/preflight/main.yml
```

You can also run individual checks in isolation:

```bash
# Just check the Pi model:
ansible-playbook -i inventory-pi5.ini common/playbooks/preflight/model.yml

# Just check the OS:
ansible-playbook -i inventory-pi5.ini common/playbooks/preflight/os_check.yml
```

All preflight playbooks are read-only -- they gather information and assert conditions but make no changes to the target hosts.
