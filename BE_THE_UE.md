# Be the UE — Interactive Testing over the 5G Network

This guide walks through using the srsUE connection interactively: SSH
into the gNB Pi, verify the radio link is up, start srsUE, enter the UE
network namespace, and run your own tests (ping, iperf, etc.) through
the 5G user plane.  It also covers how to shut down cleanly -- and what
to do if you didn't.

---

## Which machine?

srsUE runs on the **gNB Pi** (the same Pi as the base station).  The
ZMQ radio link between the gNB and srsUE uses localhost sockets, so
both must be on the same host.

Find the gNB Pi's IP in your inventory file:

```bash
grep -A1 '^\[gnb\]' inventory-pi5.ini
# 192.168.2.55 ansible_user=pi ...
```

SSH in:

```bash
ssh pi@<gnb-pi-ip>
```

---

## Step 1 — Verify the gNB is running

The gNB must be up and connected to the AMF on the core Pi before srsUE
can attach.

```bash
sudo systemctl is-active srsran-gnb
# Should print: active
```

If it's not running, start it and wait a few seconds for the NGAP
association:

```bash
sudo systemctl start srsran-gnb
sleep 5
```

Check the journal for a successful AMF connection:

```bash
sudo journalctl -u srsran-gnb --no-pager -n 20
# Look for: "AMF connected"
```

---

## Step 2 — Verify the Open5GS core is running

On the **core Pi** (or from your control machine via Ansible):

```bash
ssh pi@<core-pi-ip> sudo systemctl is-active open5gs-stack.target
# Should print: active
```

If it isn't running:

```bash
ssh pi@<core-pi-ip> sudo systemctl start open5gs-stack.target
```

---

## Step 3 — Start srsUE

Back on the gNB Pi, start srsUE in the foreground so you can see the
attach procedure:

```bash
sudo srsue /etc/srsran_4g/ue.conf
```

Watch for a successful attach:

```
Attaching UE...
Random Access Transmission: prach_occasion=0, preamble_index=0, ...
RRC Connected
PDU Session Establishment successful. IP: 10.45.0.2
```

The key line is **"PDU Session Establishment successful"** with an IP
from the `10.45.0.0/16` pool.  Once you see this, the UE is connected
and the TUN interface (`tun_srsue`) is up inside the `ue1` network
namespace.

> **Leave this terminal running.**  srsUE must stay in the foreground
> for the radio link to remain active.  Open a second SSH session for
> the next steps.

---

## Step 4 — Enter the UE namespace

Open a **second SSH session** to the gNB Pi and read the core Pi's RAN
address from the deployed gNB config:

```bash
CORE_ADDR=$(grep -Po '^\s*addr:\s*\K[\d.]+' /etc/srsran/gnb.yml | head -1)
echo "Core Pi RAN address: $CORE_ADDR"
```

Enter the UE network namespace:

```bash
sudo ip netns exec ue1 bash
```

You now have a shell with the same network view as the UE.  The only
interface is `tun_srsue`, and all traffic goes through the 5G user
plane.

Verify the interface is up:

```bash
ip addr show tun_srsue
# Should show an IP from the 10.45.0.0/16 pool
```

Add a default route so traffic to the core Pi (which is on a different
subnet) goes through the TUN:

```bash
ip route add default dev tun_srsue
```

> **Why is this needed?**  srsUE only adds a link-local /24 route for
> the UE's assigned IP.  The core Pi's RAN address (e.g. 10.53.5.1) is
> on a different subnet, so without a default route the kernel returns
> "Network is unreachable".  The automated E2E test adds this route
> automatically; here you do it by hand.

---

## Step 5 — Run your tests

### Ping

```bash
ping -c 5 "$CORE_ADDR"
```

A successful ping proves the end-to-end data path is working:
UE -> gNB (ZMQ) -> UPF (GTP-U) -> core Pi.

### iperf3 throughput test

Start an iperf3 server on the **core Pi** first:

```bash
# On the core Pi (in a separate terminal):
iperf3 -s
```

Then from the UE namespace on the gNB Pi:

```bash
# Downlink (core → UE):
iperf3 -c "$CORE_ADDR" -R -t 10

# Uplink (UE → core):
iperf3 -c "$CORE_ADDR" -t 10
```

> **Tip:** ZMQ throughput will be much lower than a real radio link.
> This is expected -- ZMQ is a software pipe, not an air interface.
> The test verifies the protocol stack end-to-end, not RF performance.

### Other tools

Any networking tool works inside the namespace:

```bash
traceroute "$CORE_ADDR"
curl http://"$CORE_ADDR":9999/    # Open5GS WebUI (if deployed)
```

> **Note:** The UE can only reach the core Pi's RAN address and
> anything the core Pi forwards.  Internet access requires NAT
> configuration on the core Pi, which is not enabled by default.

---

## Step 6 — Shut down and restart the gNB

After srsUE exits, the gNB's ZMQ sockets will be stuck and unable to
accept a new UE connection (see
[SRSUE.md — Known limitations](SRSUE.md#known-limitations-zmq-mode)).
This happens regardless of how srsUE is stopped — Ctrl+C, `kill`, or
losing the SSH session all produce the same result.

### 1. Exit the UE namespace shell

```bash
exit
# (or Ctrl+D)
```

This just closes your shell -- it does not stop srsUE.

### 2. Stop srsUE

Switch to the terminal where srsUE is running in the foreground and
press **Ctrl+C**.  You should see:

```
Stopping ..
```

> **Note:** srsUE attempts a NAS Deregistration but in practice the ZMQ
> exchange does not complete in time — you will typically see
> "Couldn't stop after 5s. Forcing exit." This is expected behaviour.

### 3. Restart the gNB

The gNB's ZMQ sockets are now stuck.  Restart it to reset them:

```bash
sudo systemctl restart srsran-gnb
sleep 5
```

Verify the NGAP connection is back:

```bash
sudo journalctl -u srsran-gnb --no-pager -n 10
# Look for: "AMF connected"
```

You can now start srsUE again from Step 3.

---

## Recovery — cleaning up stale state

If srsUE was killed with `kill -9`, lost its SSH connection, or you
forgot to follow Step 6, there may be leftover processes and stale
network interfaces that need cleaning up in addition to the gNB
restart.

### Full cleanup

```bash
# 1. Kill any leftover srsUE process
sudo pkill -9 srsue 2>/dev/null
sleep 1

# 2. Remove the stale TUN interface from the namespace
sudo ip netns exec ue1 ip link del tun_srsue 2>/dev/null

# 3. Restart the gNB to reset the ZMQ sockets
sudo systemctl restart srsran-gnb
sleep 5

# 4. Verify the gNB reconnected to the AMF
sudo journalctl -u srsran-gnb --no-pager -n 10
```

Once the gNB is back and connected to the AMF, you can start srsUE
again from Step 3.

### Quick one-liner

If you just want to reset everything fast:

```bash
sudo pkill -9 srsue; sudo ip netns exec ue1 ip link del tun_srsue 2>/dev/null; sudo systemctl restart srsran-gnb && sleep 5 && echo "Ready"
```

---

## Quick reference

| What | Command |
|---|---|
| SSH to gNB Pi | `ssh pi@<gnb-pi-ip>` |
| Check gNB status | `sudo systemctl is-active srsran-gnb` |
| Start srsUE | `sudo srsue /etc/srsran_4g/ue.conf` |
| Get core Pi address | `grep -Po '^\s*addr:\s*\K[\d.]+' /etc/srsran/gnb.yml \| head -1` |
| Enter UE namespace | `sudo ip netns exec ue1 bash` |
| Add default route | `ip route add default dev tun_srsue` (inside namespace) |
| Ping through 5G | `ping <core-addr>` (inside namespace) |
| iperf3 downlink | `iperf3 -c <core-addr> -R -t 10` (inside namespace) |
| Exit namespace | `exit` |
| Stop srsUE | Ctrl+C in the srsUE terminal |
| Restart gNB (required after every srsUE session) | `sudo systemctl restart srsran-gnb` |
| Full recovery reset | `sudo pkill -9 srsue; sudo ip netns exec ue1 ip link del tun_srsue 2>/dev/null; sudo systemctl restart srsran-gnb` |
