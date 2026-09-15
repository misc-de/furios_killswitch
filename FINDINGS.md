# Befunde: die drei Schalter des FuriPhone FLX1

Aufgenommen am 14.09.2026 auf `radon` (FuriOS 14.0, Kernel 4.19.325). Alles
hier ist am Geraet gemessen, nicht aus Dokumentation uebernommen.

## Die drei Eingaben

| Schalter | Quelle | Keycode | Eingabegeraet |
|---|---|---|---|
| Kamera-Schieber | GPIO 51, Treiber `custom_keys` | 212 (`KEY_CAMERA`) | `/dev/input/event1` |
| Netzwerk-Schieber | GPIO 52, Treiber `custom_keys` | 60 (`KEY_F2`) | `/dev/input/event1` |
| Assistant-Taste | `mtk-kpd` | 112 (`KEY_MACRO`) | `/dev/input/event2` |

Devicetree-Knoten `custom-keys`, Unterknoten `key0`/`key1`, je 50 ms
Entprellung und `wakeup-source`. Beim Boot:

```
Boot GPIO 51 (cam_switch) initial state: 0 (pressed: 1)
Boot GPIO 52 (nwk_switch) initial state: 0 (pressed: 1)
```

## Die Killswitch-Logik liegt in Android, nicht in Linux

`vendor/etc/init/hw/init.project.rc` uebergibt die beiden sysfs-Attribute an
`system:system`. Gelesen werden sie vom HAL
`/vendor/bin/hw/vendor.mediatek.hardware.nvram@1.1-service`, dessen
Stringtabelle genau die noetigen Bausteine enthaelt und sonst nichts:

```
/sys/bus/platform/devices/custom-keys/{nwk,cam}_switch   /dev/input/event1
persist.vendor.radio.disabled    ctl.start / ctl.stop    vendor.ril-daemon-mtk
persist.vendor.camera.disabled                           camerahalserver
```

Gemessener Ablauf beim Umlegen des Kamera-Schalters (14.09., 15:53):

```
15:53:38  cam_switch 1 -> 0        dmesg: "Key cam_switch (GPIO 51) ... pressed: 0"
15:53:40  ~2,0 s spaeter: persist.vendor.camera.disabled = 1
          init: Control message: Processed ctl.stop for 'camerahalserver'
                from pid: 126 (.../vendor.mediatek.hardware.nvram@1.1-service)
          init: Sending signal 9 to service 'camerahalserver'      PID 2234 weg
15:53:48  cam_switch 0 -> 1
15:53:49  ~1,0 s spaeter: persist.vendor.camera.disabled = 0
          init: Control message: Processed ctl.start for 'camerahalserver'
          imgsensor_hw_power_sequence ...                          PID 11331 neu
```

`vendor.ril-daemon-mtk` ist `/vendor/bin/hw/mtkfusionrild`.

### Es ist ein Software-Kill, kein Leitungstrenner

Im gesamten Umschaltfenster steht **keine** Kernel-Meldung ueber Regulatoren,
Sensorstrom oder MCLK. Der GPIO trennt nichts, er meldet nur; die Kamera geht
aus, weil Android den HAL mit Signal 9 beendet. Der Schalter ist damit so
stark wie die Android-Init-Schicht darunter -- nicht staerker. Fuer das
Vertrauensmodell ist das der Unterschied zu einem echten Hardware-Killswitch.

## Warum kein Linux-Programm die Tastencodes sieht

Der NVRAM-HAL haelt `/dev/input/event1` exklusiv:

```
nvram-HAL (PID 2137), fd 6 -> /dev/input/event1
EVIOCGRAB abgelehnt: [Errno 16] Device or resource busy
```

Ein eigener Leser auf `event1` sah waehrend eines kompletten Umschaltvorgangs
null Ereignisse, obwohl der Treiber sie im Kernel-Log meldet. `KEY_CAMERA` und
`KEY_F2` erreichen phoc, phosh oder eigene Programme also grundsaetzlich nie.
Deshalb liest dieses Projekt sysfs und nicht das Eingabegeraet.

Ebenfalls geprueft und nicht vorhanden: ein rfkill-Geraet (`rfkill list` ist
leer), eine udev-Regel auf die Codes, ein Auswerter im Userspace. `nmcli radio
all` meldet unabhaengig von der Schalterstellung `WWAN-HW enabled`.

## Das Prellen auf GPIO 52

Seit dem Boot stehen 113 `nwk_switch`-Ereignisse im Log, darunter 53 echte
`pressed: 0`-Flanken -- ohne dass der Schalter je bewegt wurde; sie treten auf,
wenn das Telefon in die Hand genommen wird. Trotzdem lief `mtkfusionrild`
durchgehend seit dem Boot und `persist.vendor.radio.disabled` blieb 0. Der HAL
laesst sich vom Prellen also nicht taeuschen. Fuer die Anzeige heisst das:
sysfs lesen (Ruhezustand), nicht Flanken zaehlen.

## Der Treiber meldet Aenderungen nicht von selbst

Gemessen am 14.09. mit zwei Threads auf `cam_switch`: einer wartete blockierend
in `poll()` auf `POLLPRI`, der andere las den Wert alle 50 ms.

```
Wertaenderung nach: 58.44s
poll() meldete nach: NIE (Treiber ruft sysfs_notify nicht)
```

Die Anzeige kann also nicht ereignisgesteuert arbeiten: das Pruefintervall ist
unmittelbar die Verzoegerung, mit der das Symbol erscheint. Bei 2 s kostet das
0,0154 % eines Kerns (65-s-Fenster), hochgerechnet 13,3 s CPU-Zeit pro Tag, bei
54 MB RSS -- der Speicher von Python samt GTK 3 ist der groessere Posten, nicht
die Rechenzeit. Laenger takten spart daran nichts Messbares und macht die
Anzeige nur traeger.

## Der Mikrofon-Schalter: der einzige echte, und der unsichtbare

Am Geraet gibt es drei Schieber, aber nur zwei GPIOs. Der Mikrofon-Schalter
taucht im System an **keiner** Stelle auf. Verglichen zwischen gesperrt und
frei, jeweils ohne einen einzigen Unterschied:

| Quelle | Umfang | Unterschied |
|---|---|---|
| GPIOs, Android-Properties, Eingabegeraete, Audioquellen | 448 Zeilen | 0 |
| ALSA-Controls vollstaendig, /proc/asound, Jack-Zustaende | 1889 Zeilen | 0 |

Das ist kein Versaeumnis der Firmware, sondern die Natur der Sache: ein
eingebautes Mikrofon ist kein Geraet, das sich an- und abmeldet, sondern eine
analoge Leitung an einen Codec-Eingang. Anwesenheitserkennung gibt es nur fuer
die Klinkenbuchse -- dafuer ist ACCDET da, das dort die Impedanz misst. Die
Codec-Register des PMIC waeren die letzte denkbare Stelle, taugen aber nicht:
sie aendern sich im Ruhezustand von allein um 1634 Zeilen in zwei Sekunden.

Waehrend Kamera- und Netzschalter nur einen Android-Dienst abschiessen, trennt
dieser hier tatsaechlich: der Pegel faellt um 37,8 dB, aber nicht auf digitale
Stille (91,9 % der Abtastwerte ungleich null) -- der Wandler laeuft weiter und
liefert sein Eigenrauschen, vor ihm kommt nichts mehr an.

### Wie der Zustand erkannt werden koennte -- und warum nicht mehr

Alles in diesem Abschnitt ist gemessen und gilt weiter; es traegt seit dem
14.9.2026 nur noch `mic-check` von Hand. Der Dienst misst **nicht** mehr, es
gibt **kein** drittes Symbol. Die Begruendung steht unten unter "Entschieden".

Drei Sekunden aufnehmen, die ersten 0,7 s Anlauf verwerfen, RMS je 200-ms-Block,
davon den **Median**. Gemessen, 5 Laeufe je Zustand:

```
gesperrt   2.84  2.85  2.89  2.93  3.14
frei       8.72  25.71 25.77 28.85 50.94
```

Zwei naheliegendere Kriterien wurden an diesen Daten verworfen:

- **Pegel (mittlerer RMS)**: ein einzelner Klick zieht ihn weg; ein gesperrter
  Lauf las 6.92 bei Spitze 107.
- **Schwankung**: wirkte zuerst ueberzeugend (gesperrt 3-5 %, frei 89-121 %),
  aber ein Lauf im stillen Raum mit LEBENDEM Mikrofon kam auf 13,8 % und waere
  als gesperrt gemeldet worden. Das ist der eine Fehler, der nicht passieren
  darf.

Der Median ist gegen einzelne gestoerte Bloecke immun, und das Grundrauschen des
Wandlers ist ueber Laeufe hinweg bemerkenswert stabil. Schwelle 4,5 -- zwischen
den Gruppen, naeher an "gesperrt", damit im Zweifel "frei" herauskommt. Ein
Median unter 0,5 gilt als Fehlmessung: ein Stream, der digitale Stille
ausliefert, darf nie als gekappte Leitung gelesen werden.

Gemessen wurde nur beim Start und auf ein logind-Signal hin (Ende des
Leerlaufs, Entsperren); dauerndes Messen hiesse dauerndes Oeffnen des
Mikrofons. Dieser Anlass-Mechanismus ist entfernt -- siehe "Entschieden".

## Fallen beim Bauen der Anzeige

**Layer `TOP` genuegt nicht.** Ein Layer-Shell-Fenster auf `TOP` wird gemappt,
meldet eine korrekte Groesse und Position -- und ist trotzdem unsichtbar, weil
phoshs eigene Leiste ebenfalls auf `TOP` liegt und darueber gezeichnet wird.
Erst `OVERLAY` macht das Symbol sichtbar.

**Leere Eingaberegion nicht vergessen -- und sie kommt nur beim Zeichnen an.**
Ohne `input_shape_combine_region(cairo.Region(), 0, 0)` schluckt der Streifen
genau die Wischgeste, mit der man die Schnelleinstellungen oeffnet. Er ist an
TOP, LEFT *und* RIGHT verankert, liegt also ueber der ganzen Breite der Leiste
-- misslingt das, kommt man an die Knoepfe gar nicht mehr heran.

Und aus `realize` gesetzt misslingt es. Am 15.09.2026 mit `WAYLAND_DEBUG=1` am
Geraet mitgelesen: der Streifen ging mit `wl_surface.set_input_region(nil)`
hoch, und `nil` heisst in Wayland "ich nehme ueberall Beruehrung an" -- das
genaue Gegenteil. Zwei Gruende, von denen jeder allein genuegt:

- Die Flaeche, auf die bei `realize` gesetzt wird, ist nicht die, mit der das
  Fenster endet: gtk-layer-shell tauscht sie vor dem Mappen gegen eine
  Layer-Flaeche.
- GDK schickt die Region ueberhaupt nur zum Compositor, waehrend es zeichnet
  (`gdk_wayland_window_sync_input_region` haengt am Malen). Ein Aufruf zu jedem
  anderen Zeitpunkt landet in einem Feld, das niemand absendet -- im Mitschnitt
  erscheint dann gar kein `set_input_region`.

Aus dem `draw`-Handler kommt derselbe Aufruf als das an, was er sein soll:
`create_region`, **kein** `add`, `set_input_region(wl_region)`. Der Mitschnitt
ist der Pruefstein, nicht der Quelltext -- der sah zwei Tage lang richtig aus.

**Exklusivzone -1.** Mit 0 wird das Fenster unter die Leiste geschoben, die
selbst eine Zone reserviert.

**Sperrbildschirm: geprueft, unkritisch.** `OVERLAY` ist auch die Ebene von
phoshs Sperrbildschirm. Am 14.09. mit `loginctl lock-session` getestet: die
Symbole stehen dort an derselben Stelle wie im entsperrten Zustand, ordentlich
in der Leiste neben Signal, Akku und Prozentanzeige; Uhr, Datum und der Hinweis
zum Entsperren bleiben unberuehrt. Das ist sogar das gewuenschte Verhalten --
man sieht ohne Entsperren, dass ein Schalter gesperrt ist. Die leere
Eingaberegion sorgt dafuer, dass die Wischgeste zum Entsperren durchkommt --
allerdings erst seit dem 15.09.: was am 14.09. geprueft wurde, war das Bild,
nicht die Geste. Bis dahin lag der Streifen ueber der ganzen Breite und nahm
jede Beruehrung an, auf dem Sperrbildschirm wie darueber.

**Screenshots hinken.** `org.gnome.Shell.Screenshot` liefert den zuletzt
gerenderten Frame. Aendert sich am Bildschirm sonst nichts, zeigt ein
Screenshot den Stand von vorher -- zweimal ausloesen oder die Lage der Pixel
messen, statt dem ersten Bild zu glauben.

**Anzeigeskalierung 1,5.** 720x1600 physisch, 480x1067 logisch. Alle Groessen
im Programm sind logische Pixel.

## Der Aufwach-Ausloeser, und warum er zwei Tage lang nichts tat

Das Mikrofon hat keinen auslesbaren Zustand, es muss gemessen werden, und
gemessen wird nur zu Anlaessen: beim Start und wenn das Telefon aus dem
Leerlauf oder aus der Sperre zurueckkommt. logind liefert dafuer genau das
Richtige -- `PropertiesChanged` auf der Sitzung mit `LockedHint` bzw.
`IdleHint`. Am 14.9.2026 mit `dbus-monitor` nachgesehen: beide Flanken kommen
zuverlaessig, `LockedHint true` beim Sperren, `false` beim Entsperren.

Der Dienst bekam trotzdem nie eines dieser Signale zu sehen. Kein Fehler, kein
Eintrag im Journal, der Dienst `active (running)` -- nur eine Zustandsdatei,
in der seit dem Start ausschliesslich `"reason": "Start"` stand.

**Die Ursache war eine lokale Variable.** `watch_wakeups()` holte sich die
Systembus-Verbindung, abonnierte darauf und kehrte zurueck. Damit gab Python
die Verbindung frei, und das Abo verfiel mit ihr. Isoliert nachgestellt, zwei
Fassungen desselben Programms, gleicher Ablauf:

| Verbindung | Signale beim Sperren/Entsperren |
|---|---|
| nur lokal | **keines** |
| auf `self` gehalten | beide |

Am Geraet danach belegt, beide Wege: `reason: "LockedHint"` 4,8 s nach dem
Sperren, und `reason: "LockedHint, nachgeholt"`, wenn die Abkuehlzeit von 20 s
noch laeuft -- ein Anlass waehrend der Abkuehlzeit wird verschoben, nie
verworfen.

**Ende zu Ende bestaetigt** (14.9. 17:10, mit der Hand am Schalter): Mikro
gesperrt, Telefon gesperrt -- `Mikrofon: GESPERRT (Median 3.18, Anlass:
IdleHint)`, Symbol in der Leiste sichtbar. Schalter zurueck, naechster Anlass
`Mikrofon: frei (Median 6.88, Anlass: LockedHint, nachgeholt)`, Symbol weg.
Beide Schluessel feuern also, `IdleHint` und `LockedHint` -- und `IdleHint`
kommt zuerst, weil der Bildschirm ausgeht, bevor die Sperre greift.

**Der Abstand zur Schwelle ist kleiner als gedacht.** 6,88 ist der bisher
niedrigste gemessene frei-Wert (vorher 8,72) bei 3,18 als hoechstem
gesperrt-Wert. Die Schwelle 4,5 liegt weiter richtig dazwischen, aber der
Spielraum nach unten betraegt nur noch rund das Anderthalbfache -- in einem
sehr stillen Raum ist das die Groesse, auf die zu achten ist. Beide Werte
stehen jetzt in den Testreihen.

**UNGEKLAERT, und deshalb hier als offene Frage notiert:** direkt nach diesem
Versuch meldete der Benutzer, der Schalter sei die ganze Zeit gesperrt
gewesen und es werde trotzdem kein Symbol gezeigt. Beide Lesarten sind
moeglich und noch nicht entschieden:

1. Der Schalter war um 17:11 kurz frei (dann ist 6,88 ein echter frei-Wert und
   die Einstufung stimmt).
2. Er war durchgehend gesperrt (dann hat die Messung zweimal falsch "frei"
   gesagt, und die Schwelle taugt nicht).

Was danach gemessen wurde, spricht fuer die erste Lesart. 38 Messungen bei
gesperrtem Schalter, davon 17 mit eingeschaltetem Bildschirm und dem Telefon
in der Hand: **Median 2,82 bis 3,17, Spitze 35 bis 45** -- kein einziger
Ausreisser nach oben. Ein Weckvorgang hebt nur die Spitze (593 und 144
gemessen), nicht den Median; genau dagegen wurde der Median gewaehlt. Eine
gekappte Leitung liefert also einen festen Rauschteppich, waehrend die beiden
strittigen Messungen Spitzen von 148 und 158 bei doppeltem Median zeigten --
das Bild eines lebenden Mikrofons in einem stillen Raum.

**Die wirkliche Luecke ist eine andere und unabhaengig davon da:** der
Mikrofon-Schalter meldet sich nirgends an. Wer ihn bei eingeschaltetem
Bildschirm umlegt, loest gar nichts aus -- es gibt keinen Anlass zwischen
Start und Aufwachen, das Symbol bleibt stehen wie es war.

### Entschieden (14.9.2026): gar nicht mehr messen

Die Abwaegung oben ist gefallen, und zwar gegen das Messen. Die Alternative
waere gewesen, regelmaessig nachzusehen -- also das Mikrofon regelmaessig zu
oeffnen, genau das, wogegen jemand den Schalter umlegt. Ohne das bleibt die
Anzeige zwischen zwei Anlaessen stehen, und eine Anzeige, die manchmal stimmt,
ist schlechter als keine: sie laedt dazu ein, sich auf sie zu verlassen.

Entfernt: das dritte Symbol, das logind-Abo, die Messung beim Start und beim
Umlegen der anderen Schalter, die Abkuehlzeit, das Feld `mic` in
`status --json` (ein stehengebliebenes Urteil in `state.json` wird beim Start
weggeraeumt). Geblieben: `mic-check`, eine Messung auf Zuruf, mit allen
Schwellen dieses Abschnitts -- und der Hinweis dort, dass sie nur fuer diese
drei Sekunden gilt.

Die Oberflaeche sagt das jetzt aus, statt es zu verschweigen: unter "3 ·
Microphone" steht als Position "not readable - and not listened for either",
dazu warum, und `mic-check` als das, was von Hand moeglich bleibt. Vier Tests
(30-34) halten die Automatik fern, damit sie nicht aus Versehen zurueckkommt.

**Merke:** ein GDBus-Abo lebt auf der Verbindung, nicht fuer sich. Wo die
Schwesterdienste (`furios-audio-sco-hold`, `pause-on-disconnect`) es richtig
machen, ist das Zufall der Bauform: dort laeuft die Hauptschleife im selben
`main()`, das die Verbindung noch haelt. Ein Test darauf prueft nicht das Abo,
sondern dass die Verbindung die Methode ueberlebt.

## Die Assistant-Taste

`/usr/libexec/assistant-button` liest `event2` (Keycode 112), Konfiguration aus
`/usr/lib/furios/device/assistant-button.conf` -- die Geraetekonfiguration
gewinnt gegen die Vorgabe in `/usr/share`, weshalb dort `event2` steht und
nicht das voreingestellte `event1`. Unterschieden werden kurz (< 500 ms), lang
und doppelt (< 200 ms Abstand). Pro Geste liegt in
`~/.config/assistant-button/` entweder ein Index auf eine vordefinierte Aktion
(`*_predefined`: 0 keine, dann Taschenlampe, Kamera oeffnen, Foto, Screenshot,
Tab, manuelle Drehung, Zurueck, Escape) oder eine ausfuehrbare Datei mit einem
freien Befehl. Zusaetzlich sendet das Programm `ActionPerformed` auf
`io.FuriOS.AssistantButton`.

Diese Taste ist nicht Teil der Anzeige: sie hat keinen Ruhezustand, den man
anzeigen koennte.

## Aus dem README

Das README wurde auf das gekuerzt, was man zum Benutzen braucht. Was hier folgt, stand bis dahin dort: die Begruendungen, die Messwerte und die Abwaegungen hinter den Entscheidungen.

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
