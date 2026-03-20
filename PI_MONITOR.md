# Pi Hardware Monitor

The `pi-monitor` service logs CPU temperature, thermal throttle state,
CPU load, memory usage, and clock frequency on every Raspberry Pi in the
inventory.  It runs as a systemd service, writes to a logrotate-managed
file, and produces timestamped lines that can be correlated with srsRAN
and Open5GS logs for post-hoc debugging.

## Why

Thermal throttling is the most common silent performance killer on the
Pi 4 (and to a lesser extent Pi 5) when running the srsRAN PHY.  The
CPU quietly drops from 1.8 GHz to 1.5 GHz (or lower), real-time
deadlines are missed, and the symptom shows up as dropped frames or UE
disconnects — with nothing in the gNB logs to explain it.

Having a continuous background record of temperature and throttle state
lets you answer "was the Pi throttling at 14:32 when the UE dropped?"
by grepping a single file.

## What it logs

One line per sample to `/var/log/pi-monitor.log`:

```
2026-03-18T14:32:05-04:00  temp=62.3°C  throttled=0x0 [ok]  load=3.72/3.41/2.98  mem=3842/7892MB(48%)  cpu_freq=1800MHz  governor=performance
2026-03-18T14:32:10-04:00  temp=81.1°C  throttled=0x60008 [SOFT_TEMP_LIMIT|THROTTLED]  since_boot=[throttling_occurred|soft_temp_limit_occurred]  load=3.97/3.55/3.10  mem=3901/7892MB(49%)  cpu_freq=1500MHz  governor=performance
```

| Field | Source | Notes |
|---|---|---|
| `temp` | `vcgencmd measure_temp` or `/sys/class/thermal/thermal_zone0/temp` | On-die thermal diode, instantaneous read |
| `throttled` | `vcgencmd get_throttled` | Hex bitmask + decoded flag names |
| `load` | `/proc/loadavg` | 1 / 5 / 15-minute load averages |
| `mem` | `/proc/meminfo` | Used/Total in MB and percentage |
| `cpu_freq` | `/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq` | Current clock in MHz |
| `governor` | `/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor` | Expected: `performance` on gNB Pis |

### Throttle flag bitmask

`vcgencmd get_throttled` returns a hex value whose bits indicate:

| Bit | Flag | Meaning |
|---|---|---|
| 0 | `UNDER_VOLTAGE` | PSU voltage below 4.63 V (now) |
| 1 | `FREQ_CAPPED` | ARM frequency capped (now) |
| 2 | `THROTTLED` | CPU throttled (now) |
| 3 | `SOFT_TEMP_LIMIT` | Soft temperature limit active (now) |
| 16 | `under_voltage_occurred` | Under-voltage detected at least once since boot |
| 17 | `freq_capping_occurred` | Frequency was capped at least once since boot |
| 18 | `throttling_occurred` | Throttling occurred at least once since boot |
| 19 | `soft_temp_limit_occurred` | Soft temperature limit hit at least once since boot |

Bits 0-3 reflect the current state.  Bits 16-19 are latched — once set
they remain set until reboot.  The script decodes both groups inline so
you don't need to interpret the hex manually.

## Sampling interval and thermal response

Temperature reads are **instantaneous** — a single register read from
the SoC's on-die thermal diode.  The cost is negligible.

The Pi's SoC has enough thermal mass that temperature changes on the
order of **1-2 °C per second** even under sudden full-load transitions.
A 5-second sampling interval (the default) will not miss a meaningful
thermal event.  Even a 10-second interval is adequate for post-hoc
correlation, since the temperature curve is smooth — there are no
sub-second spikes to catch.  The firmware's throttle decision is also
based on a filtered temperature reading, not a single sample, so a
brief sensor fluctuation won't trigger throttling that your log misses.

For reference, typical thermal time constants:

| Scenario | Approximate time to reach throttle threshold (80 °C) |
|---|---|
| Pi 4 (no heatsink, idle → 4-core PHY load) | ~60-90 seconds |
| Pi 4 (passive heatsink, idle → 4-core PHY load) | ~3-5 minutes |
| Pi 4 (active cooling, idle → 4-core PHY load) | Does not reach threshold |
| Pi 5 (active cooling, idle → 4-core PHY load) | Does not reach threshold |

## Configuration

Variables in `group_vars/all.yml`:

```yaml
pi_monitor_enabled: true    # deploy and enable the pi-monitor service
pi_monitor_interval: 5      # seconds between samples
```

Set `pi_monitor_enabled: false` to skip deployment entirely.  Change
`pi_monitor_interval` to adjust the sampling period (5-10 seconds is
recommended; going below 2 seconds adds log volume with little
diagnostic benefit).

## Deployment

The service is deployed automatically by `pi_setup.yml` to every host
in the `[rpi]` group:

```bash
ansible-playbook -i inventory-pi5.ini common/playbooks/pi_setup.yml
```

This deploys three artifacts:

| Artifact | Destination | Purpose |
|---|---|---|
| `pi_monitor.sh` | `/usr/local/bin/pi_monitor` | The monitoring script |
| systemd unit | `/etc/systemd/system/pi-monitor.service` | Starts at boot, restarts on failure |
| logrotate config | `/etc/logrotate.d/pi-monitor` | Daily rotation, 7-day retention, compressed |

## Usage

### Check service status

```bash
sudo systemctl status pi-monitor
```

### Watch live output

```bash
# Via the log file:
tail -f /var/log/pi-monitor.log

# Via journald:
journalctl -u pi-monitor -f
```

### Correlate with gNB logs

If a UE disconnected at a specific time, check what the Pi's thermal
state was:

```bash
# Find the gNB event:
grep "2026-03-18T14:32" /var/log/srsran/cucp.log

# Check the Pi's state at the same time:
grep "2026-03-18T14:32" /var/log/pi-monitor.log
```

### Check for any throttling since boot

```bash
grep -v '\[ok\]' /var/log/pi-monitor.log | head
```

### Quick one-liner: was throttling ever detected today?

```bash
grep "$(date +%Y-%m-%d)" /var/log/pi-monitor.log | grep -c 'THROTTLED'
```

### Stop or disable the service

```bash
# Stop (keeps enabled for next boot):
sudo systemctl stop pi-monitor

# Disable entirely:
sudo systemctl disable --now pi-monitor
```

## Pi 4 vs Pi 5

The script works identically on both models.  The interfaces it reads
(`vcgencmd`, `/sys/class/thermal/`, `/proc/loadavg`, `/proc/meminfo`,
`/sys/devices/system/cpu/`) are the same across the BCM2711 (Pi 4) and
BCM2712 (Pi 5).  The startup banner logs the model string from
`/sys/firmware/devicetree/base/model` so each log file self-identifies
which Pi it came from.

The only practical difference is thermal headroom: the Pi 5 runs cooler
under the same workload due to a larger die and better power efficiency,
so you'll see throttle events less frequently (or never, with active
cooling).

## Log rotation

The log file is rotated daily with 7-day retention by logrotate:

```
/var/log/pi-monitor.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
```

`copytruncate` is used because the script holds the file open
continuously (same strategy as the gNB log rotation).

## Files

| Path | Description |
|---|---|
| `common/tools/pi_monitor.sh` | Source script (deployed by Ansible) |
| `common/playbooks/pi_setup.yml` | Ansible tasks that deploy the service |
| `group_vars/all.yml` | Configuration variables |

## See also

- [`LOGGING.md`](LOGGING.md) -- gNB and Open5GS log locations and usage
- [`SRSRAN_PERFORMANCE.md`](SRSRAN_PERFORMANCE.md) -- CPU governor and
  performance tuning details
- [`RFHARDWARE.md`](RFHARDWARE.md) -- thermal management guidelines for
  SDR operation
