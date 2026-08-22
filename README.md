# Simhub_Kiosk
Setup for a headless web viewer for Simhub Dashboards

Read [KIOSK.md](KIOSK.md) for the full Ubuntu 26.04 LTS Kiosk & Remote Display Setup Guide, including a [Troubleshooting](KIOSK.md#troubleshooting) section covering the common issue where the kiosk returns to the login screen after a period of inactivity.

`setup_kiosk.sh` is provided as the main installer script.

If you have already run the installer and want to apply kiosk stability improvements without a clean reinstall, use the patch script:
```bash
chmod +x step2.sh
sudo ./step2.sh
```
It's safe to run from any directory — every path it touches is resolved from the kiosk's login user's home directory, not from where you invoke it. If it's run from an already-root shell (`sudo -s`/`sudo -i` first) it can't tell who that login user is and will warn you; pass `--user <name>` to set it explicitly. Add `--url <url>` to override the detected kiosk URL, or `-y` to skip the confirmation prompt for unattended re-runs. Run `sudo ./step2.sh --help` for details.

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
