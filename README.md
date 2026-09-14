# killswitch-indicator

Zeigt in der phosh-Leiste ein Symbol, solange einer der Hardware-Schalter des
FuriPhone FLX1 gesperrt ist.

![Leiste mit beiden Symbolen](doc/leiste.png)

Ohne dieses Programm merkt man am Bildschirm nicht, dass ein Schalter umgelegt
ist: FuriOS legt fuer die Schalter kein rfkill-Geraet an, und die Leiste zeigt
weiter die Signalbalken des letzten bekannten Modemzustands.

## Was angezeigt wird

| Schalter | Symbol | Bedeutung |
|---|---|---|
| Kamera (GPIO 51) | durchgestrichene Kamera | Kamera-HAL ist gestoppt |
| Mobilfunk (GPIO 52) | durchgestrichene Signalbalken | RIL ist gestoppt |

Die Symbole erscheinen rechtsbuendig, links neben Standort, Akku und
Prozentanzeige. Steht ein Schalter frei, ist dort nichts zu sehen.

## Installation

```bash
./install.sh        # ohne sudo
```

Installiert nach `~/.local/bin`, richtet eine systemd-Nutzer-Unit ein und
startet sie sofort. Entfernen mit `./uninstall.sh`.

Kein root noetig, nirgends: gelesen werden nur zwei sysfs-Attribute, und die
sind lesbar, weil Androids `system`-UID 1000 auf diesem Geraet der Nutzer
`furios` ist.

## Bedienung

```bash
killswitch-indicator status     # Schalterstellung ausgeben, ohne Bildschirm
killswitch-indicator run -v     # Symbol anzeigen, jede Aenderung protokollieren
systemctl --user status killswitch-indicator
journalctl --user -u killswitch-indicator -f
```

## Tests

```bash
./tests/run-tests.sh            # NIE mit sudo
```

Laeuft ohne Bildschirm: die Schalterstellung wird ueber
`FURIOS_KILLSWITCH_BASE` aus einem Testverzeichnis gelesen.

## Wie es funktioniert

Der FuriLabs-eigene Kernel-Treiber `custom_keys` legt die Schalterstellung
unter `/sys/devices/platform/custom-keys/{cam_switch,nwk_switch}` ab: `1` heisst
frei, `0` heisst gesperrt. Das Programm haengt sich mit `poll()` an beide
Attribute und prueft zusaetzlich alle zwei Sekunden nach, weil sich von aussen
nicht feststellen laesst, ob der Treiber `sysfs_notify()` aufruft.

Das Symbol ist ein Layer-Shell-Fenster auf der Ebene `OVERLAY` mit leerer
Eingaberegion -- es faengt also keine Beruehrung ab, insbesondere nicht die
Wischgeste, die die Schnelleinstellungen oeffnet.

Warum nicht die Tastencodes des Treibers, warum nicht rfkill, und was beim
Umlegen eines Schalters tatsaechlich passiert: siehe [FINDINGS.md](FINDINGS.md).

## Lizenz

MIT, siehe [LICENSE](LICENSE).
