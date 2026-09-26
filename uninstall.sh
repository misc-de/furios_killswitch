#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# Takes out both halves: the daemon from the home, the icons from phosh's
# plugin directory and from the setting that lists them. Run WITHOUT sudo.
set -uo pipefail

if [ "$(id -u)" = 0 ]; then
    echo "Please run WITHOUT sudo." >&2
    exit 1
fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

systemctl --user disable --now killswitch-indicator.service 2>/dev/null || true
rm -f "$HOME/.local/bin/killswitch-indicator"
rm -f "$HOME/.config/systemd/user/killswitch-indicator.service"
rm -rf "$HOME/.local/share/doc/killswitch-indicator"
systemctl --user daemon-reload

# The list first, through the tool, and only our own entry in it: a shell that
# goes on being told to load a plugin which is no longer there logs a warning
# on every start, and somebody else's plugin in the same list is none of our
# business. This is also what makes the icons go now - the shell follows that
# list while it runs.
"$SRC/killswitch-indicator" icons off || true

if pkg-config --exists phosh-plugins 2>/dev/null; then
    sudo make -C "$SRC/phosh-plugin" uninstall
fi

echo "Removed."
