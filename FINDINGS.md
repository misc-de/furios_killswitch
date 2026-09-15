# Findings: the three switches of the FuriPhone FLX1

Recorded on 14.09.2026 on `radon` (FuriOS 14.0, kernel 4.19.325). Everything
here was measured on the device, not taken from documentation.

## The three inputs

| Switch | Source | Keycode | Input device |
|---|---|---|---|
| Camera slider | GPIO 51, driver `custom_keys` | 212 (`KEY_CAMERA`) | `/dev/input/event1` |
| Network slider | GPIO 52, driver `custom_keys` | 60 (`KEY_F2`) | `/dev/input/event1` |
| Assistant button | `mtk-kpd` | 112 (`KEY_MACRO`) | `/dev/input/event2` |

Devicetree node `custom-keys`, subnodes `key0`/`key1`, 50 ms debounce each and
`wakeup-source`. At boot:

```
Boot GPIO 51 (cam_switch) initial state: 0 (pressed: 1)
Boot GPIO 52 (nwk_switch) initial state: 0 (pressed: 1)
```

## The kill switch logic lives in Android, not in Linux

`vendor/etc/init/hw/init.project.rc` hands the two sysfs attributes to
`system:system`. They are read by the HAL
`/vendor/bin/hw/vendor.mediatek.hardware.nvram@1.1-service`, whose string
table contains exactly the necessary pieces and nothing else:

```
/sys/bus/platform/devices/custom-keys/{nwk,cam}_switch   /dev/input/event1
persist.vendor.radio.disabled    ctl.start / ctl.stop    vendor.ril-daemon-mtk
persist.vendor.camera.disabled                           camerahalserver
```

Measured sequence when the camera switch is flipped (14.09., 15:53):

```
15:53:38  cam_switch 1 -> 0        dmesg: "Key cam_switch (GPIO 51) ... pressed: 0"
15:53:40  ~2.0 s later: persist.vendor.camera.disabled = 1
          init: Control message: Processed ctl.stop for 'camerahalserver'
                from pid: 126 (.../vendor.mediatek.hardware.nvram@1.1-service)
          init: Sending signal 9 to service 'camerahalserver'      PID 2234 gone
15:53:48  cam_switch 0 -> 1
15:53:49  ~1.0 s later: persist.vendor.camera.disabled = 0
          init: Control message: Processed ctl.start for 'camerahalserver'
          imgsensor_hw_power_sequence ...                          PID 11331 new
```

`vendor.ril-daemon-mtk` is `/vendor/bin/hw/mtkfusionrild`.

### It is a software kill, not a cut line

Across the whole switching window there is **no** kernel message about
regulators, sensor power or MCLK. The GPIO disconnects nothing, it only
reports; the camera goes off because Android kills the HAL with signal 9. The
switch is therefore exactly as strong as the Android init layer underneath it
-- no stronger. For the trust model that is the difference to a real hardware
kill switch.

## Why no Linux program sees the key codes

The NVRAM HAL holds `/dev/input/event1` exclusively:

```
nvram-HAL (PID 2137), fd 6 -> /dev/input/event1
EVIOCGRAB refused: [Errno 16] Device or resource busy
```

A reader of our own on `event1` saw zero events across a complete switching
sequence, although the driver reports them in the kernel log. `KEY_CAMERA` and
`KEY_F2` therefore never reach phoc, phosh or any program of ours. That is why
this project reads sysfs and not the input device.

Also checked and not present: an rfkill device (`rfkill list` is empty), a udev
rule on the codes, an evaluator in userspace. `nmcli radio all` reports `WWAN-HW
enabled` regardless of the switch position.

## The bouncing on GPIO 52

Since boot there are 113 `nwk_switch` events in the log, among them 53 real
`pressed: 0` edges -- without the switch ever being moved; they happen when the
phone is picked up. `mtkfusionrild` nevertheless ran continuously since boot and
`persist.vendor.radio.disabled` stayed 0. So the HAL is not fooled by the
bouncing. For the indicator that means: read sysfs (the resting state), do not
count edges.

## The driver does not report changes by itself

Measured on 14.09. with two threads on `cam_switch`: one waited blocking in
`poll()` for `POLLPRI`, the other read the value every 50 ms.

```
value changed after: 58.44s
poll() reported after: NEVER (the driver does not call sysfs_notify)
```

The indicator therefore cannot work event-driven: the polling interval is
directly the delay with which the icon appears. At 2 s that costs 0.0154 % of a
core (65 s window), extrapolated 13.3 s of CPU time per day, at 54 MB RSS --
the memory of Python plus GTK 3 is the larger item, not the computation.
Polling more slowly saves nothing measurable and only makes the indicator
sluggish.

## The microphone switch: the only real one, and the invisible one

The device has three sliders but only two GPIOs. The microphone switch appears
**nowhere** in the system. Compared between engaged and free, each time without
a single difference:

| Source | Extent | Difference |
|---|---|---|
| GPIOs, Android properties, input devices, audio sources | 448 lines | 0 |
| ALSA controls in full, /proc/asound, jack states | 1889 lines | 0 |

This is not an omission of the firmware but the nature of the thing: a built-in
microphone is not a device that registers and deregisters, it is an analogue
line to a codec input. Presence detection exists only for the headphone jack --
that is what ACCDET is for, measuring the impedance there. The codec registers
of the PMIC would be the last conceivable place, but they are no good: at rest
they change by themselves, 1634 lines in two seconds.

While the camera and network switches only shoot down an Android service, this
one really does disconnect: the level drops by 37.8 dB, but not to digital
silence (91.9 % of the samples are non-zero) -- the converter keeps running and
delivers its own noise, and nothing arrives in front of it any more.

### How the state could be detected -- and why it no longer is

Everything in this section was measured and still holds; since 14.9.2026 only
`mic-check` carries it out, by hand. The service does **not** measure any more,
there is **no** third icon. The reasoning is below under "Decided".

Record three seconds, discard the first 0.7 s of run-up, RMS per 200 ms block,
and of those the **median**. Measured, 5 runs per state:

```
engaged   2.84  2.85  2.89  2.93  3.14
free      8.72  25.71 25.77 28.85 50.94
```

Two more obvious criteria were rejected against this data:

- **Level (mean RMS)**: a single click drags it away; an engaged run read 6.92
  at a peak of 107.
- **Variation**: convincing at first (engaged 3-5 %, free 89-121 %), but a run
  in a quiet room with a LIVE microphone came to 13.8 % and would have been
  reported as engaged. That is the one mistake that must not happen.

The median is immune to individual disturbed blocks, and the noise floor of the
converter is remarkably stable across runs. Threshold 4.5 -- between the groups,
closer to "engaged", so that in doubt the answer is "free". A median below 0.5
counts as a failed measurement: a stream delivering digital silence must never
be read as a cut line.

Measurements were taken only at start and on a logind signal (end of idle,
unlocking); measuring continuously would mean opening the microphone
continuously. That occasion mechanism has been removed -- see "Decided".

## Traps while building the indicator

**Layer `TOP` is not enough.** A layer-shell window on `TOP` is mapped, reports
a correct size and position -- and is invisible all the same, because phosh's
own bar is on `TOP` as well and is drawn over it. Only `OVERLAY` makes the icon
visible.

**Do not forget the empty input region -- and it only arrives while drawing.**
Without `input_shape_combine_region(cairo.Region(), 0, 0)` the strip swallows
exactly the swipe that opens the quick settings. It is anchored to TOP, LEFT
*and* RIGHT, so it lies across the whole width of the bar -- get this wrong and
the buttons cannot be reached at all.

And set from `realize` it does go wrong. Read along on the device on 15.09.2026
with `WAYLAND_DEBUG=1`: the strip went up with `wl_surface.set_input_region(nil)`,
and in Wayland `nil` means "I accept touch everywhere" -- the exact opposite.
Two reasons, either of which is enough on its own:

- The surface set on at `realize` is not the one the window ends up with:
  gtk-layer-shell swaps it for a layer surface before mapping.
- GDK only ever sends the region to the compositor while it draws
  (`gdk_wayland_window_sync_input_region` hangs off painting). A call at any
  other moment lands in a field nobody sends -- and then no `set_input_region`
  appears in the trace at all.

From the `draw` handler the same call arrives as what it is meant to be:
`create_region`, **no** `add`, `set_input_region(wl_region)`. The trace is the
touchstone, not the source -- that looked right for two days.

**Exclusive zone -1.** With 0 the window is pushed under the bar, which
reserves a zone of its own.

**Lock screen: checked, unproblematic.** `OVERLAY` is also the layer of phosh's
lock screen. Tested on 14.09. with `loginctl lock-session`: the icons stand
there in the same place as when unlocked, neatly in the bar next to signal,
battery and percentage; clock, date and the unlock hint stay untouched. That is
even the wanted behaviour -- you see without unlocking that a switch is
engaged. The empty input region is what lets the unlock swipe through -- but
only since 15.09.: what was checked on 14.09. was the picture, not the gesture.
Until then the strip lay across the whole width and accepted every touch, on
the lock screen as above it.

**Screenshots lag.** `org.gnome.Shell.Screenshot` delivers the last rendered
frame. If nothing else changes on screen, a screenshot shows the previous state
-- trigger it twice, or measure where the pixels are, rather than believing the
first image.

**Display scaling 1.5.** 720x1600 physical, 480x1067 logical. All sizes in the
program are logical pixels.

## The wake-up trigger, and why it did nothing for two days

The microphone has no readable state, it has to be measured, and it is measured
only on occasions: at start, and when the phone comes back from idle or from
the lock. logind delivers exactly the right thing for that --
`PropertiesChanged` on the session with `LockedHint` and `IdleHint`
respectively. Checked with `dbus-monitor` on 14.9.2026: both edges arrive
reliably, `LockedHint true` on locking, `false` on unlocking.

The service nevertheless never got to see one of those signals. No error, no
entry in the journal, the service `active (running)` -- only a state file that
had contained nothing but `"reason": "Start"` since it started.

**The cause was a local variable.** `watch_wakeups()` fetched the system bus
connection, subscribed on it and returned. With that Python released the
connection, and the subscription expired with it. Reproduced in isolation, two
versions of the same program, same sequence:

| Connection | Signals on lock/unlock |
|---|---|
| local only | **none** |
| held on `self` | both |

Proven on the device afterwards, both ways: `reason: "LockedHint"` 4.8 s after
locking, and `reason: "LockedHint, caught up"` when the 20 s cool-down is still
running -- an occasion during the cool-down is postponed, never dropped.

**Confirmed end to end** (14.9. 17:10, with a hand on the switch): microphone
engaged, phone locked -- `Microphone: ENGAGED (median 3.18, occasion:
IdleHint)`, icon visible in the bar. Switch back, next occasion `Microphone:
free (median 6.88, occasion: LockedHint, caught up)`, icon gone. So both keys
fire, `IdleHint` and `LockedHint` -- and `IdleHint` comes first, because the
screen goes off before the lock takes hold.

**The margin to the threshold is smaller than expected.** 6.88 is the lowest
free value measured so far (previously 8.72) against 3.18 as the highest
engaged value. Threshold 4.5 still sits correctly between them, but the room
below is now only about one and a half times -- in a very quiet room that is
the figure to watch. Both values are in the test series now.

**UNEXPLAINED, and therefore noted here as an open question:** right after this
experiment the user reported that the switch had been engaged the whole time
and no icon was shown all the same. Both readings are possible and not yet
decided:

1. The switch was briefly free at 17:11 (then 6.88 is a genuine free value and
   the classification is right).
2. It was engaged throughout (then the measurement said "free" twice when it
   should not have, and the threshold is no good).

What was measured afterwards speaks for the first reading. 38 measurements with
the switch engaged, 17 of them with the screen on and the phone in hand:
**median 2.82 to 3.17, peak 35 to 45** -- not a single outlier upwards. Waking
up raises only the peak (593 and 144 measured), not the median; that is exactly
what the median was chosen against. A cut line therefore delivers a fixed
carpet of noise, while the two disputed measurements showed peaks of 148 and
158 at twice the median -- the picture of a live microphone in a quiet room.

**The real gap is a different one and is there regardless:** the microphone
switch announces itself nowhere. Flipping it while the screen is on triggers
nothing at all -- there is no occasion between start and waking up, and the
icon stays as it was.

### Decided (14.9.2026): do not measure at all any more

The weighing above has been settled, and against measuring. The alternative
would have been to look regularly -- that is, to open the microphone regularly,
exactly the thing somebody flips the switch against. Without that the indicator
stands still between two occasions, and an indicator that is sometimes right is
worse than none: it invites people to rely on it.

Removed: the third icon, the logind subscription, the measurement at start and
when the other switches are flipped, the cool-down, the `mic` field in
`status --json` (a verdict left behind in `state.json` is cleared at start).
Kept: `mic-check`, one measurement on request, with all the thresholds of this
section -- and the note there that it only holds for those three seconds.

The interface says so now instead of keeping quiet about it: under "3 ·
Microphone" the position reads "not readable - and not listened for either",
together with why, and `mic-check` as what remains possible by hand. Four tests
(30-34) keep the automation away so it cannot come back by accident.

**Note:** a GDBus subscription lives on the connection, not on its own. Where
the sibling services (`furios-audio-sco-hold`, `pause-on-disconnect`) get it
right, that is an accident of their shape: there the main loop runs in the same
`main()` that still holds the connection. A test for that does not check the
subscription, it checks that the connection outlives the method.

## The assistant button

`/usr/libexec/assistant-button` reads `event2` (keycode 112), configuration
from `/usr/lib/furios/device/assistant-button.conf` -- the device configuration
wins over the default in `/usr/share`, which is why `event2` is there and not
the preset `event1`. It distinguishes short (< 500 ms), long and double
(< 200 ms apart). Per gesture, `~/.config/assistant-button/` holds either an
index into a predefined action (`*_predefined`: 0 none, then torch, open
camera, photo, screenshot, tab, manual rotation, back, escape) or an executable
file with a free command. In addition the program sends `ActionPerformed` on
`io.FuriOS.AssistantButton`.

This button is not part of the indicator: it has no resting state that could be
displayed.

## From the README

The README was cut down to what is needed to use the thing. What follows stood
there until then: the reasons, the measurements and the trade-offs behind the
decisions.

## What is displayed

| Switch | Icon | Meaning | Detection |
|---|---|---|---|
| Camera (GPIO 51) | crossed-out camera | the camera HAL is stopped | sysfs, immediately |
| Cellular (GPIO 52) | crossed-out signal bars | the RIL is stopped | sysfs, immediately |
| Microphone | **none** | -- | not detectable, see below |

The microphone switch has **no** readable state -- it is the only one of the
three that really cuts the line, and that is exactly why the system does not
see it. It could only be told apart by listening: record three seconds and
compare the median of the block levels against a threshold measured on the
device.

That is exactly what this program no longer does. It would have to open the
microphone -- the thing the switch is flipped against -- and the answer would
hold only for those three seconds: flipped while the screen is awake, the
switch announces itself nowhere, there is no event on which to look again. An
icon that is sometimes right is worse than none. For this switch, the slider on
the case is the indicator.

Anybody who does want a number takes it by hand:

```bash
killswitch-indicator mic-check         # measure once; opens the microphone briefly
```

The icons appear right-aligned, to the left of location, battery and
percentage. Where a switch is free, nothing is shown.

## What the network switch may switch off as well

The switch itself only takes the modem down -- Wi-Fi and Bluetooth keep
running. Both can be included; the program then switches them off as soon as
the switch engages, and back on when it goes back:

```bash
killswitch-indicator config                 # show what is set
killswitch-indicator config wifi on         # switch Wi-Fi off as well
killswitch-indicator config bluetooth off   # leave Bluetooth alone
```

The default is both off: a switch that quietly does more than it says is worse
than one that does too little. Only what this program switched off itself is
switched back on -- anybody who had Wi-Fi off by hand beforehand does not find
it on afterwards.

The **modem** cannot be deselected. The Android side stops the RIL before
anybody here even learns of the switch position; deselecting it would mean
bringing the modem back up behind the switch.

No root needed: `logind` assigns the service to the active session, and
NetworkManager allows that session to switch without a password
(`allow_active`).

## The interface

The **Switches** tab in the app `misc-de` shows all three switches, turns the
indicator on and off, remembers that across a reboot and offers the choice at
the top. It appears only where this tool is installed.

## How it works

FuriLabs' own kernel driver `custom_keys` puts the switch position under
`/sys/devices/platform/custom-keys/{cam_switch,nwk_switch}`: `1` means free,
`0` means engaged. The program checks both attributes every two seconds.

Measured on the device: the driver does **not** call `sysfs_notify()` --
`poll()` stayed silent across a complete switching sequence while the value
demonstrably changed. The interval is therefore not merely a safety net but the
reaction time of the indicator. It costs 0.0154 % of a core, i.e. 13.3 s of CPU
time per day; longer means later visible, without a worthwhile saving. For
anybody who wants to turn it anyway:

```bash
killswitch-indicator run --interval 10
# or permanently in the unit: FURIOS_KILLSWITCH_INTERVAL=10
```

The icon is a layer-shell window on the `OVERLAY` layer with an empty input
region -- so it catches no touch, in particular not the swipe that opens the
quick settings. The region is set while drawing and not at `realize`: from
there it does not reach the compositor, and the strip lies across the whole
width of the bar.

It is visible on the lock screen as well, in the same place and without
covering anything: so you can tell without unlocking that a switch is engaged.
