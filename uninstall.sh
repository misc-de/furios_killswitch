#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# Takes out both halves: the daemon from the home, the icons from phosh's
# plugin directory and from the setting that lists them - and what the daemon
# wrote and changed while it ran. Afterwards the phone is what it was before
# the first install.sh: not what a new phone probably has, but what was
# recorded before the first change (`killswitch-indicator original status`
# shows the record; see "The original state" in killswitch-indicator).
# Run WITHOUT sudo.
#
# DESTDIR, as in make: a staged root instead of /, for the tests.
set -uo pipefail

if [ "$(id -u)" = 0 ]; then
    echo "Please run WITHOUT sudo." >&2
    exit 1
fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROG="$SRC/killswitch-indicator"
DESTDIR=${DESTDIR:-}

UNIT="$HOME/.config/systemd/user"

systemctl --user disable --now killswitch-indicator.service 2>/dev/null || true
# The enable link by hand as well: without a user manager to talk to (an ssh
# login) "disable" fails, and a link left in gnome-session.target.wants would
# be an enabled daemon again the moment a fresh install puts the unit back.
# Before the first install the unit did not exist, so it cannot have been
# enabled - the record says so, and there is nothing to enable again.
rm -f "$UNIT"/*.wants/killswitch-indicator.service

# With the daemon stopped, through the checkout's copy (which is there even
# when the installed one is not):
#   - phosh's plugin list back to what it was before the icons were first
#     switched on - no value in dconf when it had none, the value when it had
#     one. The shell follows that list while it runs, so the icons go now. A
#     list somebody changed since keeps their change; only our entry comes
#     out, and that is said. Without a record it compares with phosh's
#     default, as it always did, and says it is guessing;
#   - the radios it switched off with the network switch back on;
#   - its config directory: options, state, camera cache, and the temporary
#     siblings (state.json.new, state.json.neu from before the rename).
"$PROG" restore || true
rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/furios-killswitch"

rm -f "$HOME/.local/bin/killswitch-indicator" \
      "$HOME"/.local/bin/__pycache__/killswitch-indicatorcpython-*.pyc
rmdir "$HOME/.local/bin/__pycache__" 2>/dev/null || true
rm -f "$UNIT/killswitch-indicator.service"
rm -rf "$HOME/.local/share/doc/killswitch-indicator"
systemctl --user daemon-reload 2>/dev/null || true

# Where make put the plugin. pkg-config only knows while phosh-dev is
# installed; without it the plugin directory is found by our file in it.
PLUGIN_DIR=$(pkg-config --variable=status_icons_plugins_dir phosh-plugins 2>/dev/null) \
    || PLUGIN_DIR=
if [ -z "$PLUGIN_DIR" ]; then
    for d in "$DESTDIR"/usr/lib/*/phosh/plugins; do
        [ -e "$d/furios-killswitch.plugin" ] && PLUGIN_DIR=${d#"$DESTDIR"}
    done
fi
if [ -n "$PLUGIN_DIR" ]; then
    sudo make -C "$SRC/phosh-plugin" uninstall PLUGIN_DIR="$PLUGIN_DIR" DESTDIR="$DESTDIR"
fi

# The directories that were missing before the first install - in the
# system (phosh's plugin directory, should an install have had to make it)
# and in the home (~/.local/bin, ~/.config/systemd/user, the enable link's
# gnome-session.target.wants, ...) - go again, deepest first and only while
# empty. Whatever somebody put there since keeps them, and a directory that
# was there before stays, empty or not. A record taken over an install from
# before records were kept still knows which directories were missing then;
# what it cannot know is which of the others that install made, and those
# stay, as they always did.
if DESTDIR="$DESTDIR" "$PROG" original legacy; then
    echo "No full record of what the phone had before the first install (an"
    echo "install from before records were kept): directories that were already"
    echo "there are left, as before."
fi
while read -r d; do
    [ -n "$d" ] && { sudo rmdir "$DESTDIR$d" 2>/dev/null || true; }
done < <(DESTDIR="$DESTDIR" "$PROG" original system-dirs)
# Last, the home's directories and the record itself.
"$PROG" original finish

echo "Removed."
