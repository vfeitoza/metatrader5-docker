#!/bin/bash
# Container entrypoint: sets the trader RDP password, starts dbus + xrdp,
# optionally links an EA repo, then stays in the foreground as PID 1's child
# (tini forwards signals from `docker stop`).
set -o pipefail

MT5_BASE="/home/trader/.mt5"
MT5_EXE="drive_c/Program Files/MetaTrader 5/terminal64.exe"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# -- Initialize volume if empty (bind mount hides build-time files) -----
# Named volumes are auto-populated by Docker, but bind mounts (e.g.
# ./conteudo:/home/trader/.mt5) start empty and hide the image content.
# Seed from /opt/mt5-template (copy of the build-time install) when needed.
if [ ! -f "$MT5_BASE/$MT5_EXE" ]; then
    if [ -f "/opt/mt5-template/$MT5_EXE" ]; then
        log "Volume empty — seeding from template (bind mount detected)..."
        mkdir -p "$MT5_BASE"
        cp -a /opt/mt5-template/. "$MT5_BASE"/
        chown -R trader:trader "$MT5_BASE"
        log "Volume seeded successfully."
    else
        log "FATAL: terminal64.exe not found at $MT5_BASE/$MT5_EXE"
        log "The mounted volume looks empty or from an incompatible image build."
        exit 1
    fi
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

# -- Detect IP for the connection hint (best-effort, never fails) --------
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if command -v ip >/dev/null 2>&1; then
    _GW_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')"
    [ -n "$_GW_IP" ] && HOST_IP="$_GW_IP"
fi
CONTAINER_IP="$(hostname -i 2>/dev/null | awk '{print $1}')"
[ -z "$HOST_IP" ] && HOST_IP="127.0.0.1"

log "============================================="
log " RDP PRONTO PARA CONEXAO"
log "   Host:      localhost  (ou ${HOST_IP})"
log "   IP cont.:  ${CONTAINER_IP:-n/a}"
log "   Porta:     3389"
log "   Usuario:   trader"
log "   Senha:     ${TRADER_PASS}"
log "---------------------------------------------"
log " Conecte seu cliente RDP em:"
log "   -> localhost:3389  ou  ${HOST_IP}:3389"
log "   Windows: mstsc /v:localhost:3389"
log "   Linux:   xfreerdp /v:localhost:3389 /u:trader"
log "============================================="

# -- dbus system bus ---------------------------------------------------------
mkdir -p /run/dbus
if [ ! -S /run/dbus/system_bus_socket ]; then
    dbus-daemon --system --fork
fi

# -- Resolution (fixo 1920x1080; pode sobrescrever via RDP_RESOLUTION) --
RDP_RESOLUTION="${RDP_RESOLUTION:-1920x1080}"
RDP_W="${RDP_RESOLUTION%x*}"
RDP_H="${RDP_RESOLUTION#*x}"
case "$RDP_W" in ''|*[!0-9]*) RDP_W=1920 ;; esac
case "$RDP_H" in ''|*[!0-9]*) RDP_H=1080 ;; esac
[ "$RDP_W" -lt 800 ] && RDP_W=800; [ "$RDP_W" -gt 7680 ] && RDP_W=7680
[ "$RDP_H" -lt 600 ] && RDP_H=600; [ "$RDP_H" -gt 4320 ] && RDP_H=4320
RDP_RESOLUTION="${RDP_W}x${RDP_H}"
if grep -q "^\s*max_bpp" /etc/xrdp/xrdp.ini 2>/dev/null; then
    sed -i 's/^\s*max_bpp=.*/max_bpp=32/' /etc/xrdp/xrdp.ini 2>/dev/null || true
fi
mkdir -p /etc/xrdp
printf "%s\n" "$RDP_RESOLUTION" > /etc/xrdp/rdp_resolution.env
log "Resolucao RDP: ${RDP_RESOLUTION} (altere RDP_RESOLUTION no .env se quiser outro tamanho)"

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
