# killswitch-indicator

Zeigt in der phosh-Leiste ein Symbol, solange einer der Hardware-Schalter des
FuriPhone FLX1 gesperrt ist.

![Leiste mit beiden Symbolen](doc/leiste.png)

Ohne dieses Programm merkt man am Bildschirm nicht, dass ein Schalter umgelegt
ist: FuriOS legt fuer die Schalter kein rfkill-Geraet an, und die Leiste zeigt
weiter die Signalbalken des letzten bekannten Modemzustands.

## Was angezeigt wird

| Schalter | Symbol | Bedeutung | Erkennung |
|---|---|---|---|
| Kamera (GPIO 51) | durchgestrichene Kamera | Kamera-HAL ist gestoppt | sysfs, sofort |
| Mobilfunk (GPIO 52) | durchgestrichene Signalbalken | RIL ist gestoppt | sysfs, sofort |
| Mikrofon | **keins** | -- | nicht erkennbar, siehe unten |

Der Mikrofon-Schalter hat **keinen** auslesbaren Zustand -- er ist der einzige
der drei, der wirklich die Leitung kappt, und genau deshalb sieht das System
ihn nicht. Unterscheiden liesse er sich nur durchs Zuhoeren: drei Sekunden
aufnehmen und den Median der Blockpegel mit einer am Geraet gemessenen
Schwelle vergleichen.

Genau das tut dieses Programm **nicht** mehr. Dafuer muesste es das Mikrofon
oeffnen -- das, wogegen der Schalter umgelegt wird --, und die Antwort gaelte
nur fuer diese drei Sekunden: umgelegt bei wachem Bildschirm meldet sich der
Schalter nirgends, es gibt kein Ereignis, auf das hin nachgesehen wuerde. Ein
Symbol, das manchmal stimmt, ist schlechter als keins. Fuer diesen Schalter
ist der Schieber am Gehaeuse die Anzeige.

Wer doch eine Zahl will, holt sie sich von Hand:

```bash
killswitch-indicator mic-check         # einmal messen, oeffnet dafuer kurz das Mikrofon
```

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

## Was der Netzschalter zusaetzlich abschalten darf

Der Schalter selbst nimmt nur das Modem herunter -- WLAN und Bluetooth laufen
weiter. Beides laesst sich dazunehmen; das Programm schaltet sie dann ab,
sobald der Schalter sperrt, und wieder ein, wenn er zurueckgeht:

```bash
killswitch-indicator config                 # zeigen, was eingestellt ist
killswitch-indicator config wifi on         # WLAN mit abschalten
killswitch-indicator config bluetooth off   # Bluetooth in Ruhe lassen
```

Vorgabe ist beides aus: ein Schalter, der stillschweigend mehr tut als
angeschrieben, ist schlimmer als einer, der zu wenig tut. Wieder eingeschaltet
wird nur, was dieses Programm selbst abgeschaltet hat -- wer WLAN vorher von
Hand aus hatte, findet es hinterher nicht an.

Das **Modem** laesst sich nicht abwaehlen. Die Android-Seite stoppt den RIL,
bevor hier ueberhaupt jemand von der Schalterstellung erfaehrt; es abzuwaehlen
hiesse, das Modem hinter dem Schalter wieder hochzufahren.

Kein root noetig: `logind` ordnet den Dienst der aktiven Sitzung zu, und
NetworkManager erlaubt ihr das Schalten ohne Passwort (`allow_active`).

## Die Oberflaeche

Der Reiter **Switches** in der App `misc-de` (aus furios_pipewire) zeigt alle
drei Schalter, schaltet den Indikator an und aus, merkt sich das ueber den
Neustart hinaus und bietet die Auswahl oben an. Er erscheint nur, wenn dieses
Werkzeug installiert ist.

## Bedienung

```bash
killswitch-indicator status     # Schalterstellung ausgeben, ohne Bildschirm
killswitch-indicator status --json   # alles auf einmal, fuer die Oberflaeche
killswitch-indicator cameras    # welche Kameras der Schalter betrifft
killswitch-indicator mic-check  # Mikrofon einmal von Hand messen (der Dienst misst nie)
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
frei, `0` heisst gesperrt. Das Programm prueft beide Attribute alle zwei
Sekunden.

Am Geraet gemessen: der Treiber ruft `sysfs_notify()` **nicht** auf -- `poll()`
blieb ueber einen vollstaendigen Umschaltvorgang stumm, waehrend der Wert sich
nachweislich aenderte. Das Intervall ist damit nicht nur ein Sicherheitsnetz,
sondern die Reaktionszeit der Anzeige. Es kostet 0,0154 % eines Kerns, also
13,3 s CPU-Zeit pro Tag; laenger heisst spaeter sichtbar, ohne nennenswerte
Ersparnis. Wer trotzdem drehen will:

```bash
killswitch-indicator run --interval 10
# oder dauerhaft in der Unit: FURIOS_KILLSWITCH_INTERVAL=10
```

Das Symbol ist ein Layer-Shell-Fenster auf der Ebene `OVERLAY` mit leerer
Eingaberegion -- es faengt also keine Beruehrung ab, insbesondere nicht die
Wischgeste, die die Schnelleinstellungen oeffnet. Die Region wird beim
Zeichnen gesetzt und nicht beim `realize`: von dort aus kommt sie nicht beim
Compositor an, und der Streifen liegt ueber der ganzen Breite der Leiste.
Siehe [FINDINGS.md](FINDINGS.md).

Im Sperrbildschirm ist es ebenfalls zu sehen, an derselben Stelle und ohne
etwas zu verdecken: man erkennt also ohne Entsperren, dass ein Schalter
gesperrt ist.

Warum nicht die Tastencodes des Treibers, warum nicht rfkill, und was beim
Umlegen eines Schalters tatsaechlich passiert: siehe [FINDINGS.md](FINDINGS.md).

## Lizenz

MIT, siehe [LICENSE](LICENSE).
