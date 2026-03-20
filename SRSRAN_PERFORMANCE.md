# srsRAN Performance Tuning

srsRAN Project ships an interactive script at `scripts/srsran_performance` in its
source tree. This project does **not** use that script. Instead, the same tuning
is applied declaratively through Ansible tasks in the gNB install playbook.

This document explains why, and describes exactly what the Ansible tasks do.

## Why not use the upstream script?

The upstream script is designed for manual, one-shot use on a developer's
workstation. It has three properties that make it unsuitable for automated
deployment:

1. **Interactive prompts.** Each tuning step asks the operator to confirm
   with a `[Y/n]` prompt (`read -e -p`). Ansible cannot respond to
   interactive prompts in a `command` or `shell` task without fragile
   workarounds.

2. **No persistence.** The script writes directly to `/sys/` and calls
   `sysctl -w`, which take effect immediately but are lost on reboot.
   A Pi that power-cycles overnight reverts to the default `ondemand`
   governor and default buffer sizes.

3. **No idempotency.** Running the script a second time re-applies the
   same settings unconditionally. There is no way to check current state,
   skip steps that are already applied, or report what changed.

These are fine trade-offs for a quick manual setup, but not for a
repeatable, hands-off deployment that students can re-run at any time.

## What the upstream script does

For reference, the upstream `scripts/srsran_performance` performs three
steps (each gated by a `Y/n` prompt):

| Step | Command | Purpose |
|---|---|---|
| CPU governor | `echo performance > /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor` | Locks all CPU cores at maximum frequency |
| DRM KMS polling | `echo N > /sys/module/drm_kms_helper/parameters/poll` | Stops the kernel polling the GPU for display hotplug events |
| Network buffers | `sysctl -w net.core.{w,r}mem_{max,default}=33554432` | Sets socket send/receive buffers to 32 MB for Ethernet USRPs |

## What our Ansible tasks do

The playbook `srsran/playbooks/srsran_install/install.yml` applies the
same three tuning areas, plus additional hardening that the upstream script
does not cover. Every setting is applied both immediately (so the current
boot benefits) and persistently (so reboots keep the settings).

### CPU governor

| Aspect | Upstream script | Ansible |
|---|---|---|
| Mechanism | Writes to `/sys/` sysfs | Writes to `/sys/` sysfs **and** deploys a systemd oneshot service (`cpupower-governor.service`) |
| Persistence | None (lost on reboot) | `cpupower-governor.service` runs at boot via `WantedBy=multi-user.target` |
| Package | Assumes `cpufreq-set` or equivalent exists | Installs `linux-cpupower` in `build_deps.yml` (replaces the deprecated `cpufrequtils`) |
| Conditional | Always applies (after prompt) | Only when `srsran_cpu_governor == "performance"` |

### DRM KMS polling

| Aspect | Upstream script | Ansible |
|---|---|---|
| Mechanism | Writes `N` to `/sys/module/drm_kms_helper/parameters/poll` | Same **and** deploys `/etc/modprobe.d/srsran-drm-kms.conf` with `options drm_kms_helper poll=N` |
| Persistence | None | Persistent via modprobe.d (applied when the module loads at boot) |
| Conditional | Always applies (after prompt) | Only when `srsran_disable_kms_polling` is `true` |

### Network buffers

| Aspect | Upstream script | Ansible |
|---|---|---|
| Mechanism | `sysctl -w` (4 parameters) | `ansible.posix.sysctl` module (same 4 parameters, written to `/etc/sysctl.d/`) |
| Persistence | None | Persistent via sysctl.d config file |
| Conditional | Always applies (after prompt) | Only when `srsran_tune_network_buffers` is `true` (default: **false** -- not needed for USB SDRs) |

### Additional tuning not in the upstream script

| Setting | Where | Purpose |
|---|---|---|
| `cap_sys_nice=ep` on the `gnb` binary | `install.yml` | Allows real-time thread scheduling without running as root |
| `LimitRTPRIO=99` in `srsran-gnb.service` | `install.yml` | Permits real-time priority up to the kernel maximum |
| `LimitMEMLOCK=infinity` in `srsran-gnb.service` | `install.yml` | Prevents page faults in the PHY signal path by allowing unlimited memory locking |

## Configuration variables

All tuning knobs are in `group_vars/gnb.yml`:

```yaml
srsran_set_realtime_cap: true        # setcap cap_sys_nice on gnb binary
srsran_cpu_governor: "performance"   # CPU scaling governor
srsran_disable_kms_polling: true     # disable DRM KMS polling
srsran_tune_network_buffers: false   # 32 MB socket buffers (enable for Ethernet USRPs)
```

To disable a specific tuning step, set the variable to `false` (or change
the governor name) and re-run the playbook.

## Verifying the settings

The health-check script deployed to the gNB Pi validates every setting:

```bash
sudo srsran_check
```

It reports:

- CPU governor on each core (expected: `performance`)
- DRM KMS polling state (expected: `N`)
- Network buffer sizes (informational, or compared to 32 MB if tuning is enabled)
- `cap_sys_nice` capability on the gnb binary

## See also

- [`srsran/README.md`](srsran/README.md) -- full srsRAN pipeline documentation and variable reference
- [`srsran/playbooks/srsran_install/README.md`](srsran/playbooks/srsran_install/README.md) -- playbook-level details for `install.yml`
- [`RFHARDWARE.md`](RFHARDWARE.md) -- SDR hardware guide (includes when to enable network buffer tuning)
