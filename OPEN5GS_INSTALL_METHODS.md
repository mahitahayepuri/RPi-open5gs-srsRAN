# Open5GS Installation Methods: APT vs Source

The Open5GS playbook supports two installation paths, controlled by a single
variable (`open5gs_install_method` in `group_vars/core.yml`). Both paths
produce the same end state -- 11 NF daemons managed by systemd, YAML configs
under `/etc/open5gs/`, and a persistent `ogstun` TUN device -- but they differ
in how they get there and what the resulting system looks like under the hood.

## Why APT is the default

This project targets educational and lab use on Raspberry Pi hardware.
APT packages install in seconds, require no build toolchain, and match
the default paths that the Open5GS documentation assumes. Compiling from
source on a Pi 4 takes 20-40 minutes and consumes ~2 GB of disk for the
build tree, with no functional benefit unless you need to patch the code
or run an unreleased version.

## Quick comparison

| Factor | APT (default) | Source |
|---|---|---|
| Deploy time | Seconds | 20-40 min (Pi 4), 15-25 min (Pi 5) |
| Build deps needed | No | ~22 dev libraries + meson/ninja/gcc |
| Binary location | `/usr/bin/` | `/usr/local/bin/` |
| Library location | `/usr/lib/aarch64-linux-gnu/` | `/usr/local/lib/` |
| Service file location | `/usr/lib/systemd/system/` | `/etc/systemd/system/` |
| Config ownership | `root:root` | `open5gs:open5gs` |
| User/group creation | APT package creates `open5gs` automatically | Ansible creates `open5gs` explicitly |
| ldconfig needed | No (system library paths) | Yes (runs `ldconfig` after install) |
| Upgrade path | `apt upgrade` | `git pull` + rebuild |
| Disk footprint | Runtime only (~50 MB) | Runtime + build tree (~2 GB) |
| Customization | Config changes only | Full source-level control |
| Version pinning | Tracks latest OBS release | Pinned to `open5gs_source_version` (default `v2.7.7`) |

## Detailed differences

### Binary paths

APT installs all NF binaries to `/usr/bin/`:

```
/usr/bin/open5gs-amfd
/usr/bin/open5gs-smfd
/usr/bin/open5gs-upfd
...
```

Source compilation installs to the meson `--prefix` (default `/usr/local`):

```
/usr/local/bin/open5gs-amfd
/usr/local/bin/open5gs-smfd
/usr/local/bin/open5gs-upfd
...
```

The systemd service files reference the correct path for each method -- APT
service files use `/usr/bin/`, source-generated service files use
`/usr/local/bin/`. You do not need to change any paths manually.

### Systemd service files

| Aspect | APT | Source |
|---|---|---|
| Installed by | Package manager | Ansible copies from build dir |
| Location | `/usr/lib/systemd/system/` | `/etc/systemd/system/` |
| ExecStart path | `/usr/bin/open5gs-*d` | `/usr/local/bin/open5gs-*d` |
| User/Group | `open5gs` / `open5gs` | `open5gs` / `open5gs` |

Both methods produce service files with identical structure:

```ini
[Unit]
Description=Open5GS AMF Daemon
After=network-online.target

[Service]
Type=simple
User=open5gs
Group=open5gs
Restart=always
ExecStart=/usr/bin/open5gs-amfd -c /etc/open5gs/amf.yaml   # /usr/local/bin/ for source
RestartSec=2
RestartPreventExitStatus=1
ExecReload=/bin/kill -HUP $MAINPID

[Install]
WantedBy=multi-user.target
```

### Config file ownership

APT packages install config files as `root:root`:

```
-rw-r--r-- 1 root root 7072 /etc/open5gs/amf.yaml
```

Source compilation sets ownership to `open5gs:open5gs` (recursive on
`/etc/open5gs/`):

```
-rw-r--r-- 1 open5gs open5gs 7072 /etc/open5gs/amf.yaml
```

This difference is cosmetic for normal operation -- the NF daemons only
need *read* access to their configs, and both `root:root` with `644`
permissions and `open5gs:open5gs` with `755` permissions allow that.

### Library paths

APT installs shared libraries to the standard system path:

```
/usr/lib/aarch64-linux-gnu/libogscore.so.2.7.7
/usr/lib/aarch64-linux-gnu/libogsapp.so.2.7.7
...
```

Source compilation installs to `/usr/local/lib/`:

```
/usr/local/lib/libogscore.so.2.7.7
/usr/local/lib/libogsapp.so.2.7.7
...
```

The source install path runs `ldconfig` after `ninja install` so the
dynamic linker can find the libraries. APT handles this automatically
via dpkg triggers.

### Log directory

Both methods end up with `/var/log/open5gs/` owned by `open5gs:open5gs`.
For APT, the package creates the directory; for source, the Ansible task
creates it explicitly.

### User and group

Both methods result in an `open5gs` system user and group:

```
open5gs:x:102:105::/var/run/open5gs:/usr/sbin/nologin
```

For APT, the package's `postinst` script creates the user. For source,
the Ansible playbook creates it before compilation begins (with home set
to `/nonexistent` since the user never logs in).

## Downstream playbook compatibility

All subsequent pipeline stages are **install-method-agnostic**. They
operate on standardised paths and systemd unit names that both methods
provide:

| Stage | What it touches | Why it works with both methods |
|---|---|---|
| **network.yml** | `/etc/open5gs/amf.yaml`, `/etc/open5gs/upf.yaml` | Both methods install YAML configs to `/etc/open5gs/` |
| **services.yml** | systemd drop-in overrides, `open5gs-stack.target` | Looks up units by name (`open5gs-*d.service`), not by file path |
| **logging.yml** | rsyslog config, logrotate, `/var/log/open5gs/` | Routes by `$programname`; does not reference binary paths |
| **webui.yml** | Docker container, MongoDB | Independent of core installation method entirely |

## When to use source

- **Custom patches:** You need to modify Open5GS source code (e.g., custom
  AMF behaviour, additional logging, protocol extensions).
- **Unreleased fixes:** A bug fix has been merged to the Open5GS `main`
  branch but not yet published to the OBS repository.
- **Reproducibility:** You want to pin to an exact git tag (`v2.7.7`) rather
  than tracking the latest OBS package version.
- **Learning:** You want to understand the build system and internal structure
  of the 5G core.

## Switching between methods

### APT to source

Set `open5gs_install_method: "source"` in `group_vars/core.yml` and re-run
the playbook. The source build installs to `/usr/local/` which takes
precedence over `/usr/bin/` in `$PATH`, but the systemd service files will
also be replaced (source copies them to `/etc/systemd/system/`, which
overrides `/usr/lib/systemd/system/`). The APT packages remain installed
but inactive.

### Source to APT

Set `open5gs_install_method: "apt"` and re-run. The APT packages install
to `/usr/bin/` and their service files go to `/usr/lib/systemd/system/`.
However, **the source-built service files in `/etc/systemd/system/` take
precedence** over the APT-provided ones in `/usr/lib/systemd/system/`.
To fully revert, you would need to manually remove the service files from
`/etc/systemd/system/`:

```bash
sudo rm /etc/systemd/system/open5gs-*.service
sudo systemctl daemon-reload
```

Then restart the stack so systemd picks up the APT-provided units.

### Clean slate

To remove all traces of either installation method:

```bash
# Stop everything
sudo systemctl stop open5gs-stack.target

# Remove APT packages (if installed)
sudo apt purge open5gs-*

# Remove source-built files (if installed)
sudo rm -f /usr/local/bin/open5gs-*
sudo rm -f /usr/local/lib/libogs*.so*
sudo rm -f /usr/local/lib/libfd*.so*
sudo ldconfig
sudo rm -f /etc/systemd/system/open5gs-*.service
sudo systemctl daemon-reload

# Config and logs (shared by both methods)
sudo rm -rf /etc/open5gs/
sudo rm -rf /var/log/open5gs/
```

## Variables reference

All variables are defined in `group_vars/core.yml`.

### APT-specific

| Variable | Default | Description |
|---|---|---|
| `open5gs_obs_key_url` | OBS Raspbian_13 Release.key | GPG signing key for the OBS repository |
| `open5gs_obs_repo_url` | OBS Raspbian_13 URL | APT repository base URL |
| `open5gs_obs_repo_name` | `open5gs` | Filename in `/etc/apt/sources.list.d/` |

### Source-specific

| Variable | Default | Description |
|---|---|---|
| `open5gs_source_repo` | `https://github.com/open5gs/open5gs` | Git repository to clone |
| `open5gs_source_version` | `v2.7.7` | Git tag or branch |
| `open5gs_source_dir` | `/usr/local/src/open5gs` | Clone destination |
| `open5gs_source_prefix` | `/usr/local` | Meson `--prefix` (binary/library install root) |
| `open5gs_build_deps` | 22 packages | Build toolchain and development libraries |

### Shared

| Variable | Default | Description |
|---|---|---|
| `open5gs_install_method` | `"apt"` | Switch between `"apt"` and `"source"` |
| `open5gs_user` | `"open5gs"` | System user that runs the NF daemons |
| `open5gs_group` | `"open5gs"` | System group for the above user |
