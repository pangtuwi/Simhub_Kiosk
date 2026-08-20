#!/usr/bin/env bash
# ==============================================================================
# step2.sh — Kiosk Resilience Patch (run on an existing install)
# Applies kiosk stability improvements without requiring a clean reinstall.
# Safe to run multiple times (idempotent where possible).
# Does NOT remove user data or reset the kiosk URL.
# ==============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}  Kiosk Session Resilience Patch (step2.sh)           ${NC}"
echo -e "${BLUE}======================================================${NC}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Please run with sudo: sudo ./step2.sh${NC}"
  exit 1
fi

TARGET_USER="${SUDO_USER:-$USER}"
USER_HOME=$(eval echo "~$TARGET_USER")
AUTOSTART_DIR="${USER_HOME}/.config/autostart-scripts"
KIOSK_SCRIPT="${AUTOSTART_DIR}/kiosk.sh"

if [ "$TARGET_USER" = "root" ]; then
  echo -e "${YELLOW}[WARNING] Target user is root. Recommended to run under a standard user with sudo.${NC}"
fi

echo -e "${GREEN}[*] Patching kiosk for user: ${TARGET_USER} (${USER_HOME})${NC}"

# 1. Detect existing kiosk URL and browser binary from kiosk.sh
KIOSK_URL="http://localhost:5000"
BROWSER_BIN="chromium-browser"

if [ -f "$KIOSK_SCRIPT" ]; then
  # Try to read the URL from the existing script
  DETECTED_URL=$(grep -oP '(?<=TARGET_URL=")[^"]+' "$KIOSK_SCRIPT" 2>/dev/null || true)
  if [ -n "$DETECTED_URL" ]; then
    KIOSK_URL="$DETECTED_URL"
    echo -e "${GREEN}[*] Detected existing kiosk URL: ${KIOSK_URL}${NC}"
  fi

  # Try to detect the browser binary
  for bin in chromium-browser chromium google-chrome; do
    if grep -q "$bin" "$KIOSK_SCRIPT" 2>/dev/null; then
      BROWSER_BIN="$bin"
      break
    fi
  done
fi

# Fall back to whichever browser is actually installed
if ! command -v "$BROWSER_BIN" &> /dev/null; then
  if command -v chromium-browser &> /dev/null; then
    BROWSER_BIN="chromium-browser"
  elif command -v chromium &> /dev/null; then
    BROWSER_BIN="chromium"
  elif command -v google-chrome &> /dev/null; then
    BROWSER_BIN="google-chrome"
  fi
fi

echo -e "${GREEN}[*] Browser binary: ${BROWSER_BIN}${NC}"

# 2. Strengthen GNOME power and lock settings
echo -e "${BLUE}[1/3] Applying GNOME / Xfce power management settings...${NC}"
if command -v gsettings &> /dev/null; then
  sudo -u "$TARGET_USER" dbus-launch gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null || true
  sudo -u "$TARGET_USER" dbus-launch gsettings set org.gnome.desktop.screensaver idle-activation-enabled false 2>/dev/null || true
  sudo -u "$TARGET_USER" dbus-launch gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null || true
  sudo -u "$TARGET_USER" dbus-launch gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' 2>/dev/null || true
  sudo -u "$TARGET_USER" dbus-launch gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' 2>/dev/null || true
  sudo -u "$TARGET_USER" dbus-launch gsettings set org.gnome.settings-daemon.plugins.power idle-dim false 2>/dev/null || true
  echo -e "${GREEN}  [OK] GNOME settings applied.${NC}"
fi

if command -v xfconf-query &> /dev/null; then
  sudo -u "$TARGET_USER" xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-ac --create -t int -s 0 2>/dev/null || true
  sudo -u "$TARGET_USER" xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-ac --create -t int -s 0 2>/dev/null || true
  sudo -u "$TARGET_USER" xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/off-on-ac --create -t int -s 0 2>/dev/null || true
  sudo -u "$TARGET_USER" xfconf-query -c xfce4-screensaver -p /saver/enabled --create -t bool -s false 2>/dev/null || true
  sudo -u "$TARGET_USER" xfconf-query -c xfce4-screensaver -p /lock/enabled --create -t bool -s false 2>/dev/null || true
  echo -e "${GREEN}  [OK] Xfce settings applied.${NC}"
fi

# 3. Rewrite kiosk.sh to use a browser restart loop
echo -e "${BLUE}[2/3] Updating kiosk launch script with browser restart loop...${NC}"
mkdir -p "$AUTOSTART_DIR"

cat > "$KIOSK_SCRIPT" << KIOSK_EOF
#!/bin/bash

# Allow desktop session to initialize
sleep 3

# Disable X11 screensaver & power management
xset s off
xset s 0 0
xset -dpms

# Hide mouse cursor when inactive
unclutter -idle 2 -root &

# Kill any residual screensavers
killall xfce4-screensaver cinnamon-screensaver mate-screensaver 2>/dev/null

# Clean crash states
sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' ~/.config/chromium/Default/Preferences 2>/dev/null
sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/' ~/.config/chromium/Default/Preferences 2>/dev/null

TARGET_URL="${KIOSK_URL}"

# Restart loop: relaunch browser automatically if it exits or crashes
while true; do
  ${BROWSER_BIN} \\
    --kiosk \\
    --incognito \\
    --noerrdialogs \\
    --disable-infobars \\
    --disable-session-crashed-bubble \\
    --check-for-update-interval=31536000 \\
    "\$TARGET_URL"
  sleep 2
done
KIOSK_EOF

chmod +x "$KIOSK_SCRIPT"
chown "$TARGET_USER:$TARGET_USER" "$KIOSK_SCRIPT"
echo -e "${GREEN}  [OK] ${KIOSK_SCRIPT} updated.${NC}"

# 4. Kill any running kiosk browser so the updated script takes effect on next autostart
echo -e "${BLUE}[3/3] Stopping any running kiosk browser instances...${NC}"
killall "$BROWSER_BIN" 2>/dev/null || true
echo -e "${GREEN}  [OK] Browser stopped (will restart via autostart on next login, or run manually below).${NC}"

echo -e ""
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}  Resilience patch applied successfully!               ${NC}"
echo -e "${GREEN}======================================================${NC}"
echo -e ""
echo -e "${YELLOW}To start the kiosk immediately without rebooting:${NC}"
echo -e "  ${BLUE}bash ${KIOSK_SCRIPT} &${NC}"
echo -e ""
echo -e "${YELLOW}Or reboot to apply all settings cleanly:${NC}"
echo -e "  ${BLUE}sudo reboot${NC}"
