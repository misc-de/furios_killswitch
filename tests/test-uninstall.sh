#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# The invariant: after install.sh, everything switched on, and uninstall.sh,
# the home, phosh's plugin directory and phosh's settings are what they were
# before install.sh. Anything install.sh or the daemon writes that
# uninstall.sh does not take away shows up here as a path or a key - without
# this test knowing which paths those are.
#
# Everything runs in a sandbox of its own:
#   - a home of its own, and a runtime directory;
#   - systemctl is a stub that makes and removes the enable links the way the
#     real one does, and fails like it when there is no user manager;
#   - sudo is a stub that runs only "make ... install|uninstall", and that with
#     DESTDIR pointing into the sandbox - so the plugin's real Makefile is what
#     is checked, not a copy of its paths;
#   - gsettings (the command and GIO in the daemon alike) writes a key file in
#     the sandbox instead of dconf: GSETTINGS_BACKEND=keyfile.
# Nothing reaches the phone's units, its shell, its settings or its radios.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(dirname "$HERE")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
REAL_PATH=$PATH
pass=0; fail=0

check() { # name, expected, actual
    if [ "$2" = "$3" ]; then printf 'PASS  %s\n' "$1"; pass=$((pass+1))
    else printf 'FAIL  %s\n        expected: %s\n        got: %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

missing=
for tool in cc make gsettings; do command -v "$tool" >/dev/null || missing="$missing $tool"; done
pkg-config --exists phosh-plugins gtk+-3.0 2>/dev/null || missing="$missing phosh-dev"
gsettings list-schemas 2>/dev/null | grep -qx mobi.phosh.shell.plugins || missing="$missing phosh-schemas"
if [ -n "$missing" ]; then
    echo "SKIP  install.sh cannot run here, missing:$missing"
    exit 0
fi

mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$SANDBOX/systemctl.log"
if [ "${SANDBOX_NO_BUS:-}" = 1 ]; then
    echo "Failed to connect to bus: No medium found" >&2; exit 1
fi
user=; verb=; units=()
for a; do
    case $a in
        --user) user=1 ;;
        -*) ;;
        *) if [ -z "$verb" ]; then verb=$a; else units+=("$a"); fi ;;
    esac
done
[ -n "$user" ] || { echo "no system manager in the sandbox" >&2; exit 1; }
dir=$HOME/.config/systemd/user
case $verb in
    enable|disable)
        for u in "${units[@]}"; do
            [ -f "$dir/$u" ] || { echo "Unit file $u does not exist." >&2; exit 1; }
            if [ "$verb" = enable ]; then
                for t in $(sed -n 's/^WantedBy=//p' "$dir/$u"); do
                    mkdir -p "$dir/$t.wants"
                    ln -sf "$dir/$u" "$dir/$t.wants/$u"
                done
            else
                rm -f "$dir"/*.wants/"$u"
            fi
        done ;;
    is-enabled) for u in "${units[@]}"; do ls "$dir"/*.wants/"$u" >/dev/null 2>&1 || exit 1; done ;;
    is-active) exit 3 ;;
esac
exit 0
STUB
cat > "$TMP/bin/sudo" <<'STUB'
#!/bin/bash
echo "$*" >> "$SANDBOX/sudo.log"
if [ "$1" = make ]; then
    shift
    exec make DESTDIR="$SANDBOX/root" "$@"
fi
echo "sudo: only make runs in the sandbox" >&2
exit 1
STUB
chmod +x "$TMP/bin/systemctl" "$TMP/bin/sudo"

# Files and links with their content, and every directory but the generic
# parents install -d makes along the way. The settings key file is looked at
# on its own.
snapshot() {
    (cd "$SANDBOX" || exit 1
     find home run root -path home/.config/glib-2.0 -prune -o -type f -exec md5sum {} + | sort -k2
     find home run root -type l -printf 'link %p -> %l\n' | sort
     find home run root -mindepth 1 -type d -printf 'dir %p\n' | sort \
        | grep -vxE 'dir home/\.local(/bin|/share(/doc)?)?|dir home/\.config(/systemd(/user(/[^/]+\.wants)?)?|/glib-2\.0.*)?|dir root/.*')
}

scenario() {
    # scenario <name> <1 = uninstall without a user manager>
    SANDBOX=$TMP/$(echo "$1" | tr -c 'a-z0-9\n' '-')
    export SANDBOX
    mkdir -p "$SANDBOX/home" "$SANDBOX/run" "$SANDBOX/root"
    local before after keys
    before=$(snapshot)
    (
        export HOME=$SANDBOX/home XDG_RUNTIME_DIR=$SANDBOX/run GSETTINGS_BACKEND=keyfile
        unset XDG_CONFIG_HOME XDG_DATA_HOME SUDO_USER DBUS_SESSION_BUS_ADDRESS
        unset FURIOS_KILLSWITCH_BASE
        export PATH=$TMP/bin:$REAL_PATH
        bash "$SRC/install.sh" >/dev/null 2>&1 || echo "install.sh failed" >&2
        # Everything somebody can switch on, and what the daemon leaves while
        # it runs (it is not started: it would switch radios).
        "$HOME/.local/bin/killswitch-indicator" icons on >/dev/null 2>&1
        systemctl --user enable --now killswitch-indicator.service
        "$HOME/.local/bin/killswitch-indicator" config wifi on >/dev/null 2>&1
        cfg=$HOME/.config/furios-killswitch
        echo '{"we_disabled": []}' > "$cfg/state.json"
        echo '{}' > "$cfg/state.json.new"; echo '{}' > "$cfg/state.json.neu"
        echo '["Back", "Front"]' > "$cfg/cameras.json"
        mkdir -p "$HOME/.local/bin/__pycache__"
        : > "$HOME/.local/bin/__pycache__/killswitch-indicatorcpython-313.pyc"
        grep -c furios-killswitch "$HOME/.config/glib-2.0/settings/keyfile" \
            > "$SANDBOX/listed" 2>/dev/null
        find "$SANDBOX/root" -type f | wc -l > "$SANDBOX/plugin-files"
        SANDBOX_NO_BUS=$2 bash "$SRC/uninstall.sh" >/dev/null 2>&1 \
            || echo "uninstall.sh failed" >&2
    )
    after=$(snapshot)
    check "$1: the icons were listed while installed" "1" "$(cat "$SANDBOX/listed")"
    check "$1: the plugin (.so and .plugin) went into phosh's directory" "2" \
        "$(cat "$SANDBOX/plugin-files")"
    check "$1: everything is as before install.sh" "" \
        "$(diff <(echo "$before") <(echo "$after") | grep '^[<>]')"
    keys=$(grep -v '^\[' "$SANDBOX/home/.config/glib-2.0/settings/keyfile" 2>/dev/null | grep .)
    check "$1: no setting left changed (reset, not a copy of the default)" "" "$keys"
    check "$1: root only for make install/uninstall" "" \
        "$(grep -vE '^make -C .*phosh-plugin (install|uninstall)$' "$SANDBOX/sudo.log")"
}

scenario "with a user manager" ""
scenario "without a user manager (ssh)" 1

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
