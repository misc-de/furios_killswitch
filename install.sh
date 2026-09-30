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

# DESTDIR, as in make: a staged root instead of /, for the tests.
DESTDIR=${DESTDIR:-}
PLUGIN_DIR=$(pkg-config --variable=status_icons_plugins_dir phosh-plugins)

# Before anything is written, what the phone had: every path this project
# writes (here and later, from the daemon and the app's switches), whether it
# was there, and which directories above them were missing. Taken once - a
# reinstall finds the record and keeps it - and read back by uninstall.sh.
# phosh's plugin list is recorded separately, when the icons are switched on
# for the first time: that is its first change. See "The original state" in killswitch-indicator.
DESTDIR="$DESTDIR" python3 "$SRC/killswitch-indicator" original record \
    --plugin-dir "$PLUGIN_DIR"

echo "1) building the icons"
make -C "$SRC/phosh-plugin" all

echo "2) installing them where phosh looks"
sudo make -C "$SRC/phosh-plugin" install DESTDIR="$DESTDIR"

echo "3) installing the daemon"
BIN="$HOME/.local/bin"
UNIT="$HOME/.config/systemd/user"
DOC="$HOME/.local/share/doc/killswitch-indicator"

install -d "$BIN" "$UNIT" "$DOC"
install -m 0755 "$SRC/killswitch-indicator" "$BIN/killswitch-indicator"
install -m 0644 "$SRC/systemd/killswitch-indicator.service" "$UNIT/killswitch-indicator.service"
install -m 0644 "$SRC/README.md" "$SRC/FINDINGS.md" "$DOC/"

systemctl --user daemon-reload
# Not enabled and not started: after an installation everything is off until
# somebody switches it on (the app's switch, or the command printed below).
# try-restart only touches a daemon that is already running, so a reinstall
# over one somebody switched on hands it the new version.
systemctl --user try-restart killswitch-indicator.service

# The icons stay as they are: off after a first installation, and whatever
# somebody chose on a reinstall. Switching them on goes through the tool, not
# by editing phosh's list here - it may hold somebody else's plugin.

echo
echo "Installed. State:"
"$BIN/killswitch-indicator" status || true
echo
# `systemctl status` exits 3 for a unit that is not running - which is every
# first installation, since an installation switches nothing on. Under
# pipefail that ended the script right here with a perfectly good install
# behind it, and the misc-de app reported the whole output as a failure.
systemctl --user --no-pager --lines=0 status killswitch-indicator.service \
    | head -4 || true
echo
# phosh scans its plugin directory once, when the shell starts. A plugin put
# there afterwards is found by nobody until then, and the shell says so in one
# line: "Custom status-icon 'furios-killswitch' not found".
#
# And there is no shortcut: mobi.phosh.Shell.service is RefuseManualStart and
# RefuseManualStop, and taking the shell down by hand takes the whole session
# with it - OnFailure=gnome-session-shutdown.target, replace-irreversibly.
echo "An installation switches nothing on. To show the icons and run the daemon:"
echo "    \"$BIN/killswitch-indicator\" icons on"
echo "    systemctl --user enable --now killswitch-indicator.service"
echo "The icons appear after the next reboot: phosh looks for plugins only"
echo "when it starts, and its unit refuses to be restarted on its own."
