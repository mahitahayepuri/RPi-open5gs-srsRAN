# RF Hardware Guide

Moving from ZMQ software testing to over-the-air (OTA) operation with a
real software-defined radio (SDR). Read this entire document before
transmitting.

## Regulatory Warning

**Transmitting on cellular frequencies without authorisation is illegal.**
The default configuration uses band n3 (~1.8 GHz), which is licensed mobile
operator spectrum.

Before transmitting OTA you must either:

- Obtain a developmental licence from
  [Innovation, Science and Economic Development Canada (ISED)](https://ised-isde.canada.ca/site/spectrum-management-telecommunications/en/learn-more/key-telecommunications-policies/radiocommunication-act-and-regulations)
  under the Radiocommunication Act
- Operate inside a properly shielded RF enclosure (Faraday cage / shielded box)
- Use conducted testing (cables + attenuators, no antennas)

**ZMQ mode does not transmit any RF energy and requires no licence.** If you
are unsure, stay in ZMQ mode.

## Required Hardware

| Item | Purpose | Typical Cost |
|---|---|---|
| Ettus USRP B200 or B210 | Software-defined radio (transmit + receive) | $1,200 - $2,500 |
| USB 3.0 cable | Data + power connection to the Pi | Included with USRP |
| Bandpass filter (see below) | Protect SDR from out-of-band signals | $50 - $200 |
| Circulator (see below) | Protect SDR TX from reflected power | $50 - $150 |
| Antennas (x2 for B210 MIMO, x1 for B200) | TX and RX | $20 - $50 each |
| SMA cables and adapters | Connect filter, circulator, and antennas | $10 - $30 |
| RF attenuators (10-30 dB) | Reduce power for bench testing | $10 - $20 each |
| Active cooling for Pi | Fan + heatsink (mandatory for real-time PHY) | $10 - $20 |

### USRP B200 vs B210

| Feature | B200 | B210 |
|---|---|---|
| TX/RX channels | 1x1 SISO | 2x2 MIMO |
| Frequency range | 70 MHz - 6 GHz | 70 MHz - 6 GHz |
| Bandwidth | Up to 56 MHz | Up to 56 MHz |
| Interface | USB 3.0 | USB 3.0 |
| Use case | Single-cell testing | MIMO, higher throughput |

For a student lab, the **B200 is sufficient**. The B210 adds MIMO support
but is not required for basic 5G SA operation.

## Protecting the SDR

SDRs are sensitive analogue devices. The B200/B210 front-end can be damaged
by signals that are too strong, too far out of band, or reflected back from
a mismatched antenna. Two components protect it:

### Bandpass filter

A bandpass filter passes only the frequencies you intend to use and rejects
everything else. Place it **on the RX path between the circulator and the
USRP RX2 input**.

```
Circulator Port 3 ──► [ Bandpass Filter ] ──► USRP RX2
```

Without a filter, strong nearby transmitters (other cellular towers, FM
broadcast, pagers, two-way radio) can saturate the SDR's analogue-to-digital
converter, causing desensitisation or permanent damage to the front-end LNA.

The filter is not needed on the TX path -- you are already transmitting on
a known frequency, and the filter's insertion loss would reduce your output
power unnecessarily.

**What to buy:** A cavity or ceramic bandpass filter centred on your
operating band. For the default band n3 configuration:

- Centre frequency: ~1842.5 MHz (downlink ARFCN 368500)
- Passband: 1805 - 1880 MHz (band n3 downlink)
- Insertion loss: < 2 dB (lower is better)

Search for "1800 MHz bandpass filter SMA" or look at suppliers like
Mini-Circuits, Reactel, or Temwell.

### Circulator

A circulator is a three-port device that routes RF energy in one direction.
Place it **between the USRP and the antenna**, where it serves double duty:
routing TX to the antenna and antenna to RX, while protecting the TX
amplifier from reflected power.

```
                         Port 2
USRP TX/RX port ──►  [ Circulator ] ──► Antenna
  (Port 1)               │
                         ▼ Port 3
                  [ Bandpass Filter ]
                         │
                    USRP RX2 port
```

- **Port 1** (TX in): SDR TX output
- **Port 2** (antenna): Transmitted signal goes out; received signal comes in
- **Port 3** (RX out): Received signal is routed to the SDR RX input

The circulator protects the SDR in two ways:

1. **Reflected power protection** -- if the antenna is disconnected, damaged,
   or has a poor impedance match, transmitted power reflects back from port 2.
   The circulator routes it to port 3 (the RX path) rather than back into
   the TX amplifier on port 1.
2. **TX/RX isolation** -- allows a single antenna to be shared for both
   transmit and receive without a separate duplexer.

If you are not using the RX2 port for receive, terminate port 3 with a
**50-ohm dummy load** to safely absorb reflected power.

**What to buy:** A ferrite circulator rated for your band with at least
20 dB isolation. Search for "1.8 GHz circulator SMA" from suppliers like
MECA Electronics, DiTom Microwave, or UIY.

### Complete RF chain

Single-antenna setup with circulator and bandpass filter:

```
USRP TX/RX ──► Port 1
                  │
            [ Circulator ]
                  │
               Port 2 ──► [ Antenna ]

               Port 3
                  │
          [ Bandpass Filter ]
                  │
            USRP RX2 input
```

Signal flow:
- **Transmit:** USRP TX → Port 1 → Port 2 → Antenna
- **Receive:** Antenna → Port 2 → Port 3 → Bandpass Filter → USRP RX2
- **Reflected power:** Antenna reflection → Port 2 → Port 3 → Filter → RX (or 50-ohm load, not fed back to TX)

For conducted bench testing (no antennas), replace the antenna with
attenuators and a cable loopback:

```
USRP TX/RX ──► Circulator Port 2 ──► 30 dB Attenuator ──► Cable ──┐
                    │                                               │
                 Port 3                                             │
                    │                                               │
          [ Bandpass Filter ]                                       │
                    │                                               │
               USRP RX2 ◄──────────────────────────────────────────┘
```

This lets you test the full RF path without radiating.

## Switching from ZMQ to UHD

Once hardware is connected, switch the RF driver:

```bash
ansible-playbook -i inventory-pi5.ini srsran/playbooks/srsran.yml \
  -e srsran_rf_driver=uhd
```

Or edit `group_vars/gnb.yml`:

```yaml
srsran_rf_driver: "uhd"
```

This redeploys the gNB config to use the USRP. No recompilation is needed --
both ZMQ and UHD drivers are always compiled in.

### UHD-specific variables

Defined in `group_vars/gnb.yml`:

| Variable | Default | Description |
|---|---|---|
| `srsran_uhd_device_args` | `""` (auto-detect) | Device args, e.g. `type=b200` |
| `srsran_uhd_rx_antenna` | `""` (TX/RX port) | RX antenna port: `""` = TX/RX, `"RX2"` = dedicated RX2 port |
| `srsran_uhd_clock` | `internal` | Clock source: `internal`, `external`, `gpsdo` |
| `srsran_uhd_sync` | `internal` | Time source: `internal`, `external`, `gpsdo` |
| `srsran_uhd_otw_format` | `sc12` | Over-the-wire format (`sc12` saves USB bandwidth) |
| `srsran_uhd_tx_gain` | `50` | TX gain (0-89 for B200/B210) |
| `srsran_uhd_rx_gain` | `60` | RX gain (0-76 for B200/B210) |
| `srsran_uhd_srate` | `23.04` | Sample rate in MHz |

### RX antenna port selection

The B200/B210 has two RF ports: **TX/RX** (bidirectional) and **RX2** (receive-only).

By default (`srsran_uhd_rx_antenna: ""`), the gNB uses the TX/RX port for both transmit and receive. This is the simplest setup and works for loopback bench testing.

Use `RX2` when your RF chain separates TX and RX paths — for example, with a circulator where the circulator's isolated port feeds the RX2 input (the recommended setup described in the [Protecting the SDR](#protecting-the-sdr) section above).

```bash
# One-off
ansible-playbook -i inventory-pi5.ini srsran/playbooks/srsran.yml \
  -e srsran_rf_driver=uhd \
  -e srsran_uhd_rx_antenna=RX2

# Permanent — group_vars/gnb.yml
srsran_uhd_rx_antenna: "RX2"
```

When `srsran_uhd_rx_antenna` is set, its value is appended to `device_args` as `rx_antenna=RX2`. If you also set `srsran_uhd_device_args` (e.g. `type=b200`), both are combined automatically: `type=b200,rx_antenna=RX2`.

### TX power considerations

The USRP B200 outputs approximately **+10 dBm** (~10 mW) at maximum TX gain.
This is very low power -- safe for bench testing but insufficient for
coverage beyond a few metres. For a shielded enclosure or conducted test,
**reduce TX gain to 30-50** to avoid overdriving the receive path.

> **Never connect the TX output directly to the RX input without at least
> 30 dB of attenuation.** The receive front-end will be damaged.

### Verifying the USRP is detected

After connecting the USRP via USB 3.0:

```bash
# On the gNB Pi:
uhd_find_devices
```

Expected output:

```
[INFO] [UHD] linux; ...
--------------------------------------------------
-- UHD Device 0
--------------------------------------------------
Device Address:
    serial: ...
    name: ...
    product: B200
    type: b200
```

If no device is found, check:

- The USB cable is plugged into a **USB 3.0 port** (blue)
- udev rules are installed (`/etc/udev/rules.d/99-usrp.rules` -- deployed by the playbook)
- UHD firmware images are downloaded (`/usr/share/uhd/images/`)

### Network buffer tuning

For UHD with Ethernet-connected USRPs (not typical for B200/B210 which use
USB), enable the 32 MB network buffer tuning:

```bash
ansible-playbook -i inventory-pi5.ini srsran/playbooks/srsran.yml \
  -e srsran_tune_network_buffers=true
```

This is not needed for USB-connected B200/B210 devices.

## Thermal Management

Real-time PHY processing under UHD generates significantly more CPU load
than ZMQ mode. **Active cooling is mandatory:**

- Pi 4: Sustained ~100% CPU on all 4 cores during PHY processing. Will
  thermal-throttle within minutes without a heatsink + fan.
- Pi 5: Better thermal headroom but still requires active cooling for
  sustained operation.

Monitor CPU temperature:

```bash
vcgencmd measure_temp
```

If temperature exceeds 80°C, the Pi will throttle the CPU frequency and
real-time PHY performance will degrade (dropped frames, UE disconnects).

## Antenna Selection

For band n3 (1800 MHz):

- **Type:** Omnidirectional whip or dipole
- **Frequency range:** 1710-1880 MHz (covers both UL and DL)
- **Connector:** SMA male (matches USRP)
- **Gain:** 2-5 dBi is typical for a whip antenna

For shielded enclosure testing, antennas can be replaced with SMA
attenuators and cables (conducted testing).

## Safety Checklist

Before powering on the USRP in TX mode:

- [ ] Regulatory authorisation obtained (or operating in a shielded enclosure)
- [ ] Circulator installed on TX path with 50-ohm load on isolated port
- [ ] Bandpass filter installed on RX path
- [ ] Antenna connected (or attenuators for conducted testing)
- [ ] TX gain set to a conservative value (start at 30, increase as needed)
- [ ] Active cooling installed and verified (`vcgencmd measure_temp` < 70°C idle)
- [ ] `uhd_find_devices` confirms the USRP is detected
- [ ] `srsran_check` health check passes

See [`GLOSSARY.md`](GLOSSARY.md) for definitions of RF terms.
