# TL;DR — Quick Command Reference

Short-form commands for every major workflow in this project.  Each
section is one task you can copy-paste into your terminal.  For the
full explanation of what each playbook does, see the README linked in
the **Details** column.

> All commands assume you are in the project root directory and your
> inventory file is `inventory-pi5.ini`.  Substitute `inventory-pi4.ini`
> if you are targeting a Pi 4 pair.

---

## Deploy Open5GS Core (apt)

```bash
ansible-playbook -i inventory-pi5.ini open5gs/playbooks/open5gs.yml
```

Installs the full 5G SA core on the `[core]` Pi via apt packages.
Includes MongoDB, TUN device, systemd services, and the WebUI.

**Details:** [open5gs/README.md](open5gs/README.md),
[OPEN5GS_INSTALL_METHODS.md](OPEN5GS_INSTALL_METHODS.md)

---

## Deploy srsRAN gNB

```bash
ansible-playbook -i inventory-pi5.ini srsran/playbooks/srsran.yml
```

Builds srsRAN Project from source and deploys the gNB on the `[gnb]`
Pi.  Default RF driver is ZMQ (no SDR hardware needed).

**Details:** [srsran/README.md](srsran/README.md)

---

## Deploy srsUE and Run the E2E Test

Run **after** both Open5GS and srsRAN are deployed:

```bash
ansible-playbook -i inventory-pi5.ini srsue/playbooks/srsue.yml
ansible-playbook -i inventory-pi5.ini e2e-test-srsue.yml
```

The first command builds the srsUE software UE and provisions a test
subscriber in MongoDB.  The second starts the gNB, attaches the UE
over ZMQ, pings through the 5G data path, and reports pass/fail.

**Details:** [SRSUE.md](SRSUE.md), [E2ETEST-SRSUE.md](E2ETEST-SRSUE.md)

---

## Reconfigure PLMN / TAC

```bash
ansible-playbook -i inventory-pi5.ini reconfigure-plmn.yml \
  -e open5gs_mcc=001 -e open5gs_mnc=01 -e open5gs_tac=7
```

Patches AMF, gNB, and srsUE configs with the new PLMN and TAC, updates
the MongoDB subscriber IMSI, and restarts affected services.  Omit the
`-e` flags to use the defaults from `group_vars/all.yml`.

---

## Reconfigure RF Band / Bandwidth (UHD only)

```bash
ansible-playbook -i inventory-pi5.ini reconfigure-rf.yml \
  -e rf_band=78 -e rf_bandwidth_mhz=20
```

Auto-calculates DL ARFCN, subcarrier spacing, and sample rate for the
chosen band and bandwidth.  Only works when the gNB is in UHD mode.

| Band | Duplex | Frequency | SCS |
|---|---|---|---|
| n3 | FDD | 1805–1880 MHz | 15 kHz |
| n7 | FDD | 2620–2690 MHz | 15 kHz |
| n41 | TDD | 2496–2690 MHz | 30 kHz |
| n77 | TDD | 3300–4200 MHz | 30 kHz |
| n78 | TDD | 3300–3800 MHz | 30 kHz |

---

## Convert to OTA (attach an SDR)

1. Connect a USRP B200/B210 to the gNB Pi via USB 3.0.
2. Re-run the gNB playbook with the UHD driver:

```bash
ansible-playbook -i inventory-pi5.ini srsran/playbooks/srsran.yml \
  -e srsran_rf_driver=uhd
```

No recompilation is needed — both ZMQ and UHD drivers are always built.
After switching, use `reconfigure-rf.yml` above to select band and
bandwidth.

**Details:** [RFHARDWARE.md](RFHARDWARE.md)

---

## See also

- [README.md](README.md) — project overview and architecture
- [GLOSSARY.md](GLOSSARY.md) — term definitions
- [FIREWALL.md](FIREWALL.md) — port reference
- [LOGGING.md](LOGGING.md) — log files and timestamps
- [VERSION_PINNING.md](VERSION_PINNING.md) — pinning srsRAN / Open5GS versions
