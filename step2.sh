#!/usr/bin/env bash
# ==============================================================================
# Kiosk Session Resilience Patch (run on an existing install)
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
GDM_CONF="/etc/gdm3/custom.conf"
X11VNC_SERVICE="/etc/systemd/system/x11vnc.service"

if [ "$TARGET_USER" = "root" ]; then
  echo -e "${YELLOW}[WARNING] Target user is root. Recommended to run under a standard user with sudo.${NC}"
fi

echo -e "${GREEN}[*] Patching kiosk for user: ${TARGET_USER} (${USER_HOME})${NC}"

# 1. Detect existing kiosk URL and browser binary from kiosk.sh
KIOSK_URL="http://localhost:5000"
BROWSER_BIN="chromium-browser"

if [ -f "$KIOSK_SCRIPT" ]; then
  DETECTED_URL=$(grep -oP '(?<=TARGET_URL=")[^"]+' "$KIOSK_SCRIPT" 2>/dev/null || true)
  if [ -n "$DETECTED_URL" ]; then
    KIOSK_URL="$DETECTED_URL"
    echo -e "${GREEN}[*] Detected existing kiosk URL: ${KIOSK_URL}${NC}"
  fi

  for bin in chromium-browser chromium google-chrome; do
    if grep -q "$bin" "$KIOSK_SCRIPT" 2>/dev/null; then
      BROWSER_BIN="$bin"
      break
    fi
  done
fi

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

# 2. Force GDM to use X11 instead of Wayland for VNC compatibility
echo -e "${BLUE}[1/4] Disabling Wayland in GDM and preserving autologin...${NC}"
sudo mkdir -p /etc/gdm3
sudo touch "$GDM_CONF"

if grep -q '^\[daemon\]' "$GDM_CONF"; then
  :
else
  printf '\n[daemon]\n' | sudo tee -a "$GDM_CONF" >/dev/null
fi

if grep -q '^#\?WaylandEnable=' "$GDM_CONF"; then
  sudo sed -i 's/^#\?WaylandEnable=.*/WaylandEnable=false/' "$GDM_CONF"
else
  if grep -q '^\[daemon\]' "$GDM_CONF"; then
    if grep -n '^\[daemon\]' "$GDM_CONF" | tail -1 | awk -F: '{print $1}' | xargs -I{} sh -c "sed -n '{}',\$p '$GDM_CONF' | grep -q '^WaylandEnable=false'"; then
      :
    else
      sudo awk 'BEGIN{added=0} {print} /^\[daemon\]$/ && !added {print "WaylandEnable=false"; added=1}' "$GDM_CONF" > "$GDM_CONF.tmp" && sudo mv "$GDM_CONF.tmp" "$GDM_CONF"
    fi
  fi
fi

if ! grep -q '^WaylandEnable=false' "$GDM_CONF"; then
  if grep -q '^\[daemon\]' "$GDM_CONF"; then
    sudo awk 'BEGIN{in_daemon=0; inserted=0} /^\[daemon\]$/ {print; in_daemon=1; next} /^\[/ { if (in_daemon && !inserted) {print "WaylandEnable=false"; inserted=1} in_daemon=0; print; next} {print} END { if (in_daemon && !inserted) print "WaylandEnable=false" }' "$GDM_CONF" > "$GDM_CONF.tmp" && sudo mv "$GDM_CONF.tmp" "$GDM_CONF"
  else
    printf '\n[daemon]\nWaylandEnable=false\n' | sudo tee -a "$GDM_CONF" >/dev/null
  fi
fi

sudo sed -i 's/^#\?AutomaticLoginEnable=.*/AutomaticLoginEnable=true/' "$GDM_CONF" 2>/dev/null || true
if ! grep -q '^AutomaticLoginEnable=true' "$GDM_CONF"; then
  printf 'AutomaticLoginEnable=true\n' | sudo tee -a "$GDM_CONF" >/dev/null
fi
if [ -n "$TARGET_USER" ] && ! grep -q "^AutomaticLogin=${TARGET_USER}$" "$GDM_CONF"; then
  if grep -q '^AutomaticLogin=' "$GDM_CONF"; then
    sudo sed -i "s/^AutomaticLogin=.*/AutomaticLogin=${TARGET_USER}/" "$GDM_CONF"
  else
    printf 'AutomaticLogin=%s\n' "$TARGET_USER" | sudo tee -a "$GDM_CONF" >/dev/null
  fi
fi

echo -e "${GREEN}  [OK] GDM configured for X11 autologin.${NC}"

# 3. Create / update x11vnc service so remote desktop starts automatically
echo -e "${BLUE}[2/4] Installing x11vnc systemd service...${NC}"
cat << 'EOF' | sudo tee "$X11VNC_SERVICE" >/dev/null
[Unit]
Description=x11vnc Remote Desktop Server
After=display-manager.service network.target graphical.target
Wants=display-manager.service

[Service]
Type=simple
ExecStart=/usr/bin/x11vnc -forever -display :0 -auth guess -rfbauth /etc/x11vnc.pass -rfbport 5900 -shared -repeat
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now x11vnc || true
echo -e "${GREEN}  [OK] x11vnc.service installed and enabled.${NC}"

# 4. Strengthen GNOME power and lock settings
echo -e "${BLUE}[3/4] Applying GNOME / Xfce power management settings...${NC}"
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

# 5. Rewrite kiosk.sh to use a browser restart loop
echo -e "${BLUE}[4/4] Updating kiosk launch script with browser restart loop...${NC}"
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
  ${BROWSER_BIN} \
    --kiosk \
    --incognito \
    --noerrdialogs \
    --disable-infobars \
    --disable-session-crashed-bubble \
    --check-for-update-interval=31536000 \
    "$TARGET_URL"
  sleep 2
done
KIOSK_EOF

chmod +x "$KIOSK_SCRIPT"
chown "$TARGET_USER:$TARGET_USER" "$KIOSK_SCRIPT"
echo -e "${GREEN}  [OK] ${KIOSK_SCRIPT} updated.${NC}"

# 6. Kill any running kiosk browser so the updated script takes effect on next autostart
echo -e "${YELLOW}[*] Stopping any running kiosk browser instances...${NC}"
killall "$BROWSER_BIN" 2>/dev/null || true

echo -e ""
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}  Resilience patch applied successfully!               ${NC}"
echo -e "${GREEN}======================================================${NC}"
echo -e ""
echo -e "${YELLOW}Wayland has been disabled in GDM for X11/VNC support.${NC}"
echo -e "${YELLOW}Reboot is required for the session type change to take effect.${NC}"
echo -e "${YELLOW}After reboot, verify with: echo \$XDG_SESSION_TYPE  # should be x11${NC}"
echo -e ""
echo -e "${YELLOW}To start the kiosk immediately without rebooting:${NC}"
echo -e "  ${BLUE}bash ${KIOSK_SCRIPT} &${NC}"
echo -e ""
echo -e "${YELLOW}Or reboot to apply all settings cleanly:${NC}"
echo -e "  ${BLUE}sudo reboot${NC}
