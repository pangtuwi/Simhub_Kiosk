#!/usr/bin/env bash
# ==============================================================================
# Remote Desktop (RDP) Fallback Setup — GNOME Remote Desktop
# ==============================================================================
# x11vnc fundamentally requires an X11 session. On a Wayland-only Ubuntu
# install (no /usr/share/xsessions/ entry, no Xorg session package available
# in the repos), x11vnc can never work no matter how custom.conf or
# AccountsService are configured — there is nothing for it to attach to.
#
# GNOME's built-in Remote Desktop support works natively over Wayland via
# PipeWire screen capture and needs no Xorg session at all. This script
# configures it in PER-SESSION mode - the same mechanism as GNOME Settings
# > Sharing > Remote Desktop - which mirrors the kiosk's actual running
# autologin'd session, and is reachable with a standard RDP client (Windows'
# built-in "Remote Desktop Connection" / mstsc, or Microsoft Remote Desktop
# on macOS) instead of a VNC client.
#
# Deliberately NOT "system"/headless mode (`grdctl --system`): that spins up
# a brand-new, separate session per RDP login rather than mirroring the one
# already on screen, and - confirmed on real hardware - refuses to do so
# when the target user already has an active session (the autologin'd kiosk
# session itself), failing at login with "there is already a local session
# running". Per-session mode shares the actual live session instead, which
# is what a kiosk needs.
#
# Requires the kiosk user to already be logged in (true for an autologin'd
# kiosk) - it configures RDP against that live session's own D-Bus bus.
#
# Safe to run multiple times. Does not remove or disable x11vnc — the two
# can coexist; use whichever one actually works on your system.
# ==============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}  Remote Desktop (RDP) Fallback Setup                 ${NC}"
echo -e "${BLUE}======================================================${NC}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Please run with sudo: sudo ./setup_rdp.sh${NC}"
  exit 1
fi

# --- Argument parsing -------------------------------------------------------
TARGET_USER_OVERRIDE=""
RDP_USER_OVERRIDE=""
RDP_PASSWORD=""
ASSUME_YES=0

usage() {
  cat <<USAGE
Usage: sudo ./setup_rdp.sh [--user USERNAME] [--rdp-user NAME] [--rdp-password PASS] [-y|--yes]

  --user USERNAME       The kiosk's login user (for detection only, same
                         convention as step2.sh). Defaults to \$SUDO_USER.
  --rdp-user NAME        Username RDP clients will log in with. Defaults to
                         the kiosk login user.
  --rdp-password PASS    Password RDP clients will use. Prompted for
                         interactively if omitted.
  -y, --yes              Skip the confirmation prompt.
  -h, --help              Show this help and exit.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --user) TARGET_USER_OVERRIDE="$2"; shift 2 ;;
    --user=*) TARGET_USER_OVERRIDE="${1#*=}"; shift ;;
    --rdp-user) RDP_USER_OVERRIDE="$2"; shift 2 ;;
    --rdp-user=*) RDP_USER_OVERRIDE="${1#*=}"; shift ;;
    --rdp-password) RDP_PASSWORD="$2"; shift 2 ;;
    --rdp-password=*) RDP_PASSWORD="${1#*=}"; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo -e "${RED}[ERROR] Unknown argument: $1${NC}"; usage; exit 1 ;;
  esac
done

if [ -n "$TARGET_USER_OVERRIDE" ]; then
  TARGET_USER="$TARGET_USER_OVERRIDE"
elif [ -n "$SUDO_USER" ]; then
  TARGET_USER="$SUDO_USER"
else
  TARGET_USER="$USER"
  echo -e "${YELLOW}[WARNING] \$SUDO_USER is not set — falling back to '${TARGET_USER}'.${NC}"
  echo -e "${YELLOW}          If this isn't your kiosk's login user, re-run with --user <name>.${NC}"
fi

RDP_USER="${RDP_USER_OVERRIDE:-$TARGET_USER}"

if [ -z "$RDP_PASSWORD" ]; then
  echo -e "${YELLOW}Enter the password RDP clients will use to log in as '${RDP_USER}':${NC}"
  read -r -s -p "Password: " RDP_PASSWORD
  echo ""
  if [ -z "$RDP_PASSWORD" ]; then
    echo -e "${RED}[ERROR] A password is required.${NC}"
    exit 1
  fi
fi

echo -e "${BLUE}------------------------------------------------------${NC}"
echo -e "${BLUE}  Kiosk login user : ${TARGET_USER}${NC}"
echo -e "${BLUE}  RDP login user   : ${RDP_USER}${NC}"
echo -e "${BLUE}------------------------------------------------------${NC}"

if [ "$ASSUME_YES" -ne 1 ]; then
  read -r -p "Proceed with these values? [Y/n] " CONFIRM
  case "$CONFIRM" in
    [nN]*) echo -e "${RED}Aborted.${NC}"; exit 1 ;;
  esac
fi

# 1. Install gnome-remote-desktop -------------------------------------------
echo -e "${BLUE}[1/5] Installing gnome-remote-desktop...${NC}"
apt-get update -qq || true
if ! apt-get install -y gnome-remote-desktop; then
  echo -e "${RED}[ERROR] Could not install gnome-remote-desktop. This desktop environment${NC}"
  echo -e "${RED}        may not ship GNOME's Remote Desktop support. Check with:${NC}"
  echo -e "${RED}          apt-cache search remote-desktop${NC}"
  exit 1
fi

if ! command -v grdctl &> /dev/null; then
  echo -e "${RED}[ERROR] grdctl not found after installing gnome-remote-desktop.${NC}"
  exit 1
fi

# 2. Disable system/headless mode if a previous run enabled it --------------
# It actively conflicts with per-session mode: it binds port 3389 itself and
# tries to spawn a new session on login, which fails outright when the
# target user already has one - exactly the "already a local session
# running" error. Stop it so per-session mode can bind the port instead.
echo -e "${BLUE}[2/5] Disabling system/headless RDP mode if previously enabled...${NC}"
if systemctl is-enabled gnome-remote-desktop.service &> /dev/null || systemctl is-active gnome-remote-desktop.service &> /dev/null; then
  systemctl disable --now gnome-remote-desktop.service 2>/dev/null || true
  echo -e "${GREEN}  [OK] Stopped and disabled the system/headless gnome-remote-desktop.service.${NC}"
else
  echo -e "${GREEN}  [OK] System/headless mode was not enabled.${NC}"
fi
command -v grdctl &> /dev/null && grdctl --system rdp disable 2>/dev/null || true

# 3. Confirm the kiosk user actually has a live session ----------------------
echo -e "${BLUE}[3/5] Checking for ${TARGET_USER}'s active session...${NC}"
USER_UID=$(id -u "$TARGET_USER")
USER_BUS_PATH="/run/user/${USER_UID}/bus"
if [ ! -S "$USER_BUS_PATH" ]; then
  echo -e "${RED}[ERROR] No active session bus found for ${TARGET_USER} at ${USER_BUS_PATH}.${NC}"
  echo -e "${RED}        Per-session RDP mode configures the user's already-running graphical${NC}"
  echo -e "${RED}        session, so ${TARGET_USER} needs to actually be logged in first (true${NC}"
  echo -e "${RED}        for an autologin'd kiosk once it's booted). Log in, then re-run this script.${NC}"
  exit 1
fi
USER_BUS="unix:path=${USER_BUS_PATH}"
as_target_user() {
  sudo -u "$TARGET_USER" env XDG_RUNTIME_DIR="/run/user/${USER_UID}" DBUS_SESSION_BUS_ADDRESS="$USER_BUS" "$@"
}
echo -e "${GREEN}  [OK] Found an active session bus for ${TARGET_USER}.${NC}"

# 4. Generate a self-signed TLS certificate, owned by the kiosk user ---------
echo -e "${BLUE}[4/5] Configuring TLS certificate...${NC}"
TARGET_USER_HOME=$(eval echo "~${TARGET_USER}")
CERT_DIR="${TARGET_USER_HOME}/.local/share/gnome-remote-desktop-certs"
CERT_FILE="${CERT_DIR}/rdp-tls.crt"
KEY_FILE="${CERT_DIR}/rdp-tls.key"
mkdir -p "$CERT_DIR"

if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
  openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
    -keyout "$KEY_FILE" -out "$CERT_FILE" \
    -subj "/CN=$(hostname)" 2>&1 | tail -5
  echo -e "${GREEN}  [OK] Generated self-signed certificate at ${CERT_FILE}${NC}"
else
  echo -e "${GREEN}  [OK] Certificate already exists at ${CERT_FILE}, leaving it in place.${NC}"
fi

# Per-session mode runs as the logged-in user, not a dedicated system
# account (that was --system mode's own, different, permissions bug -
# fixed separately when that mode was still in use). The cert must be
# owned by TARGET_USER, not root, or the exact same class of failure
# ("TLS certificate and key not yet configured properly") recurs here too.
chown -R "${TARGET_USER}:${TARGET_USER}" "$CERT_DIR"
chmod 700 "$CERT_DIR"
chmod 600 "$KEY_FILE"
chmod 644 "$CERT_FILE"

# 5. Configure GNOME Remote Desktop in per-session mode ----------------------
echo -e "${BLUE}[5/5] Configuring RDP via grdctl (per-session)...${NC}"
as_target_user grdctl rdp set-tls-cert "$CERT_FILE"
as_target_user grdctl rdp set-tls-key "$KEY_FILE"
as_target_user grdctl rdp set-credentials "$RDP_USER" "$RDP_PASSWORD"
as_target_user grdctl rdp enable
# GNOME Remote Desktop defaults new RDP configs to view-only (screen visible,
# keyboard/mouse input ignored) - confirmed on real hardware: connected fine
# from both Windows and macOS clients, but clicks and typing did nothing
# until this was disabled. A kiosk needs interactive control, not just a
# view, so always turn it off.
as_target_user grdctl rdp disable-view-only

echo -e "${GREEN}  [OK] Per-session RDP configured for ${TARGET_USER} (interactive, not view-only).${NC}"

echo -e "${BLUE}[*] Verifying RDP is actually listening on port 3389...${NC}"
LISTENING=""
for i in 1 2 3 4 5; do
  if ss -tlnp 2>/dev/null | grep -q ':3389 '; then
    LISTENING=1
    break
  fi
  sleep 1
done
if [ -n "$LISTENING" ]; then
  echo -e "${GREEN}  [OK] Port 3389 is listening.${NC}"
else
  echo -e "${RED}[ERROR] Port 3389 is still not listening.${NC}"
  echo -e "${RED}        RDP will not be reachable. Current status:${NC}"
  as_target_user grdctl status 2>&1 | sed 's/^/    /' || true
fi

RDP_STATUS_OUTPUT=$(as_target_user grdctl status 2>&1 || true)
if echo "$RDP_STATUS_OUTPUT" | grep -q "View-only: yes"; then
  echo -e "${RED}[ERROR] View-only is still enabled — clicks and keyboard input will be${NC}"
  echo -e "${RED}        ignored even though the screen is visible. 'grdctl rdp${NC}"
  echo -e "${RED}        disable-view-only' did not take effect; check the RDP status below.${NC}"
else
  echo -e "${GREEN}  [OK] View-only is disabled — clicks and keyboard input will work.${NC}"
fi

# Open the firewall for RDP if ufw is active ---------------------------------
if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
  echo -e "${GREEN}  [OK] ufw is active — allowing 3389/tcp for RDP${NC}"
  ufw allow 3389/tcp
fi

echo -e "${BLUE}[*] RDP status:${NC}"
echo "$RDP_STATUS_OUTPUT" | sed 's/^/    /'

IP_ADDR=$(hostname -I | awk '{print $1}')

echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}             RDP SETUP COMPLETE                       ${NC}"
echo -e "${GREEN}======================================================${NC}"
echo -e "Connect from Windows using the built-in ${BLUE}Remote Desktop Connection${NC} app (mstsc):"
echo -e "  Computer: ${BLUE}${IP_ADDR}${NC}"
echo -e "  Username: ${BLUE}${RDP_USER}${NC}"
echo -e "  Password: (the one you just set)"
echo -e ""
echo -e "On macOS, use the ${BLUE}Microsoft Remote Desktop${NC} app from the App Store with the same details."
echo -e ""
echo -e "${YELLOW}Note: this uses a self-signed certificate, so your RDP client will warn${NC}"
echo -e "${YELLOW}about an untrusted certificate on first connect — that's expected on a${NC}"
echo -e "${YELLOW}private LAN kiosk; accept it to continue.${NC}"
echo -e ""
echo -e "This does not require Wayland to be disabled and works alongside (or"
echo -e "instead of) the existing x11vnc setup on port 5900."
