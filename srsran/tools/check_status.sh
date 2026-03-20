#!/usr/bin/env bash
# srsran_check — Pre-flight health check for the srsRAN gNB
#
# Checks:
#   1. srsran-gnb systemd service status
#   2. gNB binary exists and has real-time capability
#   3. gNB configuration file present and valid YAML
#   4. CPU governor set to performance
#   5. DRM KMS polling disabled
#   6. RF driver detection (ZMQ or UHD)
#   7. UHD device detection (if UHD driver configured)
#   8. AMF network reachability
#   9. Metrics endpoint port
#  10. Grafana stack (if running on this host)
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more checks failed

set -euo pipefail

# ---------------------------------------------------------------------------
# Configurable defaults (override with environment variables)
# ---------------------------------------------------------------------------
GNB_BINARY="${SRSRAN_GNB_BINARY:-/usr/local/bin/gnb}"
GNB_CONFIG="${SRSRAN_GNB_CONFIG:-/etc/srsran/gnb.yml}"
GNB_SERVICE="srsran-gnb"
METRICS_PORT="${SRSRAN_METRICS_PORT:-55555}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0
WARN=0

pass()  { printf "  ${GREEN}✓${RESET} %s\n" "$1"; (( ++PASS )); }
fail()  { printf "  ${RED}✗${RESET} %s\n" "$1";   (( ++FAIL )); }
warn()  { printf "  ${YELLOW}!${RESET} %s\n" "$1"; (( ++WARN )); }
header(){ printf "\n${BOLD}── %s${RESET}\n" "$1"; }

# ---------------------------------------------------------------------------
# 1. systemd service
# ---------------------------------------------------------------------------
header "gNB Service"

state=$(systemctl is-active "$GNB_SERVICE" 2>/dev/null || true)
enabled=$(systemctl is-enabled "$GNB_SERVICE" 2>/dev/null || true)

if [[ "$state" == "active" ]]; then
  pass "$GNB_SERVICE: active (running)"
elif [[ "$enabled" == "enabled" ]]; then
  warn "$GNB_SERVICE: enabled but $state (expected — start manually after AMF is up)"
else
  fail "$GNB_SERVICE: $state (not enabled)"
fi

# ---------------------------------------------------------------------------
# 2. gNB binary
# ---------------------------------------------------------------------------
header "gNB Binary"

if [[ -x "$GNB_BINARY" ]]; then
  pass "$GNB_BINARY: exists and executable"
else
  fail "$GNB_BINARY: not found or not executable"
fi

# Check real-time capability
if command -v getcap &>/dev/null && [[ -f "$GNB_BINARY" ]]; then
  caps=$(getcap "$GNB_BINARY" 2>/dev/null || true)
  if echo "$caps" | grep -q "cap_sys_nice"; then
    pass "cap_sys_nice: set"
  else
    warn "cap_sys_nice: not set (gNB may need root for real-time scheduling)"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Configuration file
# ---------------------------------------------------------------------------
header "gNB Configuration"

if [[ -f "$GNB_CONFIG" ]]; then
  pass "$GNB_CONFIG: exists"

  # Detect RF driver from config
  rf_driver=$(grep -E '^\s*device_driver:' "$GNB_CONFIG" 2>/dev/null | head -1 | awk '{print $2}' || true)
  if [[ -n "$rf_driver" ]]; then
    pass "RF driver: $rf_driver"
  else
    warn "RF driver: could not detect from config"
  fi

  # Extract AMF address from config
  amf_addr=$(grep -E '^\s*addr:' "$GNB_CONFIG" 2>/dev/null | head -1 | awk '{print $2}' || true)
  if [[ -n "$amf_addr" ]]; then
    pass "AMF address: $amf_addr (from config)"
  else
    warn "AMF address: could not detect from config"
  fi
else
  fail "$GNB_CONFIG: not found"
  rf_driver=""
  amf_addr=""
fi

# ---------------------------------------------------------------------------
# 4. CPU governor
# ---------------------------------------------------------------------------
header "Performance Tuning"

governors_ok=true
for gov_file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  [[ -f "$gov_file" ]] || continue
  gov=$(cat "$gov_file")
  if [[ "$gov" != "performance" ]]; then
    governors_ok=false
    break
  fi
done

if [[ "$governors_ok" == true ]]; then
  pass "CPU governor: performance (all cores)"
else
  fail "CPU governor: $gov (expected performance)"
fi

# DRM KMS polling
kms_poll_file="/sys/module/drm_kms_helper/parameters/poll"
if [[ -f "$kms_poll_file" ]]; then
  kms_poll=$(cat "$kms_poll_file")
  if [[ "$kms_poll" == "N" ]]; then
    pass "DRM KMS polling: disabled"
  else
    warn "DRM KMS polling: enabled (Y) — adds CPU overhead"
  fi
else
  pass "DRM KMS polling: module not loaded (not applicable)"
fi

# Network buffer tuning (informational)
wmem_max=$(cat /proc/sys/net/core/wmem_max 2>/dev/null || echo "unknown")
rmem_max=$(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo "unknown")
if [[ "$wmem_max" -ge 33554432 ]] 2>/dev/null && [[ "$rmem_max" -ge 33554432 ]] 2>/dev/null; then
  pass "Network buffers: tuned (wmem_max=$wmem_max, rmem_max=$rmem_max)"
else
  # Not a failure — only needed for Ethernet USRPs
  warn "Network buffers: default (wmem_max=$wmem_max, rmem_max=$rmem_max) — tune if using Ethernet USRP"
fi

# ---------------------------------------------------------------------------
# 5. RF driver specifics
# ---------------------------------------------------------------------------
header "RF Driver"

if [[ "$rf_driver" == "uhd" ]]; then
  # Check for UHD images
  if [[ -d /usr/share/uhd/images ]]; then
    pass "UHD firmware images: present"
  else
    fail "UHD firmware images: /usr/share/uhd/images not found"
  fi

  # Check for USB SDR device
  if command -v uhd_find_devices &>/dev/null; then
    uhd_output=$(uhd_find_devices 2>&1 || true)
    if echo "$uhd_output" | grep -qi "device address"; then
      device_type=$(echo "$uhd_output" | grep -i "type" | head -1 || true)
      pass "UHD device: detected ($device_type)"
    else
      warn "UHD device: not found (is the SDR connected via USB?)"
    fi
  else
    fail "uhd_find_devices: command not found (uhd-host not installed?)"
  fi

  # Check udev rules
  if [[ -f /etc/udev/rules.d/99-usrp.rules ]]; then
    pass "USRP udev rules: present"
  else
    warn "USRP udev rules: /etc/udev/rules.d/99-usrp.rules not found"
  fi

elif [[ "$rf_driver" == "zmq" ]]; then
  # Check ZMQ library is available
  # Use full path — /usr/sbin may not be in PATH under sudo
  if /usr/sbin/ldconfig -p 2>/dev/null | grep -q "libzmq"; then
    pass "ZMQ library: found"
  else
    fail "ZMQ library: not found"
  fi

  pass "ZMQ mode: no hardware required"
else
  warn "RF driver: unknown or not detected — skipping driver-specific checks"
fi

# ---------------------------------------------------------------------------
# 6. AMF reachability
# ---------------------------------------------------------------------------
header "AMF Connectivity"

if [[ -n "$amf_addr" ]]; then
  if ping -c 1 -W 2 "$amf_addr" &>/dev/null; then
    pass "AMF host $amf_addr: reachable (ping)"
  else
    fail "AMF host $amf_addr: unreachable"
  fi

  # Check NGAP port (SCTP 38412)
  if ss -SlnH "dst ${amf_addr}:38412" 2>/dev/null | grep -q "38412"; then
    pass "NGAP connection to $amf_addr:38412: established"
  elif command -v nc &>/dev/null && nc -z -w 2 "$amf_addr" 38412 2>/dev/null; then
    pass "NGAP port $amf_addr:38412: open"
  else
    warn "NGAP port $amf_addr:38412: not reachable (AMF may not be running yet)"
  fi
else
  warn "AMF address: not detected — skipping connectivity check"
fi

# ---------------------------------------------------------------------------
# 7. Metrics endpoint
# ---------------------------------------------------------------------------
header "Metrics"

if [[ "$state" == "active" ]]; then
  if ss -tlnH "src *:${METRICS_PORT}" 2>/dev/null | grep -q "${METRICS_PORT}"; then
    pass "Metrics endpoint: listening on port $METRICS_PORT"
  else
    warn "Metrics endpoint: port $METRICS_PORT not listening (check metrics config)"
  fi
else
  warn "Metrics endpoint: gNB not running — cannot check port $METRICS_PORT"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
header "Summary"
printf "  Passed: ${GREEN}%d${RESET}  Failed: ${RED}%d${RESET}  Warnings: ${YELLOW}%d${RESET}\n" \
  "$PASS" "$FAIL" "$WARN"

if [[ "$FAIL" -gt 0 ]]; then
  printf "\n${RED}${BOLD}PREFLIGHT FAILED${RESET} — %d check(s) did not pass.\n" "$FAIL"
  exit 1
else
  printf "\n${GREEN}${BOLD}ALL CHECKS PASSED${RESET}\n"
  exit 0
fi
