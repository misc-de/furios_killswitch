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

# 13: install.sh refuses to run as root
out="$(echo | sudo -n true 2>/dev/null; grep -c 'WITHOUT sudo' "$SRC/install.sh")"
check "install.sh refuses root" "1" "$out"

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
check "default: Wi-Fi is left alone" "no" "$("$PROG" config wifi)"
check "default: Bluetooth is left alone" "no" "$("$PROG" config bluetooth)"
"$PROG" config wifi on >/dev/null
check "switched on and remembered" "yes" "$("$PROG" config wifi)"
check "the neighbouring field stays untouched" "no" "$("$PROG" config bluetooth)"
"$PROG" config wifi off >/dev/null
check "deselected again" "no" "$("$PROG" config wifi)"

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
ind = mod.Indicator.__new__(mod.Indicator)
ind.forget_stale_mic_state()
PYEOF2
check "an old verdict is forgotten at start" "0" \
    "$(grep -c 'mic' "$TMP/config/furios-killswitch/state.json")"

# 37: measuring by hand stays possible -- only on request.
check "mic-check is still there" "yes" \
    "$("$PROG" --help | grep -q 'mic-check' && echo yes || echo no)"

# 38-40: The empty input region, and the one place where it arrives. Set from
# "realize" it does NOTHING: gtk-layer-shell swaps the surface between realize
# and map for a layer surface, and GDK only sends the region to the compositor
# while drawing. Measured on the device on 15.09.2026 with WAYLAND_DEBUG=1 --
# the strip went up with set_input_region(nil) and swallowed the swipe to the
# quick settings across the whole width of the bar.
check "input region not from realize" "0" \
    "$(grep -c 'connect("realize"' "$PROG")"
check "input region while drawing" "1" \
    "$(grep -c 'def on_draw' "$PROG")"
check "an empty region, nothing else" "1" \
    "$(grep -c 'input_shape_combine_region(self.cairo.Region(), 0, 0)' "$PROG")"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
