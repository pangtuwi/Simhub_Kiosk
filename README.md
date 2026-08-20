# Simhub_Kiosk
Setup for a headless web viewer for Simhub Dashboards

read KIOSK.md for Ubuntu 26.04 LTS Kiosk & Remote Display Setup Guide

setup_kiosk.sh provided as run script

## Day-to-Day Operations

### Close the Kiosk Browser and Open a Terminal
If you are connected over remote desktop and need to stop the kiosk app before restarting it, use:
```bash
killall chromium-browser chromium google-chrome 2>/dev/null
```
Then open a terminal with:
```bash
Ctrl + Alt + T
```

If the terminal shortcut does not work, you can also use the desktop menu / system menu to launch Terminal.

### Restart the Kiosk Browser
From the terminal, restart the kiosk using:
```bash
bash ~/.config/autostart-scripts/kiosk.sh &
```

### Full Restart in One Go
```bash
killall chromium-browser chromium google-chrome 2>/dev/null && bash ~/.config/autostart-scripts/kiosk.sh &
```
