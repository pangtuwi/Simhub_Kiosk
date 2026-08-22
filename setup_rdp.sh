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
# configures it in "system" (headless-capable) mode, so it comes up on boot
# for the autologin'd kiosk session the same way x11vnc was meant to, and is
# reachable with a standard RDP client (Windows' built-in "Remote Desktop
# Connection" / mstsc, or Microsoft Remote Desktop on macOS) instead of a VNC
# client.
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
echo -e "${BLUE}[1/4] Installing gnome-remote-desktop...${NC}"
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

# 2. Generate a self-signed TLS certificate ----------------------------------
echo -e "${BLUE}[2/4] Configuring TLS certificate...${NC}"
CERT_DIR="/etc/gnome-remote-desktop/certs"
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
chmod 600 "$KEY_FILE"
chmod 644 "$CERT_FILE"

# 3. Configure GNOME Remote Desktop (system/headless mode) -------------------
echo -e "${BLUE}[3/4] Configuring RDP via grdctl --system...${NC}"
grdctl --system rdp set-tls-cert "$CERT_FILE"
grdctl --system rdp set-tls-key "$KEY_FILE"
grdctl --system rdp set-credentials "$RDP_USER" "$RDP_PASSWORD"
grdctl --system rdp enable

systemctl daemon-reload
systemctl enable gnome-remote-desktop.service
# Always restart (not just "enable --now"): if the daemon was already
# running from a previous boot/run, "enable --now" is a no-op that leaves
# it running with whatever config it read at its own startup - it does not
# reload just because grdctl wrote new config. Confirmed on real hardware:
# the service can come up at boot logging "RDP TLS certificate and key not
# yet configured properly" and never actually bind its listening socket,
# even though `grdctl --system status` reports everything correctly
# configured moments later. A restart forces it to re-read the current
# config from a clean start.
systemctl restart gnome-remote-desktop.service

echo -e "${GREEN}  [OK] gnome-remote-desktop configured and restarted.${NC}"

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
  echo -e "${RED}[ERROR] Port 3389 is still not listening after restarting the service.${NC}"
  echo -e "${RED}        RDP will not be reachable. Recent logs:${NC}"
  journalctl -u gnome-remote-desktop -b --no-pager | tail -20 | sed 's/^/    /'
fi

# 4. Open the firewall for RDP if ufw is active -------------------------------
echo -e "${BLUE}[4/4] Checking firewall...${NC}"
if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
  echo -e "${GREEN}  [OK] ufw is active — allowing 3389/tcp for RDP${NC}"
  ufw allow 3389/tcp
else
  echo -e "${GREEN}  [OK] ufw is not active — nothing to open.${NC}"
fi

echo -e "${BLUE}[*] Service status:${NC}"
systemctl status gnome-remote-desktop.service --no-pager -l | sed 's/^/    /'
grdctl --system status 2>&1 | sed 's/^/    /' || true

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
