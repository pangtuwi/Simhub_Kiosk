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

# --- Argument parsing -------------------------------------------------------
# Note: the folder you run step2.sh *from* never matters for any of this —
# every path below is resolved absolutely from the target user's home
# directory, not from $PWD. What DOES matter is which user is detected as
# the kiosk's login user; see the --user flag below.
TARGET_USER_OVERRIDE=""
URL_OVERRIDE=""
ASSUME_YES=0

usage() {
  cat <<USAGE
Usage: sudo ./step2.sh [--user USERNAME] [--url URL] [-y|--yes]

  --user USERNAME   Explicitly set the kiosk's login user instead of relying
                     on \$SUDO_USER autodetection. Use this if you ran
                     step2.sh from an already-root shell (e.g. after
                     'sudo -s' or 'sudo -i'), where \$SUDO_USER is empty and
                     autodetection would otherwise silently fall back to
                     'root' — the classic cause of "it didn't find my saved
                     URL".
  --url URL         Explicitly set the kiosk target URL instead of
                     detecting it from the existing kiosk.sh.
  -y, --yes         Skip the confirmation prompt and accept the
                     detected/default values automatically (for unattended
                     re-runs).
  -h, --help        Show this help and exit.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --user) TARGET_USER_OVERRIDE="$2"; shift 2 ;;
    --user=*) TARGET_USER_OVERRIDE="${1#*=}"; shift ;;
    --url) URL_OVERRIDE="$2"; shift 2 ;;
    --url=*) URL_OVERRIDE="${1#*=}"; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo -e "${RED}[ERROR] Unknown argument: $1${NC}"; usage; exit 1 ;;
  esac
done

# --- Resolve the target user -------------------------------------------------
if [ -n "$TARGET_USER_OVERRIDE" ]; then
  TARGET_USER="$TARGET_USER_OVERRIDE"
elif [ -n "$SUDO_USER" ]; then
  TARGET_USER="$SUDO_USER"
else
  TARGET_USER="$USER"
  echo -e "${YELLOW}[WARNING] \$SUDO_USER is not set, so the kiosk's login user could not be${NC}"
  echo -e "${YELLOW}          auto-detected. This usually means step2.sh was run from an${NC}"
  echo -e "${YELLOW}          already-root shell (e.g. 'sudo -s' / 'sudo -i' first, then${NC}"
  echo -e "${YELLOW}          './step2.sh' with plain sudo already consumed). Falling back to${NC}"
  echo -e "${YELLOW}          '${TARGET_USER}', which is almost certainly NOT your kiosk's real${NC}"
  echo -e "${YELLOW}          login user. Re-run as: sudo ./step2.sh --user <your_kiosk_username>${NC}"
fi

if ! id "$TARGET_USER" &> /dev/null; then
  echo -e "${RED}[ERROR] User '${TARGET_USER}' does not exist on this system.${NC}"
  echo -e "${RED}        Re-run with: sudo ./step2.sh --user <your_kiosk_username>${NC}"
  exit 1
fi

USER_HOME=$(eval echo "~$TARGET_USER")
AUTOSTART_DIR="${USER_HOME}/.config/autostart-scripts"
KIOSK_SCRIPT="${AUTOSTART_DIR}/kiosk.sh"
GDM_CONF="/etc/gdm3/custom.conf"
X11VNC_SERVICE="/etc/systemd/system/x11vnc.service"

if [ "$TARGET_USER" = "root" ]; then
  echo -e "${YELLOW}[WARNING] Target user is root. Recommended to run under a standard user with sudo.${NC}"
fi

echo -e "${GREEN}[*] Patching kiosk for user: ${TARGET_USER} (${USER_HOME})${NC}"
echo -e "${GREEN}[*] Expecting existing kiosk script at: ${KIOSK_SCRIPT}${NC}"

# 1. Detect existing kiosk URL and browser binary from kiosk.sh
KIOSK_URL="http://localhost:5000"
BROWSER_BIN="chromium-browser"
URL_SOURCE="default (no existing kiosk.sh found)"

if [ -f "$KIOSK_SCRIPT" ]; then
  DETECTED_URL=$(grep -oP '(?<=TARGET_URL=")[^"]+' "$KIOSK_SCRIPT" 2>/dev/null || true)
  if [ -n "$DETECTED_URL" ]; then
    KIOSK_URL="$DETECTED_URL"
    URL_SOURCE="detected from ${KIOSK_SCRIPT}"
    echo -e "${GREEN}[*] Detected existing kiosk URL: ${KIOSK_URL}${NC}"
  else
    echo -e "${YELLOW}[WARNING] ${KIOSK_SCRIPT} exists but no TARGET_URL was found inside it.${NC}"
    URL_SOURCE="default (TARGET_URL not found in existing kiosk.sh)"
  fi

  for bin in chromium-browser chromium google-chrome; do
    if grep -q "$bin" "$KIOSK_SCRIPT" 2>/dev/null; then
      BROWSER_BIN="$bin"
      break
    fi
  done
else
  echo -e "${YELLOW}[WARNING] No existing kiosk script found at ${KIOSK_SCRIPT}.${NC}"
  # A kiosk.sh sitting under a *different* user's home is the tell-tale sign
  # that TARGET_USER was guessed wrong rather than the install being fresh.
  CANDIDATES=$(find /home /root -maxdepth 4 -path '*/.config/autostart-scripts/kiosk.sh' 2>/dev/null || true)
  if [ -n "$CANDIDATES" ]; then
    echo -e "${YELLOW}[WARNING] Found an existing kiosk.sh under a different user's home:${NC}"
    echo "$CANDIDATES" | sed 's/^/    /'
    echo -e "${YELLOW}          If one of these is yours, re-run with:${NC}"
    echo -e "${YELLOW}            sudo ./step2.sh --user <that_username>${NC}"
    echo -e "${YELLOW}          instead of letting it proceed with the default URL below.${NC}"
  fi
fi

if [ -n "$URL_OVERRIDE" ]; then
  KIOSK_URL="$URL_OVERRIDE"
  URL_SOURCE="--url override"
  echo -e "${GREEN}[*] Using explicitly provided kiosk URL: ${KIOSK_URL}${NC}"
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

echo -e "${BLUE}------------------------------------------------------${NC}"
echo -e "${BLUE}  Target user : ${TARGET_USER}${NC}"
echo -e "${BLUE}  Kiosk script: ${KIOSK_SCRIPT}${NC}"
echo -e "${BLUE}  Kiosk URL   : ${KIOSK_URL}  (${URL_SOURCE})${NC}"
echo -e "${BLUE}------------------------------------------------------${NC}"

if [ "$ASSUME_YES" -ne 1 ]; then
  read -r -p "Proceed with these values? [Y/n] " CONFIRM
  case "$CONFIRM" in
    [nN]*)
      echo -e "${RED}Aborted. Re-run with --user/--url to correct the detected values, or -y to skip this prompt.${NC}"
      exit 1
      ;;
  esac
fi

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

# Ensure xdpyinfo is available for the wrapper's readiness check
if ! command -v xdpyinfo &> /dev/null; then
  sudo apt install -y x11-utils || true
fi

# x11vnc's "-auth guess" is unreliable against GDM3 autologin: the Xauthority
# file location can vary by boot/session, and if x11vnc starts before the
# autologin'd X session actually exists, it guesses wrong (or guesses nothing)
# and silently refuses/drops incoming connections while still reporting as
# "active (running)". This wrapper waits for a real, working Xauthority
# instead of trusting the guess. This is the fix for "kiosk looks fine but
# Windows/VNC still can't connect" surviving previous runs of this script.
cat << 'EOF' | sudo tee /usr/local/bin/x11vnc-wait.sh >/dev/null
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
sudo chmod +x /usr/local/bin/x11vnc-wait.sh

cat << 'EOF' | sudo tee "$X11VNC_SERVICE" >/dev/null
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

sudo systemctl daemon-reload
sudo systemctl restart x11vnc || sudo systemctl enable --now x11vnc || true
echo -e "${GREEN}  [OK] x11vnc.service installed and enabled with Xauthority-wait wrapper.${NC}"

# Open the firewall for VNC if ufw is active (silent connection failures from
# Windows are commonly just port 5900 being blocked, with x11vnc itself fine)
if command -v ufw &> /dev/null && sudo ufw status | grep -q "Status: active"; then
  echo -e "${GREEN}  [OK] ufw is active — allowing 5900/tcp for VNC${NC}"
  sudo ufw allow 5900/tcp
fi

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
echo -e "  ${BLUE}sudo reboot${NC}"
