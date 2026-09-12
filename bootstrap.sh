#!/bin/bash
# ==========================================================
#  MT5 MULTI-INSTANCE BOOTSTRAP
#
#  How to use:
#    EC2      -> "Advanced Details > User Data" when launching the instance
#    Hetzner  -> "User data" field when creating the server
#    Azure    -> "Custom data" (cloud-init)
#    Any VPS  -> paste as cloud-init/user-data, or run via SSH: sudo bash bootstrap.sh
#
#  Follow progress after logging in via SSH:
#    tail -f /var/log/mt5_bootstrap.log
#
#  Edit ONLY the CONFIGURATION section below.
# ==========================================================

# ==================== CONFIGURATION ====================
MT5_INSTANCES=4             # How many MT5 instances to create

TRADER_USER="trader"        # Linux/RDP username
TRADER_PASS="trader@123"    # RDP login password. If you leave this default
                             # value, a strong random password is generated
                             # automatically and printed in the final log
                             # summary — change it here if you want your own.

# URL of a tar.gz snapshot of an already-installed ~/.mt5.
# Leave empty to install MT5 from scratch via Xvfb (~15 min).
# Examples:
#   "https://my-bucket.s3.amazonaws.com/mt5base.tar.gz"
#   "https://fsn1.your-objectstorage.com/bucket/mt5base.tar.gz"
MT5_BASE_URL=""

# Git repository with your EAs. Leave empty to skip linking.
# An https:// URL works out of the box for public repositories.
# A git@ (SSH) URL requires a deploy key already configured on the server.
# Example: "git@github.com:user/mt5_ea_repo.git"
EA_REPO_URL=""

# Install XRDP (remote access via port 3389)?
#   true  -> EC2 and other providers without a native GUI console
#   false -> Hetzner (uses the built-in VNC console, lighter)
INSTALL_XRDP=true
# ======================================================

export DEBIAN_FRONTEND=noninteractive
LOG="/var/log/mt5_bootstrap.log"
exec > >(tee -a "$LOG") 2>&1

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
die()  { log "FATAL ERROR: $*"; exit 1; }
ok()   { log "✓ $*"; }

# ----------------------------------------------------------
# PART 0 — VALIDATIONS (before touching the system)
# ----------------------------------------------------------
if [ "$TRADER_PASS" = "trader@123" ]; then
    TRADER_PASS="$(openssl rand -base64 12)"
    log "WARNING: TRADER_PASS was not customized — generating a random password for security."
fi

case "$MT5_INSTANCES" in
    ''|*[!0-9]*) die "MT5_INSTANCES must be a positive integer (current value: '$MT5_INSTANCES')" ;;
    0) die "MT5_INSTANCES must be greater than zero" ;;
esac

if [ -r /etc/os-release ]; then
    . /etc/os-release
    ARCH="$(uname -m)"
    if [ "$ID" != "ubuntu" ] || { [ "$VERSION_ID" != "22.04" ] && [ "$VERSION_ID" != "24.04" ]; } || [ "$ARCH" != "x86_64" ]; then
        die "Unsupported distro/architecture ($ID $VERSION_ID $ARCH). This bootstrap requires Ubuntu 22.04 or 24.04 x86_64."
    fi
else
    die "Could not detect the distro (/etc/os-release missing). This bootstrap requires Ubuntu 22.04 or 24.04 x86_64."
fi

log "============================================="
log " MT5 BOOTSTRAP STARTED — $(date)"
log " Distro: $PRETTY_NAME"
log " Instances: $MT5_INSTANCES"
log " Mode: $([ -n "$MT5_BASE_URL" ] && echo 'SNAPSHOT' || echo 'FRESH INSTALL')"
log "============================================="

# ----------------------------------------------------------
# PART 1 — SYSTEM (root)
# ----------------------------------------------------------
log "-> Updating system..."
apt update -y -q
apt upgrade -y -q \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"

log "-> Disabling auto-upgrades..."
systemctl disable unattended-upgrades 2>/dev/null || true
systemctl stop    unattended-upgrades 2>/dev/null || true

log "-> Enabling i386 architecture for Wine..."
dpkg --add-architecture i386
apt update -y -q

log "-> Installing packages (desktop + tools)..."
PKGS="lxde dbus-x11 xvfb xdotool wmctrl wget curl git ca-certificates"
[ "$INSTALL_XRDP" = "true" ] && PKGS="$PKGS xrdp"
apt install -y -q $PKGS

log "-> Installing Wine..."
apt install -y -q wine wine64 || apt install -y -q wine64
apt install -y -q wine32 || apt install -y -q libwine:i386 || log "WARNING: wine32/libwine:i386 not available, continuing without 32-bit support"

log "-> Creating user ${TRADER_USER}..."
if ! id "${TRADER_USER}" &>/dev/null; then
    useradd -m -s /bin/bash "${TRADER_USER}"
fi
usermod -aG sudo "${TRADER_USER}"
echo "${TRADER_USER}:${TRADER_PASS}" | chpasswd
usermod -aG ssl-cert "${TRADER_USER}" 2>/dev/null || true

TRADER_HOME=$(getent passwd "${TRADER_USER}" | cut -d: -f6)
cat > "${TRADER_HOME}/mt5_credentials.txt" << CRED_EOF
RDP login for this server
--------------------------
User:     ${TRADER_USER}
Password: ${TRADER_PASS}
Port:     3389
CRED_EOF
chown "${TRADER_USER}:${TRADER_USER}" "${TRADER_HOME}/mt5_credentials.txt"
chmod 600 "${TRADER_HOME}/mt5_credentials.txt"

log "-> Configuring LXDE autologin..."
mkdir -p /etc/lightdm
cat > /etc/lightdm/lightdm.conf << LIGHTDM_EOF
[Seat:*]
autologin-user=${TRADER_USER}
autologin-user-timeout=0
user-session=LXDE
LIGHTDM_EOF

# update-alternatives defaults x-session-manager to gnome-session (higher
# priority) even though only LXDE packages are installed — XRDP uses this
# alternative (not lightdm's user-session setting) to pick the desktop, and
# an incomplete gnome-session crashes within seconds. Force LXDE explicitly.
update-alternatives --set x-session-manager /usr/bin/startlxde

if [ "$INSTALL_XRDP" = "true" ]; then
    log "-> Configuring XRDP..."
    systemctl enable xrdp
    systemctl restart xrdp
else
    log "-> XRDP skipped (using the provider's native console)"
fi

log "-> Configuring local firewall (UFW) as a second layer..."
apt install -y -q ufw
ufw allow 22/tcp >/dev/null
[ "$INSTALL_XRDP" = "true" ] && ufw allow 3389/tcp >/dev/null
ufw --force enable >/dev/null
ok "System configured"

# ----------------------------------------------------------
# PART 2 — Write config for the trader user's script
# ----------------------------------------------------------
cat > /tmp/mt5_config.env << CONF_EOF
MT5_INSTANCES=${MT5_INSTANCES}
MT5_BASE_URL=${MT5_BASE_URL}
EA_REPO_URL=${EA_REPO_URL}
TRADER_USER=${TRADER_USER}
CONF_EOF

# ----------------------------------------------------------
# PART 3 — Trader script (Wine, MT5, instances)
# Uses 'TRADER_EOF' (single quotes) to avoid expansion here.
# Internal variables are expanded when the script actually runs.
# ----------------------------------------------------------
cat > /tmp/mt5_setup_trader.sh << 'TRADER_EOF'
#!/bin/bash
set -o pipefail
source /tmp/mt5_config.env

log() { echo "  [$(date '+%H:%M:%S')] $*"; }

MT5_BASE="$HOME/.mt5"
MT5_EXE="drive_c/Program Files/MetaTrader 5/terminal64.exe"
DESKTOP="$HOME/Desktop"
mkdir -p "$DESKTOP"

# -- Install / restore MT5 base --------------------------
if [ -f "$MT5_BASE/$MT5_EXE" ]; then
    log "-> MT5 base already installed at $MT5_BASE — skipping reinstall (idempotent run)."
elif [ -n "$MT5_BASE_URL" ]; then
    log "-> Downloading MT5 base snapshot..."
    wget -q --show-progress "$MT5_BASE_URL" -O /tmp/mt5base.tar.gz
    log "-> Extracting..."
    tar xzf /tmp/mt5base.tar.gz -C "$HOME"
    rm -f /tmp/mt5base.tar.gz
    log "✓ MT5 restored from snapshot"
else
    log "-> Installing MT5 from scratch via Xvfb (virtual display)..."
    export DISPLAY=:99
    export WINEDEBUG=-all

    Xvfb :99 -screen 0 1024x768x24 -ac &
    XVFB_PID=$!
    sleep 3

    cd /tmp
    log "  -> Downloading mt5setup.exe..."
    curl -sL "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe" -o mt5setup.exe

    log "  -> Installing MT5 (Wine initializes the prefix automatically)..."
    WINEARCH=win64 WINEPREFIX="$MT5_BASE" wine /tmp/mt5setup.exe /auto

    # Wait for terminal64.exe to appear (up to 45 min — Wine initializes the prefix on first run)
    # Also aborts early if Xvfb dies, instead of waiting out the full timeout.
    TIMEOUT=2700
    ELAPSED=0
    while [ ! -f "$MT5_BASE/$MT5_EXE" ] && [ "$ELAPSED" -lt "$TIMEOUT" ]; do
        if ! kill -0 "$XVFB_PID" 2>/dev/null; then
            log "ERROR: Xvfb exited unexpectedly before MT5 finished installing."
            break
        fi
        sleep 10
        ELAPSED=$((ELAPSED + 10))
        log "  -> Waiting for terminal64.exe... ${ELAPSED}s"
    done

    kill "$XVFB_PID" 2>/dev/null || true
    log "✓ MT5 installed via Xvfb (silent)"
fi

# Validate installation
[ -f "$MT5_BASE/$MT5_EXE" ] || {
    log "ERROR: terminal64.exe not found at $MT5_BASE"
    log "Check /var/log/mt5_bootstrap.log"
    exit 1
}

# -- Remove old instances and create new ones ------------
log "-> Cleaning up previous instances..."
rm -rf "$HOME"/wine-mt5-* "$HOME"/run-mt5-*.sh "$DESKTOP"/mt5-*.desktop 2>/dev/null || true

log "-> Creating $MT5_INSTANCES instances..."
for ((i=1; i<=MT5_INSTANCES; i++)); do
    printf -v ID "%02d" "$i"
    PREFIX="$HOME/wine-mt5-$ID"
    RUNSCRIPT="$HOME/run-mt5-$ID.sh"
    SHORTCUT="$DESKTOP/mt5-$ID.desktop"

    log "  -> Instance $ID..."
    cp -r "$MT5_BASE" "$PREFIX"

    cat > "$RUNSCRIPT" << RUN_EOF
#!/bin/bash
export WINEPREFIX="$PREFIX"
exec wine "$PREFIX/$MT5_EXE"
RUN_EOF
    chmod +x "$RUNSCRIPT"

    cat > "$SHORTCUT" << SHORT_EOF
[Desktop Entry]
Name=MT5-$ID
Exec=env WINEPREFIX=$PREFIX wine "$PREFIX/$MT5_EXE"
Type=Application
Terminal=false
Icon=mt5
Categories=Finance;
SHORT_EOF
    chmod +x "$SHORTCUT"
done
log "✓ $MT5_INSTANCES instances created"

# -- EA repository (optional) -----------------------------
# An https:// URL works directly for public repositories, no extra config.
# A git@ (SSH) URL requires a deploy key already configured on the server.
if [ -n "$EA_REPO_URL" ]; then
    log "-> Cloning EA repository..."
    git clone "$EA_REPO_URL" "$HOME/mt5_ea_repo"

    log "-> Linking Experts into each instance..."
    for ((i=1; i<=MT5_INSTANCES; i++)); do
        printf -v ID "%02d" "$i"
        PREFIX="$HOME/wine-mt5-$ID"

        MT5_DIR=$(find \
            "$PREFIX/drive_c/Program Files" \
            "$PREFIX/drive_c/Program Files (x86)" \
            -maxdepth 2 -type d -name "MetaTrader 5" 2>/dev/null | head -n 1)

        if [ -n "$MT5_DIR" ]; then
            rm -rf "$MT5_DIR/MQL5/Experts"
            ln -s "$HOME/mt5_ea_repo" "$MT5_DIR/MQL5/Experts"
            log "  ✓ Experts linked: instance $ID"
        else
            log "  ⚠ MetaTrader 5 dir not found for instance $ID"
        fi
    done
fi

log ""
log "============================================="
log " TRADER SETUP COMPLETE!"
log "============================================="
TRADER_EOF

chmod +x /tmp/mt5_setup_trader.sh
log "-> Running setup as user ${TRADER_USER}..."
sudo -u "${TRADER_USER}" bash /tmp/mt5_setup_trader.sh || {
    log "FATAL ERROR: trader setup failed. See the log above for details."
    exit 1
}

# ----------------------------------------------------------
# FINAL SUMMARY
# ----------------------------------------------------------
PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "<server IP>")

log ""
log "============================================="
log " BOOTSTRAP COMPLETE! — $(date)"
log ""
log " Connect via RDP:"
log "   IP:       $PUBLIC_IP"
log "   Port:     3389"
log "   User:     $TRADER_USER"
log "   Password: $TRADER_PASS"
log ""
log " (also saved to /home/${TRADER_USER}/mt5_credentials.txt)"
log ""
if [ -z "$MT5_BASE_URL" ]; then
log " NEXT STEP — Create a snapshot for future servers:"
log "   tar czf mt5base.tar.gz -C /home/trader .mt5"
log "   # Upload it to S3 or Object Storage and fill in MT5_BASE_URL"
fi
log "============================================="
