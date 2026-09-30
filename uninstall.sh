#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# Takes out both halves: the daemon from the home, the icons from phosh's
# plugin directory and from the setting that lists them - and what the daemon
# wrote and changed while it ran. Afterwards a fresh install.sh finds the
# phone as it finds a new one. Run WITHOUT sudo.
set -uo pipefail

if [ "$(id -u)" = 0 ]; then
    echo "Please run WITHOUT sudo." >&2
    exit 1
fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

UNIT="$HOME/.config/systemd/user"

systemctl --user disable --now killswitch-indicator.service 2>/dev/null || true
# The enable link by hand as well: without a user manager to talk to (an ssh
# login) "disable" fails, and a link left in gnome-session.target.wants would
# be an enabled daemon again the moment a fresh install puts the unit back.
rm -f "$UNIT"/*.wants/killswitch-indicator.service

# With the daemon stopped: the radios it switched off with the network switch
# come back on, and its config directory goes - options, state, camera cache,
# and the temporary siblings (state.json.new, state.json.neu from before the
# rename). Through the checkout's copy, which is there even when the
# installed one is not.
"$SRC/killswitch-indicator" restore || true
rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/furios-killswitch"

rm -f "$HOME/.local/bin/killswitch-indicator" \
      "$HOME"/.local/bin/__pycache__/killswitch-indicatorcpython-*.pyc
rmdir "$HOME/.local/bin/__pycache__" 2>/dev/null || true
rm -f "$UNIT/killswitch-indicator.service"
rm -rf "$HOME/.local/share/doc/killswitch-indicator"
systemctl --user daemon-reload 2>/dev/null || true

# The list first, through the tool, and only our own entry in it: a shell that
# goes on being told to load a plugin which is no longer there logs a warning
# on every start, and somebody else's plugin in the same list is none of our
# business. This is also what makes the icons go now - the shell follows that
# list while it runs. Once our entry is out and the list is phosh's default
# again, the key is reset rather than kept as a copy of it.
"$SRC/killswitch-indicator" icons off || true

if pkg-config --exists phosh-plugins 2>/dev/null; then
    sudo make -C "$SRC/phosh-plugin" uninstall
fi

echo "Removed."
