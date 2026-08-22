# Ubuntu 26.04 LTS Kiosk & Remote Display Setup Guide

This guide details the complete configuration process for transforming a laptop running **Ubuntu 26.04 LTS** (or compatible Debian/Ubuntu derivatives) into an unattended, always-on full-screen Web Dashboard Kiosk with remote viewing and control capabilities.

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
   - [6b. RDP Fallback for Wayland-Only Systems](#6b-rdp-fallback-for-wayland-only-systems)
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
   - [Cannot Connect from Windows (or macOS) via VNC](#cannot-connect-from-windows-or-macos-via-vnc)
   - [Session Still Reports Wayland After Disabling It](#session-still-reports-wayland-after-disabling-it)

---

## Automated Installation

A complete automation script `setup_kiosk.sh` is provided in this repository.

**`setup_kiosk.sh` is a complete, self-contained installer.** On a clean/fresh Ubuntu install it is the only script you need — it already includes the browser restart loop, GNOME/Xfce power hardening, and the x11vnc remote-desktop resilience fixes (Xauthority-wait wrapper, firewall rule) described in [Troubleshooting](#troubleshooting) below. Do **not** also run `step2.sh` afterwards; there is nothing left for it to add on a system `setup_kiosk.sh` just configured. `step2.sh` exists solely to bring an *existing* install (set up before these fixes were added, or one you're unsure is current) up to date in place, without a clean reinstall — see [Applying the Resilience Patch](#kiosk-returns-to-login-page-after-a-while) below.

If your system turns out to have **no Xorg session available at all** (some Ubuntu builds don't ship one — `x11vnc` cannot work there regardless of configuration), use `setup_rdp.sh` instead/in addition — see [6b. RDP Fallback for Wayland-Only Systems](#6b-rdp-fallback-for-wayland-only-systems).

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

For `x11vnc` to mirror the physical display directly, the desktop session **must use X11** (not Wayland). The installer (`setup_kiosk.sh`) automatically sets `WaylandEnable=false` in `/etc/gdm3/custom.conf`. A reboot is required for this to take effect. After rebooting, confirm the active session type with:
```bash
echo $XDG_SESSION_TYPE
```
It should report `x11`. If it reports `wayland`, VNC will not work reliably.

> **`WaylandEnable=false` alone is not always enough for an autologin account.** That setting only controls the session offered on GDM's *greeter* screen — with `AutomaticLoginEnable=true`, GDM skips the greeter entirely and can launch whatever session is recorded for that user in `/var/lib/AccountsService/users/<username>` instead, ignoring `custom.conf`. If `echo $XDG_SESSION_TYPE` still reports `wayland` after setting `WaylandEnable=false` and rebooting, this is almost always why. Both `setup_kiosk.sh` and `step2.sh` now also pin the autologin user's saved session to an Xorg one directly in that AccountsService file (printed at the end of each script's run) — see [Session Still Reports Wayland After Disabling It](#session-still-reports-wayland-after-disabling-it) if you're hitting this on an install from before that fix.

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

> **Requirement:** `x11vnc` works with **X11 sessions only**. The installer automatically disables Wayland in GDM and creates the systemd service. After running the installer, reboot to ensure X11 is active before connecting.

`x11vnc` allows you to view and interact with the physical display (:0) directly. The installer (`setup_kiosk.sh`) handles all steps below automatically.

1. Install `x11vnc`:
   ```bash
   sudo apt install -y x11vnc
   ```

2. Store the VNC password:
   ```bash
   sudo x11vnc -storepasswd /etc/x11vnc.pass
   sudo chmod 644 /etc/x11vnc.pass
   ```

3. The installer creates `/etc/systemd/system/x11vnc.service` automatically, pointed at a small wrapper (`/usr/local/bin/x11vnc-wait.sh`) rather than calling `x11vnc` directly:
   ```ini
   [Unit]
   Description=x11vnc Remote Desktop Server
   After=display-manager.service network.target graphical.target
   Wants=display-manager.service

   [Service]
   Type=simple
   ExecStart=/usr/local/bin/x11vnc-wait.sh
   Restart=on-failure
   RestartSec=5

   [Install]
   WantedBy=graphical.target
   ```
   The wrapper exists because `x11vnc -auth guess` is unreliable against GDM3 autologin: the Xauthority file's location can vary by boot/session, and if x11vnc starts before the autologin'd X session actually exists, it guesses wrong (or finds nothing) and silently refuses or drops every incoming connection — while `systemctl status` still reports it as `active (running)`. The wrapper instead polls for a real Xauthority file and a live display before launching x11vnc with an explicit `-auth` path. See [Cannot Connect from Windows (or macOS) via VNC](#cannot-connect-from-windows-or-macos-via-vnc) if you're hitting this.

4. Enable and start the service:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now x11vnc
   ```

5. **Reboot** after installation so the system starts an X11 session. Verify:
   ```bash
   echo $XDG_SESSION_TYPE   # should print: x11
   systemctl status x11vnc
   sudo ss -tlnp | grep 5900
   ```

---

### 6b. RDP Fallback for Wayland-Only Systems

`x11vnc` fundamentally requires an X11 session — no amount of `WaylandEnable=false` or AccountsService configuration can make it work if the machine has no Xorg desktop session at all. This is a real, confirmed situation on some Ubuntu builds: `/usr/share/xsessions/` can be entirely absent, with only `/usr/share/wayland-sessions/` present, and no Xorg session package available in the repos to install one (`apt install gnome-session-xsession` failing with "Unable to locate package" is the tell).

If `step2.sh`/`setup_kiosk.sh` report they couldn't find or install an Xorg session, stop trying to force X11 and use `setup_rdp.sh` instead:
```bash
chmod +x setup_rdp.sh
sudo ./setup_rdp.sh
```
This configures **GNOME's built-in Remote Desktop support** (`gnome-remote-desktop` / `grdctl`), which works natively over Wayland via PipeWire screen capture — it needs no Xorg session, and is the modern, actually-Wayland-compatible replacement for x11vnc-style physical-display mirroring. Specifically, it:

1. Installs `gnome-remote-desktop`.
2. Disables GNOME Remote Desktop's **system/headless mode** if a previous run enabled it (`grdctl --system`, `gnome-remote-desktop.service`) — see the note below on why that mode is the wrong one for a kiosk.
3. Confirms the kiosk user already has a live graphical session (true once an autologin'd kiosk has booted).
4. Generates a self-signed TLS certificate under `~<kiosk-user>/.local/share/gnome-remote-desktop-certs/` (reused on subsequent runs), owned by the kiosk user.
5. Configures RDP credentials and enables it in **per-session** mode via `grdctl rdp ...` run against that user's own live session — the same mechanism as GNOME Settings → Sharing → Remote Desktop, mirroring the actual visible kiosk screen.
6. Disables **view-only mode** (`grdctl rdp disable-view-only`) — see the note below on why this is needed.
7. Installs an **autostart entry** (`~<kiosk-user>/.config/autostart-scripts/rdp-reassert.sh`) that re-applies the entire RDP config on every login — see the note below on why this is needed.
8. Opens `3389/tcp` in `ufw` if active.

**Why per-session mode, not `--system`/headless:** GNOME Remote Desktop's system/headless mode doesn't mirror an already-running session — it spins up a *separate, new* session per RDP login, the way a VDI/remote-login setup would want. Confirmed on real hardware: it refuses to do this when the target user already has an active session (the autologin'd kiosk session itself), and login fails with **"there is already a local session running"**. Per-session mode shares the actual live session instead, which is what a kiosk needs — you see and can interact with the same screen physically showing on the machine.

**Why view-only is explicitly disabled:** GNOME Remote Desktop's default for a newly-configured RDP session is view-only — confirmed on real hardware: connecting from both Windows and macOS clients worked (screen visible, login successful), but clicking or typing did nothing at all, with no error or indication why. `grdctl rdp disable-view-only` is what actually enables mouse/keyboard control, separate from `grdctl rdp enable` (which only turns RDP itself on). `setup_rdp.sh` checks for this explicitly in its output ("View-only is disabled — clicks and keyboard input will work").

**Why an autostart entry re-applies the config on every login:** confirmed on real hardware after a reboot — `grdctl status` showed the TLS certificate and `View-only: no` had survived, but `Username`/`Password` came back `(empty)`, and RDP clients failed to connect with a generic network-looking error (Windows' `0x204`). This kiosk's own setup deliberately wipes `~/.local/share/keyrings/*` to avoid an autologin keyring-unlock password prompt (see [7. Keyring Password Prompt Removal](#7-keyring-password-prompt-removal) below), and GNOME Remote Desktop stores RDP credentials via that same keyring/secret-service — so a keyring left unlockable-but-empty for autologin's sake also means the RDP password specifically doesn't survive past the session it was set in. Rather than depend on the keyring working, `setup_rdp.sh` writes the credentials to a `chmod 600` file under the kiosk user's own home and installs an autostart script that re-supplies the full config (cert, credentials, enable, disable-view-only) a few seconds into every login — idempotent and safe to run every time.

**The keyring-unlock prompt can still come back even after this.** Confirmed on real hardware: wiping `~/.local/share/keyrings/*` and leaving the recreated keyring's password blank fixed it for one reboot, then the exact same "Authentication required, the login keyring did not get unlocked" prompt returned on a *later* reboot. Root cause: GNOME Keyring's normal auto-unlock is triggered by the password typed at login (`pam_gnome_keyring.so`) — autologin never types one, so that mechanism never reliably fires, blank keyring password or not; the one successful reboot depended on unlock-at-creation timing rather than anything that actually persists. `rdp-reassert.sh` now also runs `echo -n "" | gnome-keyring-daemon --unlock` before touching `grdctl`, to unlock the (blank-password) keyring explicitly rather than hope PAM did it. This is a standard technique for unlocking GNOME Keyring on headless/autologin systems, but hasn't yet been confirmed to fully eliminate the prompt across multiple reboots on this specific hardware — if it recurs even with this in place, that points at something deeper in how this system's keyring auto-unlock is configured, worth a fresh diagnosis rather than another guess.

Flags: `--user <name>` for the kiosk login user (detection only), `--rdp-user <name>` / `--rdp-password <pass>` to set the RDP login credentials non-interactively, `-y` to skip confirmation. Run `sudo ./setup_rdp.sh --help` for details. It's safe to run alongside an existing x11vnc setup — the two don't conflict, and you can use whichever one actually works on your hardware.

**Connecting is different from VNC**: use Windows' built-in **Remote Desktop Connection** app (`mstsc`), or **Microsoft Remote Desktop** on macOS — not a VNC client, and port `3389` instead of `5900`. Enter the kiosk's IP address, then the username/password `setup_rdp.sh` configured. Expect a certificate-trust warning on first connect (self-signed cert) — accept it to continue; this is expected and fine on a private LAN kiosk.

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

   It's safe to run from any directory — every path it touches is resolved from the kiosk's login user's home directory, not from your current working directory. It detects that user from `$SUDO_USER`; if you ran it from an already-root shell (`sudo -s`/`sudo -i` first) that's empty and it will warn you and fall back to `root`, which is wrong for almost every kiosk setup. Pass `--user <name>` to set it explicitly, `--url <url>` to override the detected kiosk URL, or `-y` to skip the confirmation summary it prints before making changes (useful for unattended re-runs). Run `sudo ./step2.sh --help` for the full flag list.

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

---

### Cannot Connect from Windows (or macOS) via VNC

**Symptom:** `systemctl status x11vnc` reports `active (running)` and `sudo ss -tlnp | grep 5900` shows the port listening, but a VNC client on Windows (RealVNC Viewer, TightVNC) times out, gets "connection refused", or fails authentication even with the correct password.

**Likely causes, in order of likelihood:**

| Cause | Description |
| :--- | :--- |
| Stale/guessed Xauthority | `x11vnc -auth guess` picked the wrong (or no) Xauthority cookie for the current autologin session, so x11vnc is running but can't actually attach to display `:0` |
| Boot-time race | x11vnc's systemd unit started before the autologin'd X session existed, so the guess above happened too early |
| Firewall | `ufw` (or another firewall) is blocking port 5900/tcp |
| Wrong IP | The IP address you're connecting to isn't the laptop's actual LAN-reachable address (e.g. it picked up a VPN/docker interface, or the DHCP lease changed since you last checked) |

A service that is "active (running)" is **not** proof the connection will work — a wrong Xauthority guess still leaves the process alive and the port bound, it just can't service RFB connections correctly.

**Recommended fix:**

1. **Apply the resilience patch**, which replaces the plain `x11vnc -auth guess` unit with a wrapper that waits for the real session and resolves its actual Xauthority path, and opens the firewall if `ufw` is active:
   ```bash
   chmod +x step2.sh
   sudo ./step2.sh
   ```
   No reinstall of Ubuntu is needed for this — it's a systemd unit and firewall change, not an OS-level problem.

2. **Confirm the fix took effect:**
   ```bash
   systemctl status x11vnc
   sudo ss -tlnp | grep 5900
   sudo ufw status            # confirm 5900/tcp is allowed if ufw is active
   hostname -I                # confirm which IP you should actually be connecting to
   ```

3. **If it still fails**, check whether the wrapper is stuck waiting for the session (it retries for up to two minutes before giving up):
   ```bash
   journalctl -u x11vnc -b --no-pager | tail -50
   ```
   A repeated "timed out waiting for X session/Xauthority" means the machine isn't reaching a real X11 autologin session at all — check `echo $XDG_SESSION_TYPE` (should be `x11`, not `wayland`) and confirm GDM autologin is actually configured (`AutomaticLoginEnable=true` / `AutomaticLogin=<user>` in `/etc/gdm3/custom.conf`).

---

### Session Still Reports Wayland After Disabling It

**Symptom:** `WaylandEnable=false` is present in `/etc/gdm3/custom.conf`, you've rebooted, but `echo $XDG_SESSION_TYPE` still prints `wayland` instead of `x11`.

**Cause:** `WaylandEnable=false` only controls which session GDM's *greeter* (login screen) offers. With autologin enabled (`AutomaticLoginEnable=true`), GDM skips the greeter entirely — and for an autologin user, GDM commonly launches whatever session is recorded for that user in `/var/lib/AccountsService/users/<username>` (keys `Session=` / `XSession=`) instead of consulting `custom.conf` at all. If that file is missing, or still says `gnome` (the Wayland default), the autologin session stays Wayland no matter what `custom.conf` says.

**Recommended fix:**

1. **Re-run the installer/patch script** — both `setup_kiosk.sh` and `step2.sh` now also pin the autologin user's saved session to an available Xorg entry in AccountsService, not just `WaylandEnable=false` in `custom.conf`:
   ```bash
   chmod +x step2.sh
   sudo ./step2.sh
   ```
   Its output includes a "Resulting GDM/session configuration" block showing exactly what was written to both files — check that before rebooting.

2. **If it reports "No Xorg session found under /usr/share/xsessions/"**, your system genuinely has no X11 session installed at all — confirmed on real hardware via `ls /usr/share/xsessions/` returning "No such file or directory" while `/usr/share/wayland-sessions/` had the only session present. `WaylandEnable=false` can't select a session that doesn't exist, and no amount of config editing or rebooting fixes that. Both scripts now attempt to install one automatically (`gnome-session-xsession`, falling back to `xserver-xorg`/`xinit`/`ubuntu-session`) before giving up. **If `apt install gnome-session-xsession` (or the other candidates) fails with "Unable to locate package"**, this Ubuntu build doesn't offer an Xorg session at all — confirmed on real hardware. Forcing X11 is a dead end on that machine; stop here and use the RDP fallback instead: [6b. RDP Fallback for Wayland-Only Systems](#6b-rdp-fallback-for-wayland-only-systems). If some other X11-session-providing package genuinely is available under a different name, install it and continue:
   ```bash
   apt-cache search xsession
   apt-cache search "on xorg"
   sudo apt install -y <package found above>
   ls /usr/share/xsessions/          # should now show an *xorg* entry
   ```
   then re-run `step2.sh` and reboot.

3. **Verify manually** if you want to check both files yourself before rebooting:
   ```bash
   grep -E '^(WaylandEnable|AutomaticLogin)' /etc/gdm3/custom.conf
   cat /var/lib/AccountsService/users/<your_username>
   ls /usr/share/xsessions/          # confirm an *xorg*/*x11* entry exists
   ```
   The AccountsService file's `Session=` and `XSession=` values should name the Xorg `.desktop` file (minus the `.desktop` extension) found in the last command, e.g. `ubuntu-xorg`.

4. **Reboot** to apply:
   ```bash
   sudo reboot
   ```
