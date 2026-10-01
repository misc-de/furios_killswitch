#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# Runs without a display and without root. NEVER start it with sudo.
set -uo pipefail

if [ "$(id -u)" = 0 ]; then
    echo "never start run-tests.sh with sudo." >&2
    exit 1
fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROG="$SRC/killswitch-indicator"
UNIT="$SRC/systemd/killswitch-indicator.service"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

check() { # name, expected, actual
    if [ "$2" = "$3" ]; then printf 'PASS  %s\n' "$1"; pass=$((pass+1))
    else printf 'FAIL  %s\n        expected: %s\n        got: %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

# 1-2: both switches free
echo 1 > "$TMP/cam_switch"; echo 1 > "$TMP/nwk_switch"
out="$(FURIOS_KILLSWITCH_BASE=$TMP "$PROG" status)"; rc=$?
check "both free: cam reported as free" "1" "$(grep -c 'cam_switch: free' <<<"$out")"
check "both free: exit code 0" "0" "$rc"

# 3-4: camera engaged
echo 0 > "$TMP/cam_switch"
out="$(FURIOS_KILLSWITCH_BASE=$TMP "$PROG" status)"
check "cam=0 counts as ENGAGED" "1" "$(grep -c 'cam_switch: ENGAGED' <<<"$out")"
check "nwk stays free meanwhile" "1" "$(grep -c 'nwk_switch: free' <<<"$out")"

# 5: a trailing newline must not get in the way (sysfs delivers "0\n")
printf '0\n' > "$TMP/nwk_switch"
check "the trailing newline is cut off" "1" \
    "$(FURIOS_KILLSWITCH_BASE=$TMP "$PROG" status | grep -c 'nwk_switch: ENGAGED')"

# 6-7: a missing sysfs attribute says so instead of keeping quiet
rm -f "$TMP/cam_switch"
out="$(FURIOS_KILLSWITCH_BASE=$TMP "$PROG" status)"; rc=$?
check "a missing attribute is reported" "1" "$(grep -c 'cam_switch: not readable' <<<"$out")"
check "a missing attribute -> exit code 1" "1" "$rc"

# 8: an unknown value is NOT engaged (only exactly "0" engages)
echo x > "$TMP/cam_switch"; echo 1 > "$TMP/nwk_switch"
check "an unexpected value does not count as engaged" "0" \
    "$(FURIOS_KILLSWITCH_BASE=$TMP "$PROG" status | grep -c 'ENGAGED')"

# 9: StartLimit* has to be in [Unit], or the limit never applies
awk '/^\[/{sec=$0} /^StartLimit/{print sec}' "$UNIT" | sort -u > "$TMP/sections"
check "StartLimit* is in [Unit]" "[Unit]" "$(cat "$TMP/sections")"

# 10: the unit must not start something that does not exist
check "ExecStart points at killswitch-indicator" "1" \
    "$(grep -c 'ExecStart=%h/.local/bin/killswitch-indicator run' "$UNIT")"

# 11-12: the icons used have to exist in the theme
for icon in camera-disabled network-cellular-disabled; do
    found=$(find /usr/share/icons -name "${icon}-symbolic.svg" 2>/dev/null | head -1)
    check "icon ${icon}-symbolic present" "yes" "$([ -n "$found" ] && echo yes || echo no)"
done

# 13: install.sh refuses to run as root. It does ask for root for the one
# step that needs it - the plugin goes into phosh's directory - but run as
# root throughout it would install the daemon into root's home.
check "install.sh refuses root" "1" \
    "$(grep -c 'if \[ "$(id -u)" = 0 \]; then' "$SRC/install.sh")"

# 14-16: -v has to work on both sides of the subcommand. That is exactly what
# went wrong: "run -v" died with "unrecognized arguments", the service was
# stopped for the test, and on the phone there was simply no icon to be seen.
echo 1 > "$TMP/cam_switch"; echo 1 > "$TMP/nwk_switch"
FURIOS_KILLSWITCH_BASE=$TMP "$PROG" status -v >/dev/null 2>&1
check "status -v is accepted" "0" "$?"
FURIOS_KILLSWITCH_BASE=$TMP "$PROG" -v status >/dev/null 2>&1
check "-v status is accepted" "0" "$?"
out="$(FURIOS_KILLSWITCH_BASE=$TMP "$PROG" run -v --help 2>&1)"
check "run -v is accepted" "0" "$(grep -c 'unrecognized arguments' <<<"$out")"

# 17-19: the polling interval is adjustable because it IS the reaction time --
# the driver reports nothing by itself (see FINDINGS.md).
check "--interval is offered" "yes" \
    "$("$PROG" --help | grep -q -- '--interval' && echo yes || echo no)"
FURIOS_KILLSWITCH_BASE=$TMP "$PROG" run --interval 0 >/dev/null 2>&1
check "--interval 0 is refused" "2" "$?"
check "the default is 2 s" "1" "$(grep -c '^DEFAULT_INTERVAL_S = 2' "$PROG")"

# 20-22: The microphone threshold against the values actually measured. The
# third switch has NO readable state (see FINDINGS.md). Nobody measures by
# itself here any more (tests 30-33), but `mic-check` by hand is still there --
# and its verdict has to say "free" in doubt, never wrongly "engaged", as long
# as the microphone can hear.
mic_verdict() {
    python3 - "$PROG" "$1" <<'PYEOF'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("ks", sys.argv[1])
spec = importlib.util.spec_from_loader("ks", loader)
mod = importlib.util.module_from_spec(spec); loader.exec_module(mod)
r = mod.classify_microphone(float(sys.argv[2]))
print({True: "engaged", False: "free", None: "unusable"}[r])
PYEOF
}
wrong=0
for value in 2.84 2.85 2.89 2.93 3.14 3.18; do
    [ "$(mic_verdict $value)" = "engaged" ] || wrong=$((wrong+1))
done
check "6 measured engaged values classified correctly" "0" "$wrong"

wrong=0
for value in 6.88 8.72 25.71 25.77 28.85 50.94; do
    [ "$(mic_verdict $value)" = "free" ] || wrong=$((wrong+1))
done
check "6 measured free values classified correctly" "0" "$wrong"

# Digital silence is a failed measurement, not a cut cable.
check "digital silence counts as unusable" "unusable" "$(mic_verdict 0.0)"

# 23-27: What the network switch may switch off as well. The default is
# nothing: a switch that quietly does more than it says is worse than one that
# does too little.
export XDG_CONFIG_HOME="$TMP/config"
# config also enables or disables the user unit - never the real one here.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\necho "$*" >> "%s/systemctl.log"\n' "$TMP" > "$TMP/bin/systemctl"
chmod +x "$TMP/bin/systemctl"
SAVED_PATH=$PATH
export PATH="$TMP/bin:$PATH"
check "default: Wi-Fi is left alone" "no" "$("$PROG" config wifi)"
check "default: Bluetooth is left alone" "no" "$("$PROG" config bluetooth)"
"$PROG" config wifi on >/dev/null
check "switched on and remembered" "yes" "$("$PROG" config wifi)"
check "the neighbouring field stays untouched" "no" "$("$PROG" config bluetooth)"
check "an option switches the daemon on with it" \
    "--user enable --now killswitch-indicator.service" "$(tail -n1 "$TMP/systemctl.log")"
"$PROG" config bluetooth on >/dev/null
"$PROG" config wifi off >/dev/null
check "deselected again" "no" "$("$PROG" config wifi)"
check "one option left keeps the daemon running" \
    "--user enable --now killswitch-indicator.service" "$(tail -n1 "$TMP/systemctl.log")"
"$PROG" config bluetooth off >/dev/null
check "nothing selected stops the daemon" \
    "--user disable --now killswitch-indicator.service" "$(tail -n1 "$TMP/systemctl.log")"
check "reading the options touches no unit" "4" "$(wc -l < "$TMP/systemctl.log")"
export PATH=$SAVED_PATH

# 28: The modem deliberately does NOT appear here - the Android side stops the
# RIL before this program learns of the switch position.
"$PROG" config modem on >/dev/null 2>&1
check "config refuses 'modem'" "2" "$?"

# 29: status --json is the contract with the interface - the fields the app
# reads have to be there, even when nothing was measured.
json="$(FURIOS_KILLSWITCH_BASE=$TMP "$PROG" status --json)"
missing=""
for field in switches network_extras radios we_disabled cameras camera_hal; do
    grep -q "\"$field\"" <<<"$json" || missing="$missing $field"
done
check "status --json has every field the app needs" "" "$missing"

# 30-34: The service does NOT measure. That is a decision, not a gap: telling
# it apart would mean opening the microphone, and the answer holds only for the
# three seconds of the measurement -- flipped while the screen is awake, the
# switch announces itself nowhere. An icon that is sometimes right is worse
# than none. These tests keep away the automation that used to be here (the
# wake-up subscription on logind, the measurement at start and when the other
# switches are flipped).
for gone in start_mic_measurement watch_wakeups on_session_changed mic_image; do
    check "no automation any more: $gone" "0" "$(grep -c "def $gone\|self\.$gone" "$PROG")"
done
check "no wake-up subscription on logind" "0" "$(grep -c 'login1' "$PROG")"

# 35: status --json must not carry a verdict any more -- the app reads none,
# and one left behind would read like a current answer.
check "status --json without a verdict" "0" \
    "$(FURIOS_KILLSWITCH_BASE=$TMP "$PROG" status --json | grep -c '"mic"')"

# 36: a verdict from an older version is cleared away at start.
mkdir -p "$TMP/config/furios-killswitch"
echo '{"we_disabled": [], "mic": {"verdict": "ENGAGED"}}' \
    > "$TMP/config/furios-killswitch/state.json"
python3 - "$PROG" <<'PYEOF2'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("ks", sys.argv[1])
spec = importlib.util.spec_from_loader("ks", loader)
mod = importlib.util.module_from_spec(spec); loader.exec_module(mod)
w = mod.Watcher.__new__(mod.Watcher)
w.forget_stale_mic_state()
PYEOF2
check "an old verdict is forgotten at start" "0" \
    "$(grep -c 'mic' "$TMP/config/furios-killswitch/state.json")"

# 37: measuring by hand stays possible -- only on request.
check "mic-check is still there" "yes" \
    "$("$PROG" --help | grep -q 'mic-check' && echo yes || echo no)"

# 38-41: Nothing here draws any more. The icons were a layer-shell strip of
# our own, and a strip can only pin them a fixed distance from an edge: it
# cannot see how wide phosh's indicators are at that moment, so the battery
# time that appeared beside them ended up underneath them. In the shell's own
# box they are laid out with everything else, and the whole apparatus that
# went with a surface of our own - the empty input region that kept the swipe
# to the quick settings working, the layer, the CSS - goes with it.
for gone in GtkLayerShell input_shape_combine_region Gtk.main "import cairo"; do
    check "no window of our own any more: $gone" "0" "$(grep -c -- "$gone" "$PROG")"
done

# 42-43: The two halves know each other by one name, and it is written down
# once. A mismatch there is silent: the shell says "Custom status-icon '...'
# not found" once, at its start, and carries on without the icons.
id_in_plugin=$(sed -n 's/^Id=//p' "$SRC/phosh-plugin/plugin.in")
id_in_tool=$(sed -n 's/^PLUGIN_ID = "\(.*\)"$/\1/p' "$PROG")
check "the plugin declares a name" "furios-killswitch" "$id_in_plugin"
check "and the tool switches that same name on" "$id_in_plugin" "$id_in_tool"

# 44-46: switching the icons on and off is one command, and both scripts go
# through it rather than editing phosh's list themselves - the list may hold
# somebody else's plugin.
check "icons is offered" "yes" \
    "$("$PROG" --help | grep -q ' icons ' && echo yes || echo no)"
# uninstall.sh does it through `restore`, which takes the icons out with the
# same function `icons off` uses - back to the list recorded before they were
# first switched on.
check "uninstall.sh goes through the tool" "1" \
    "$(grep -c '"$PROG" restore' "$SRC/uninstall.sh")"
check "and edits no list of its own" "0" \
    "$(grep -v '^ *#' "$SRC/uninstall.sh" | grep -c 'gsettings')"
# After an installation everything is off until somebody switches it on.
check "install.sh switches no icons on" "0" \
    "$(grep -v '^ *echo' "$SRC/install.sh" | grep -c 'icons on')"
check "and enables no unit" "0" \
    "$(grep -v '^ *echo' "$SRC/install.sh" | grep -Ec 'systemctl --user (enable|start|restart) ')"

# 47: reading the setting is allowed to answer "no phosh here" - the tests
# run on machines that have none, and must never write the real list.
"$PROG" icons >/dev/null 2>&1
rc=$?
check "icons without an argument only reads" "yes" \
    "$([ "$rc" = 0 ] || [ "$rc" = 1 ] && echo yes || echo no)"

# 48: status --json carries it too, because that is the one call the app makes
check "status --json says whether the icons are on" "1" \
    "$(FURIOS_KILLSWITCH_BASE=$TMP "$PROG" status --json | grep -c '"icons"')"

# 49: the icons the plugin asks for have to exist in the theme, the same way
# the daemon's used to.
missing=""
for icon in camera-disabled network-cellular-disabled; do
    grep -q "\"$icon-symbolic\"" "$SRC/phosh-plugin/killswitch-icons.c" \
        || missing="$missing $icon"
done
check "the plugin names the icons that exist" "" "$missing"

# 50-56: the extra radios, driven with a D-Bus that answers slowly - the way
# NetworkManager does - and a switch that goes down and up again meanwhile.
ks_py() {
    python3 - "$PROG" "$@" <<'PYEOF3'
import importlib.machinery, importlib.util, os, sys, time, threading
loader = importlib.machinery.SourceFileLoader("ks", sys.argv[1])
spec = importlib.util.spec_from_loader("ks", loader)
mod = importlib.util.module_from_spec(spec); loader.exec_module(mod)
radios = {"wifi": True, "bluetooth": True}
def slow_set(radio, enabled):
    time.sleep(0.2)
    radios[radio] = enabled
    return True
mod.radio_state = lambda radio: radios[radio]
mod.set_radio = slow_set
def config(**on):
    c = mod.load_config()
    for radio in mod.RADIOS:
        c.set("network", radio, "yes" if on.get(radio) else "no")
    mod.save_config(c)
def reset():
    radios.update(wifi=True, bluetooth=True)
    mod.save_state({})
case = sys.argv[2]
if case == "down-up":
    config(wifi=True); reset()
    if not hasattr(mod, "queue_network_extras"):
        print("no worker"); sys.exit()
    mod.queue_network_extras(True)
    mod.queue_network_extras(False).join()
    print(radios["wifi"], mod.load_state().get("we_disabled"))
elif case == "option-off":
    config(wifi=True); reset()
    mod.apply_network_extras(True)
    config(wifi=False)
    mod.apply_network_extras(False)
    print(radios["wifi"], mod.load_state().get("we_disabled"))
elif case == "unreadable":
    moves = []
    mod.queue_network_extras = lambda *a: moves.append(a)
    mod.threading.Thread = lambda target, args, **k: type(
        "T", (), {"start": lambda self: moves.append(args)})()
    w = mod.Watcher.__new__(mod.Watcher)
    w.verbose = False
    w.state = {"cam_switch": False, "nwk_switch": True}
    mod.read_switch = lambda name: None
    w.refresh()
    print(len(moves), w.state["nwk_switch"])
elif case == "symlink":
    os.makedirs(mod.CONFIG_DIR, exist_ok=True)
    victim = os.path.join(os.path.dirname(mod.CONFIG_DIR), "victim")
    with open(victim, "w") as fh:
        fh.write("untouched\n")
    try:
        os.unlink(mod.CAMERA_CACHE)
    except OSError:
        pass
    os.symlink(victim, mod.CAMERA_CACHE)
    mod.subprocess.run = lambda *a, **k: type(
        "Out", (), {"stdout": "  Facing: Back\n"})()
    mod.list_cameras(refresh=True)
    print(open(victim).read().strip())
    os.unlink(mod.CAMERA_CACHE)
elif case == "sudo-order":
    calls = []
    real_open = os.open
    os.environ.update(SUDO_UID="4711", SUDO_GID="4712")
    mod.os.geteuid = lambda: 0
    mod.os.seteuid = lambda v: calls.append("euid %d" % v)
    mod.os.setegid = lambda v: calls.append("egid %d" % v)
    def recording_open(path, *a, **k):
        calls.append("open")
        return real_open(path, *a, **k)
    mod.os.open = recording_open
    mod.subprocess.run = lambda *a, **k: type(
        "Out", (), {"stdout": "  Facing: Back\n"})()
    mod.list_cameras(refresh=True)
    print(",".join(calls))
elif case == "bt-bus":
    # What really goes over D-Bus for Bluetooth: phosh's rfkill switch on the
    # session bus, inverted - not bluez's Powered, which the bar never sees.
    # The preamble stubbed set_radio and radio_state - use the real ones.
    mod = importlib.util.module_from_spec(spec); loader.exec_module(mod)
    sent = []
    class Bus:
        def call_sync(self, service, path, _i, method, args, *rest):
            sent.append((service, method, args.unpack()[-1]))
            return (True,)
    mod._radio_bus = lambda radio: Bus()
    mod.set_radio("bluetooth", False)
    state = mod.radio_state("bluetooth")
    print("bluetooth" in mod.SESSION_BUS_RADIOS, sent[0][0], sent[0][2], state)
PYEOF3
}
check "switch down and up while D-Bus is slow: Wi-Fi comes back, nothing left over" \
    "True []" "$(ks_py down-up)"
check "an option switched off meanwhile still gets its radio back" \
    "True []" "$(ks_py option-off)"
check "an unreadable switch is not a move to 'free'" "0 True" "$(ks_py unreadable)"
check "sudo cameras --refresh: a planted symlink is not followed" \
    "untouched" "$(ks_py symlink)"
check "sudo cameras --refresh: writes as the user, and gives root back after" \
    "egid 4712,euid 4711,open,euid 0,egid 0" "$(ks_py sudo-order)"
check "Bluetooth goes through phosh's rfkill switch, inverted" \
    "True org.gnome.SettingsDaemon.Rfkill True False" "$(ks_py bt-bus)"
check "mic-check speaks English" "0" "$(grep -c 'Fehlmessung' "$PROG")"

# The plugin's own suite: built and loaded the way phosh loads it, then driven
# through a directory of switch files. It needs phosh's headers and a display,
# and says so rather than failing when either is missing.
echo
echo "== the icons (phosh plugin)"
if ! pkg-config --exists phosh-plugins gtk+-3.0 2>/dev/null; then
    echo "SKIP  no phosh-plugins/gtk+-3.0 (apt install phosh-dev libgtk-3-dev)"
elif ! make -C "$SRC/phosh-plugin" all tests/plugin-loads >/dev/null; then
    echo "FAIL  the plugin does not build"; fail=$((fail+1))
else
    # GDK looks for the Wayland socket under XDG_RUNTIME_DIR; an absolute
    # WAYLAND_DISPLAY is read as the socket itself.
    if [ -n "${WAYLAND_DISPLAY:-}" ] && [ "${WAYLAND_DISPLAY#/}" = "${WAYLAND_DISPLAY}" ]; then
        export WAYLAND_DISPLAY="${XDG_RUNTIME_DIR:-/nonexistent}/$WAYLAND_DISPLAY"
    fi
    "$SRC/phosh-plugin/tests/plugin-loads" "$SRC/phosh-plugin"
    rc=$?
    if [ "$rc" -eq 77 ]; then
        :   # the test says what it is missing, and it is not a failure
    elif [ "$rc" -ne 0 ]; then
        fail=$((fail+1))
    else
        pass=$((pass+1))
    fi
fi

# furios-nwk-mask: while its file exists the network slider is ignored -
# reported as such, never as engaged, and the extra radios are not touched.
mkdir -p "$TMP/mask"; printf '0\n' > "$TMP/nwk_switch"; printf '1\n' > "$TMP/mask/nwk_switch"
out="$(FURIOS_KILLSWITCH_BASE=$TMP FURIOS_NWK_MASK_DIR=$TMP/mask "$PROG" status)"
check "masked slider reads as ignored" "1" "$(grep -c 'nwk_switch: ignored' <<<"$out")"
check "masked slider is never ENGAGED" "0" "$(grep -c 'nwk_switch: ENGAGED' <<<"$out")"
check "status --json says it is ignored" "1" \
    "$(FURIOS_KILLSWITCH_BASE=$TMP FURIOS_NWK_MASK_DIR=$TMP/mask "$PROG" status --json \
       | grep -c '"network_switch_ignored": true')"
check "without the file the slider counts again" "1" \
    "$(FURIOS_KILLSWITCH_BASE=$TMP FURIOS_NWK_MASK_DIR=$TMP/none "$PROG" status | grep -c 'nwk_switch: ENGAGED')"
check "the mask unit stops through release" "1" \
    "$(grep -c '^ExecStopPost=/usr/local/sbin/furios-nwk-mask release' "$SRC/systemd/furios-nwk-mask.service")"
check "the mask unit is never enabled by install.sh" "0" \
    "$(grep -c 'enable.*furios-nwk-mask' "$SRC/install.sh")"
check "furios-nwk-mask parses" "0" "$(sh -n "$SRC/furios-nwk-mask"; echo $?)"
printf '1\n' > "$TMP/nwk_switch"

# The invariant between install.sh and uninstall.sh, in a sandbox of its own:
# see the file for what is stubbed and why.
echo
echo "== install.sh, then uninstall.sh"
if bash "$SRC/tests/test-uninstall.sh"; then pass=$((pass+1)); else fail=$((fail+1)); fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
