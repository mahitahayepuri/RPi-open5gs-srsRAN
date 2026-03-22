# TODO — Deferred Improvements

Low-priority items that are not blocking functionality but would improve
robustness or maintainability.  Tracked here so they don't get lost.

---

## E2E test script (`srsue/tools/srsue_e2e_test.sh`)

### Error handling hardening

- **Add journalctl hint on gNB restart failure.**  When the gNB fails to
  restart, print `Check: sudo journalctl -u srsran-gnb -n 20` so the
  student knows where to look.

- **Verify srsUE actually started.**  After backgrounding srsUE, add a
  short `sleep 0.5` + `kill -0 "$UE_PID"` check before entering the
  attach-wait loop.  Currently a bad binary path or missing config will
  silently fail and the script waits the full attach timeout.

- **Check FIFO creation.**  `mkfifo` can fail if `/tmp` is full or
  read-only.  Wrap it in an `if !` guard with a clear error message.

### Parameterisation

- **gNB config path** (`/etc/srsran/gnb.yml`) — hardcoded in the
  `PING_TARGET` auto-detection block.  Could be exposed as
  `GNB_CONFIG="${GNB_CONFIG:-/etc/srsran/gnb.yml}"`.

- **TUN interface name** (`tun_srsue`) — hardcoded.  Could be
  auto-detected from the srsUE config file like the netns name is.

- **Log paths** (`/tmp/srsue_e2e.log`, `/tmp/srsue_e2e_ping.log`) —
  hardcoded.  Could be exposed as `SRSUE_LOG_DIR`.

---

## Pi 4 pair — subscriber provisioning

- **MongoDB not running on Pi 4 core (192.168.2.66).**  `mongod`,
  `mongodb`, and `mongos` services are all inactive.  AMF returns
  HTTP 400 on subscriber lookup, causing Registration reject [95].
  Needs investigation — possibly a deployment ordering issue or a
  missing `mongod` install on Pi 4.

---

## Grafana stack

- **Disabled pending rework for `release_24_10_1`'s metrics
  architecture.**  The old Grafana playbook expected Prometheus scraping;
  the new srsRAN release uses JSON-over-TCP on port 55555.  See
  `srsran/playbooks/srsran_install/main.yml` TODO comment.
