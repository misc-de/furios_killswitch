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
# "What they were" is what was recorded before the first change, not what a
# new phone probably has: a plugin list with no value in dconf comes back
# with none, a value comes back as that value (even the default one), a list
# changed after ours keeps that change, a reinstall keeps the first record,
# and without a record the uninstall says it is guessing.
#
# Everything runs in a sandbox of its own:
#   - a home of its own, and a runtime directory;
#   - systemctl is a stub that makes and removes the enable links the way the
#     real one does, and fails like it when there is no user manager;
#   - sudo is a stub that runs only "make ... install|uninstall", with
#     DESTDIR pointing into the sandbox - so the plugin's real Makefile is what
#     is checked, not a copy of its paths - and rmdir inside the sandbox;
#   - gsettings (the command and GIO in the daemon alike) writes a key file in
#     the sandbox instead of dconf: GSETTINGS_BACKEND=keyfile, with phosh's
#     plugin schema compiled into the sandbox.
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
for tool in cc make gsettings glib-compile-schemas; do command -v "$tool" >/dev/null || missing="$missing $tool"; done
pkg-config --exists phosh-plugins gtk+-3.0 2>/dev/null || missing="$missing phosh-dev"
python3 -c 'import gi' 2>/dev/null || missing="$missing python3-gi"
if [ -n "$missing" ]; then
    echo "SKIP  install.sh cannot run here, missing:$missing"
    exit 0
fi

mkdir -p "$TMP/bin" "$TMP/schemas"
cat > "$TMP/schemas/mobi.phosh.shell.plugins.gschema.xml" <<'XML'
<schemalist>
  <schema id="mobi.phosh.shell.plugins" path="/mobi/phosh/shell/plugins/">
    <key name="status-icons" type="as"><default>[]</default></key>
  </schema>
</schemalist>
XML
glib-compile-schemas "$TMP/schemas"
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
    # As the real one: prints the unit, and exits 3 while it is not running.
    status) echo "o killswitch-indicator.service"; exit 3 ;;
esac
exit 0
STUB
cat > "$TMP/bin/sudo" <<'STUB'
#!/bin/bash
echo "$*" >> "$SANDBOX/sudo.log"
if [ "$1" = make ]; then
    shift
    exec make "$@" DESTDIR="$SANDBOX/root"
fi
if [ "$1" = rmdir ]; then
    for a in "${@:2}"; do
        case $a in -*) ;; "$SANDBOX"/*) ;; *) echo "sudo: rmdir outside the sandbox: $a" >&2; exit 1 ;; esac
    done
    exec "$@"
fi
echo "sudo: only make and rmdir run in the sandbox" >&2
exit 1
STUB
chmod +x "$TMP/bin/systemctl" "$TMP/bin/sudo"

# Files and links with their content, and every directory - the ones
# install -d and make install create along the way included: those that were
# missing before go again. The settings' key file is looked at on its own.
snapshot() {
    (cd "$SANDBOX" || exit 1
     find home run root -path home/.config/glib-2.0 -prune -o -type f -exec md5sum {} + | sort -k2
     find home run root -type l -printf 'link %p -> %l\n' | sort
     find home run root -mindepth 1 -path home/.config/glib-2.0 -prune -o -type d -printf 'dir %p\n' | sort)
}

# What dconf would hold for the plugin list: the key's line in the key file,
# or nothing when it has no value - which is not the same as the default.
stored() { grep '^status-icons=' "$SANDBOX/home/.config/glib-2.0/settings/keyfile" 2>/dev/null; }

sandbox_env() {
    export HOME=$SANDBOX/home XDG_RUNTIME_DIR=$SANDBOX/run GSETTINGS_BACKEND=keyfile
    export GSETTINGS_SCHEMA_DIR=$TMP/schemas DESTDIR=$SANDBOX/root
    unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME SUDO_USER DBUS_SESSION_BUS_ADDRESS
    unset FURIOS_KILLSWITCH_BASE
    export PATH=$TMP/bin:$REAL_PATH
}
gs() { (sandbox_env; gsettings "$1" mobi.phosh.shell.plugins status-icons "${@:2}"); }

new_sandbox() {
    SANDBOX=$TMP/$(echo "$1" | tr -c 'a-z0-9\n' '-')
    export SANDBOX
    mkdir -p "$SANDBOX/home/.config/glib-2.0/settings" "$SANDBOX/run" "$SANDBOX/root"
}

scenario() {
    # scenario <name> <1 = uninstall without a user manager>
    new_sandbox "$1"
    local before after keys
    before=$(snapshot)
    (
        sandbox_env
        bash "$SRC/install.sh" >/dev/null 2>&1
        echo $? > "$SANDBOX/install-rc"
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
    # The app takes a non-zero exit for a failed install and shows the whole
    # output as an error - found on 30.9.2026 on a fresh phone.
    check "$1: install.sh succeeds with the daemon not running" "0" \
        "$(cat "$SANDBOX/install-rc")"
    check "$1: the icons were listed while installed" "1" "$(cat "$SANDBOX/listed")"
    check "$1: the plugin (.so and .plugin) went into phosh's directory" "2" \
        "$(cat "$SANDBOX/plugin-files")"
    check "$1: everything is as before install.sh" "" \
        "$(diff <(echo "$before") <(echo "$after") | grep '^[<>]')"
    keys=$(grep -v '^\[' "$SANDBOX/home/.config/glib-2.0/settings/keyfile" 2>/dev/null | grep .)
    check "$1: no setting left changed (reset, not a copy of the default)" "" "$keys"
    check "$1: root only for make install/uninstall and rmdir" "" \
        "$(grep -vE '^make -C .*phosh-plugin (install|uninstall)( |$)|^rmdir ' "$SANDBOX/sudo.log")"
}

scenario "with a user manager" ""
scenario "without a user manager (ssh)" 1

# The same round trip for the cases where "as before" is not "as on a new
# phone". $1 name, $2 a hook run between `icons on` and uninstall.sh (in the
# sandbox's environment). Output of uninstall.sh lands in $SANDBOX/out.
round_trip() {
    (
        sandbox_env
        bash "$SRC/install.sh" >/dev/null 2>&1 || echo "install.sh failed" >&2
        "$HOME/.local/bin/killswitch-indicator" icons on >/dev/null 2>&1
        systemctl --user enable killswitch-indicator.service
        eval "$1"
        bash "$SRC/uninstall.sh" > "$SANDBOX/out" 2>&1 || echo "uninstall.sh failed" >&2
    )
}

# The default written on purpose: pinned before, pinned after - reset, it
# would follow whatever a later phosh ships.
new_sandbox "pinned default"
gs set "@as []"
pinned=$(stored); before=$(snapshot)
round_trip ""
check "pinned default: the key had a value before" yes "$([ -n "$pinned" ] && echo yes || echo no)"
check "pinned default: and has the same after" "$pinned" "$(stored)"
check "pinned default: everything else as before" "" \
    "$(diff <(echo "$before") <(snapshot) | grep '^[<>]')"

# A list of somebody's own: exactly that back, in its order.
new_sandbox "own list"
gs set "['wifi-hotspot', 'furios-battery-time']"
round_trip ""
check "own list: back as it was" "['wifi-hotspot', 'furios-battery-time']" "$(gs get)"

# Changed after us: their plugin stays, ours goes, and that is said.
new_sandbox "changed since"
export CHANGED="['furios-killswitch', 'caffeine']"
round_trip 'gsettings set mobi.phosh.shell.plugins status-icons "$CHANGED"'
check "changed since: their plugin stays, ours goes" "['caffeine']" "$(gs get)"
check "changed since: and that is said" yes \
    "$(grep -q 'changed since' "$SANDBOX/out" && echo yes || echo no)"

# A reinstall, and the icons off and on again, keep the first record.
new_sandbox "reinstall"
before=$(snapshot)
round_trip '
    rec=$HOME/.local/state/furios-killswitch/original.json
    md5sum < "$rec" > "$SANDBOX/first"
    bash "$SRC/install.sh" >/dev/null 2>&1
    "$HOME/.local/bin/killswitch-indicator" icons off >/dev/null 2>&1
    "$HOME/.local/bin/killswitch-indicator" icons on >/dev/null 2>&1
    md5sum < "$rec" > "$SANDBOX/second"'
check "reinstall: the record is not taken again" "$(cat "$SANDBOX/first")" "$(cat "$SANDBOX/second")"
check "reinstall: back to no value" "" "$(stored)"
check "reinstall: everything as before" "" "$(diff <(echo "$before") <(snapshot) | grep '^[<>]')"
check "reinstall: no talk of a missing record" no \
    "$(grep -qi 'no record\|no full record' "$SANDBOX/out" && echo yes || echo no)"

# No record (switched on by a version that kept none): the old behaviour,
# and the uninstall says it is guessing.
new_sandbox "no record"
round_trip 'rm -rf "$HOME/.local/state/furios-killswitch"'
check "no record: says so" yes "$(grep -qi 'no record' "$SANDBOX/out" && echo yes || echo no)"
check "no record: the default list is reset as before" "" "$(stored)"

# Directories that were there stay, even empty; the ones that were missing go.
new_sandbox "lived in"
plugin_dir=$(pkg-config --variable=status_icons_plugins_dir phosh-plugins)
mkdir -p "$SANDBOX/root$plugin_dir" "$SANDBOX/home/.local/bin" "$SANDBOX/home/.config/systemd/user"
before=$(snapshot)
round_trip ""
check "lived in: empty directories that were there are kept" "" \
    "$(diff <(echo "$before") <(snapshot) | grep '^[<>]')"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
