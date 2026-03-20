# Version Pinning

This project pins specific release versions of the srsRAN Project (gNB) and
srsRAN 4G (srsUE) to ensure they work together.  This document explains **why**
these versions were chosen and **how** to override them.

---

## Current Pins

| Component    | Repository       | Pin                | Commit    | Date       |
|------------- |------------------|--------------------|-----------|------------|
| **gNB**      | srsRAN\_Project  | `release_24_10_1`  | `ef4b074` | 2025-01-09 |
| **srsUE**    | srsRAN\_4G       | `release_23_11`    | `eea87b1` | 2023-11-23 |

### Where the pins are set

| Variable               | File                   | Used by            |
|------------------------|------------------------|--------------------|
| `srsran_source_version`| `group_vars/gnb.yml`   | gNB compile & config |
| `srsue_source_version` | `group_vars/ue.yml`    | srsUE compile & config |
| `srsran_source_version`| `group_vars/all.yml`   | Grafana metrics stack clone |

---

## Why These Versions?

### gNB: `release_24_10_1`

`release_24_10_1` is the last hotfix on the 24.10 branch before the 25.10
release.  The 25.10 release (and later `main`) introduced a **reworked threading
and execution model** that fundamentally changed how the PHY layer schedules
work.  This architectural change broke timing compatibility with srsUE's
prototype NR PHY, causing srsUE to hang at "Waiting PHY to initialize" and
never achieve PRACH sync.

Key compatibility details for `release_24_10_1`:

- The `amf` block lives under `cu_cp:` (moved in 24.10 from top-level).
- `remote_control` does **not** exist (introduced in 25.10).
- `metrics` uses a JSON-over-TCP endpoint on port 55555, not WebSocket.
- `pdcch` and `prach` sections under `cell_cfg` are required for srsUE
  interop (the Ansible-generated `/etc/srsran/gnb.yml` includes these
  automatically when `srsran_rf_driver` is `zmq`).

> **Note:** The srsRAN Project was archived on 2026-02-17 and development
> moved to the [OCUDU project](https://github.com/OCUDU) (Open Cellular
> User-Defined Unit -- the successor project for open-source RAN).
> `release_24_10_1` is effectively the last
> release that works with srsUE.

### srsUE: `release_23_11`

`release_23_11` is the srsRAN 4G release that **fixed srsUE for 5G SA mode**
at 5/10/15/20 MHz bandwidths.  The official srsRAN Project documentation
requires "srsRAN 4G 23.11 or later" for the ZMQ-based srsUE testing workflow.

Since srsRAN 4G development is frozen (last commit: December 2023), there are
no newer releases to choose from.  `release_23_11` is the correct and only
choice.

---

## How to Override

### Temporarily (one run)

```bash
# Build gNB from a different tag
ansible-playbook -i inventory-pi4.ini srsran/playbooks/srsran.yml \
  -e srsran_source_version=main

# Build srsUE from a different tag
ansible-playbook -i inventory-pi4.ini srsue/playbooks/srsue.yml \
  -e srsue_source_version=master
```

### Permanently

Edit the version variable in the corresponding `group_vars/` file:

```yaml
# group_vars/gnb.yml
srsran_source_version: "release_24_10_1"   # change this

# group_vars/ue.yml
srsue_source_version: "release_23_11"      # change this
```

After changing the pin, re-run the corresponding playbook to trigger a fresh
`git clone --depth 1` + full recompile.

### Per-host override

If you want different versions on different Pis (e.g. testing a new release on
the Pi 5 pair while keeping the Pi 4 stable), use host variables:

```ini
# inventory-pi5.ini
[gnb]
192.168.2.55 ansible_user=pi srsran_source_version=main
```

---

## Compatibility Matrix

The following combinations have been tested:

| gNB version       | srsUE version   | Result |
|--------------------|-----------------|--------|
| `release_24_10_1`  | `release_23_11` | Works (ZMQ, 10 MHz, band 3) |
| `main` (post-25.10)| `release_23_11` | Fails: srsUE hangs at PHY init |
| `main` (post-25.10)| `master`        | Fails: srsUE hangs at PHY init |

---

## Related Config Changes by Version

When changing the gNB version pin, the gNB config template in
`srsran/playbooks/srsran_install/install.yml` must match.  Key differences:

| Config area       | `release_24_10_1`                  | `release_25_10` / `main`           |
|--------------------|------------------------------------|------------------------------------|
| AMF location       | `cu_cp.amf.addr`                  | `cu_cp.amf.addr`                  |
| Metrics            | `metrics.addr` + `metrics.port`   | `metrics.enable_json`             |
| Remote control     | Not available                      | `remote_control.enabled/bind_addr`|
| PDCCH/PRACH        | Required for srsUE                 | Required for srsUE                |
| Grafana stack      | `docker-compose.yml` (metrics\_server + InfluxDB 2) | `docker-compose.ui.yml` (Telegraf + InfluxDB 3) |
