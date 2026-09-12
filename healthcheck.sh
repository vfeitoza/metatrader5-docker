#!/bin/bash
# Healthy = xrdp and xrdp-sesman are running. MT5 itself only starts once
# someone logs in via RDP, so it is not part of the healthcheck criteria.
pgrep -x xrdp >/dev/null || exit 1
pgrep -x xrdp-sesman >/dev/null || exit 1
exit 0
