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

### Wie der Zustand trotzdem erkannt wird

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

Gemessen wird nur beim Start und auf ein logind-Signal hin (Ende des Leerlaufs,
Entsperren). Dauerndes Messen hiesse dauerndes Oeffnen des Mikrofons.

## Fallen beim Bauen der Anzeige

**Layer `TOP` genuegt nicht.** Ein Layer-Shell-Fenster auf `TOP` wird gemappt,
meldet eine korrekte Groesse und Position -- und ist trotzdem unsichtbar, weil
phoshs eigene Leiste ebenfalls auf `TOP` liegt und darueber gezeichnet wird.
Erst `OVERLAY` macht das Symbol sichtbar.

**Leere Eingaberegion nicht vergessen.** Ohne
`input_shape_combine_region(cairo.Region(), 0, 0)` schluckt der Streifen genau
die Wischgeste, mit der man die Schnelleinstellungen oeffnet.

**Exklusivzone -1.** Mit 0 wird das Fenster unter die Leiste geschoben, die
selbst eine Zone reserviert.

**Sperrbildschirm: geprueft, unkritisch.** `OVERLAY` ist auch die Ebene von
phoshs Sperrbildschirm. Am 14.09. mit `loginctl lock-session` getestet: die
Symbole stehen dort an derselben Stelle wie im entsperrten Zustand, ordentlich
in der Leiste neben Signal, Akku und Prozentanzeige; Uhr, Datum und der Hinweis
zum Entsperren bleiben unberuehrt. Das ist sogar das gewuenschte Verhalten --
man sieht ohne Entsperren, dass ein Schalter gesperrt ist. Die leere
Eingaberegion sorgt dafuer, dass die Wischgeste zum Entsperren durchkommt.

**Screenshots hinken.** `org.gnome.Shell.Screenshot` liefert den zuletzt
gerenderten Frame. Aendert sich am Bildschirm sonst nichts, zeigt ein
Screenshot den Stand von vorher -- zweimal ausloesen oder die Lage der Pixel
messen, statt dem ersten Bild zu glauben.

**Anzeigeskalierung 1,5.** 720x1600 physisch, 480x1067 logisch. Alle Groessen
im Programm sind logische Pixel.

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
