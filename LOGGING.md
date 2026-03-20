# Log Files and Monitoring

Both Pis produce structured logs that can be monitored in real time.
This guide covers where to find them and how to view them.

## gNB Pi (srsRAN)

The gNB logs to journald via stdout. rsyslog splits the stream into
per-component files based on the 3GPP functional split:

| File | Component | What it contains |
|---|---|---|
| `/var/log/srsran/cucp.log` | CU-CP | RRC connection setup/release, NGAP messages to AMF, F1AP, E1AP |
| `/var/log/srsran/cuup.log` | CU-UP | PDCP encryption, SDAP QoS mapping, GTP-U tunnels to UPF |
| `/var/log/srsran/du.log` | DU | MAC scheduling, HARQ, RLC segmentation, PHY layer |
| `/var/log/srsran/gnb.log` | All | Combined log (all components in one file) |

### Viewing gNB logs

```bash
# Watch a single component:
tail -f /var/log/srsran/cucp.log

# Watch all three side by side (if multitail is installed):
multitail /var/log/srsran/cucp.log /var/log/srsran/cuup.log /var/log/srsran/du.log

# Full unfiltered stream via journald:
journalctl -u srsran-gnb -f

# Search for a specific UE (by RNTI):
grep "rnti=0x4601" /var/log/srsran/cucp.log

# Last 100 lines from the DU:
tail -100 /var/log/srsran/du.log
```

### Installing multitail (optional)

```bash
sudo apt install multitail
```

Then view all gNB components simultaneously:

```bash
multitail /var/log/srsran/cucp.log /var/log/srsran/cuup.log /var/log/srsran/du.log
```

Press `q` to quit. Press `b` to scroll back in a pane.

## Core Pi (Open5GS)

Each Open5GS network function writes to its own log file under
`/var/log/open5gs/`:

| File | NF | What it contains |
|---|---|---|
| `/var/log/open5gs/amf.log` | AMF | UE registration, NGAP from gNB, mobility |
| `/var/log/open5gs/smf.log` | SMF | PDU session creation, PFCP to UPF |
| `/var/log/open5gs/upf.log` | UPF | GTP-U tunnels, user-plane forwarding |
| `/var/log/open5gs/nrf.log` | NRF | NF registration and discovery |
| `/var/log/open5gs/ausf.log` | AUSF | UE authentication |
| `/var/log/open5gs/udm.log` | UDM | Subscriber profile lookups |
| `/var/log/open5gs/udr.log` | UDR | Database queries (MongoDB) |
| `/var/log/open5gs/pcf.log` | PCF | QoS policy decisions |
| `/var/log/open5gs/nssf.log` | NSSF | Network slice selection |
| `/var/log/open5gs/bsf.log` | BSF | Session binding |
| `/var/log/open5gs/scp.log` | SCP | SBI message routing |

### Viewing Open5GS logs

```bash
# Watch the AMF (most useful for debugging UE attach):
tail -f /var/log/open5gs/amf.log

# Watch AMF and UPF together (control + user plane):
multitail /var/log/open5gs/amf.log /var/log/open5gs/upf.log

# Watch all NFs at once:
multitail /var/log/open5gs/amf.log /var/log/open5gs/smf.log \
  /var/log/open5gs/upf.log /var/log/open5gs/ausf.log

# Check for errors across all NFs:
grep -i error /var/log/open5gs/*.log

# Follow a specific NF via journald:
journalctl -u open5gs-amfd -f
```

## What to watch during a UE attach

When a UE (srsUE or a real phone) connects, the key events flow through
these logs in order:

| Step | Where to look | What you'll see |
|---|---|---|
| 1. gNB → AMF connection | `cucp.log` + `amf.log` | NGAP Setup Request/Response |
| 2. UE RRC setup | `cucp.log` | RRC Setup Request/Complete |
| 3. Authentication | `amf.log` + `ausf.log` | Authentication Request/Response |
| 4. Security mode | `cucp.log` + `amf.log` | Security Mode Command/Complete |
| 5. PDU session setup | `amf.log` + `smf.log` + `upf.log` | PDU Session Resource Setup |
| 6. Data flows | `du.log` + `cuup.log` + `upf.log` | MAC grants, PDCP packets, GTP-U |

### Quick debugging recipe

If a UE fails to attach, check in this order:

```bash
# 1. Is the gNB connected to the AMF?
tail -20 /var/log/srsran/cucp.log | grep -i ngap

# 2. Did authentication succeed?
tail -20 /var/log/open5gs/amf.log | grep -i auth

# 3. Was a PDU session created?
tail -20 /var/log/open5gs/smf.log | grep -i "PDU session"

# 4. Is the UPF forwarding traffic?
tail -20 /var/log/open5gs/upf.log | grep -i gtpu
```

## Timestamp reference

Each log source uses a different timestamp format and timezone.  When
correlating events across Pis (e.g. "was the gNB throttling when the UE
dropped?"), use the **rsyslog prefix** — it is the one consistent
timebase across all log files.

### Timestamp summary

| Source | Example | Timezone | Format |
|---|---|---|---|
| rsyslog prefix (all routed log files) | `2026-03-18T14:19:57.562454-04:00` | Local with offset | ISO-8601 |
| syslog (`/var/log/syslog`) | `2026-03-18T14:56:26.105881-04:00` | Local with offset | ISO-8601 |
| journalctl output | `Mar 18 14:56:25` | Local (no offset) | Short, no year |
| srsRAN gNB (app timestamp) | `2026-03-18T18:56:25.525343` | **UTC, no offset indicator** | ISO-8601 |
| Open5GS NFs (app timestamp) | `03/18 14:19:57.435` | Local (no offset) | MM/DD HH:MM:SS, no year |

### srsRAN timestamps are UTC

The srsRAN gNB application logs timestamps in **UTC** regardless of the
system's local timezone.  This is hardcoded in the application (it uses
`gmtime`, not `localtime`) and there is no configuration option to
change it.

In the rsyslog-routed log files (`/var/log/srsran/*.log`), each line
contains **two** timestamps — the rsyslog prefix (local) and the srsRAN
application timestamp (UTC):

```
2026-03-18T14:19:57.562454-04:00 raspi4b-2 srsran-gnb[89777]: 2026-03-18T18:19:57.560284 [NGAP] [I] ...
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^                                  ^^^^^^^^^^^^^^^^^^^^^^^^^^^
rsyslog prefix: 14:19 local (EDT)                               srsRAN app: 18:19 UTC
```

The 4-hour difference (EDT = UTC-4) is easy to miss when scanning logs.
**Always use the rsyslog prefix** (the first timestamp on each line) for
cross-log correlation.

### Open5GS timestamps are local but abbreviated

Open5GS NFs log with `MM/DD HH:MM:SS.mmm` format in local time.  This
matches the rsyslog prefix but has **no year and no timezone indicator**.
The rsyslog prefix is again the authoritative source for unambiguous
timestamps.

### Correlating across Pis

When investigating an event that spans both Pis (e.g. a UE attach that
involves the gNB on one Pi and the AMF on another), use the rsyslog
prefix from both log files.  Both Pis are NTP-synchronized
(`System clock synchronized: yes`) so the rsyslog prefixes are
directly comparable:

```bash
# Find the NGAP message on the gNB Pi:
grep "2026-03-18T14:19:57" /var/log/srsran/cucp.log

# Find the corresponding AMF event on the core Pi:
grep "2026-03-18T14:19:57" /var/log/open5gs/amf.log
```

Both timestamps will be in local time with offset, making direct
comparison straightforward.

## Log rotation

Both gNB and Open5GS logs are rotated daily by logrotate (7 days retained, compressed).

- **gNB logs** (`/var/log/srsran/*.log`): Rotated by `/etc/logrotate.d/srsran-gnb`
- **Open5GS NF logs** (`/var/log/open5gs/*.log`): Rotated by `/etc/logrotate.d/open5gs`

Both configs use: daily rotation, 7-day retention, compression, and `copytruncate`.

## Implementation details

### Log pipeline architecture

**srsRAN gNB:**

1. gNB process logs to stdout
2. systemd (`srsran-gnb.service`) captures to journald
3. rsyslog reads from journald (`/etc/rsyslog.d/30-srsran-gnb.conf`)
4. rsyslog routes by component tag (`[RRC]`, `[MAC]`, etc.) to `/var/log/srsran/`
5. logrotate manages rotation (`/etc/logrotate.d/srsran-gnb`)

**Open5GS NFs:**

1. Each NF (amfd, smfd, upfd, etc.) logs to stdout (built-in file logger removed via `yq`)
2. systemd captures to journald
3. rsyslog reads from journald (`/etc/rsyslog.d/30-open5gs.conf`)
4. rsyslog routes by program name (e.g. `open5gs-amfd`) to `/var/log/open5gs/`
5. logrotate manages rotation (`/etc/logrotate.d/open5gs`)

rsyslog itself is installed by the common `pi_setup.yml` playbook on both Pis.

## See also

- [`GLOSSARY.md`](GLOSSARY.md) -- definitions of CU-CP, CU-UP, DU, NF
  names, and protocol acronyms
- [`E2ETEST-SRSUE.md`](E2ETEST-SRSUE.md) -- automated test with
  troubleshooting for common failures
