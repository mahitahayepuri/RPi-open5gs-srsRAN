# srsRAN Source Edits

Two patches are applied to the upstream srsRAN source code after
cloning.  Both work around real issues that prevent the ZMQ-based
srsUE testing workflow from functioning correctly on Raspberry Pi
hardware.  This document explains each edit in detail: what the
problem is, why it happens, and how the fix works.

---

## 1. FFTW Planner Flag: FFTW_MEASURE to FFTW_ESTIMATE

**Affects:** srsRAN 4G (srsUE) -- `lib/src/phy/dft/dft_fftw.c`

**Applied by:** `srsue/playbooks/srsue_install/compile.yml`

### Problem

srsUE hangs at **"Waiting PHY to initialize"** and never progresses
to cell search or PRACH.

### Root cause

The FFTW3 library uses *planner flags* to control how it selects a DFT
algorithm.  The srsRAN 4G source uses `FFTW_MEASURE`, which tells FFTW
to run real timing benchmarks on multiple candidate algorithms and pick
the fastest one.

When the RF backend is ZMQ (software radio over localhost sockets),
there is no real-time sample clock.  The FFTW benchmark loop runs
indefinitely because the timing measurements never converge -- the
samples arrive on a software schedule, not at a fixed sample rate.
PHY initialization blocks forever waiting for the planner to finish.

### Fix

Replace `FFTW_MEASURE` with `FFTW_ESTIMATE` in `dft_fftw.c`:

```c
// Before (upstream)
p = fftwf_plan_dft_1d(dft->size, dft->in, dft->out, sign, FFTW_MEASURE);

// After (patched)
p = fftwf_plan_dft_1d(dft->size, dft->in, dft->out, sign, FFTW_ESTIMATE);
```

`FFTW_ESTIMATE` uses heuristics to choose an algorithm without running
any benchmarks.  The resulting plan may be slightly slower for very large
transforms, but at the bandwidths used in this project (10 MHz / 15 kHz
SCS) the difference is negligible.  PHY initialization completes
immediately.

The Ansible playbook applies this automatically with a regex replace
across the file -- all `FFTW_MEASURE` occurrences become
`FFTW_ESTIMATE` before the cmake build step.

### Manual application

```bash
cd /usr/local/src/srsRAN_4G
sudo sed -i 's/FFTW_MEASURE/FFTW_ESTIMATE/g' lib/src/phy/dft/dft_fftw.c
```

Then rebuild:

```bash
cd build && sudo make -j$(nproc) srsue && sudo make install
```

### References

- FFTW3 planner flags: <http://www.fftw.org/fftw3_doc/Planner-Flags.html>
- The flag applies to both `fftwf_plan_dft_1d` (float) and
  `fftw_plan_dft_1d` (double) calls in the file.

---

## 2. ZMQ Socket Hang: Stdin FIFO and Graceful Deregistration

**Affects:** srsRAN 4G (srsUE) + srsRAN Project (gNB) via ZMQ

**Applied by:** `srsue/tools/srsue_e2e_test.sh`

### Problem

The E2E test passes on the first run but **fails on the second
consecutive run**.  srsUE cannot find the cell -- it times out at cell
search with no downlink samples arriving.

### Root cause

The failure chain involves three components:

1. **srsUE stdin EOF** -- The test script runs srsUE as a background
   process (`&`).  In bash, a backgrounded process has stdin connected
   to `/dev/null` (or the script's stdin, which is already closed when
   run non-interactively by Ansible).  srsUE's `main.cc` has an input
   thread that reads stdin for interactive commands.  When it gets EOF,
   it calls `raise(SIGTERM)`.

2. **Premature SIGTERM** -- The SIGTERM fires almost immediately after
   launch.  srsUE's signal handler sets `running = false` and the main
   loop calls `ue.switch_off()`, which sends a NAS Deregistration
   Request.  But the SIGTERM arrives so quickly that the deregistration
   exchange over ZMQ doesn't have time to complete before the process
   exits.

3. **gNB ZMQ REQ socket stuck** -- The gNB's ZMQ radio transport uses a
   REQ/REP socket pair.  ZMQ enforces strict send/receive alternation
   on REQ sockets: after sending a request, the socket must receive a
   reply before it can send again.  When srsUE exits mid-exchange, the
   gNB's REQ socket is left waiting for a reply that will never come.
   The socket cannot be recovered -- it's permanently stuck.  All
   subsequent radio traffic is frozen.

4. **Second run fails** -- A new srsUE instance connects to the gNB's
   ZMQ ports, but the gNB cannot send or receive samples because the
   REQ socket is hung.  srsUE sees no downlink, finds no cell, and
   times out.

### Fix (two parts)

> **Update (March 2026):** Live testing on Raspberry Pi hardware showed
> that Part B (graceful deregistration) does **not** reliably prevent the
> ZMQ hang.  srsUE consistently reports *"Couldn't stop after 5s.
> Forcing exit."* — the NAS Deregistration exchange never completes over
> ZMQ before the grace period expires.  The gNB's ZMQ sockets get stuck
> after **every** srsUE session, regardless of how srsUE is stopped.
>
> The reliable workaround is to **restart the gNB service** before each
> new srsUE session (`systemctl restart srsran-gnb`).  The E2E test
> script does this automatically.  Parts A and B are retained as defence
> in depth.
>
> See [SRSUE.md — Known limitations](SRSUE.md#known-limitations-zmq-mode)
> for the full status.

#### Part A: FIFO-based stdin keepalive

Instead of letting srsUE inherit a closed stdin, the test script creates
a named FIFO and holds the write end open with `sleep infinity`:

```bash
_stdin_fifo="/tmp/.srsue_stdin_$$"
mkfifo "$_stdin_fifo"
sleep infinity > "$_stdin_fifo" &
STDIN_PID=$!
"$SRSUE_BINARY" "$SRSUE_CONFIG" < "$_stdin_fifo" > /tmp/srsue_e2e.log 2>&1 &
```

srsUE's input thread reads from the FIFO.  Since the write end is held
open by `sleep infinity`, `read()` blocks instead of returning EOF.
No EOF means no `raise(SIGTERM)` -- srsUE stays alive until the test
script sends an explicit signal.

#### Part B: Graceful SIGTERM with deregistration grace period

The cleanup function sends SIGTERM and waits up to 5 seconds for srsUE
to complete the NAS Deregistration exchange:

```bash
kill "$UE_PID" 2>/dev/null
# Wait for NAS Deregistration to complete over ZMQ
local grace=5
for i in $(seq 1 "$grace"); do
  kill -0 "$UE_PID" 2>/dev/null || break
  sleep 1
done
# Force-kill if still alive
if kill -0 "$UE_PID" 2>/dev/null; then
  kill -9 "$UE_PID" 2>/dev/null
fi
```

The intent is to give `switch_off()` enough time to send the
Deregistration Request, receive the Accept from the AMF via the gNB,
and close the ZMQ sockets cleanly.  In practice, however, the NAS
exchange never completes over ZMQ in time — srsUE reports "Couldn't
stop after 5s. Forcing exit." and the gNB's REQ socket is left stuck
(see the Update note above).

The cleanup function also kills the `sleep infinity` keepalive process
and removes the FIFO file.

### Why not fix the gNB instead?

The gNB's ZMQ transport is part of the upstream srsRAN Project, which
was archived in February 2026.  Patching the REQ/REP socket to use a
timeout or DEALER/ROUTER pattern would be a deeper change to frozen
code.  The FIFO + graceful shutdown approach mitigates the premature
SIGTERM issue on the srsUE side without modifying the gNB source, but
the ZMQ hang still occurs after every session, requiring a gNB restart.

### Reproducing the original failure

To see the original bug:

1. Remove the FIFO mechanism (launch srsUE with `"$SRSUE_BINARY" "$SRSUE_CONFIG" &`)
2. Run the E2E test twice in a row
3. The first run passes; the second hangs at cell search
4. `journalctl -u srsran-gnb` on the gNB Pi shows no further radio
   activity after the first srsUE exit

### References

- ZMQ REQ/REP pattern: <https://zguide.zeromq.org/docs/chapter2/#Request-Reply-Combinations>
- srsUE `main.cc` input thread: calls `raise(SIGTERM)` on stdin EOF
- srsUE `switch_off()`: sends NAS Deregistration Request via RRC
