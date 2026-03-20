# Raspberry Pi Preparation

How to get a Raspberry Pi ready for the 5G SA playbooks. Repeat these steps
for each Pi (one core, one gNB).

## What you need (per Pi)

- Raspberry Pi 4 or 5 (4 GB RAM minimum, 8 GB recommended)
- microSD card (32 GB+)
- Ethernet cable and access to a wired network (the playbooks disable Wi-Fi)
- A computer with a microSD reader to flash the OS
- Power supply for the Pi (USB-C, 5V/3A for Pi 4, 5V/5A for Pi 5)
- Active cooling (fan + heatsink) -- essential for srsRAN real-time workloads

## 1. Flash Raspberry Pi OS

Download and install [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
on your computer.

1. Insert the microSD card
2. Open Raspberry Pi Imager
3. **Choose Device** -- select your Pi model (Pi 4 or Pi 5)
4. **Choose OS** -- select **Raspberry Pi OS (other)** then
   **Raspberry Pi OS (64-bit)** based on Debian Trixie. The 64-bit (arm64)
   image is required -- the 32-bit image will not work.
5. **Choose Storage** -- select your microSD card
6. Click **Next**

## 2. Configure for headless use

When Imager prompts "Would you like to apply OS customisation settings?",
click **Edit Settings** and configure:

### General tab

- **Set hostname** -- e.g. `core` for the Open5GS Pi, `gnb` for the srsRAN Pi
- **Set username and password** -- username: `pi`, pick a password you'll
  remember (the playbooks expect the user `pi`)

### Services tab

- **Enable SSH** -- select "Use password authentication"

Click **Save**, then **Yes** to apply, then **Yes** to write. Wait for the
write and verify to finish.

## 3. Boot the Pi

1. Insert the flashed microSD card into the Pi
2. Connect an Ethernet cable to the Pi and your network switch/router
3. Connect power -- the Pi will boot automatically

**Important:** Do not rely on Wi-Fi. The playbooks will disable Wi-Fi and
Bluetooth during the Pi Setup stage. If you are using Wi-Fi for SSH access,
you will be locked out. Always use a wired Ethernet connection.

## 4. Find the Pi's IP address

### Option A: DHCP (default)

If your network has a DHCP server (most home/lab routers do), the Pi will
get an IP address automatically. To find it:

- **Router admin page** -- log in to your router and look at the DHCP lease
  table (often under Status or LAN). Find the entry matching the hostname
  you set (e.g. `core` or `gnb`).
- **From another machine on the same network:**
  ```bash
  # If you set the hostname to 'core':
  ping core.local

  # Or scan the local subnet (replace with your subnet):
  nmap -sn 192.168.2.0/24
  ```

### Option B: Static IP

If you want a fixed address, you can assign one before first boot. After
Imager finishes writing, re-insert the microSD card and edit
`/boot/firmware/cmdline.txt` on the boot partition. This file contains
a single long line of kernel boot parameters (the bootloader expects
everything on one line). Append the following to the **end of the
existing line** -- do not press Enter or add a newline:

```
ip=192.168.2.72::192.168.2.1:255.255.255.0:core:eth0:off
```

The format is `ip=<address>::<gateway>:<netmask>:<hostname>:<interface>:off`.
Replace the address, gateway, and hostname for each Pi.

Alternatively, configure a static lease in your DHCP server by reserving an
IP for each Pi's MAC address. The MAC address is printed on the Pi's
Ethernet port label or visible in the router's lease table after first boot.

## 5. Test SSH access

From your computer:

```bash
ssh pi@<pi-ip-address>
```

Accept the host key when prompted and enter the password you set in step 2.
Type `exit` to disconnect. Repeat for each Pi.

## Next steps

Your Pis are ready. Return to the [main README](README.md) and continue
with **Step 2** (setting up Ansible on your computer).
