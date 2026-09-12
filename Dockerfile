# ==========================================================
#  MT5 (MetaTrader 5) via Wine + LXDE + xrdp, one instance per container
#
#  Build:  docker build -t lanzara/lxde-metatrader5:test .
#  Run:    docker run -d -p 3389:3389 --shm-size=512m \
#            -v mt5data:/home/trader/.mt5 lanzara/lxde-metatrader5:test
#
#  See README.md for environment variables and full usage.
# ==========================================================
FROM ubuntu:24.04
SHELL ["/bin/bash", "-c"]

ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------
# System packages
# ---------------------------------------------------------
RUN apt-get update -y -q && \
    apt-get upgrade -y -q \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" && \
    dpkg --add-architecture i386 && \
    apt-get update -y -q && \
    apt-get install -y -q \
        lxde dbus-x11 xvfb xdotool wmctrl wget curl git ca-certificates \
        xrdp tini openssl && \
    rm -rf /var/lib/apt/lists/*

# Wine from Ubuntu's own repos only — never add the WineHQ repo here.
# WineHQ Staging 8+ has a WoW64 init mode that takes 30+ minutes on first
# run; Ubuntu's distro-packaged Wine (validated in bootstrap.sh) does not.
RUN apt-get update -y -q && \
    (apt-get install -y -q wine wine64 || apt-get install -y -q wine64) && \
    (apt-get install -y -q wine32 || apt-get install -y -q libwine:i386 || true) && \
    rm -rf /var/lib/apt/lists/*

# update-alternatives defaults x-session-manager to gnome-session (higher
# priority) even though only LXDE packages are installed — xrdp uses this
# alternative directly to pick the desktop, and an incomplete gnome-session
# crashes the session within seconds. Force LXDE explicitly.
RUN update-alternatives --set x-session-manager /usr/bin/startlxde

# ---------------------------------------------------------
# Non-root trader user (Wine must never run as root)
# ---------------------------------------------------------
RUN useradd -m -s /bin/bash trader

# ---------------------------------------------------------
# MT5 install (build-time, as trader) — same logic as bootstrap.sh
# ---------------------------------------------------------
USER trader
ENV MT5_BASE=/home/trader/.mt5
ENV MT5_EXE="drive_c/Program Files/MetaTrader 5/terminal64.exe"

RUN set -o pipefail; \
    export DISPLAY=:99; \
    export WINEDEBUG=-all; \
    Xvfb :99 -screen 0 1024x768x24 -ac & \
    XVFB_PID=$!; \
    sleep 3; \
    cd /tmp && \
    curl -sL "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe" -o mt5setup.exe && \
    WINEARCH=win64 WINEPREFIX="$MT5_BASE" wine /tmp/mt5setup.exe /auto; \
    TIMEOUT=2700; ELAPSED=0; \
    while [ ! -f "$MT5_BASE/$MT5_EXE" ] && [ "$ELAPSED" -lt "$TIMEOUT" ]; do \
        kill -0 "$XVFB_PID" 2>/dev/null || { echo "ERROR: Xvfb exited unexpectedly"; break; }; \
        sleep 10; ELAPSED=$((ELAPSED + 10)); \
        echo "Waiting for terminal64.exe... ${ELAPSED}s"; \
    done; \
    kill "$XVFB_PID" 2>/dev/null || true; \
    rm -f /tmp/mt5setup.exe; \
    [ -f "$MT5_BASE/$MT5_EXE" ] || { echo "FATAL: terminal64.exe not found after install"; exit 1; }

# Autostart MT5 when the LXDE session loads via RDP (can be disabled at
# runtime via a flag file written by entrypoint.sh; see mt5-autostart.sh).
# Copy the system default autostart first (lxpanel, pcmanfm --desktop, etc.)
# instead of overwriting it — a bare "echo > autostart" replaces the panel
# and desktop icons with nothing.
RUN mkdir -p /home/trader/.config/lxsession/LXDE && \
    cp /etc/xdg/lxsession/LXDE/autostart /home/trader/.config/lxsession/LXDE/autostart && \
    echo '@/usr/local/bin/mt5-autostart.sh' >> /home/trader/.config/lxsession/LXDE/autostart

# Disable lxpolkit: it tries to talk to systemd-logind, which doesn't exist
# in a container, and pops a "No session for pid" dialog on every login.
RUN printf '[Session]\nwindow_manager=openbox-lxde\npolkit/command=/bin/true\n' \
        > /home/trader/.config/lxsession/LXDE/desktop.conf

# Desktop shortcut so MT5 can be reopened manually if the user closes it
# (autostart only fires once, on session start).
RUN mkdir -p /home/trader/Desktop && \
    printf '[Desktop Entry]\nName=MetaTrader 5\nExec=/usr/local/bin/mt5-launch.sh\nType=Application\nTerminal=false\nIcon=mt5\nCategories=Finance;\n' \
        > /home/trader/Desktop/MetaTrader5.desktop && \
    chmod +x /home/trader/Desktop/MetaTrader5.desktop

# ---------------------------------------------------------
# Entrypoint / healthcheck
# ---------------------------------------------------------
USER root
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
COPY mt5-autostart.sh /usr/local/bin/mt5-autostart.sh
COPY mt5-launch.sh /usr/local/bin/mt5-launch.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh /usr/local/bin/mt5-autostart.sh /usr/local/bin/mt5-launch.sh

VOLUME ["/home/trader/.mt5"]
EXPOSE 3389

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
