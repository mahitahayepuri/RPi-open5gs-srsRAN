# Firewall Recommendations

This project does **not** deploy firewall rules. The playbooks configure only the networking required for the 5G stack to function (interface addressing, IP forwarding, NAT masquerade). Security-oriented traffic filtering is left to the operator.

This document provides a port reference and example nftables rulesets for hardening both Pis.

## Port Reference

### Core Pi (Open5GS)

| Port | Protocol | Bind Address | Direction | Purpose |
|---|---|---|---|---|
| 22 | TCP | 0.0.0.0 | in | SSH (management) |
| 7777 | TCP | 127.0.0.{4,5,...,20} | local | SBI (inter-NF communication) |
| 38412 | SCTP | `open5gs_ran_addr` | in (from gNB) | NGAP / N2 (gNB control plane) |
| 8805 | UDP | 127.0.0.4, 127.0.0.7 | local | PFCP / N4 (SMF and UPF) |
| 2152 | UDP | `open5gs_ran_addr` | in (from gNB) | GTP-U / N3 (gNB user plane) |
| 27017 | TCP | 127.0.0.1 | local | MongoDB |
| 9999 | TCP | 0.0.0.0 | in | Open5GS WebUI (Docker container) |
| 3300 | TCP | 0.0.0.0 | in | Grafana dashboard |
| 8081 | TCP | 0.0.0.0 | in | InfluxDB (Grafana stack internal) |

### gNB Pi (srsRAN)

| Port | Protocol | Bind Address | Direction | Purpose |
|---|---|---|---|---|
| 22 | TCP | 0.0.0.0 | in | SSH (management) |
| 38412 | SCTP | `srsran_gnb_bind_addr` | out (to AMF) | NGAP / N2 (initiated by gNB) |
| 2152 | UDP | `srsran_gnb_bind_addr` | out (to UPF) | GTP-U / N3 (initiated by gNB) |
| 8001 | TCP | 0.0.0.0 | in (from Telegraf) | Metrics WebSocket (release_25_10+) |
| 55555 | TCP | 0.0.0.0 | in (from metrics_server) | JSON metrics (release_24_10_1) |
| 2000 | TCP | 127.0.0.1 | local | ZMQ TX (testing only) |
| 2001 | TCP | 127.0.0.1 | local | ZMQ RX (testing only) |

### Subnet Reference

| Subnet | Purpose |
|---|---|
| `10.53.1.0/24` | RAN backhaul (N2/N3 between core and gNB) |
| `10.45.0.0/16` | UE IPv4 pool (NAT masqueraded on core Pi) |
| `2001:db8:cafe::/48` | UE IPv6 pool |

## Example nftables Rules

### Core Pi

```nft
#!/usr/sbin/nft -f
flush ruleset

# --- NAT for UE traffic (deployed by Ansible in /etc/open5gs/nat.nft) ---
# This table is already managed by the open5gs-nat.service.
# Do NOT duplicate it here; it is included for reference only.
#
# table ip open5gs {
#   chain postrouting {
#     type nat hook postrouting priority srcnat; policy accept;
#     oifname != "ogstun" ip saddr 10.45.0.0/16 masquerade
#   }
# }

# --- Security filtering ---
table inet firewall {
  chain input {
    type filter hook input priority filter; policy drop;

    # Established / related traffic
    ct state established,related accept

    # Loopback
    iif "lo" accept

    # ICMP / ICMPv6 (ping, neighbor discovery)
    meta l4proto icmp accept
    meta l4proto icmpv6 accept

    # SSH (restrict to your management subnet if possible)
    tcp dport 22 accept
    # tcp dport 22 ip saddr 192.168.2.0/24 accept

    # NGAP from gNB (SCTP 38412 on the RAN subnet)
    ip saddr 10.53.1.0/24 sctp dport 38412 accept

    # GTP-U from gNB (UDP 2152 on the RAN subnet)
    ip saddr 10.53.1.0/24 udp dport 2152 accept

    # Grafana dashboard (restrict to LAN if desired)
    tcp dport 3300 accept

    # Grafana stack internals — Telegraf WebSocket from gNB
    # (InfluxDB 8081 is only needed locally by the Grafana containers)

    # Open5GS WebUI (Docker container — restrict to LAN)
    # tcp dport 9999 ip saddr 192.168.2.0/24 accept

    # Log and drop everything else
    # limit rate 5/minute log prefix "nft-drop: " drop
  }

  chain forward {
    type filter hook forward priority filter; policy drop;

    # Established / related
    ct state established,related accept

    # UE traffic from ogstun to physical NIC (NAT handles source rewrite)
    iifname "ogstun" accept

    # Return traffic to UEs
    oifname "ogstun" ct state established,related accept
  }

  chain output {
    type filter hook output priority filter; policy accept;
  }
}
```

### gNB Pi

```nft
#!/usr/sbin/nft -f
flush ruleset

table inet firewall {
  chain input {
    type filter hook input priority filter; policy drop;

    ct state established,related accept
    iif "lo" accept
    meta l4proto icmp accept
    meta l4proto icmpv6 accept

    # SSH
    tcp dport 22 accept

    # Metrics endpoint (from metrics_server on the core Pi)
    # Port depends on srsRAN version: 55555 for release_24_10_1, 8001 for release_25_10+
    ip saddr 10.53.1.0/24 tcp dport 55555 accept
    # Or restrict to the core Pi's LAN address:
    # ip saddr 192.168.2.72 tcp dport 55555 accept
  }

  chain forward {
    type filter hook forward priority filter; policy drop;
  }

  chain output {
    type filter hook output priority filter; policy accept;
  }
}
```

## Deployment Notes

1. **Test before persisting.** Load the rules with `nft -f <file>` and verify connectivity before enabling them at boot. A bad ruleset can lock you out of SSH.

2. **Persist via nftables.service.** Copy your ruleset to `/etc/nftables.conf` and enable `systemctl enable nftables`. The service loads the file at boot.

3. **Do not conflict with open5gs-nat.service.** The NAT table (`table ip open5gs`) is managed by the Ansible-deployed `open5gs-nat.service`. Your security rules should use a separate table name (e.g., `table inet firewall` as shown above). Using `flush ruleset` at the top of your firewall config will delete the NAT table — either remove the flush or load security rules first and NAT after.

   A safe approach:
   ```bash
   # Load security rules (no flush — append to existing)
   sudo nft -f /etc/nftables-security.conf

   # Or start NAT after security rules
   sudo systemctl restart open5gs-nat
   ```

4. **SCTP support.** Ensure your kernel has SCTP connection tracking (`nf_conntrack_proto_sctp`). Without it, `ct state established,related` won't track NGAP connections. On Raspberry Pi OS Trixie, this module is typically available:
   ```bash
   sudo modprobe nf_conntrack
   # Verify: lsmod | grep sctp
   ```

5. **Docker and nftables.** Docker manages its own iptables/nftables chains for container networking. The rules above do not interfere with Docker's chains because they use a separate table (`inet firewall` vs Docker's `ip nat` / `ip filter`). However, if you use `flush ruleset`, you will break Docker networking. Avoid flushing if Docker containers are running.
