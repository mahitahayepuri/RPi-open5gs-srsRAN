#!/usr/bin/env bash
# srsue_e2e_test.sh — End-to-end 5G SA data-path verification using srsUE
#
# Starts srsUE in the background, waits for a PDU session to be established
# (tun_srsue interface appears), pings the core Pi's RAN address through
# the 5G network, then cleans up.
#
# Exit codes:
#   0 — end-to-end test passed (PDU session + ping successful)
#   1 — srsUE failed to attach or ping failed
#   2 — srsUE binary or config not found
#
# Usage:
#   sudo srsue_e2e_test
#
# Environment variables (optional):
#   SRSUE_BINARY    — path to srsue binary (default: /usr/local/bin/srsue)
#   SRSUE_CONFIG    — path to ue.conf (default: /etc/srsran_4g/ue.conf)
#   PING_TARGET     — IP to ping through tun_srsue (default: 10.53.1.1)
#   ATTACH_TIMEOUT  — seconds to wait for PDU session (default: 30)
#   PING_COUNT      — number of ping packets (default: 3)
#
# The script auto-detects the network namespace from the UE config file
# ([gw] netns = ...) and checks for the TUN interface / pings inside it.

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SRSUE_BINARY="${SRSUE_BINARY:-/usr/local/bin/srsue}"
SRSUE_CONFIG="${SRSUE_CONFIG:-/etc/srsran_4g/ue.conf}"
PING_TARGET="${PING_TARGET:-10.53.1.1}"
ATTACH_TIMEOUT="${ATTACH_TIMEOUT:-30}"
PING_COUNT="${PING_COUNT:-3}"
TUN_IFACE="tun_srsue"
UE_PID=""

# Auto-detect network namespace from UE config (if [gw] netns = ... is set)
UE_NETNS=""
if [[ -f "${SRSUE_CONFIG}" ]]; then
  UE_NETNS=$(grep -Po '^\s*netns\s*=\s*\K\S+' "$SRSUE_CONFIG" 2>/dev/null || true)
fi
# Prefix for running commands inside the netns (empty if no netns)
if [[ -n "$UE_NETNS" ]]; then
  NS_EXEC="ip netns exec $UE_NETNS"
else
  NS_EXEC=""
fi

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

# ---------------------------------------------------------------------------
# Cleanup — kill srsUE on exit (normal or error)
# ---------------------------------------------------------------------------
cleanup() {
  if [[ -n "$UE_PID" ]] && kill -0 "$UE_PID" 2>/dev/null; then
    printf "${YELLOW}Stopping srsUE (PID %s)...${RESET}\n" "$UE_PID"
    kill "$UE_PID" 2>/dev/null
    wait "$UE_PID" 2>/dev/null
  fi
  # Remove TUN so it doesn't persist as a stale device after srsUE exits
  if [[ -n "$UE_NETNS" ]]; then
    $NS_EXEC ip link del "$TUN_IFACE" 2>/dev/null || true
  else
    ip link del "$TUN_IFACE" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
printf "\n${BOLD}── Pre-flight${RESET}\n"

if [[ ! -x "$SRSUE_BINARY" ]]; then
  printf "  ${RED}✗${RESET} srsue binary not found at %s\n" "$SRSUE_BINARY"
  printf "  Run the srsUE playbook first: ansible-playbook -i <inventory> srsue/playbooks/srsue.yml\n"
  exit 2
fi
printf "  ${GREEN}✓${RESET} srsue binary: %s\n" "$SRSUE_BINARY"

if [[ ! -f "$SRSUE_CONFIG" ]]; then
  printf "  ${RED}✗${RESET} srsue config not found at %s\n" "$SRSUE_CONFIG"
  exit 2
fi
printf "  ${GREEN}✓${RESET} srsue config: %s\n" "$SRSUE_CONFIG"

# Check gNB is running (srsUE needs it)
if ! systemctl is-active --quiet srsran-gnb 2>/dev/null; then
  printf "  ${RED}✗${RESET} srsran-gnb service is not running\n"
  printf "  Start it first: sudo systemctl start srsran-gnb\n"
  exit 1
fi
printf "  ${GREEN}✓${RESET} srsran-gnb: active\n"

# ---------------------------------------------------------------------------
# Start srsUE
# ---------------------------------------------------------------------------
printf "\n${BOLD}── Starting srsUE${RESET}\n"

# Kill any leftover srsUE from a previous run and remove stale TUN device.
# A stale TUN in the netns with no process behind it causes the ping to
# black-hole, and a leftover process holds the ZMQ port.
if pkill -0 srsue 2>/dev/null; then
  printf "  Cleaning up leftover srsUE process...\n"
  pkill -9 srsue 2>/dev/null
  sleep 1
fi
if [[ -n "$UE_NETNS" ]]; then
  $NS_EXEC ip link del "$TUN_IFACE" 2>/dev/null || true
else
  ip link del "$TUN_IFACE" 2>/dev/null || true
fi

"$SRSUE_BINARY" "$SRSUE_CONFIG" > /tmp/srsue_e2e.log 2>&1 &
UE_PID=$!
printf "  srsUE started (PID %s), waiting for PDU session...\n" "$UE_PID"

# ---------------------------------------------------------------------------
# Wait for PDU session (tun_srsue interface appears)
# ---------------------------------------------------------------------------
printf "\n${BOLD}── Waiting for PDU session (up to %ds)${RESET}\n" "$ATTACH_TIMEOUT"

attached=false
for i in $(seq 1 "$ATTACH_TIMEOUT"); do
  # Check srsUE hasn't crashed
  if ! kill -0 "$UE_PID" 2>/dev/null; then
    printf "  ${RED}✗${RESET} srsUE exited unexpectedly after %ds\n" "$i"
    printf "  Check /tmp/srsue_e2e.log for details\n"
    UE_PID=""
    exit 1
  fi

  # Check for TUN interface (may be in a network namespace)
  if $NS_EXEC ip link show "$TUN_IFACE" &>/dev/null; then
    ue_ip=$($NS_EXEC ip -4 addr show "$TUN_IFACE" 2>/dev/null | grep -oP 'inet \K[\d.]+')
    printf "  ${GREEN}✓${RESET} PDU session established after %ds (UE IP: %s)\n" "$i" "${ue_ip:-unknown}"
    if [[ -n "$UE_NETNS" ]]; then
      printf "  (TUN interface in netns '%s')\n" "$UE_NETNS"
    fi
    attached=true
    break
  fi

  # Progress indicator every 5 seconds
  if (( i % 5 == 0 )); then
    printf "  ... %ds\n" "$i"
  fi
  sleep 1
done

if [[ "$attached" != true ]]; then
  printf "  ${RED}✗${RESET} PDU session not established within %ds\n" "$ATTACH_TIMEOUT"
  printf "  Check /tmp/srsue_e2e.log for details\n"
  exit 1
fi

# Brief pause to let the route settle
sleep 2

# When a netns is used, srsUE creates the TUN inside it but only adds a
# link-local /24 route.  We need a default route through the TUN so
# traffic to the core Pi (e.g. 10.53.1.1) can flow.
if [[ -n "$UE_NETNS" ]]; then
  if ! $NS_EXEC ip route show default &>/dev/null || \
     [[ -z "$($NS_EXEC ip route show default 2>/dev/null)" ]]; then
    $NS_EXEC ip route add default dev "$TUN_IFACE" 2>/dev/null || true
    printf "  Added default route via %s in netns '%s'\n" "$TUN_IFACE" "$UE_NETNS"
  fi
fi

# ---------------------------------------------------------------------------
# Ping test through the 5G network
# ---------------------------------------------------------------------------
printf "\n${BOLD}── Ping test (%s via %s)${RESET}\n" "$PING_TARGET" "$TUN_IFACE"

if $NS_EXEC ping -I "$TUN_IFACE" -c "$PING_COUNT" -W 5 "$PING_TARGET" 2>&1 | tee /tmp/srsue_e2e_ping.log; then
  printf "\n  ${GREEN}✓${RESET} Ping successful — end-to-end data path is working\n"
  RESULT=0
else
  printf "\n  ${RED}✗${RESET} Ping failed — data path is not working\n"
  printf "  UE attached successfully but traffic is not reaching the core.\n"
  printf "  Check IP forwarding and NAT on the core Pi: sudo open5gs_check\n"
  RESULT=1
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf "\n${BOLD}── Summary${RESET}\n"
printf "  srsUE log:  /tmp/srsue_e2e.log\n"
printf "  Ping log:   /tmp/srsue_e2e_ping.log\n"

if [[ "$RESULT" -eq 0 ]]; then
  printf "\n${GREEN}${BOLD}E2E TEST PASSED${RESET} — UE attached and data flows through the 5G network.\n\n"
else
  printf "\n${RED}${BOLD}E2E TEST FAILED${RESET}\n\n"
fi

exit "$RESULT"
