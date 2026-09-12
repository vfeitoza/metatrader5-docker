#!/bin/bash
# Launched by LXDE's autostart on RDP login. RDP/PAM logins don't inherit
# the container's Docker ENV vars, so the AUTOSTART_MT5 flag is read from a
# file written by entrypoint.sh instead of the environment. Exits cleanly
# (0) when disabled, so lxsession doesn't treat it as a crash and retry it.
if [ "$(cat /home/trader/.autostart_mt5 2>/dev/null)" = "false" ]; then
    exit 0
fi
exec /usr/local/bin/mt5-launch.sh
