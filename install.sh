#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# Two halves, and they are installed in different places:
#
#   the icons  - a phosh plugin, into the shell's plugin directory. That one
#                needs root, because phosh takes the directory from a
#                compile-time constant: there is no place in the home the
#                shell would look in.
#   the daemon - into the user's home, no root at all. It reads two sysfs
#                attributes, and those are readable because Android's `system`
#                UID 1000 is the host user.
#
# Run WITHOUT sudo - the two lines that write to /usr/lib ask for themselves.
set -euo pipefail

if [ "$(id -u)" = 0 ]; then
    echo "Please run WITHOUT sudo - the daemon runs in the user session." >&2
    exit 1
fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Checked BEFORE anything is installed: a half-installed pair - a daemon
# running with no icons to go with it - is harder to understand than nothing
# at all. On FuriOS phosh brings all of this along itself.
missing=()
command -v cc >/dev/null || missing+=("a C compiler (apt install build-essential)")
command -v make >/dev/null || missing+=("make (apt install build-essential)")
pkg-config --exists phosh-plugins 2>/dev/null \
    || missing+=("phosh's plugin headers (apt install phosh-dev)")
pkg-config --exists gtk+-3.0 2>/dev/null \
    || missing+=("GTK 3 headers (apt install libgtk-3-dev)")
python3 -c 'import gi' 2>/dev/null \
    || missing+=("python3-gi")
if [ ${#missing[@]} -gt 0 ]; then
    printf 'Missing: %s\n' "${missing[@]}" >&2
    echo "Nothing was installed." >&2
    exit 1
fi

echo "1) building the icons"
make -C "$SRC/phosh-plugin" all

echo "2) installing them where phosh looks"
sudo make -C "$SRC/phosh-plugin" install

echo "3) installing the daemon"
BIN="$HOME/.local/bin"
UNIT="$HOME/.config/systemd/user"
DOC="$HOME/.local/share/doc/killswitch-indicator"

install -d "$BIN" "$UNIT" "$DOC"
install -m 0755 "$SRC/killswitch-indicator" "$BIN/killswitch-indicator"
install -m 0644 "$SRC/systemd/killswitch-indicator.service" "$UNIT/killswitch-indicator.service"
install -m 0644 "$SRC/README.md" "$SRC/FINDINGS.md" "$DOC/"

systemctl --user daemon-reload
systemctl --user enable killswitch-indicator.service
# restart, not just start: on a reinstall the service is already running and
# would otherwise carry on with the old version.
systemctl --user restart killswitch-indicator.service

echo "4) switching the icons on"
# Through the tool, not by editing the list here: it reads phosh's list,
# adds our own name to it and writes it back, so a plugin of somebody else's
# in the same list survives. Same command the app and uninstall.sh use.
"$BIN/killswitch-indicator" icons on

echo
echo "Installed. State:"
"$BIN/killswitch-indicator" status || true
echo
systemctl --user --no-pager --lines=0 status killswitch-indicator.service | head -4
echo
# phosh scans its plugin directory once, when the shell starts. A plugin put
# there afterwards is found by nobody until then, and the shell says so in one
# line: "Custom status-icon 'furios-killswitch' not found".
#
# And there is no shortcut: mobi.phosh.Shell.service is RefuseManualStart and
# RefuseManualStop, and taking the shell down by hand takes the whole session
# with it - OnFailure=gnome-session-shutdown.target, replace-irreversibly.
echo "The icons appear after the next reboot: phosh looks for plugins only"
echo "when it starts, and its unit refuses to be restarted on its own."
echo "The daemon - the extra radios on the network switch - is running now."
