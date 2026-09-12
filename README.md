# MT5 Server

Run **MetaTrader 5** on Linux (no Windows needed), accessible over RDP — no
manual Wine setup, no X server configuration.

This repo ships two ways to run MT5:

- **[Docker](#docker)** (below) — one container = one MT5 instance. The
  simplest path, recommended for most users.
- **[Bootstrap script](BOOTSTRAP.md)** — sets up multiple MT5 instances
  directly on a full VM (no Docker), for when you need several instances on
  one server or full control over the machine.

---

## Docker

A single `docker run` gives you one MT5 instance, ready to use via RDP, built
from the same Wine/LXDE/xrdp setup validated by `bootstrap.sh` (Ubuntu's own
Wine, the `x-session-manager`/LXDE fix, the `/auto` install flag, etc.) —
packaged as `lanzara/lxde-metatrader5` on Docker Hub.

If the VM doesn't have Docker yet, install it first with the official
one-liner:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER && newgrp docker
```

> **Note:** If `docker pull` or `docker run` fails right after this with
> `permission denied ... docker.sock`, log out and back into your SSH
> session (or reboot the VM) so the new `docker` group membership takes
> effect.

Then pull and run the image:

```bash
docker pull lanzara/lxde-metatrader5

docker run -d \
  --name mt5 \
  -p 3389:3389 \
  --shm-size=512m \
  -v mt5data:/home/trader/.mt5 \
  -e TRADER_PASS=YOURPASSWORD \
  lanzara/lxde-metatrader5:latest
```

If you omit `-e TRADER_PASS=YOURPASSWORD`, a random strong password is
generated automatically. Check it with:

```bash
docker logs mt5
```

And connect via any RDP client (Windows: `mstsc.exe`; Linux: Remmina/FreeRDP)
to `<host>:3389`, user `trader`, using your configured (or generated)
password. MT5 opens automatically once the LXDE session loads.

**Environment variables:**

| Variable        | Default    | Purpose                                                        |
|-----------------|------------|-----------------------------------------------------------------|
| `TRADER_PASS`   | random     | RDP login password for the `trader` user (printed in `docker logs`) |
| `EA_REPO_URL`   | empty      | Git repo (https or git@ with a configured deploy key) to symlink into `MQL5/Experts` |
| `AUTOSTART_MT5` | `true`     | Set to `false` to skip auto-opening MT5 on RDP login             |

**Persistence:** mount a volume at `/home/trader/.mt5` (as in the example
above) to keep account logins, config, templates and EAs across container
recreation. Without it, everything is lost when the container is removed.

**Notes:**
- `--shm-size=512m` is recommended — Docker's 64 MB default `/dev/shm` can be
  too small for X11/Wine.
- One container = one MT5 instance. To run several, start several containers
  (each with its own volume).
- Building the image locally takes ~20 min (MT5 is installed at build time,
  not on first run) and produces a ~1.5–2.5 GB image.

---

## Bootstrap script (multiple instances, full VM)

For running several MT5 instances on one server without Docker — see
**[BOOTSTRAP.md](BOOTSTRAP.md)** for the full guide (quick flow, web console
walkthrough, configuration, troubleshooting).

---

## Repository structure

```
bootstrap.sh    <- full-VM bootstrap script (see BOOTSTRAP.md)
Dockerfile      <- Docker image (Wine + LXDE + xrdp + MT5, one instance per container)
entrypoint.sh   <- container startup: RDP password, dbus, xrdp, EA linking
healthcheck.sh  <- container HEALTHCHECK (xrdp/xrdp-sesman running)
```
