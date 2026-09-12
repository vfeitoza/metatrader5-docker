#!/bin/bash
# Container entrypoint: sets the trader RDP password, starts dbus + xrdp,
# optionally links an EA repo, then stays in the foreground as PID 1's child
# (tini forwards signals from `docker stop`).
set -o pipefail

MT5_BASE="/home/trader/.mt5"
MT5_EXE="drive_c/Program Files/MetaTrader 5/terminal64.exe"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# -- Fail fast if the volume was mounted empty/corrupted -----------------
# Build-time install is the source of truth; we never reinstall at runtime.
if [ ! -f "$MT5_BASE/$MT5_EXE" ]; then
    log "FATAL: terminal64.exe not found at $MT5_BASE/$MT5_EXE"
    log "The mounted volume looks empty or from an incompatible image build."
    exit 1
fi

# -- RDP password -----------------------------------------------------------
if [ -z "$TRADER_PASS" ]; then
    TRADER_PASS="$(openssl rand -base64 12)"
fi
echo "trader:${TRADER_PASS}" | chpasswd
cat > /home/trader/mt5_credentials.txt << CRED_EOF
RDP login for this container
-----------------------------
User:     trader
Password: ${TRADER_PASS}
Port:     3389
CRED_EOF
chown trader:trader /home/trader/mt5_credentials.txt
chmod 600 /home/trader/mt5_credentials.txt

log "============================================="
log " RDP CREDENTIALS"
log "   user:     trader"
log "   password: ${TRADER_PASS}"
log "   port:     3389"
log "============================================="

# -- dbus system bus ---------------------------------------------------------
mkdir -p /run/dbus
if [ ! -S /run/dbus/system_bus_socket ]; then
    dbus-daemon --system --fork
fi

# -- xrdp ---------------------------------------------------------------
mkdir -p /var/run/xrdp
/usr/sbin/xrdp-sesman --nodaemon &
/usr/sbin/xrdp --nodaemon &
XRDP_PID=$!

# -- Optional EA repository (idempotent) ------------------------------------
if [ -n "$EA_REPO_URL" ] && [ ! -d "$MT5_BASE/ea_repo" ]; then
    log "-> Cloning EA repository..."
    git clone "$EA_REPO_URL" "$MT5_BASE/ea_repo" || log "WARNING: failed to clone EA_REPO_URL"
fi

if [ -d "$MT5_BASE/ea_repo" ]; then
    MT5_DIR=$(dirname "$MT5_BASE/$MT5_EXE")
    if [ -d "$MT5_DIR" ] && [ ! -L "$MT5_DIR/MQL5/Experts" ]; then
        rm -rf "$MT5_DIR/MQL5/Experts"
        ln -s "$MT5_BASE/ea_repo" "$MT5_DIR/MQL5/Experts"
        log "-> Experts linked to EA repository"
    fi
fi

chown -R trader:trader "$MT5_BASE"

# -- Autostart flag for mt5-autostart.sh -------------------------------------
# RDP/PAM logins don't inherit the container's Docker ENV vars, so
# AUTOSTART_MT5 is handed to mt5-autostart.sh via this file instead.
echo "${AUTOSTART_MT5:-true}" > /home/trader/.autostart_mt5
chown trader:trader /home/trader/.autostart_mt5

# -- Stay alive, forward signals cleanly -------------------------------------
trap 'log "Shutting down..."; kill -TERM "$XRDP_PID" 2>/dev/null; exit 0' TERM INT

log "Ready. Waiting for RDP connections on port 3389."
wait "$XRDP_PID"
