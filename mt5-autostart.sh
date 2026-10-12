#!/bin/bash
# Launched by LXDE's autostart on RDP login. RDP/PAM logins don't inherit
# the container's Docker ENV vars, so the AUTOSTART_MT5 flag is read from a
# file written by entrypoint.sh instead of the environment. Exits cleanly
# (0) when disabled, so lxsession doesn't treat it as a crash and retry it.
if [ "$(cat /home/trader/.autostart_mt5 2>/dev/null)" = "false" ]; then
    exit 0
fi
# Aplica resolucao fixa 1920x1080 (via /etc/xrdp/rdp_resolution.env)
RES="$(cut -d= -f2 /etc/xrdp/rdp_resolution.env 2>/dev/null)"
[ -z "$RES" ] && RES="1920x1080"
# xrdp cria o DISPLAY dinamicamente (:10, :11...); aguarda X subir
for _i in 1 2 3 4 5; do
    xrandr -s "$RES" >/dev/null 2>&1 && break
    xrandr --output default --mode "$RES" >/dev/null 2>&1 && break
    # tenta adicionar modo se nao existir (xorgxrdp as vezes so tem 640x480 default)
    if command -v cvt >/dev/null 2>&1 && command -v xrandr >/dev/null 2>&1; then
        MODELINE="$(cvt 1920 1080 60 2>/dev/null | grep Modeline | cut -d' ' -f2-)"
        if [ -n "$MODELINE" ]; then
            MODENAME="$(echo "$MODELINE" | awk '{print $1}' | tr -d '"')"
            xrandr --newmode $MODELINE >/dev/null 2>&1 || true
            xrandr --addmode default "$MODENAME" >/dev/null 2>&1 || true
            xrandr --output default --mode "$MODENAME" >/dev/null 2>&1 && break
        fi
    fi
    sleep 1
done
exec /usr/local/bin/mt5-launch.sh
