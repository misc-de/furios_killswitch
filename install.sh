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

# Was das Symbol zum Leben braucht. Geprueft, BEVOR etwas installiert wird:
# ohne GtkLayerShell startet der Dienst zwar, zeichnet aber nie etwas - und
# ein Programm, das sauber installiert wurde und stumm nichts tut, ist
# schwerer zu verstehen als eines, das gar nicht erst einzieht. Auf FuriOS
# bringt phosh diese Pakete selbst mit, hier feuert das also nie; auf einem
# Telefon ohne sie ist der fehlende Name die ganze Auskunft.
if ! python3 - <<'PRUEFUNG' 2>/dev/null
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("GtkLayerShell", "0.1")
from gi.repository import Gtk, GtkLayerShell  # noqa: F401
PRUEFUNG
then
    echo "Fehlt: python3-gi, gir1.2-gtk-3.0 oder gir1.2-gtklayershell-0.1." >&2
    echo "Ohne die zeichnet das Symbol nichts - nichts wurde installiert." >&2
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
