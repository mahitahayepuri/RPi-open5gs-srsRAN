# Setting Up srsUE (Software UE for ZMQ Testing)

This guide covers installing and running **srsUE** on the gNB Raspberry Pi
to test the 5G network end-to-end without radio hardware.

srsUE is a software UE simulator from the
[srsRAN 4G](https://github.com/srsRAN/srsRAN_4G) project (a separate
repository from the srsRAN Project gNB deployed by the main playbooks). In
ZMQ mode, srsUE connects to the gNB over local TCP sockets instead of over
the air, simulating a phone attaching to the network.

## Prerequisites

- The gNB Pi has been deployed with `srsran_rf_driver: "zmq"` (the default)
- The Open5GS core is deployed and all NF services are running
- You have SSH access to both Pis

## Architecture

```
gNB Pi (e.g. 192.168.2.55)
┌─────────────────────────────────────────────┐
│                                             │
│  srsRAN gNB                                 │
│    ZMQ tx → tcp://127.0.0.1:2000 ───┐      │
│    ZMQ rx ← tcp://127.0.0.1:2001 ◄──┤      │
│                                      │      │
│  srsUE                               │      │
│    ZMQ rx ← tcp://127.0.0.1:2000 ◄──┘      │
│    ZMQ tx → tcp://127.0.0.1:2001 ───┘      │
│                                             │
└──────────────────┬──────────────────────────┘
                   │ N2/N3 (10.53.1.0/24)
                   │
┌──────────────────┴──────────────────────────┐
│  Core Pi (e.g. 192.168.2.72)               │
│  Open5GS AMF/UPF/...                       │
└─────────────────────────────────────────────┘
```

The gNB's ZMQ TX port is the UE's RX port and vice versa -- they cross over.
Both run on the same Pi using loopback sockets.

## Automated setup (recommended)

A separate Ansible pipeline handles the entire srsUE setup: compiling the
binary, deploying the configuration, and provisioning a test subscriber in
Open5GS. Run it from your computer after the Open5GS and srsRAN pipelines
have completed:

```bash
ansible-playbook -i inventory-pi5.ini srsue/playbooks/srsue.yml
```

This runs four stages:

| Stage | Playbook | Host | What it does |
|---|---|---|---|
| 1 | `build_deps.yml` | gNB Pi | Installs compilation dependencies |
| 2 | `compile.yml` | gNB Pi | Clones srsRAN 4G and compiles `srsue` (~10-40 min) |
| 3 | `install.yml` | gNB Pi | Installs binary and deploys UE config |
| 4 | `subscriber.yml` | Core Pi | Adds test subscriber to Open5GS MongoDB |

### Configuration

Variables are split across `group_vars/all.yml` (subscriber credentials,
shared with the core) and `group_vars/ue.yml` (RF, build, and network
namespace settings).  Key settings:

| Variable | Default | Description |
|---|---|---|
| `srsue_imsi` | `001010000000001` | Auto-derived from MCC+MNC+MSIN -- updates automatically if you change the PLMN in `all.yml` |
| `srsue_ki` | `465B5CE8...` | Subscriber authentication key |
| `srsue_opc` | `E8ED289D...` | Operator-derived key |
| `srsue_apn` | `internet` | Access point name |
| `srsue_rf_device` | `zmq` | RF device (always `zmq` for software testing) |
| `srsue_dl_nr_arfcn` | `368500` | DL NR-ARFCN -- must match `srsran_cell_dl_arfcn` |
| `srsue_ssb_nr_arfcn` | `367930` | SSB ARFCN broadcast by the gNB (band n3, 10 MHz) |
| `srsue_netns` | `ue1` | Network namespace for UE TUN interface isolation |
| `srsue_tun_name` | `tun_srsue` | TUN device name inside the namespace |

To use different subscriber credentials:

```bash
ansible-playbook -i inventory-pi5.ini srsue/playbooks/srsue.yml \
  -e srsue_imsi=001010000000002 \
  -e srsue_ki=YOUR_KI_VALUE \
  -e srsue_opc=YOUR_OPC_VALUE
```

## Running srsUE

After the playbook completes, SSH into the gNB Pi to start the test.

### Start the gNB (if not already running)

```bash
sudo systemctl start srsran-gnb
```

Wait a few seconds, then check for a successful AMF connection:

```bash
sudo journalctl -u srsran-gnb -f
```

### Start srsUE

In a separate SSH session to the gNB Pi:

```bash
sudo srsue /etc/srsran_4g/ue.conf
```

A successful attach looks like:

```
Attaching UE...
Random Access Transmission: prach_occasion=0, preamble_index=0, ...
RRC Connected
PDU Session Establishment successful. IP: 10.45.0.2
```

The key line is **"PDU Session Establishment successful"** with an IP from
the `10.45.0.0/16` pool.

### Test the data connection

With srsUE running, it creates a TUN interface (usually `tun_srsue`):

```bash
# Ping the internet through the 5G network:
sudo ping -I tun_srsue 8.8.8.8

# Or curl a website:
sudo curl --interface tun_srsue https://ifconfig.me
```

If the ping succeeds, you have a working end-to-end 5G SA data path:
UE -> gNB (ZMQ) -> AMF/UPF (N2/N3) -> internet (NAT).

### Stopping srsUE

Press `Ctrl+C` in the srsUE terminal. The TUN interface is removed
automatically.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| srsUE hangs at "Waiting PHY to initialize" | `FFTW_MEASURE` blocks indefinitely over ZMQ | Patch `lib/src/phy/dft/dft_fftw.c`: replace `FFTW_MEASURE` with `FFTW_ESTIMATE`, then rebuild |
| srsUE hangs at "Attaching UE..." | gNB not running or not connected to AMF | Check `journalctl -u srsran-gnb` for NGAP errors |
| Cell search finds nothing | Wrong SSB ARFCN in UE config | Ensure `ssb_nr_arfcn` and `dl_nr_arfcn` in `ue.conf` match the gNB (check gNB log for "SSB derived" frequency) |
| "Authentication failure" | IMSI/Ki/OPC mismatch between UE config and Open5GS | Verify subscriber: `docker exec open5gs-mongodb mongo --quiet --eval 'db.getSiblingDB("open5gs").subscribers.find().pretty()'` on the core Pi (use `mongosh` instead of `mongo` on Pi 5) |
| "Registration reject" with "No SEPP" / "NF-Discover failed [504]" in SCP log | NRF serving PLMN doesn't match your network's PLMN | Patch `/etc/open5gs/nrf.yaml`: set `nrf.serving[0].plmn_id` to your MCC/MNC, then restart NRF |
| "Registration reject" with "No SST" / "No UE-AMBR" in UDR log | Subscriber BSON types wrong (doubles instead of INT32) | Re-insert subscriber using `NumberInt()` for all integer fields and add top-level `ambr` (see manual setup above) |
| "RRC Connection rejected" | PLMN mismatch | Ensure AMF PLMN matches gNB: check `/etc/open5gs/amf.yaml` for `mcc`/`mnc` values |
| No IP address after attach | UPF or SMF issue | Check `journalctl -u open5gs-upfd` and `journalctl -u open5gs-smfd` on the core Pi |
| "PDU Session failed" | ogstun not up or NAT not configured | Run `sudo open5gs_check` on the core Pi |
| Ping through `tun_srsue` fails | NAT/forwarding issue on core Pi | Verify: `cat /proc/sys/net/ipv4/ip_forward` (should be `1`) |

## Manual setup

If you prefer to set up srsUE manually instead of using the playbook, the
steps are documented below for reference.

<details>
<summary>Click to expand manual setup steps</summary>

### Install build dependencies

SSH into the gNB Pi:

```bash
sudo apt update
sudo apt install -y \
  cmake make gcc g++ pkg-config git \
  libfftw3-dev libmbedtls-dev libsctp-dev \
  libconfig++-dev libzmq3-dev \
  libboost-program-options-dev
```

### Clone and compile

```bash
cd /usr/local/src
sudo git clone https://github.com/srsRAN/srsRAN_4G.git
cd srsRAN_4G

# Patch FFTW_MEASURE → FFTW_ESTIMATE.  FFTW_MEASURE runs timing
# benchmarks that block indefinitely when the RF backend is ZMQ
# (no real-time clock).  FFTW_ESTIMATE skips the benchmarks so PHY
# initialization completes immediately.
sudo sed -i 's/FFTW_MEASURE/FFTW_ESTIMATE/g' lib/src/phy/dft/dft_fftw.c

sudo mkdir build && cd build

sudo cmake .. \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_SRSUE=ON \
  -DENABLE_SRSENB=OFF \
  -DENABLE_SRSEPC=OFF \
  -DENABLE_ZEROMQ=ON

# Use -j2 on 4 GB Pis to avoid OOM
sudo make -j$(nproc) srsue
sudo make install
```

### Provision a test subscriber

On the **core Pi**:

```bash
# Using the mongo shell inside the MongoDB Docker container.
#
# Pi 5 (MongoDB 7.0) ships 'mongosh'; Pi 4 (MongoDB 4.4) ships 'mongo'.
# Detect which is available, then run the insert:
#
# IMPORTANT: The legacy 'mongo' shell stores plain numbers as BSON
# doubles (floating-point).  Open5GS requires BSON INT32 for integer
# fields (sst, type, qos values, ambr units).  If you type just '1',
# the shell stores it as '1.0', and the UDR silently ignores the field
# — causing "No SST" errors.  Always use NumberInt() for these fields.
MONGO_SH=$(docker exec open5gs-mongodb sh -c 'command -v mongosh || command -v mongo' | xargs basename)
docker exec open5gs-mongodb "$MONGO_SH" --eval '
  db = db.getSiblingDB("open5gs");
  db.subscribers.insertOne({
    imsi: "001010000000001",
    security: {
      k:   "465B5CE8B199B49FAA5F0A2EE238A6BC",
      opc: "E8ED289DEBA952E4283B54E88E6183CA",
      amf: "8000",
      sqn: NumberLong(513)
    },
    ambr: {
      downlink: { value: NumberInt(1), unit: NumberInt(3) },
      uplink:   { value: NumberInt(1), unit: NumberInt(3) }
    },
    slice: [{
      sst: NumberInt(1),
      default_indicator: true,
      session: [{
        name: "internet",
        type: NumberInt(3),
        qos: {
          index: NumberInt(9),
          arp: {
            priority_level: NumberInt(8),
            pre_emption_capability: NumberInt(1),
            pre_emption_vulnerability: NumberInt(1)
          }
        },
        ambr: {
          downlink: { value: NumberInt(1), unit: NumberInt(3) },
          uplink:   { value: NumberInt(1), unit: NumberInt(3) }
        }
      }]
    }]
  });
'
```

### Create the UE configuration

On the **gNB Pi**:

```bash
sudo mkdir -p /etc/srsran_4g
sudo tee /etc/srsran_4g/ue.conf > /dev/null << 'EOF'
[rf]
freq_offset = 0
tx_gain = 50
rx_gain = 40
srate = 11.52e6
nof_antennas = 1

device_name = zmq
device_args = tx_port=tcp://127.0.0.1:2001,rx_port=tcp://127.0.0.1:2000,base_srate=11.52e6

[rat.eutra]
dl_earfcn = 2850
nof_carriers = 0

[rat.nr]
nof_carriers = 1
bands = 3
nof_prb = 52
max_nof_prb = 52
dl_nr_arfcn = 368500
ssb_nr_arfcn = 367930

[pcap]
enable = none
mac_filename = /tmp/ue_mac.pcap
mac_nr_filename = /tmp/ue_mac_nr.pcap
nas_filename = /tmp/ue_nas.pcap

[log]
all_level = info
phy_lib_level = none
all_hex_limit = 32
filename = /tmp/srsue.log
file_max_size = -1

[usim]
mode = soft
algo = milenage
opc  = E8ED289DEBA952E4283B54E88E6183CA
k    = 465B5CE8B199B49FAA5F0A2EE238A6BC
imsi = 001010000000001
imei = 353490069873319

[rrc]
release = 15
ue_category = 4

[nas]
apn = internet
apn_protocol = ipv4

[gw]
netns = ue1
ip_devname = tun_srsue
ip_netmask = 255.255.255.0
EOF

# Create the network namespace for the UE TUN interface
sudo ip netns add ue1 2>/dev/null || true
```

</details>

## Reference: Test subscriber credentials

| Parameter | Value |
|---|---|
| IMSI | `001010000000001` |
| Ki | `465B5CE8B199B49FAA5F0A2EE238A6BC` |
| OPC | `E8ED289DEBA952E4283B54E88E6183CA` |
| APN / DNN | `internet` |
| PLMN | `00101` (MCC=001, MNC=01) |

See [`GLOSSARY.md`](GLOSSARY.md) for definitions of these terms.
