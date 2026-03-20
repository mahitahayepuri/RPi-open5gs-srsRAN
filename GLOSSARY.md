# Glossary

Quick reference for the telecom, networking, and Linux terms used throughout
this project. Grouped by topic.

## 5G Network Architecture

| Term | Meaning |
|---|---|
| **5G SA** | 5G Standalone -- a 5G network that operates independently without relying on a 4G/LTE core. This project deploys a 5G SA network. |
| **gNB** | Next-generation Node B -- the 5G base station (radio access point). In this project, the srsRAN gNB runs on one Raspberry Pi. |
| **UE** | User Equipment -- any device that connects to the 5G network (phone, modem, IoT device, or software simulator like srsUE). |
| **srsUE** | A software UE simulator from the srsRAN 4G project. Required for testing in ZMQ mode since there is no real radio -- srsUE connects to the gNB over ZMQ sockets to simulate a phone attaching to the network. Separate from srsRAN Project (the gNB). |
| **Core network** | The backend of the mobile network. Handles authentication, session management, routing, and policy. Open5GS implements the 5G SA core. |
| **RAN** | Radio Access Network -- the radio side of the network (gNBs and the air interface to UEs). |
| **E2E** | End-to-end -- from the UE through the gNB through the core to the internet and back. |

## gNB Architecture

The srsRAN gNB is internally split into three logical components, each
handling a different layer of the protocol stack:

| Term | Full Name | Role |
|---|---|---|
| **CU-CP** | Centralized Unit -- Control Plane | Handles RRC connection setup/release, NGAP messages to the AMF, F1AP-C, and E1AP signalling. Logs appear under `[RRC`, `[NGAP`, `[CU-CP` tags. |
| **CU-UP** | Centralized Unit -- User Plane | Handles PDCP encryption, SDAP QoS mapping, and GTP-U tunnels to the UPF. Logs appear under `[PDCP`, `[SDAP`, `[GTPU`, `[CU-UP` tags. |
| **DU** | Distributed Unit | Handles MAC scheduling, HARQ, RLC segmentation, and PHY layer processing. Logs appear under `[MAC`, `[RLC`, `[PHY`, `[DU` tags. |

## 5G Core Network Functions (NFs)

The 5G core is a set of microservices. Open5GS deploys 11 of them:

| NF | Full Name | Role |
|---|---|---|
| **AMF** | Access and Mobility Management Function | Handles UE registration, connection, and mobility. The gNB connects to the AMF. |
| **SMF** | Session Management Function | Manages PDU sessions (data connections) between UE and the internet. |
| **UPF** | User Plane Function | Forwards user data packets between the gNB and the internet. Runs the `ogstun` TUN device. |
| **NRF** | Network Repository Function | Service registry -- other NFs register with NRF and discover each other through it. Starts first. |
| **SCP** | Service Communication Proxy | Routes SBI messages between NFs (optional delegation layer). |
| **AUSF** | Authentication Server Function | Handles UE authentication (verifies SIM credentials). |
| **UDM** | Unified Data Management | Manages subscriber profiles and authentication data. |
| **UDR** | Unified Data Repository | Database backend for UDM (stores subscriber records in MongoDB). |
| **PCF** | Policy Control Function | Enforces QoS policies and charging rules. |
| **NSSF** | Network Slice Selection Function | Selects which network slice a UE should use. |
| **BSF** | Binding Support Function | Maintains session bindings for policy control. |

## 3GPP Interfaces and Protocols

| Term | Meaning |
|---|---|
| **N2** | Control-plane interface between the gNB and AMF. Carries NGAP messages. |
| **N3** | User-plane interface between the gNB and UPF. Carries GTP-U tunneled user data. |
| **N4** | Interface between the SMF and UPF (PFCP protocol). Used to set up forwarding rules. |
| **NGAP** | Next Generation Application Protocol -- the control-plane protocol on the N2 interface. Runs over SCTP. |
| **SCTP** | Stream Control Transmission Protocol -- a transport protocol (like TCP) used for NGAP. Provides reliable, ordered delivery with multi-homing support. |
| **GTP-U** | GPRS Tunnelling Protocol (User plane) -- encapsulates user data between the gNB and UPF over UDP port 2152. |
| **PFCP** | Packet Forwarding Control Protocol -- used on the N4 interface for the SMF to program forwarding rules in the UPF. |
| **SBI** | Service Based Interface -- the HTTP/2-based API that 5G core NFs use to communicate with each other. Runs on TCP port 7777 in Open5GS. |

## Identity and Registration

| Term | Meaning |
|---|---|
| **PLMN** | Public Land Mobile Network -- the network identity, formed by MCC + MNC. Identifies a specific mobile operator. |
| **MCC** | Mobile Country Code -- 3-digit country identifier (e.g. 001 = test, 302 = Canada, 310 = USA). |
| **MNC** | Mobile Network Code -- 2 or 3-digit operator identifier within a country (e.g. 01 = test network). |
| **IMSI** | International Mobile Subscriber Identity -- the unique ID stored on a SIM card. Used to identify a subscriber in the core network. |
| **SUPI** | Subscription Permanent Identifier -- the 5G equivalent of IMSI. In practice, often the same value. |
| **Ki** | Subscriber authentication key -- a 128-bit secret shared between the SIM card and the core. Used to authenticate the UE. |
| **OPC** | Operator-derived key -- derived from Ki and the operator key (OP). Used in the authentication algorithm. |
| **TAC** | Tracking Area Code -- a number identifying a geographic area served by the AMF. The gNB and AMF must agree on this value. |
| **GUAMI** | Globally Unique AMF Identifier -- identifies a specific AMF instance, composed of PLMN + AMF ID. |
| **APN / DNN** | Access Point Name / Data Network Name -- identifies which external network the UE wants to reach (e.g. "internet"). DNN is the 5G term. |

## Radio and RF

| Term | Meaning |
|---|---|
| **ARFCN** | Absolute Radio Frequency Channel Number -- a number that maps to a specific radio frequency. For example, 368500 maps to ~1842.5 MHz in band n3. |
| **Band** | NR operating band -- defines the frequency range (e.g. band n3 = 1805-1880 MHz downlink). |
| **SCS** | Subcarrier Spacing -- the spacing between radio subcarriers in kHz (15, 30, 60, 120). Affects bandwidth and latency tradeoffs. |
| **ZMQ / ZeroMQ** | A software messaging library used as a virtual RF interface. Allows the gNB to run without radio hardware -- data is exchanged over TCP sockets instead of over the air. |
| **UHD** | USRP Hardware Driver -- the software driver for Ettus Research USRP software-defined radios (B200, B210, etc.). |
| **USRP** | Universal Software Radio Peripheral -- an SDR device from Ettus Research that transmits and receives real RF signals. |
| **SDR** | Software Defined Radio -- a radio system where signal processing is done in software rather than dedicated hardware. |
| **FDD** | Frequency Division Duplexing -- transmit and receive happen on separate frequencies simultaneously. Band n3 is FDD (uplink 1710-1785 MHz, downlink 1805-1880 MHz). |
| **TDD** | Time Division Duplexing -- transmit and receive share the same frequency but alternate in time. Many NR bands (e.g. n78) are TDD. |
| **dBm** | Decibels relative to one milliwatt -- a logarithmic unit of RF power. 0 dBm = 1 mW, +10 dBm = 10 mW, +20 dBm = 100 mW. |
| **Insertion loss** | The power lost when a signal passes through a component (filter, cable, connector). Measured in dB. |
| **Impedance** | The opposition to AC current flow, measured in ohms. RF systems use 50-ohm impedance; a mismatch causes signal reflections and power loss. |
| **Duplexer** | A device that separates TX and RX signals so a single antenna can be used for both transmitting and receiving simultaneously. |
| **Circulator** | A three-port RF device that routes signals in one direction: port 1 → 2 → 3. Used to protect the receiver from the transmitter's output. The isolated port is terminated with a dummy load. |
| **Dummy load** | A 50-ohm resistor that absorbs RF power safely. Used to terminate unused ports (e.g. the isolated port of a circulator). |
| **SMA** | SubMiniature version A -- a common RF connector type used on USRP devices and antennas. Threaded, rated to 18 GHz. |
| **S-NSSAI** | Single Network Slice Selection Assistance Information -- identifies a network slice. Contains SST (and optionally SD). |
| **SST** | Slice/Service Type -- a number indicating the type of service (1 = eMBB, 2 = URLLC, 3 = MIoT). Default is 1 (enhanced Mobile Broadband). |

## Networking and Linux

| Term | Meaning |
|---|---|
| **TUN** | A virtual network tunnel device. The Linux kernel presents it as a network interface, but packets are read/written by a userspace program (the UPF). |
| **ogstun** | The name of the TUN device created by the Open5GS playbooks. UE traffic enters and exits the core through this interface. |
| **NAT** | Network Address Translation -- rewrites packet source addresses so UE traffic (from the 10.45.0.0/16 pool) can reach the internet through the Pi's physical interface. |
| **Masquerade** | A form of NAT where the source address is dynamically replaced with the outgoing interface's address. Used by the nftables rules in this project. |
| **nftables** | The Linux packet filtering framework (successor to iptables). Used in this project for NAT masquerade rules. |
| **systemd** | The init system and service manager on modern Linux. Manages starting, stopping, and monitoring services on the Pis. |
| **PDU session** | Protocol Data Unit session -- a data connection between a UE and the network. Established after the UE registers and requests connectivity. |
| **QoS** | Quality of Service -- traffic prioritization rules that ensure different types of data (voice, video, best-effort) get appropriate treatment. |
| **DHCP** | Dynamic Host Configuration Protocol -- automatically assigns IP addresses to devices on a network. The Pi gets its address from the router's DHCP server unless a static IP is configured. |
| **MAC address** | Media Access Control address -- a unique 48-bit hardware identifier burned into every network interface (e.g. `dc:a6:32:xx:xx:xx` for Raspberry Pi Ethernet). Used by DHCP servers to identify devices. |
| **Headless** | A computer running without a monitor, keyboard, or mouse, accessed entirely via SSH or serial console. All Pis in this project run headless. |
| **Page fault** | When a program accesses memory that the OS has swapped to disk, the CPU must pause and load it back into RAM. In real-time signal processing (PHY), this pause causes dropped samples. `LimitMEMLOCK=infinity` prevents it by locking memory in RAM. |
| **cpufreq** | The Linux CPU frequency scaling subsystem. Controls which clock speed each CPU core runs at. The `performance` governor locks cores at maximum frequency; `ondemand` scales dynamically. |
| **DRM KMS polling** | Direct Rendering Manager / Kernel Mode Setting polling -- the kernel periodically checks for display hotplug events (monitors being connected/disconnected). Wastes CPU cycles on a headless Pi. Disabled by writing `N` to `/sys/module/drm_kms_helper/parameters/poll`. |
| **pi-monitor** | A systemd service (`pi-monitor.service`) that periodically logs CPU temperature, thermal throttle state, load average, memory usage, and clock frequency to `/var/log/pi-monitor.log`. Deployed to all Pis for thermal debugging. See [`PI_MONITOR.md`](PI_MONITOR.md). |
| **cap_sys_nice** | A Linux capability (permission) that allows a process to set real-time thread scheduling priority without running as root. Granted to the gNB binary via `setcap`. |
| **Idempotent** | An operation that produces the same result whether you run it once or many times. Ansible tasks are designed to be idempotent -- re-running a playbook won't break anything or re-apply changes unnecessarily. |
| **sysfs** | A virtual filesystem at `/sys/` that exposes kernel and hardware state as readable/writable files. Used to read CPU temperature, governor, and throttle state. |
| **WebSocket** | A protocol for persistent, bidirectional communication over a single TCP connection. Used by srsRAN `release_25_10`+ for streaming metrics from the gNB to Telegraf. |

## Ansible

| Term | Meaning |
|---|---|
| **Control node** | Your computer -- where you run `ansible-playbook` commands. Ansible connects from here to the Pis via SSH. |
| **Target / Managed node** | A Raspberry Pi that Ansible configures remotely. |
| **Inventory** | A file listing the target hosts and their groups (e.g. `[core]`, `[gnb]`). |
| **Playbook** | A YAML file describing a sequence of tasks for Ansible to execute on the targets. |
| **Task** | A single action in a playbook (e.g. install a package, copy a file, start a service). |
| **Handler** | A task that only runs when notified by another task (e.g. restart a service after its config changes). |
| **group_vars** | Variables applied to all hosts in a specific inventory group. `core.yml` applies to `[core]` hosts, `gnb.yml` to `[gnb]` hosts. |
| **Async polling** | An Ansible execution mode where a long-running task (e.g. a 2-hour compile) runs in the background on the target. Ansible periodically checks ("polls") whether it has finished, keeping the SSH session alive. |
| **nuke-from-orbit** | The `nuke-from-orbit.yml` playbook -- a full teardown that removes all project artifacts (services, packages, containers, configs, logs, network state) from a Pi pair, returning them to a clean post-`pi_setup` baseline. Named after the famous _Aliens_ quote. |
