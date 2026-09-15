#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# Runs without a display and without root. NIE mit sudo starten.
set -uo pipefail

if [ "$(id -u)" = 0 ]; then
    echo "run-tests.sh niemals mit sudo starten." >&2
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
    else printf 'FAIL  %s\n        erwartet: %s\n        erhalten: %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

# 1-2: beide Schalter frei
echo 1 > "$TMP/cam_switch"; echo 1 > "$TMP/nwk_switch"
out="$(FURIOS_KILLSWITCH_BASE=$TMP "$PROG" status)"; rc=$?
check "beide frei: cam als frei gemeldet" "1" "$(grep -c 'cam_switch: frei' <<<"$out")"
check "beide frei: Rueckgabewert 0" "0" "$rc"

# 3-4: Kamera gesperrt
echo 0 > "$TMP/cam_switch"
out="$(FURIOS_KILLSWITCH_BASE=$TMP "$PROG" status)"
check "cam=0 gilt als GESPERRT" "1" "$(grep -c 'cam_switch: GESPERRT' <<<"$out")"
check "nwk bleibt dabei frei" "1" "$(grep -c 'nwk_switch: frei' <<<"$out")"

# 5: nachlaufendes Leerzeichen/Zeilenende darf nicht stoeren (sysfs liefert "0\n")
printf '0\n' > "$TMP/nwk_switch"
check "Zeilenende wird abgeschnitten" "1" \
    "$(FURIOS_KILLSWITCH_BASE=$TMP "$PROG" status | grep -c 'nwk_switch: GESPERRT')"

# 6-7: fehlendes sysfs meldet sich, statt still zu schweigen
rm -f "$TMP/cam_switch"
out="$(FURIOS_KILLSWITCH_BASE=$TMP "$PROG" status)"; rc=$?
check "fehlendes Attribut wird gemeldet" "1" "$(grep -c 'cam_switch: nicht lesbar' <<<"$out")"
check "fehlendes Attribut -> Rueckgabewert 1" "1" "$rc"

# 8: unbekannter Wert ist NICHT gesperrt (nur exakt "0" sperrt)
echo x > "$TMP/cam_switch"; echo 1 > "$TMP/nwk_switch"
check "unerwarteter Wert gilt nicht als gesperrt" "0" \
    "$(FURIOS_KILLSWITCH_BASE=$TMP "$PROG" status | grep -c 'GESPERRT')"

# 9: StartLimit* muss in [Unit] stehen, sonst greift die Grenze nie
awk '/^\[/{sec=$0} /^StartLimit/{print sec}' "$UNIT" | sort -u > "$TMP/sections"
check "StartLimit* steht in [Unit]" "[Unit]" "$(cat "$TMP/sections")"

# 10: die Unit darf nichts starten, was es nicht gibt
check "ExecStart zeigt auf killswitch-indicator" "1" \
    "$(grep -c 'ExecStart=%h/.local/bin/killswitch-indicator run' "$UNIT")"

# 11-12: die verwendeten Symbole muessen im Theme wirklich existieren
for icon in camera-disabled network-cellular-disabled; do
    found=$(find /usr/share/icons -name "${icon}-symbolic.svg" 2>/dev/null | head -1)
    check "Symbol ${icon}-symbolic vorhanden" "ja" "$([ -n "$found" ] && echo ja || echo nein)"
done

# 13: install.sh weigert sich als root
out="$(echo | sudo -n true 2>/dev/null; grep -c 'Bitte OHNE sudo' "$SRC/install.sh")"
check "install.sh lehnt root ab" "1" "$out"

# 14-16: -v muss auf beiden Seiten des Unterbefehls funktionieren. Genau das
# ging schief: "run -v" brach mit "unrecognized arguments" ab, der Dienst war
# fuer den Test gestoppt, und am Telefon war schlicht kein Symbol zu sehen.
echo 1 > "$TMP/cam_switch"; echo 1 > "$TMP/nwk_switch"
FURIOS_KILLSWITCH_BASE=$TMP "$PROG" status -v >/dev/null 2>&1
check "status -v wird angenommen" "0" "$?"
FURIOS_KILLSWITCH_BASE=$TMP "$PROG" -v status >/dev/null 2>&1
check "-v status wird angenommen" "0" "$?"
out="$(FURIOS_KILLSWITCH_BASE=$TMP "$PROG" run -v --help 2>&1)"
check "run -v wird angenommen" "0" "$(grep -c 'unrecognized arguments' <<<"$out")"

# 17-19: das Pruefintervall ist einstellbar, weil es die Reaktionszeit IST --
# der Treiber meldet nichts von selbst (siehe FINDINGS.md).
check "--interval wird angeboten" "ja" \
    "$("$PROG" --help | grep -q -- '--interval' && echo ja || echo nein)"
FURIOS_KILLSWITCH_BASE=$TMP "$PROG" run --interval 0 >/dev/null 2>&1
check "--interval 0 wird abgelehnt" "2" "$?"
check "Vorgabe steht auf 2 s" "1" "$(grep -c '^DEFAULT_INTERVAL_S = 2' "$PROG")"

# 20-22: Die Mikrofon-Schwelle gegen die tatsaechlich gemessenen Werte. Der
# dritte Schalter hat KEINEN auslesbaren Zustand (siehe FINDINGS.md). Von
# selbst misst hier niemand mehr (Tests 30-33), aber `mic-check` von Hand gibt
# es weiter -- und dessen Einstufung muss im Zweifel "frei" sagen, niemals
# faelschlich "gesperrt", solange das Mikrofon hoeren kann.
mic_urteil() {
    python3 - "$PROG" "$1" <<'PYEOF'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("ks", sys.argv[1])
spec = importlib.util.spec_from_loader("ks", loader)
mod = importlib.util.module_from_spec(spec); loader.exec_module(mod)
r = mod.classify_microphone(float(sys.argv[2]))
print({True: "gesperrt", False: "frei", None: "unbrauchbar"}[r])
PYEOF
}
falsch=0
for wert in 2.84 2.85 2.89 2.93 3.14 3.18; do
    [ "$(mic_urteil $wert)" = "gesperrt" ] || falsch=$((falsch+1))
done
check "6 gemessene gesperrt-Werte richtig eingestuft" "0" "$falsch"

falsch=0
for wert in 6.88 8.72 25.71 25.77 28.85 50.94; do
    [ "$(mic_urteil $wert)" = "frei" ] || falsch=$((falsch+1))
done
check "6 gemessene frei-Werte richtig eingestuft" "0" "$falsch"

# Digitale Stille ist ein Messfehler, kein gekapptes Kabel.
check "digitale Stille gilt als unbrauchbar" "unbrauchbar" "$(mic_urteil 0.0)"

# 23-27: Was der Netzschalter zusaetzlich abschalten darf. Vorgabe ist nichts:
# ein Schalter, der stillschweigend mehr tut als angeschrieben, ist schlimmer
# als einer, der zu wenig tut.
export XDG_CONFIG_HOME="$TMP/config"
check "Vorgabe: Wi-Fi bleibt unberuehrt" "nein" "$("$PROG" config wifi)"
check "Vorgabe: Bluetooth bleibt unberuehrt" "nein" "$("$PROG" config bluetooth)"
"$PROG" config wifi on >/dev/null
check "eingeschaltet und gemerkt" "ja" "$("$PROG" config wifi)"
check "das Nachbarfeld bleibt davon unberuehrt" "nein" "$("$PROG" config bluetooth)"
"$PROG" config wifi off >/dev/null
check "wieder abgewaehlt" "nein" "$("$PROG" config wifi)"

# 28: Das Modem taucht hier absichtlich NICHT auf - die Android-Seite stoppt
# den RIL, bevor dieses Programm von der Schalterstellung erfaehrt.
"$PROG" config modem on >/dev/null 2>&1
check "config lehnt 'modem' ab" "2" "$?"

# 29: status --json ist der Vertrag mit der Oberflaeche - die Felder, die die
# App liest, muessen da sein, auch wenn nichts gemessen wurde.
json="$(FURIOS_KILLSWITCH_BASE=$TMP "$PROG" status --json)"
fehlend=""
for feld in switches network_extras radios we_disabled cameras camera_hal; do
    grep -q "\"$feld\"" <<<"$json" || fehlend="$fehlend $feld"
done
check "status --json hat alle Felder fuer die App" "" "$fehlend"

# 30-34: Der Dienst misst NICHT. Das ist eine Entscheidung, keine Luecke:
# unterscheiden hiesse das Mikrofon oeffnen, und die Antwort gilt nur fuer die
# drei Sekunden der Messung -- umgelegt bei wachem Bildschirm meldet sich der
# Schalter nirgends. Ein Symbol, das manchmal stimmt, ist schlimmer als keins.
# Diese Tests halten die Automatik fern, die frueher hier stand (Aufwach-Abo
# auf logind, Messung beim Start und beim Umlegen der anderen Schalter).
for weg in start_mic_measurement watch_wakeups on_session_changed mic_image; do
    check "keine Automatik mehr: $weg" "0" "$(grep -c "def $weg\|self\.$weg" "$PROG")"
done
check "kein Aufwach-Abo auf logind" "0" "$(grep -c 'login1' "$PROG")"

# 35: status --json darf kein Messurteil mehr fuehren -- die App liest keins
# mehr, und ein stehengebliebenes laese sich wie eine aktuelle Antwort.
check "status --json ohne Messurteil" "0" \
    "$(FURIOS_KILLSWITCH_BASE=$TMP "$PROG" status --json | grep -c '"mic"')"

# 36: ein Urteil aus einer aelteren Fassung wird beim Start weggeraeumt.
mkdir -p "$TMP/config/furios-killswitch"
echo '{"we_disabled": [], "mic": {"verdict": "GESPERRT"}}' \
    > "$TMP/config/furios-killswitch/state.json"
python3 - "$PROG" <<'PYEOF2'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("ks", sys.argv[1])
spec = importlib.util.spec_from_loader("ks", loader)
mod = importlib.util.module_from_spec(spec); loader.exec_module(mod)
ind = mod.Indicator.__new__(mod.Indicator)
ind.forget_stale_mic_state()
PYEOF2
check "altes Messurteil wird beim Start vergessen" "0" \
    "$(grep -c 'mic' "$TMP/config/furios-killswitch/state.json")"

# 37: von Hand messen bleibt moeglich -- nur eben auf Zuruf.
check "mic-check gibt es weiterhin" "ja" \
    "$("$PROG" --help | grep -q 'mic-check' && echo ja || echo nein)"

# 38-40: Die leere Eingaberegion, und der eine Ort, an dem sie ankommt.
# Aus "realize" gesetzt tut sie NICHTS: gtk-layer-shell tauscht die Flaeche
# zwischen realize und map gegen eine Layer-Flaeche aus, und GDK schickt die
# Region nur waehrend des Zeichnens zum Compositor. Am 15.09.2026 mit
# WAYLAND_DEBUG=1 am Geraet nachgemessen -- der Streifen ging mit
# set_input_region(nil) hoch und schluckte die Wischgeste zu den
# Schnelleinstellungen ueber die ganze Breite der Leiste.
check "Eingaberegion nicht aus realize" "0" \
    "$(grep -c 'connect("realize"' "$PROG")"
check "Eingaberegion beim Zeichnen" "1" \
    "$(grep -c 'def on_draw' "$PROG")"
check "leere Region, nichts anderes" "1" \
    "$(grep -c 'input_shape_combine_region(self.cairo.Region(), 0, 0)' "$PROG")"

echo
echo "$pass bestanden, $fail durchgefallen"
[ "$fail" -eq 0 ]
