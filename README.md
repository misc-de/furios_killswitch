# killswitch-indicator

Shows an icon in the phosh status bar while one of the FuriPhone FLX1's
hardware switches is engaged.

![Status bar with both icons](doc/leiste.png)

Without it there is nothing on screen to tell you: FuriOS creates no rfkill
device for these switches, so the bar goes on showing the signal strength of a
modem that is no longer there.

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

Installs to `~/.local/bin`, sets up a systemd user unit and starts it. Remove
with `./uninstall.sh`.

Nothing here needs root: it reads two sysfs attributes and nothing else.

## Usage

    killswitch-indicator status          switch positions, no display needed
    killswitch-indicator status --json   the same for the app
    killswitch-indicator cameras         which cameras the switch affects
    killswitch-indicator mic-check       measure the microphone once, by hand
    killswitch-indicator run -v          show the icon, log every change

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

Runs without a display: switch positions are read from a test directory via
`FURIOS_KILLSWITCH_BASE`.

## Licence

MIT — see [LICENSE](LICENSE) and [NOTICE](NOTICE) for what this builds on.
How it works, and why the microphone switch is left alone, are in
[FINDINGS.md](FINDINGS.md).
