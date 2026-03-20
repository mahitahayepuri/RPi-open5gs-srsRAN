# End-to-End Test with srsUE

Automated verification that the complete 5G SA data path is working:
UE → gNB (ZMQ) → AMF/UPF (N2/N3) → core Pi.

## Prerequisites

Before running the test, all three deployment playbooks must have completed
successfully:

1. `open5gs/playbooks/open5gs.yml` -- 5G core deployed and running
2. `srsran/playbooks/srsran.yml` -- gNB deployed (ZMQ mode)
3. `srsue/playbooks/srsue.yml` -- srsUE compiled, configured, and subscriber
   provisioned

## Running the test

From your computer:

```bash
ansible-playbook -i inventory-pi5.ini e2e-test-srsue.yml
```

The playbook:

1. **Verifies the Open5GS core** is running on the core Pi
2. **Starts the gNB** if it isn't already running, and waits for the NGAP
   connection to the AMF
3. **Deploys and runs the test script** on the gNB Pi, which:
   - Starts srsUE in the background
   - Waits up to 30 seconds for a PDU session (watches for the `tun_srsue`
     interface to appear)
   - Pings the core Pi's RAN address (`10.53.1.1`) through the `tun_srsue`
     interface -- this traffic flows through the full 5G user plane
   - Stops srsUE and reports the result
4. **Reports pass or fail** in the Ansible output

## What "pass" means

A passing test proves that:

- The AMF accepted the gNB's NGAP association (control plane works)
- The UE successfully authenticated with the core (subscriber credentials
  match between srsUE config, MongoDB, and the USIM parameters)
- A PDU session was established (SMF created the session, UPF allocated
  an IP from the 10.45.0.0/16 pool)
- User-plane data flows through the GTP-U tunnel from the UE through the
  gNB to the UPF and out the `ogstun` TUN device on the core Pi

## What "fail" means

| Failure | Likely cause | Where to look |
|---|---|---|
| "Open5GS stack is not running" | Core Pi services not started | `sudo open5gs_check` on core Pi |
| "srsran-gnb service is not running" | gNB failed to start | `journalctl -u srsran-gnb` on gNB Pi |
| "srsUE exited unexpectedly" | srsUE crashed during attach | `/tmp/srsue_e2e.log` on gNB Pi |
| "PDU session not established" | Authentication failure or PLMN mismatch | `/tmp/srsue_e2e.log` on gNB Pi; check IMSI/Ki/OPC and PLMN match |
| "PDU session not established" with "No SEPP" / "NF-Discover failed [504]" in SCP journal | NRF serving PLMN is still the default 999/70 instead of your network's PLMN | Check `/etc/open5gs/nrf.yaml` `serving` section; re-run `network.yml` or fix manually with `yq` |
| "PDU session not established" with "No SST" / "No UE-AMBR" in UDR journal | Subscriber integer fields stored as BSON doubles instead of INT32 | Re-insert subscriber using `NumberInt()` wrappers and add top-level `ambr`; see SRSUE.md |
| "Ping failed" | UE attached but data path broken | IP forwarding or NAT issue on core Pi; `sudo open5gs_check` |

## Logs

The test script saves logs on the gNB Pi:

- `/tmp/srsue_e2e.log` -- full srsUE console output (attach procedure,
  RRC messages, errors)
- `/tmp/srsue_e2e_ping.log` -- ping command output

## Running the test manually

You can also run the test script directly on the gNB Pi (useful for
debugging):

```bash
# On the gNB Pi (gNB must already be running):
sudo srsue_e2e_test
```

The script accepts environment variables for customisation:

| Variable | Default | Description |
|---|---|---|
| `SRSUE_BINARY` | `/usr/local/bin/srsue` | Path to srsue binary |
| `SRSUE_CONFIG` | `/etc/srsran_4g/ue.conf` | Path to UE config file |
| `PING_TARGET` | `10.53.1.1` | IP to ping through tun_srsue |
| `ATTACH_TIMEOUT` | `30` | Seconds to wait for PDU session |
| `PING_COUNT` | `3` | Number of ping packets |

Example with custom timeout:

```bash
sudo ATTACH_TIMEOUT=60 srsue_e2e_test
```

## Sequence diagram

```
Control node                gNB Pi                    Core Pi
     │                         │                         │
     ├── Check core running ──►│                         │
     │                         │         ◄── is-active ──┤
     │                         │                         │
     ├── Start gNB ───────────►│                         │
     │                         ├── NGAP Setup Request ──►│
     │                         │◄── NGAP Setup Response──┤
     │                         │                         │
     ├── Run test script ─────►│                         │
     │                         ├── Start srsUE           │
     │                         │   ├── RRC Setup ───────►│
     │                         │   ├── Auth Request ◄────┤
     │                         │   ├── Auth Response ───►│
     │                         │   ├── PDU Session Req ─►│
     │                         │   ◄── PDU Session OK ───┤
     │                         │   (tun_srsue appears)   │
     │                         │                         │
     │                         ├── ping -I tun_srsue ───►│
     │                         │◄── pong ────────────────┤
     │                         │                         │
     │                         ├── Kill srsUE            │
     │◄── Result (pass/fail) ──┤                         │
     │                         │                         │
```
