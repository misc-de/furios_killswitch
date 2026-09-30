# killswitch-indicator

Shows an icon in the phosh status bar while one of the FuriPhone FLX1's
hardware switches is engaged.

![Status bar with both icons](doc/status-bar.png)

Without it there is nothing on screen to tell you: FuriOS creates no rfkill
device for these switches, so the bar goes on showing the signal strength of a
modem that is no longer there.

It comes in two halves, and they are installed in different places:

* **the icons** — a phosh status-icon plugin (`phosh-plugin/`). They sit in
  phosh's own indicator box, at its left end, so the box lays them out with
  everything else in it and nothing can overlap. They were a layer-shell strip
  of our own once, and a strip can only pin them a fixed distance from an edge:
  it cannot see how wide the indicators are at that moment, so anything that
  appeared beside them ended up underneath.
* **the daemon** — what a widget in the shell's process has no business doing:
  taking Wi-Fi or Bluetooth down with the network switch and bringing them
  back, saying in the journal when a switch moved, and answering `status` for
  the app.

| Switch | Icon | What it means |
|---|---|---|
| Camera | crossed-out camera | the camera HAL is stopped |
| Cellular | crossed-out signal bars | the radio interface is stopped |
| Microphone | none | the state cannot be read — see below |

The microphone switch is the only one of the three that physically cuts the
line, and that is exactly why software cannot see it. This program does not
guess at it: telling would mean opening the microphone — the one thing the
switch exists to prevent — and the answer would only hold for those few
seconds. For that switch, the slider on the case is the display.

If you do want a reading, take one by hand with
`killswitch-indicator mic-check`.

## Install

    ./install.sh        # without sudo

Builds the plugin, puts it where phosh looks for plugins, and installs the
daemon into `~/.local/bin` with a systemd user unit - and switches nothing on.
Turn it on in the app, or with

    killswitch-indicator icons on
    systemctl --user enable --now killswitch-indicator.service

Remove both again with `./uninstall.sh`.

**The icons appear after the next reboot.** phosh scans its plugin directory
once, when it starts, and its unit refuses to be restarted on its own —
stopping the shell by hand takes the whole session with it. Switching them off
again, on the other hand, works immediately: the shell follows the setting
while it runs.

The one step that needs root is the plugin: phosh takes its plugin directory
from a compile-time constant, so there is no place in the home the shell would
look in. The daemon needs none — it reads two sysfs attributes and nothing
else.

## Usage

    killswitch-indicator status          switch positions, no display needed
    killswitch-indicator status --json   the same for the app
    killswitch-indicator cameras         which cameras the switch affects
    killswitch-indicator mic-check       measure the microphone once, by hand
    killswitch-indicator run -v          follow the switches, log every change

    systemctl --user status killswitch-indicator
    journalctl --user -u killswitch-indicator -f

The cellular switch only powers down the modem; Wi-Fi and Bluetooth keep
running. You can have either of them switched off along with it, and back on
when the switch is released:

    killswitch-indicator config                 show the current setting
    killswitch-indicator config wifi on         take Wi-Fi down as well
    killswitch-indicator config bluetooth off   leave Bluetooth alone

Both are off by default, and only what this program switched off is ever
switched back on.

The **Switches** tab in the `misc-de` app shows all three switches and offers
the same settings.

## Tests

    ./tests/run-tests.sh        # never with sudo

Runs without a display, except for the plugin's own suite — that one builds
the plugin, loads it the way phosh does and moves the switches under it, and
skips itself when there is no display or no `phosh-dev`. Switch positions come
from a test directory, via `FURIOS_KILLSWITCH_BASE` on both sides.

## Licence

MIT — see [LICENSE](LICENSE) and [NOTICE](NOTICE) for what this builds on.
How it works, and why the microphone switch is left alone, are in
[FINDINGS.md](FINDINGS.md).
