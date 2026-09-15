#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# Installs into the user's home. This needs no root at all: the indicator only
# reads two sysfs attributes, and those are readable because Android's `system`
# UID 1000 is the host user. Asking for a password here would buy nothing.
set -euo pipefail

if [ "$(id -u)" = 0 ]; then
    echo "Please run WITHOUT sudo - the program runs in the user session." >&2
    exit 1
fi

# What the icon needs to come alive. Checked BEFORE anything is installed:
# without GtkLayerShell the service does start but never draws anything - and
# a program that installed cleanly and then silently does nothing is harder to
# understand than one that never moves in. On FuriOS phosh brings these
# packages along itself, so this never fires here; on a phone without them the
# missing name is the whole answer.
if ! python3 - <<'PRUEFUNG' 2>/dev/null
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("GtkLayerShell", "0.1")
from gi.repository import Gtk, GtkLayerShell  # noqa: F401
PRUEFUNG
then
    echo "Missing: python3-gi, gir1.2-gtk-3.0 or gir1.2-gtklayershell-0.1." >&2
    echo "Without them the icon draws nothing - nothing was installed." >&2
    exit 1
fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

echo
echo "Installed. State:"
"$BIN/killswitch-indicator" status || true
echo
systemctl --user --no-pager --lines=0 status killswitch-indicator.service | head -4
