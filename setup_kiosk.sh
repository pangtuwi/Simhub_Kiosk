#!/usr/bin/env bash
# ==============================================================================
# Post-Install Kiosk & Remote Desktop Setup Script
# Target: Ubuntu 26.04 LTS / Debian-based distributions
# ==============================================================================

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}  Ubuntu 26.04 LTS Kiosk & Remote Desktop Installer   ${NC}"
echo -e "${BLUE}======================================================${NC}"

# Check for root / sudo
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Please run this script with sudo: sudo ./setup_kiosk.sh${NC}"
  exit 1
fi

TARGET_USER="${SUDO_USER:-$USER}"
USER_HOME=$(eval echo "~$TARGET_USER")

if [ "$TARGET_USER" = "root" ]; then
  echo -e "${YELLOW}[WARNING] Target user is root. It is recommended to run under a standard user with sudo.${NC}"
fi

echo -e "${GREEN}[*] Configuring setup for user: ${TARGET_USER} (${USER_HOME})${NC}"

# 1. Prompt for Configuration Options
read -p "Enter Target Kiosk URL [http://localhost:5000]: " KIOSK_URL
KIOSK_URL=${KIOSK_URL:-http://localhost:5000}

echo -e "${GREEN}[*] Target URL set to: ${KIOSK_URL}${NC}"

# 2. Update and Install Core Dependencies
echo -e "${BLUE}[1/7] Updating package index and installing dependencies...${NC}"
apt update
apt install -y   unclutter   x11-xserver-utils   xdotool   x11vnc   curl   wget   sed

# Install Chromium (handle snap / deb fallback)
if ! command -v chromium &> /dev/null && ! command -v chromium-browser &> /dev/null; then
  echo -e "${GREEN}[*] Installing Chromium Browser...${NC}"
  apt install -y chromium-browser || apt install -y chromium || true
fi

# Detect browser binary
BROWSER_BIN="chromium"
if command -v chromium-browser &> /dev/null; then
  BROWSER_BIN="chromium-browser"
elif command -v google-chrome &> /dev/null; then
  BROWSER_BIN="google-chrome"
fi

# 3. Configure Lid Switch (Never sleep with lid closed)
echo -e "${BLUE}[2/7] Configuring systemd power management for lid-closed operation...${NC}"
LOGIND_CONF="/etc/systemd/logind.conf"
sed -i 's/^#\?HandleLidSwitch=.*/HandleLidSwitch=ignore/' "$LOGIND_CONF"
sed -i 's/^#\?HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/' "$LOGIND_CONF"
sed -i 's/^#\?HandleLidSwitchDocked=.*/HandleLidSwitchDocked=ignore/' "$LOGIND_CONF"

systemctl restart systemd-logind || true

# 4. Disable Display Power Management & Screensavers
echo -e "${BLUE}[3/7] Disabling screensavers and sleep timers...${NC}"
# GNOME Settings
if command -v gsettings &> /dev/null; then
  sudo -u "$TARGET_USER" dbus-launch gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null || true
  sudo -u "$TARGET_USER" dbus-launch gsettings set org.gnome.desktop.screensaver idle-activation-enabled false 2>/dev/null || true
  sudo -u "$TARGET_USER" dbus-launch gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null || true
  sudo -u "$TARGET_USER" dbus-launch gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' 2>/dev/null || true
  sudo -u "$TARGET_USER" dbus-launch gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' 2>/dev/null || true
  sudo -u "$TARGET_USER" dbus-launch gsettings set org.gnome.settings-daemon.plugins.power idle-dim false 2>/dev/null || true
fi

# Xfce Settings (if installed)
if command -v xfconf-query &> /dev/null; then
  sudo -u "$TARGET_USER" xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-ac --create -t int -s 0 2>/dev/null || true
  sudo -u "$TARGET_USER" xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-ac --create -t int -s 0 2>/dev/null || true
  sudo -u "$TARGET_USER" xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/off-on-ac --create -t int -s 0 2>/dev/null || true
  sudo -u "$TARGET_USER" xfconf-query -c xfce4-screensaver -p /saver/enabled --create -t bool -s false 2>/dev/null || true
  sudo -u "$TARGET_USER" xfconf-query -c xfce4-screensaver -p /lock/enabled --create -t bool -s false 2>/dev/null || true
fi

# 5. Create Kiosk Autostart Script
echo -e "${BLUE}[4/7] Generating Kiosk Launch Script...${NC}"
AUTOSTART_DIR="${USER_HOME}/.config/autostart-scripts"
mkdir -p "$AUTOSTART_DIR"

cat << 'EOF' > "${AUTOSTART_DIR}/kiosk.sh"
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

EOF

# Append configured browser command wrapped in a restart loop
cat << EOF >> "${AUTOSTART_DIR}/kiosk.sh"
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
EOF

chmod +x "${AUTOSTART_DIR}/kiosk.sh"
chown -R "$TARGET_USER:$TARGET_USER" "${USER_HOME}/.config"

# 6. Create Autostart Desktop Entry
echo -e "${BLUE}[5/7] Registering Autostart Desktop Entry...${NC}"
AUTOSTART_DESKTOP_DIR="${USER_HOME}/.config/autostart"
mkdir -p "$AUTOSTART_DESKTOP_DIR"

cat << EOF > "${AUTOSTART_DESKTOP_DIR}/kiosk.desktop"
[Desktop Entry]
Type=Application
Exec=${AUTOSTART_DIR}/kiosk.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=Kiosk Display
Comment=Always-on Web Kiosk
EOF

chown -R "$TARGET_USER:$TARGET_USER" "$AUTOSTART_DESKTOP_DIR"

# 7. Configure Remote Desktop (x11vnc)
echo -e "${BLUE}[6/7] Configuring x11vnc Server...${NC}"
echo -e "${YELLOW}Please enter the password you want to use for Remote Desktop (VNC) connections:${NC}"
x11vnc -storepasswd /etc/x11vnc.pass
chmod 644 /etc/x11vnc.pass

cat << 'EOF' > /etc/systemd/system/x11vnc.service
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
EOF

systemctl daemon-reload
systemctl enable --now x11vnc

# 8. Clean Keyring Prompts
echo -e "${BLUE}[7/7] Resetting Keyrings for Unattended Auto-login...${NC}"
rm -rf "${USER_HOME}/.local/share/keyrings/"* || true

IP_ADDR=$(hostname -I | awk '{print $1}')

echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}             INSTALLATION COMPLETE!                   ${NC}"
echo -e "${GREEN}======================================================${NC}"
echo -e "Kiosk Target URL:  ${BLUE}${KIOSK_URL}${NC}"
echo -e "Remote VNC Access: ${BLUE}vnc://${IP_ADDR}:5900${NC}"
echo -e ""
echo -e "${YELLOW}Notes:${NC}"
echo -e "1. Ensure Automatic Login is enabled in your Desktop Display Manager settings."
echo -e "2. When prompted on the first reboot to set a keyring password, leave it blank."
echo -e "3. Reboot your machine to start the kiosk display:"
echo -e "   ${BLUE}sudo reboot${NC}"