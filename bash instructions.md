Found it — that's a known default GNOME Remote Desktop sets. Looking back at setup_rdp_output.txt from earlier, grdctl status showed View-only: yes. That means the RDP session is deliberately rejecting keyboard/mouse input — connecting and seeing the screen but clicks doing nothing is exactly what view-only mode looks like.

Quick fix to test first:

Ran
a command

Sorry — same mistake again, that ran in my own sandbox, not yours. Please run this yourself on the kiosk machine:

sudo -u pangtuwi env XDG_RUNTIME_DIR=/run/user/$(id -u pangtuwi) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u pangtuwi)/bus grdctl rdp disable-view-only
Then confirm it took effect:

sudo -u pangtuwi env XDG_RUNTIME_DIR=/run/user/$(id -u pangtuwi) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u pangtuwi)/bus grdctl status

You want to see View-only: no in the output. Then reconnect from Windows/Mac and try clicking again.

If disable-view-only isn't a recognized subcommand on your grdctl version, run grdctl rdp --help and paste the output — I'll adjust the exact command and bake it into setup_rdp.sh either way so it doesn't need to be set by hand again.
