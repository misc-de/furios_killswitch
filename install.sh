#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# Installs into the user's home. This needs no root at all: the indicator only
# reads two sysfs attributes, and those are readable because Android's `system`
# UID 1000 is the host user. Asking for a password here would buy nothing.
set -euo pipefail

if [ "$(id -u)" = 0 ]; then
    echo "Bitte OHNE sudo ausfuehren - das Programm laeuft in der Nutzersitzung." >&2
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
# restart, nicht nur start: bei einer Neuinstallation laeuft der Dienst schon
# und wuerde sonst mit der alten Fassung weiterlaufen.
systemctl --user restart killswitch-indicator.service

echo
echo "Installiert. Zustand:"
"$BIN/killswitch-indicator" status || true
echo
systemctl --user --no-pager --lines=0 status killswitch-indicator.service | head -4
