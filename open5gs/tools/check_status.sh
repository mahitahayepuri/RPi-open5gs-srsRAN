#!/usr/bin/env bash
# open5gs_check — Pre-flight health check for the Open5GS 5G SA core
#
# Checks:
#   1. systemd service status for every NF
#   2. SBI port (TCP 7777) reachable on each NF's loopback address
#   3. AMF NGAP port (SCTP 38412) and UPF GTP-U (UDP 2152) on RAN address
#   4. IP forwarding enabled and NAT rules loaded
#   5. RAN backhaul address present on interface
#   6. MongoDB Docker container running and TCP 27017 accepting connections
#   7. ogstun TUN device present and up
#   8. Grafana metrics stack (if deployed on this host)
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more checks failed

set -euo pipefail

# ---------------------------------------------------------------------------
# Configurable defaults (override with environment variables)
# ---------------------------------------------------------------------------
MONGO_PORT="${OPEN5GS_MONGO_PORT:-27017}"
MONGO_CONTAINER="${OPEN5GS_MONGO_CONTAINER:-open5gs-mongodb}"
SBI_PORT=7777

# ---------------------------------------------------------------------------
# Read RAN-facing addresses from Open5GS config files
# ---------------------------------------------------------------------------
# NGAP and GTP-U may be patched to a routable address by network.yml.
# Fall back to upstream defaults if yq is unavailable or parsing fails.
AMF_NGAP_ADDR="127.0.0.5"
if command -v yq &>/dev/null && [[ -f /etc/open5gs/amf.yaml ]]; then
  _addr=$(yq '.amf.ngap.server[0].address' /etc/open5gs/amf.yaml 2>/dev/null)
  [[ -n "$_addr" && "$_addr" != "null" ]] && AMF_NGAP_ADDR="$_addr"
fi

UPF_GTPU_ADDR="127.0.0.7"
if command -v yq &>/dev/null && [[ -f /etc/open5gs/upf.yaml ]]; then
  _addr=$(yq '.upf.gtpu.server[0].address' /etc/open5gs/upf.yaml 2>/dev/null)
  [[ -n "$_addr" && "$_addr" != "null" ]] && UPF_GTPU_ADDR="$_addr"
fi

# NF name → systemd unit, loopback address, extra checks
# Format: "unit_name|bind_addr|extra"
#   extra: comma-separated list of "proto:addr:port" for non-SBI interfaces
declare -A NFS=(
  [NRF]="open5gs-nrfd|127.0.0.10|"
  [SCP]="open5gs-scpd|127.0.0.200|"
  [AMF]="open5gs-amfd|127.0.0.5|sctp:${AMF_NGAP_ADDR}:38412"
  [SMF]="open5gs-smfd|127.0.0.4|udp:127.0.0.4:8805"
  [UPF]="open5gs-upfd|127.0.0.7|udp:127.0.0.7:8805,udp:${UPF_GTPU_ADDR}:2152"
  [AUSF]="open5gs-ausfd|127.0.0.11|"
  [UDM]="open5gs-udmd|127.0.0.12|"
  [UDR]="open5gs-udrd|127.0.0.20|"
  [PCF]="open5gs-pcfd|127.0.0.13|"
  [NSSF]="open5gs-nssfd|127.0.0.14|"
  [BSF]="open5gs-bsfd|127.0.0.15|"
)

# Ordered list so output is deterministic
NF_ORDER=(NRF SCP AMF SMF UPF AUSF UDM UDR PCF NSSF BSF)

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

# Check if a TCP port is open on a given address
check_tcp() {
  local addr="$1" port="$2"
  if ss -tlnH "src ${addr}:${port}" 2>/dev/null | grep -q "${port}"; then
    return 0
  fi
  return 1
}

# Check if a UDP port is bound on a given address
check_udp() {
  local addr="$1" port="$2"
  if ss -ulnH "src ${addr}:${port}" 2>/dev/null | grep -q "${port}"; then
    return 0
  fi
  return 1
}

# Check if an SCTP port is listening on a given address
check_sctp() {
  local addr="$1" port="$2"
  if ss -SlnH "src ${addr}:${port}" 2>/dev/null | grep -q "${port}"; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# 1. systemd service status
# ---------------------------------------------------------------------------
header "Network Function Services"

for nf in "${NF_ORDER[@]}"; do
  IFS='|' read -r unit addr extra <<< "${NFS[$nf]}"
  state=$(systemctl is-active "$unit" 2>/dev/null || true)
  if [[ "$state" == "active" ]]; then
    pass "$nf ($unit): active"
  else
    fail "$nf ($unit): $state"
  fi
done

# ---------------------------------------------------------------------------
# 2. SBI ports (TCP 7777 on each NF's loopback)
# ---------------------------------------------------------------------------
header "SBI Ports (TCP ${SBI_PORT})"

for nf in "${NF_ORDER[@]}"; do
  IFS='|' read -r unit addr extra <<< "${NFS[$nf]}"

  # UPF has no SBI interface
  if [[ "$nf" == "UPF" ]]; then
    continue
  fi

  if check_tcp "$addr" "$SBI_PORT"; then
    pass "$nf: ${addr}:${SBI_PORT} listening"
  else
    fail "$nf: ${addr}:${SBI_PORT} not listening"
  fi
done

# ---------------------------------------------------------------------------
# 3. Non-SBI ports (NGAP, PFCP, GTP-U)
# ---------------------------------------------------------------------------
header "Non-SBI Ports (NGAP / PFCP / GTP-U)"

for nf in "${NF_ORDER[@]}"; do
  IFS='|' read -r unit addr extra <<< "${NFS[$nf]}"
  [[ -z "$extra" ]] && continue

  IFS=',' read -ra checks <<< "$extra"
  for check in "${checks[@]}"; do
    IFS=':' read -r proto caddr cport <<< "$check"
    label="${nf}: ${caddr}:${cport} (${proto^^})"

    case "$proto" in
      tcp)
        if check_tcp "$caddr" "$cport"; then pass "$label listening"
        else fail "$label not listening"; fi
        ;;
      udp)
        if check_udp "$caddr" "$cport"; then pass "$label listening"
        else fail "$label not listening"; fi
        ;;
      sctp)
        if check_sctp "$caddr" "$cport"; then pass "$label listening"
        else fail "$label not listening"; fi
        ;;
    esac
  done
done

# ---------------------------------------------------------------------------
# 4. IP forwarding & NAT
# ---------------------------------------------------------------------------
header "IP Forwarding & NAT"

ipv4_fwd=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "0")
if [[ "$ipv4_fwd" == "1" ]]; then
  pass "IPv4 forwarding: enabled"
else
  fail "IPv4 forwarding: disabled (UE traffic cannot reach internet)"
fi

if command -v nft &>/dev/null; then
  if nft list table ip open5gs &>/dev/null 2>&1; then
    pass "NAT rules: open5gs nftables table loaded"
  else
    fail "NAT rules: open5gs nftables table not found"
  fi
else
  fail "nftables: not installed"
fi

# ---------------------------------------------------------------------------
# 5. RAN backhaul address
# ---------------------------------------------------------------------------
header "RAN Backhaul"

if [[ "$AMF_NGAP_ADDR" != "127.0.0.5" ]]; then
  if ip addr show 2>/dev/null | grep -q "inet ${AMF_NGAP_ADDR}/"; then
    pass "RAN address ${AMF_NGAP_ADDR}: present on interface"
  else
    fail "RAN address ${AMF_NGAP_ADDR}: not found on any interface"
  fi
else
  warn "NGAP bound on loopback (127.0.0.5) — gNB on another Pi cannot reach AMF"
fi

# ---------------------------------------------------------------------------
# 6. MongoDB Docker container
# ---------------------------------------------------------------------------
header "MongoDB"

if command -v docker &>/dev/null; then
  container_state=$(docker inspect -f '{{.State.Status}}' "$MONGO_CONTAINER" 2>/dev/null || echo "not_found")
  if [[ "$container_state" == "running" ]]; then
    pass "Container '${MONGO_CONTAINER}': running"
  elif [[ "$container_state" == "not_found" ]]; then
    fail "Container '${MONGO_CONTAINER}': not found"
  else
    fail "Container '${MONGO_CONTAINER}': ${container_state}"
  fi
else
  fail "Docker not installed"
fi

# MongoDB TCP connectivity
if check_tcp "127.0.0.1" "$MONGO_PORT"; then
  pass "MongoDB port 127.0.0.1:${MONGO_PORT} listening"
else
  fail "MongoDB port 127.0.0.1:${MONGO_PORT} not listening"
fi

# ---------------------------------------------------------------------------
# 7. TUN device
# ---------------------------------------------------------------------------
header "TUN Device"

if ip link show ogstun &>/dev/null; then
  tun_state=$(ip -br link show ogstun | awk '{print $2}')
  if [[ "$tun_state" == "UP" ]] || [[ "$tun_state" == "UNKNOWN" ]]; then
    pass "ogstun: ${tun_state}"
  else
    fail "ogstun: ${tun_state} (expected UP)"
  fi
else
  fail "ogstun: interface not found"
fi

# ---------------------------------------------------------------------------
# 8. Grafana metrics stack (Telegraf + InfluxDB + Grafana containers)
# ---------------------------------------------------------------------------
if command -v docker &>/dev/null; then
  grafana_running=$(docker ps --filter "name=grafana" --format '{{.Names}}' 2>/dev/null || true)
  telegraf_running=$(docker ps --filter "name=telegraf" --format '{{.Names}}' 2>/dev/null || true)
  influx_running=$(docker ps --filter "name=influxdb" --format '{{.Names}}' 2>/dev/null || true)

  if [[ -n "$grafana_running" ]] || [[ -n "$telegraf_running" ]] || [[ -n "$influx_running" ]]; then
    header "Grafana Metrics Stack"

    if [[ -n "$grafana_running" ]]; then
      pass "Grafana container: running"
    else
      fail "Grafana container: not running"
    fi

    if [[ -n "$telegraf_running" ]]; then
      pass "Telegraf container: running"
    else
      fail "Telegraf container: not running"
    fi

    if [[ -n "$influx_running" ]]; then
      pass "InfluxDB container: running"
    else
      fail "InfluxDB container: not running"
    fi
  fi
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
