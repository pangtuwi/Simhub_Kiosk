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
apt install -y   unclutter   x11-xserver-utils   x11-utils   xdotool   x11vnc   curl   wget   sed

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

# 7. Force X11 (disable Wayland) for VNC compatibility
echo -e "${BLUE}[6/7] Forcing X11 session (disabling Wayland) and configuring x11vnc Server...${NC}"
echo -e "${YELLOW}[INFO] x11vnc requires an X11 session. Wayland will be disabled in GDM.${NC}"

GDM_CONF="/etc/gdm3/custom.conf"
if [ -f "$GDM_CONF" ]; then
  # If WaylandEnable line exists (commented or not), update it
  if grep -q '^\s*#\?\s*WaylandEnable=' "$GDM_CONF"; then
    sed -i 's/^\s*#\?\s*WaylandEnable=.*/WaylandEnable=false/' "$GDM_CONF"
  # If [daemon] section exists but no WaylandEnable line, insert after [daemon]
  elif grep -q '^\[daemon\]' "$GDM_CONF"; then
    sed -i '/^\[daemon\]/a WaylandEnable=false' "$GDM_CONF"
  # Otherwise append a [daemon] section with the setting
  else
    printf '\n[daemon]\nWaylandEnable=false\n' >> "$GDM_CONF"
  fi
  echo -e "${GREEN}[*] WaylandEnable=false set in ${GDM_CONF}${NC}"
else
  echo -e "${YELLOW}[WARNING] ${GDM_CONF} not found. Creating it with Wayland disabled.${NC}"
  cat << 'GDMEOF' > "$GDM_CONF"
[daemon]
WaylandEnable=false
GDMEOF
fi

# Also preserve/ensure AutomaticLogin settings in [daemon]
if grep -q "AutomaticLoginEnable=" "$GDM_CONF"; then
  sed -i 's/^\s*#\?\s*AutomaticLoginEnable=.*/AutomaticLoginEnable=true/' "$GDM_CONF"
else
  sed -i '/^\[daemon\]/a AutomaticLoginEnable=true' "$GDM_CONF"
fi
if grep -qE '^\s*#?\s*AutomaticLogin=[^E]' "$GDM_CONF"; then
  sed -i "s/^\s*#\?\s*AutomaticLogin=[^E].*/AutomaticLogin=${TARGET_USER}/" "$GDM_CONF"
else
  sed -i "/^\[daemon\]/a AutomaticLogin=${TARGET_USER}" "$GDM_CONF"
fi

# WaylandEnable=false above only affects GDM's *greeter* session picker.
# For an autologin user specifically, GDM frequently launches whichever
# session is recorded in that user's AccountsService file instead of
# consulting custom.conf at all - a well-known reason "WaylandEnable=false
# + reboot" alone still leaves $XDG_SESSION_TYPE as wayland for an
# autologin account. Pin that user's saved session to an Xorg one directly.
echo -e "${BLUE}[*] Pinning ${TARGET_USER}'s saved session to Xorg (AccountsService)...${NC}"
find_xorg_session() {
  XORG_SESSION=""
  for f in /usr/share/xsessions/*.desktop; do
    [ -e "$f" ] || continue
    base=$(basename "$f" .desktop)
    case "$base" in
      *xorg*|*-x11*|*X11*) XORG_SESSION="$base"; break ;;
    esac
  done
}
find_xorg_session

if [ -z "$XORG_SESSION" ]; then
  echo -e "${YELLOW}[WARNING] No Xorg session found under /usr/share/xsessions/ (it may not even${NC}"
  echo -e "${YELLOW}          exist yet) - only Wayland sessions appear to be installed. x11vnc${NC}"
  echo -e "${YELLOW}          requires X11 and cannot work on a Wayland-only system. Attempting to${NC}"
  echo -e "${YELLOW}          install an Xorg session automatically...${NC}"
  apt-get update -qq || true
  for pkg in gnome-session-xsession xserver-xorg xinit ubuntu-session; do
    apt-get install -y "$pkg" 2>&1 | tail -3
  done
  find_xorg_session
  if [ -n "$XORG_SESSION" ]; then
    echo -e "${GREEN}  [OK] Xorg session now available: ${XORG_SESSION}${NC}"
  else
    echo -e "${RED}[ERROR] Still no Xorg session available after attempting install.${NC}"
    echo -e "${RED}        VNC cannot work until one exists. Check manually with:${NC}"
    echo -e "${RED}          apt search xsession 2>/dev/null | grep -i gnome${NC}"
    echo -e "${RED}          ls /usr/share/xsessions/${NC}"
    echo -e "${RED}        then install whatever package provides it and re-run this script.${NC}"
  fi
fi

if [ -n "$XORG_SESSION" ]; then
  ACCOUNTS_FILE="/var/lib/AccountsService/users/${TARGET_USER}"
  mkdir -p /var/lib/AccountsService/users
  touch "$ACCOUNTS_FILE"
  if ! grep -q '^\[User\]' "$ACCOUNTS_FILE" 2>/dev/null; then
    printf '[User]\n' >> "$ACCOUNTS_FILE"
  fi
  for key in Session XSession; do
    if grep -q "^${key}=" "$ACCOUNTS_FILE" 2>/dev/null; then
      sed -i "s/^${key}=.*/${key}=${XORG_SESSION}/" "$ACCOUNTS_FILE"
    else
      sed -i "/^\[User\]/a ${key}=${XORG_SESSION}" "$ACCOUNTS_FILE"
    fi
  done
  echo -e "${GREEN}  [OK] ${TARGET_USER}'s saved session pinned to '${XORG_SESSION}' in ${ACCOUNTS_FILE}.${NC}"
fi

echo -e "${YELLOW}Please enter the password you want to use for Remote Desktop (VNC) connections:${NC}"
x11vnc -storepasswd /etc/x11vnc.pass
chmod 644 /etc/x11vnc.pass

# x11vnc's "-auth guess" is unreliable against GDM3 autologin: the Xauthority
# file location can vary by boot/session, and if x11vnc starts before the
# autologin'd X session actually exists, it guesses wrong (or guesses nothing)
# and silently refuses/drops incoming connections while still reporting as
# "active (running)". This wrapper waits for a real, working Xauthority
# instead of trusting the guess.
cat << 'EOF' > /usr/local/bin/x11vnc-wait.sh
#!/bin/bash
# Wait for the autologin'd X session to actually exist, then resolve its
# real Xauthority path instead of relying on x11vnc's -auth guess.
for i in $(seq 1 60); do
  XAUTH=$(find /run/user/*/gdm/Xauthority /run/gdm3/auth-for-*/database 2>/dev/null | head -n1)
  if [ -n "$XAUTH" ] && DISPLAY=:0 XAUTHORITY="$XAUTH" xdpyinfo >/dev/null 2>&1; then
    exec /usr/bin/x11vnc -forever -display :0 -auth "$XAUTH" \
      -rfbauth /etc/x11vnc.pass -rfbport 5900 -shared -repeat
  fi
  sleep 2
done
echo "x11vnc-wait: timed out waiting for X session/Xauthority" >&2
exit 1
EOF
chmod +x /usr/local/bin/x11vnc-wait.sh

cat << 'EOF' > /etc/systemd/system/x11vnc.service
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
EOF

systemctl daemon-reload
systemctl enable --now x11vnc

# Open the firewall for VNC if ufw is active (silent connection failures from
# Windows are commonly just port 5900 being blocked, with x11vnc itself fine)
if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
  echo -e "${GREEN}[*] ufw is active — allowing 5900/tcp for VNC${NC}"
  ufw allow 5900/tcp
fi

# 8. Clean Keyring Prompts
echo -e "${BLUE}[7/7] Resetting Keyrings for Unattended Auto-login...${NC}"
rm -rf "${USER_HOME}/.local/share/keyrings/"* || true

IP_ADDR=$(hostname -I | awk '{print $1}')

echo -e "${BLUE}[*] Resulting GDM/session configuration:${NC}"
grep -E '^(WaylandEnable|AutomaticLoginEnable|AutomaticLogin)=' "$GDM_CONF" 2>/dev/null | sed 's/^/    custom.conf: /'
if [ -n "$XORG_SESSION" ]; then
  grep -E '^(Session|XSession)=' "/var/lib/AccountsService/users/${TARGET_USER}" 2>/dev/null | sed "s/^/    ${TARGET_USER}: /"
fi

echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}             INSTALLATION COMPLETE!                   ${NC}"
echo -e "${GREEN}======================================================${NC}"
echo -e "Kiosk Target URL:  ${BLUE}${KIOSK_URL}${NC}"
echo -e "Remote VNC Access: ${BLUE}vnc://${IP_ADDR}:5900${NC}"
echo -e ""
echo -e "${YELLOW}Notes:${NC}"
echo -e "1. Automatic Login has been configured for ${TARGET_USER} in GDM."
echo -e "2. When prompted on the first reboot to set a keyring password, leave it blank."
echo -e "3. ${RED}Wayland has been disabled. A reboot is required for X11 and VNC to work correctly.${NC}"
echo -e "4. After reboot, verify with: ${BLUE}echo \$XDG_SESSION_TYPE${NC} — it should report ${GREEN}x11${NC}."
echo -e "5. Reboot your machine now to apply all changes:"
echo -e "   ${BLUE}sudo reboot${NC}"