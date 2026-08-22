#!/usr/bin/env bash
# ==============================================================================
# Kiosk Diagnostic Script
# Collects the state relevant to "still on Wayland" / "can't connect via VNC"
# style issues into one place, so it can be pasted back for troubleshooting.
# Read-only: makes no changes to the system.
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

section() {
  echo ""
  echo -e "${BLUE}==============================================================${NC}"
  echo -e "${BLUE}  $1${NC}"
  echo -e "${BLUE}==============================================================${NC}"
}

run() {
  # run <description> -- <command...>
  local desc="$1"; shift
  echo -e "${GREEN}\$ $*${NC}"
  if ! eval "$@" 2>&1; then
    echo -e "${YELLOW}(command failed or produced no output: ${desc})${NC}"
  fi
  echo ""
}

TARGET_USER="${SUDO_USER:-$USER}"

section "Repo state (confirms which fixes are present)"
if [ -n "$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)" ]; then
  run "git log" git -C "$(dirname "$0")" log --oneline -8
else
  echo -e "${YELLOW}Not inside a git checkout of this repo — can't confirm which commit is checked out.${NC}"
fi

section "Basic system info"
run "os-release" cat /etc/os-release
run "uname" uname -a
run "current session type" 'echo "XDG_SESSION_TYPE=$XDG_SESSION_TYPE"'
run "current user" 'echo "Running as: $(whoami), target/login user: ${TARGET_USER}"'

section "GDM configuration"
run "custom.conf" cat /etc/gdm3/custom.conf
run "display manager in use" cat /etc/X11/default-display-manager
run "gdm3 service status" systemctl status gdm3 --no-pager -l

section "Available desktop sessions"
run "xsessions (X11)" ls -la /usr/share/xsessions/ 2>/dev/null
run "wayland-sessions" ls -la /usr/share/wayland-sessions/ 2>/dev/null

section "Per-user session preference (AccountsService)"
run "AccountsService entry" sudo cat "/var/lib/AccountsService/users/${TARGET_USER}"

section "Login session details (alternate check)"
run "loginctl list-sessions" loginctl list-sessions --no-legend
SESSION_ID=$(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$TARGET_USER" '$3==u{print $1; exit}')
if [ -n "$SESSION_ID" ]; then
  run "loginctl session details" loginctl show-session "$SESSION_ID" -p Type -p Class -p State -p Remote -p Service
else
  echo -e "${YELLOW}Could not find an active loginctl session for ${TARGET_USER}.${NC}"
fi

section "GPU / driver (NVIDIA proprietary drivers can affect session selection)"
run "lspci VGA/3D" 'lspci | grep -iE "vga|3d"'
run "nvidia-smi (if present)" 'command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi || echo "nvidia-smi not present"'

section "x11vnc / VNC"
run "x11vnc.service status" systemctl status x11vnc --no-pager -l
run "port 5900 listening" 'sudo ss -tlnp 2>/dev/null | grep 5900 || echo "nothing listening on 5900"'
run "ufw status" 'command -v ufw >/dev/null 2>&1 && sudo ufw status || echo "ufw not installed"'
run "x11vnc recent logs" journalctl -u x11vnc -b --no-pager | tail -n 40

section "RDP / GNOME Remote Desktop"
run "gnome-remote-desktop installed?" 'dpkg -l | grep -i gnome-remote-desktop || echo "gnome-remote-desktop not installed"'
run "gnome-remote-desktop.service status" systemctl status gnome-remote-desktop --no-pager -l
run "grdctl --system status" sudo grdctl --system status
run "TLS cert/key present" 'ls -la /etc/gnome-remote-desktop/certs/ 2>/dev/null || echo "no certs directory"'
run "port 3389 listening" 'sudo ss -tlnp 2>/dev/null | grep 3389 || echo "nothing listening on 3389"'
run "gnome-remote-desktop recent logs" journalctl -u gnome-remote-desktop -b --no-pager | tail -n 60
run "any grd- processes running" 'ps aux | grep -i "[g]rd-" || echo "no grd- processes found"'

section "SSH (noted as also not working)"
run "sshd installed?" 'dpkg -l | grep -i openssh-server || echo "openssh-server not installed"'
run "ssh.service status" systemctl status ssh --no-pager -l
run "port 22 listening" 'sudo ss -tlnp 2>/dev/null | grep ":22 " || echo "nothing listening on 22"'

section "Network"
run "IP addresses" hostname -I
run "default route" ip route show default

echo ""
echo -e "${GREEN}==============================================================${NC}"
echo -e "${GREEN}  Diagnosis complete. Copy the full output above and share it.${NC}"
echo -e "${GREEN}==============================================================${NC}"
