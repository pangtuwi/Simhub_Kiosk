# Ubuntu 26.04 LTS Kiosk & Remote Display Setup Guide

This guide details the complete configuration process for transforming a laptop running **Ubuntu 26.04 LTS** (or compatible Debian/Ubuntu derivatives) into an unattended, always-on full-screen Web viewer for Simhub dashboards.

---

## Architecture & System Overview

* **Base OS:** Ubuntu 26.04 LTS (Desktop / Minimal X11 / Wayland fallback to X11 for VNC)
* **Kiosk Engine:** Chromium / Google Chrome in dedicated `--kiosk` execution mode
* **Cursor Management:** `unclutter` to automatically hide mouse pointers during inactivity
* **Remote Management:** `x11vnc` attached directly to Display `:0` (allowing real-time interaction with the physical kiosk display)
* **Power & Thermal Policy:** Lid switch ignored at systemd level; screensaver, DPMS, and display blanking permanently disabled
* **Keyring:** Configured to unlock silently on autologin to prevent security credential popups

---

## Table of Contents
1. [Automated Installation](#automated-installation)
2. [Manual Step-by-Step Configuration](#manual-step-by-step-configuration)
   - [1. Power Management & Lid Switch Policy](#1-power-management--lid-switch-policy)
   - [2. Display Server & Automatic Login](#2-display-server--automatic-login)
   - [3. Display Output Configuration (Lid Closed / External Monitor)](#3-display-output-configuration-lid-closed--external-monitor)
   - [4. Kiosk Autostart Script Setup](#4-kiosk-autostart-script-setup)
   - [5. Screen Saver & DPMS Blanking Prevention](#5-screen-saver--dpms-blanking-prevention)
   - [6. Remote Desktop Setup (x11vnc)](#6-remote-desktop-setup-x11vnc)
   - [7. Keyring Password Prompt Removal](#7-keyring-password-prompt-removal)
3. [Connecting Remotely](#connecting-remotely)
   - [Connecting from macOS](#connecting-from-macos)
   - [Connecting from Windows](#connecting-from-windows)
4. [Day-to-Day Operations & Maintenance](#day-to-day-operations--maintenance)
   - [Keyboard Shortcuts (Remote Desktop)](#keyboard-shortcuts-remote-desktop)
   - [Restarting the Kiosk Browser](#restarting-the-kiosk-browser)
   - [Closing the Kiosk Browser and Opening a Terminal](#closing-the-kiosk-browser-and-opening-a-terminal)
   - [Clearing Browser Cache & Ephemeral Incognito Mode](#clearing-browser-cache--ephemeral-incognito-mode)
5. [Troubleshooting](#troubleshooting)
   - [Kiosk Returns to Login Page After a While](#kiosk-returns-to-login-page-after-a-while)

---

## Automated Installation

A complete automation script `setup_kiosk.sh` is provided in this repository.

### Quick Start:
```bash
chmod +x setup_kiosk.sh
sudo ./setup_kiosk.sh
```

Follow the on-screen prompts to configure your target dashboard URL and VNC password.

---

## Manual Step-by-Step Configuration

### 1. Power Management & Lid Switch Policy

To prevent the laptop from suspending, sleeping, or powering down external displays when the lid is closed:

1. Edit `/etc/systemd/logind.conf`:
   ```bash
   sudo nano /etc/systemd/logind.conf
   ```
2. Set the following parameters (remove `#` if commented out):
   ```ini
   [Login]
   HandleLidSwitch=ignore
   HandleLidSwitchExternalPower=ignore
   HandleLidSwitchDocked=ignore
   LidSwitchIgnoreInhibited=no
   ```
3. Restart the systemd login service:
   ```bash
   sudo systemctl restart systemd-logind
   ```

---

### 2. Display Server & Automatic Login

For `x11vnc` to mirror the physical display directly, ensure your desktop manager uses an **X11 session** (rather than pure Wayland) and enables user auto-login.

#### For GDM3 (Default Ubuntu Desktop):
Edit `/etc/gdm3/custom.conf`:
```ini
[daemon]
WaylandEnable=false
AutomaticLoginEnable=true
AutomaticLogin=your_username
```

#### For LightDM (Xfce / MATE / Cinnamon):
Edit `/etc/lightdm/lightdm.conf`:
```ini
[Seat:*]
autologin-user=your_username
autologin-user-timeout=0
```

---

### 3. Display Output Configuration (Lid Closed / External Monitor)

When running with the laptop lid closed, force the primary video output to the external display (e.g. HDMI-1) and disable the internal laptop panel (e.g. eDP-1):

1. Check your connected displays:
   ```bash
   xrandr --query
   ```
2. Turn off the internal panel and assign external as primary:
   ```bash
   xrandr --output eDP-1 --off --output HDMI-1 --auto --primary
   ```

---

### 4. Kiosk Autostart Script Setup

1. Install required packages:
   ```bash
   sudo apt update
   sudo apt install -y chromium-browser unclutter x11-xserver-utils xdotool
   ```
   *(Note: On Ubuntu, `chromium` installs via snap or deb; Google Chrome (`google-chrome-stable`) can also be used).*

2. Create the kiosk launch script:
   ```bash
   mkdir -p ~/.config/autostart-scripts
   nano ~/.config/autostart-scripts/kiosk.sh
   ```

3. Paste the following script:
   ```bash
   #!/bin/bash

   # Wait for desktop session and display manager to initialize
   sleep 3

   # Disable screen blanking, screen savers, and DPMS power saving
   xset s off
   xset s 0 0
   xset -dpms

   # Hide the mouse cursor after 2 seconds of inactivity
   unclutter -idle 2 -root &

   # Kill any residual screensavers
   killall xfce4-screensaver cinnamon-screensaver mate-screensaver 2>/dev/null

   # Reset dirty session crashes to prevent recovery dialog bubbles
   sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' ~/.config/chromium/Default/Preferences 2>/dev/null
   sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/' ~/.config/chromium/Default/Preferences 2>/dev/null

   # Target Webpage URL
   TARGET_URL="http://localhost:5000"

   # Restart loop: relaunch browser automatically if it exits or crashes
   while true; do
     chromium-browser \
       --kiosk \
       --noerrdialogs \
       --disable-infobars \
       --disable-session-crashed-bubble \
       --check-for-update-interval=31536000 \
       --incognito \
       "$TARGET_URL"
     sleep 2
   done
   ```

4. Make the script executable:
   ```bash
   chmod +x ~/.config/autostart-scripts/kiosk.sh
   ```

5. Register as an autostart desktop entry:
   ```bash
   mkdir -p ~/.config/autostart
   nano ~/.config/autostart/kiosk.desktop
   ```
   Add:
   ```ini
   [Desktop Entry]
   Type=Application
   Exec=/home/your_username/.config/autostart-scripts/kiosk.sh
   Hidden=false
   NoDisplay=false
   X-GNOME-Autostart-enabled=true
   Name=Web Kiosk Display
   Comment=Full Screen Web Kiosk
   ```

---

### 5. Screen Saver & DPMS Blanking Prevention

To ensure the display never sleeps, blanks, or defaults to a floating OS logo:

```bash
# GNOME Settings
gsettings set org.gnome.desktop.screensaver lock-enabled false
gsettings set org.gnome.desktop.screensaver idle-activation-enabled false
gsettings set org.gnome.desktop.session idle-delay 0
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
gsettings set org.gnome.settings-daemon.plugins.power idle-dim false

# Xfce Settings (if using Xfce desktop)
xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-ac --create -t int -s 0 2>/dev/null
xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-ac --create -t int -s 0 2>/dev/null
xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/off-on-ac --create -t int -s 0 2>/dev/null
xfconf-query -c xfce4-screensaver -p /saver/enabled --create -t bool -s false 2>/dev/null
xfconf-query -c xfce4-screensaver -p /lock/enabled --create -t bool -s false 2>/dev/null
```

---

### 6. Remote Desktop Setup (x11vnc)

`x11vnc` allows you to view and interact with the physical display (:0) directly.

1. Install `x11vnc`:
   ```bash
   sudo apt install -y x11vnc
   ```

2. Store the VNC password:
   ```bash
   sudo x11vnc -storepasswd /etc/x11vnc.pass
   sudo chmod 644 /etc/x11vnc.pass
   ```

3. Create the systemd service unit:
   ```bash
   sudo nano /etc/systemd/system/x11vnc.service
   ```
   Add:
   ```ini
   [Unit]
   Description=x11vnc Remote Desktop Server
   After=multi-user.target network.target

   [Service]
   Type=simple
   ExecStart=/usr/bin/x11vnc -forever -display :0 -auth guess -rfbauth /etc/x11vnc.pass -rfbport 5900 -shared
   Restart=on-failure
   RestartSec=5

   [Install]
   WantedBy=multi-user.target
   ```

4. Enable and start the service:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now x11vnc
   ```

---

### 7. Keyring Password Prompt Removal

Auto-login bypasses entering a user password, leaving the default GNOME Keyring locked. To prevent the *"The login keyring did not get unlocked"* popup:

```bash
# Clear existing password-protected keyrings
rm -rf ~/.local/share/keyrings/*
```
*On subsequent reboot, when prompted to "Choose password for new keyring", leave both fields completely **blank** and confirm.*

---

## Connecting Remotely

### Connecting from macOS
1. Press `Cmd + Space` and launch **Screen Sharing**.
2. Enter:
   ```text
   vnc://<LAPTOP_IP>:5900
   ```
3. Enter your configured VNC password.

### Connecting from Windows
1. Download and run **RealVNC Viewer** or **TightVNC**.
2. Enter:
   ```text
   <LAPTOP_IP>:5900
   ```
3. Enter your configured VNC password.

---

## Day-to-Day Operations & Maintenance

### Keyboard Shortcuts (Remote Desktop)

| Action | Mac Shortcut | Windows Shortcut |
| :--- | :--- | :--- |
| **Open Terminal** | `Control + Option + T` | `Ctrl + Alt + T` |
| **Open System Menu** | `Command (⌘)` | `Windows Key` |
| **Close Kiosk Window** | `Option + F4` | `Alt + F4` |
| **Hard Refresh Page** | `Control + Shift + R` | `Ctrl + F5` |

### Closing the Kiosk Browser and Opening a Terminal
If you need to stop the kiosk before restarting it:
```bash
killall chromium-browser chromium google-chrome 2>/dev/null
```
Then open a terminal with the shortcut above, or launch Terminal from the desktop menu.

### Restarting the Kiosk Browser
To restart the kiosk window over SSH or terminal:
```bash
bash ~/.config/autostart-scripts/kiosk.sh &
```

### Full Restart in One Go
```bash
killall chromium-browser chromium google-chrome 2>/dev/null && bash ~/.config/autostart-scripts/kiosk.sh &
```

### Clearing Browser Cache & Ephemeral Incognito Mode
If assets or UI elements get stuck:
```bash
# Delete cache directories
rm -rf ~/.cache/chromium/Default/Cache/*
rm -rf ~/.cache/chromium/Default/Code\ Cache/*
rm -rf ~/.cache/chromium/Default/GPUCache/*

# Restart kiosk
killall chromium-browser 2>/dev/null && bash ~/.config/autostart-scripts/kiosk.sh &
```

---

## Troubleshooting

### Kiosk Returns to Login Page After a While

**Symptom:** After running for a period of time, the display returns to the Ubuntu login screen instead of showing the dashboard.

**Likely causes:**

| Cause | Description |
| :--- | :--- |
| Session / screen lock | The desktop lock screen activates and covers the kiosk view |
| Idle timeout / auto-logout | GNOME or the display manager ends the session due to inactivity |
| System sleep or suspend | The machine sleeps and the session is reset on wake |
| Chromium exit or crash | Chromium exits and, with no restart loop, the desktop is exposed |

**Recommended fix:**

1. **Apply the resilience patch** on an existing install (no clean reinstall needed):
   ```bash
   chmod +x step2.sh
   sudo ./step2.sh
   ```
   This script will:
   - Disable GNOME and Xfce lock/sleep settings more completely.
   - Rewrite `~/.config/autostart-scripts/kiosk.sh` to use a browser restart loop so Chromium relaunches automatically if it exits or crashes.

2. **Manual steps** (if you prefer to apply the changes yourself):

   Disable GNOME power/lock settings:
   ```bash
   gsettings set org.gnome.desktop.screensaver lock-enabled false
   gsettings set org.gnome.desktop.screensaver idle-activation-enabled false
   gsettings set org.gnome.desktop.session idle-delay 0
   gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
   gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
   gsettings set org.gnome.settings-daemon.plugins.power idle-dim false
   ```

   Add a browser restart loop to `~/.config/autostart-scripts/kiosk.sh` (replace the final `chromium-browser ...` line):
   ```bash
   while true; do
     chromium-browser \
       --kiosk \
       --incognito \
       --noerrdialogs \
       --disable-infobars \
       --disable-session-crashed-bubble \
       --check-for-update-interval=31536000 \
       "$TARGET_URL"
     sleep 2
   done
   ```

3. **Reboot** (or restart the kiosk manually) to apply all changes:
   ```bash
   sudo reboot
   ```

**Checking the logs** if the problem persists:
```bash
# Display manager / session logs
journalctl -b -u gdm3
journalctl -b -u lightdm

# General system log
journalctl -b --no-pager | grep -i "session\|sleep\|lock\|suspend" | tail -50
```
