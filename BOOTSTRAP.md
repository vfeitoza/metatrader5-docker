# Bootstrap script (full VM)

Automated Linux server setup to run **multiple** MetaTrader 5 instances via
Wine directly on a VM (no Docker) — for when you want several instances on
one server, or full control over the underlying machine.

Works on **any cloud** (EC2, Hetzner, Azure, DigitalOcean, etc.) running
Ubuntu 24.04 LTS (also compatible with 22.04) — via cloud-init/User Data or
manual SSH. Total time from zero to RDP: **~17–20 minutes**.

If you just want a single MT5 instance with the least setup, use the
[Docker image](README.md#docker) instead — it's simpler for most users.

---

## Quick flow

### Option A — New server (any cloud)

1. Edit the variables at the top of `bootstrap.sh`
2. Paste the whole file content into the provider's init-data field (it's always cloud-init/user-data, just a different name):

   | Provider      | Where to paste                                |
   |---------------|------------------------------------------------|
   | AWS EC2       | Advanced details → **User data**                |
   | Hetzner       | **User data** when creating the server          |
   | Azure         | Advanced → **Custom data** (cloud-init)         |
   | DigitalOcean  | **User data** when creating the Droplet         |
   | Other cloud   | Look for "cloud-init" or "user data"            |

3. Wait ~20 min and connect via RDP — everything will be ready

### Option B — Existing server (manual SSH)

```bash
sudo bash bootstrap.sh
```

Follow progress:

```bash
tail -f /var/log/mt5_bootstrap.log
```

---

## Step-by-step via web console (no CLI needed)

Validated end-to-end through the AWS console; the same logic applies to any
provider's console (Hetzner, Azure, GCP, DigitalOcean) — only the exact
button labels/layout differ.

1. **Create the instance/server:**
   - Choose an image explicitly labeled **Ubuntu 24.04 LTS** (or 22.04).
     Don't trust a generic "ubuntu" search result blindly — providers keep
     adding newer LTS releases (e.g. 26.04) to the top of the list, and this
     bootstrap intentionally refuses to run on anything else. Confirm the
     version in the image name before launching.
   - Instance type: 2 vCPU / 4 GB RAM or more (e.g. AWS `t3.small`), 30 GB disk.
   - Region/datacenter location is free to choose — it only affects package
     download speed (closer to major mirrors = faster install), not whether
     it works.
2. **Firewall / security group:** open ports **22** (SSH) and **3389** (RDP),
   ideally restricted to your own IP.
   - Exception: if you plan to use a **browser-based SSH terminal**
     (AWS "EC2 Instance Connect", GCP "SSH in browser", DigitalOcean's
     web console, etc.), those connect from the *provider's* IP ranges, not
     yours — restricting port 22 to "My IP" will block them. Either open SSH
     to `0.0.0.0/0` to use the browser terminal, or keep it IP-restricted and
     connect with your own SSH client + key pair instead.
3. **User data / init script:** paste the full `bootstrap.sh` content into
   the provider's init-data field (see table above).
4. **Launch**, wait for the instance to reach "running", then connect via
   SSH (browser terminal or your own client) as the **default cloud image
   user** (e.g. `ubuntu` on AWS) — not `trader` yet, since that user is only
   created once the bootstrap script runs.
5. Follow progress with `tail -f /var/log/mt5_bootstrap.log`. The heaviest
   steps are the LXDE/XRDP package install and the MT5 install via Xvfb —
   each can take several minutes.
6. Once finished, connect via RDP as `trader` using the credentials printed
   at the end of the log (also saved to `~trader/mt5_credentials.txt`).
7. **Don't forget to terminate/destroy the instance when done testing**, to
   avoid ongoing cloud costs.

---

## Configuration

Edit **only** the block at the top of `bootstrap.sh`:

```bash
MT5_INSTANCES=4           # Number of MT5 instances

TRADER_USER="trader"      # Linux/RDP username
TRADER_PASS="trader@123"  # If you leave this default value, a strong password
                          # is generated automatically, printed at the end of
                          # the log, and saved to ~trader/mt5_credentials.txt

MT5_BASE_URL=""           # Leave empty — installs MT5 from scratch (~17 min)

EA_REPO_URL=""            # git@github.com:user/mt5_ea_repo.git
                          # Leave empty to skip EA linking

INSTALL_XRDP=true         # false for Hetzner (uses native VNC console, lighter)
                          # true for EC2 and providers without a GUI console
```

---

## What the bootstrap does

| Step | What happens |
|------|----------------|
| Validation | Checks distro/version/architecture and required config before touching anything |
| System | `apt update`, disables auto-upgrades, installs dependencies |
| GUI | Installs LXDE + XRDP, configures autologin for the `trader` user |
| Wine | Installs `wine` + `wine64` + `wine32` from the Ubuntu repositories |
| Firewall | Enables UFW allowing only ports 22/3389, as a second layer |
| MT5 | Installs from scratch via Xvfb (headless virtual display) |
| Instances | Clones `~/.mt5` N times → `~/wine-mt5-01`, `~/wine-mt5-02`, etc. |
| Desktop | Creates `.desktop` shortcuts in LXDE for each instance |
| EAs | Clones the EA repository and creates symlinks (if `EA_REPO_URL` is set) |

---

## Requirements

- Ubuntu 24.04 LTS (Noble) — 22.04 (Jammy) is also supported
- x86_64 architecture
- Port 3389 open in the firewall/security group (for RDP), restricted to your IP
- Port 22 open (for SSH), restricted to your IP
- Recommended minimum: 2 vCPU / 4 GB RAM (e.g. EC2 `t3.small`/`t3.medium`) for 4 instances
- The bootstrap itself enables a local firewall (UFW) allowing only ports 22 and 3389 as an extra layer — configure the provider's firewall too

---

## Lessons learned / Troubleshooting

This section documents the problems that took weeks to solve.
If the bootstrap fails, start here.

---

### 1. Silent MT5 install flag: `/auto`, not `/S`

**The error:** `wine mt5setup.exe /S` starts the process but doesn't install anything.
`terminal64.exe` never shows up.

**The cause:** The MT5 installer (`mt5setup.exe`) is NSIS-based but uses the non-standard
`/auto` flag for a silent install. The standard NSIS `/S` doesn't work.

**The fix:**
```bash
wine /tmp/mt5setup.exe /auto   # correct
wine /tmp/mt5setup.exe /S      # doesn't work
```

---

### 2. Use Ubuntu's Wine — NOT WineHQ Staging

**The error:** With WineHQ Staging 8+ installed, the process
`rundll32.exe setupapi,InstallHinfSection` (Wine prefix initialization)
takes **30+ minutes** and blocks the MT5 install.

**The cause:** WineHQ Staging 8+ introduced a new WoW64 mode that processes
`wine.inf` much more slowly on VMs. MT5 works fine with Ubuntu's
default Wine (version 6.x/7.x on 22.04, 8.x/9.x on 24.04).

**The fix:**
```bash
# CORRECT — Ubuntu's Wine with fallback
apt install -y wine wine64 || apt install -y wine64
apt install -y wine32 || apt install -y libwine:i386 || true

# WRONG — WineHQ Staging (too slow initializing the prefix)
# wget .../winehq.key && apt install winehq-staging
```

---

### 3. Don't initialize the Wine prefix manually

**The error:** Running `wineboot --init` before `wine mt5setup.exe /auto` creates
a race condition — `wineboot` returns before its child processes
(`winedevice`, `rundll32 setupapi`) finish. When `mt5setup` is called
right after, the prefix isn't ready yet, causing:
```
wine: could not load kernel32.dll, status c0000135
```

**The fix:** Let Wine initialize the prefix automatically on the first run of
`wine mt5setup.exe /auto`. Wine blocks until initialization is
complete before running the installer.

```bash
# CORRECT — let Wine handle everything
WINEARCH=win64 WINEPREFIX="$MT5_BASE" wine /tmp/mt5setup.exe /auto

# WRONG — manual initialization creates a race condition
WINEPREFIX="$MT5_BASE" wineboot --init
sleep 5
WINEPREFIX="$MT5_BASE" wine /tmp/mt5setup.exe /auto
```

---

### 4. `set -euo pipefail` breaks Wine commands

**The error:** With `set -euo pipefail`, the script aborts on Wine commands that
return a non-zero exit code (which happens often during normal Wine
initialization).

**The fix:** Use only `set -o pipefail` in the trader script.

```bash
set -o pipefail    # correct
set -euo pipefail  # breaks Wine
```

---

### 5. `done` is a bash reserved word

**The error:** Using `done()` as a function name causes a bash parsing error.

**The fix:** Use a different name (`ok()`, `success()`, etc.).

---

### 6. WebView2 is not needed to install MT5

Earlier versions of this bootstrap tried to install the Microsoft WebView2
Runtime before MT5. That's unnecessary — MT5 installs and runs
fine without it. Removing it simplified the script and eliminated a
possible source of failures.

---

### 7. `wine: could not load kernel32.dll, status c0000135` error

This error can show up in the log during Wine prefix initialization
(especially in `wineboot` subprocesses). **It's normal and not a failure**
when it happens during the initial prefix creation. The process continues
correctly.

The error is only a problem if it appears while trying to run `mt5setup.exe`
directly (outside of Wine's auto-initialization flow).

---

### 8. Monitoring progress

```bash
# Real-time
tail -f /var/log/mt5_bootstrap.log

# Check if MT5 was installed
ls ~/wine-mt5-01/drive_c/Program\ Files/MetaTrader\ 5/terminal64.exe

# Check created instances
ls ~/Desktop/mt5-*.desktop
```
