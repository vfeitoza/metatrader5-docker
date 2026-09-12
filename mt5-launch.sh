#!/bin/bash
# Launches MT5 directly, no autostart flag check. Used by the desktop
# shortcut so the user can always reopen MT5 manually if closed.
export WINEPREFIX="/home/trader/.mt5"
exec wine "/home/trader/.mt5/drive_c/Program Files/MetaTrader 5/terminal64.exe"
