#!/usr/bin/env bash
# pi_monitor — Periodic CPU temperature, throttle state, load, and memory logger
#
# Designed for Raspberry Pi 4 and Pi 5.  Reads the on-die thermal sensor,
# the VideoCore throttle register, /proc/loadavg, /proc/meminfo, and the
# current CPU frequency.  Writes one timestamped line per sample to stdout
# (systemd/journald captures it) and optionally to a dedicated log file.
#
# Environment variables (all optional — sane defaults for Raspberry Pi):
#   PI_MONITOR_INTERVAL   Seconds between samples (default: 5)
#   PI_MONITOR_LOG        Path to a dedicated log file (default: /var/log/pi-monitor.log)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
INTERVAL="${PI_MONITOR_INTERVAL:-5}"
LOGFILE="${PI_MONITOR_LOG:-/var/log/pi-monitor.log}"

# ---------------------------------------------------------------------------
# Throttle-flag bitmask decoder (vcgencmd get_throttled)
#
#   Bit  Meaning
#   ---  -------
#    0   Under-voltage detected (now)
#    1   ARM frequency capped (now)
#    2   Currently throttled (now)
#    3   Soft temperature limit active (now)
#   16   Under-voltage has occurred (since boot)
#   17   ARM frequency capping has occurred (since boot)
#   18   Throttling has occurred (since boot)
#   19   Soft temperature limit has occurred (since boot)
# ---------------------------------------------------------------------------

# Current-state flag names (bits 0-3)
declare -A CURRENT_FLAGS=(
  [0]="UNDER_VOLTAGE"
  [1]="FREQ_CAPPED"
  [2]="THROTTLED"
  [3]="SOFT_TEMP_LIMIT"
)

# Since-boot flag names (bits 16-19)
declare -A HISTORY_FLAGS=(
  [16]="under_voltage_occurred"
  [17]="freq_capping_occurred"
  [18]="throttling_occurred"
  [19]="soft_temp_limit_occurred"
)

decode_throttle() {
  local hex="$1"
  local val=$(( hex ))

  # Decode current flags (bits 0-3)
  local current=()
  for bit in 0 1 2 3; do
    if (( val & (1 << bit) )); then
      current+=("${CURRENT_FLAGS[$bit]}")
    fi
  done

  # Decode since-boot flags (bits 16-19)
  local history=()
  for bit in 16 17 18 19; do
    if (( val & (1 << bit) )); then
      history+=("${HISTORY_FLAGS[$bit]}")
    fi
  done

  # Format current flags
  if (( ${#current[@]} > 0 )); then
    printf "[%s]" "$(IFS='|'; echo "${current[*]}")"
  else
    printf "[ok]"
  fi

  # Append since-boot flags if any
  if (( ${#history[@]} > 0 )); then
    printf "  since_boot=[%s]" "$(IFS='|'; echo "${history[*]}")"
  fi
}

# ---------------------------------------------------------------------------
# Read helpers
# ---------------------------------------------------------------------------

read_temp() {
  # Prefer vcgencmd (reads the VideoCore thermal sensor directly).
  # Fall back to the kernel thermal zone (millidegrees → degrees).
  if command -v vcgencmd &>/dev/null; then
    vcgencmd measure_temp 2>/dev/null | sed "s/temp=//;s/'C//"
  elif [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
    awk '{ printf "%.1f", $1 / 1000 }' /sys/class/thermal/thermal_zone0/temp
  else
    echo "n/a"
  fi
}

read_throttle() {
  if command -v vcgencmd &>/dev/null; then
    # Returns e.g. "throttled=0x50000"
    vcgencmd get_throttled 2>/dev/null | sed 's/throttled=//'
  else
    echo "n/a"
  fi
}

read_cpu_freq_mhz() {
  # Read current frequency from the first core (representative — all cores
  # share the same clock domain on Pi 4 and Pi 5).
  if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]]; then
    awk '{ printf "%d", $1 / 1000 }' /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq
  else
    echo "n/a"
  fi
}

read_governor() {
  if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
  else
    echo "n/a"
  fi
}

read_memory() {
  # Outputs "used/total_MB(pct%)"
  awk '
    /^MemTotal:/     { total = $2 }
    /^MemAvailable:/ { avail = $2 }
    END {
      used  = total - avail
      pct   = (total > 0) ? (used / total) * 100 : 0
      printf "%d/%dMB(%.0f%%)", used/1024, total/1024, pct
    }
  ' /proc/meminfo
}

# ---------------------------------------------------------------------------
# Startup banner
# ---------------------------------------------------------------------------

model="unknown"
if [[ -f /sys/firmware/devicetree/base/model ]]; then
  model=$(tr -d '\0' < /sys/firmware/devicetree/base/model)
fi

banner="pi_monitor starting: model=${model}  interval=${INTERVAL}s  log=${LOGFILE}"

log_line() {
  local line="$1"
  echo "$line"
  echo "$line" >> "$LOGFILE"
}

log_line "$banner"

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

while true; do
  ts=$(date --iso-8601=seconds)

  temp=$(read_temp)
  throttle_hex=$(read_throttle)
  load=$(awk '{ print $1"/"$2"/"$3 }' /proc/loadavg)
  mem=$(read_memory)
  freq=$(read_cpu_freq_mhz)
  gov=$(read_governor)

  # Decode throttle flags
  if [[ "$throttle_hex" != "n/a" ]]; then
    throttle_decoded=$(decode_throttle "$throttle_hex")
    throttle_field="throttled=${throttle_hex} ${throttle_decoded}"
  else
    throttle_field="throttled=n/a"
  fi

  line="${ts}  temp=${temp}°C  ${throttle_field}  load=${load}  mem=${mem}  cpu_freq=${freq}MHz  governor=${gov}"

  log_line "$line"

  sleep "$INTERVAL"
done
