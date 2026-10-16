# micproctl — standalone CLI for the Insta360 Mic Pro

`micproctl` is a fork addition: a single, self-contained command-line tool that
talks to an Insta360 Mic Pro TX **without running the menu-bar app**. It reuses
the upstream Swift protocol implementation directly (same files, one source of
truth; MIT).

Verified on firmware 2.0.2.4 by upstream; every write follows the same
transactional discipline (whole-group write, full read-back verification,
no automatic retries).

## Build

```sh
./cli/build.sh          # → build/micproctl
```

## First-run setup

The Mic Pro must already be paired in macOS Bluetooth settings (it pairs as
an audio device like normal). Then:

```sh
./build/micproctl configure --list                  # find your unit's BT address
./build/micproctl configure --address AA:BB:CC:DD:EE:01 --suffix XXXXXX
```

`--suffix` is the last six characters of the device name (as configured in the
vendor app). Everything is additionally verified against the device's own
serial identity during each session, so a stale configuration can never talk
to the wrong device.

## Daily commands

```sh
micproctl status                 # battery, charging, both settings groups, e-ink md5
micproctl battery                # just the battery
micproctl battery --classic      # no control session; macOS BT cache only
micproctl settings               # decoded settings, both groups
micproctl set gain -6            # input gain, -12...12 dB
micproctl set noise off|on|high
micproctl set mute on|off
micproctl set float32 on|off     # 32-bit float recording
micproctl set lowcut on|off
micproctl set led on|off
micproctl set vibration on|off
micproctl set childlock on|off
```

Add `--json` for machine-readable output.

### Transports

* **rfcomm** (default whenever the mic is connected to macOS as an audio
  device): a serial control channel the mic exposes alongside audio. Works
  while the mic is live as your input device.
* **ble**: the app-link BLE service (same one the vendor phone app uses).
  Requires the device to accept a control connection; if nothing is found,
  triple-press the power button to put the TX in pairing/advertising mode.
  Control and audio are mutually exclusive on this path (the CLI will tell
  you and suggest `micproctl disconnect-audio` first if needed).

`--transport auto|ble|rfcomm` forces a specific transport.

## E-ink screen

The wallpaper slot is the one piece of device state an upload can *erase*, so
the CLI keeps upstream's gates: upload only from a **verified backup of the
current screen**, and every upload ends with a **full read-back** that must
byte-match what we sent.

```sh
micproctl wallpaper backup                        # verified backup of current screen →
                                                  #   ~/Library/Application Support/MicProMac/backups/<uuid>/
micproctl wallpaper upload my-image.png           # auto-uses the newest verified backup
micproctl wallpaper upload my-image.png --backup <dir>
micproctl wallpaper restore --backup <dir>        # restores a verified backup
```

Images are rendered to the 240×240 six-color panel format (nearest-color +
optional dithering upstream calls "六色量化") and wilfully round-trip through
the panel codec before anything is sent. `wallpaper backup` after an upload is
automatic in each upload/restore invocation.

## Mapping the unmapped fields: pattern, mono/stereo, bit depth

The two settings groups (6-byte `0x1000` "common", 12-byte `0x1012` "more")
hold every normal transmitter setting, but upstream has only decoded part of
them. Known so far: recording state, mute, gain, noise reduction, 32-bit
float, low-cut, child lock, vibration, LED. The remaining bytes encode the
pattern (omni/cardioid/figure-8/…), mono/stereo, and bit-depth selection —
but their exact positions/values differ per firmware.

Find them in two guided reads. **You do not need the Mac to change settings
here** — the phone app does the writing, the CLI does the reading. The TX
serves both links at once: it streams audio to the Mac over classic
Bluetooth while the phone app talks to it over its BLE app-link (the same
way the app controls the TX during normal phone use).

```sh
micproctl probe diff          # snapshot 1
# …in the phone app, change exactly ONE setting (e.g. pattern → cardioid),
#   wait for the app / e-ink to confirm the change…
# press ENTER                  # snapshot 2; the CLI prints the byte that moved:
#   group 0x1012 byte [6]: 0 -> 1
```

Repeat the diff for each remaining value of the same field
(omni→cardioid, cardioid→figure-8, …) — every diff pins one more value.

Practice first with a known-good setting: toggling **mute** on the device
should produce a one-line delta at `group 0x1000 byte [1]`. That validates
your technique and the tool before you touch the app-only settings.

If extra groups are needed (in case a setting lives outside the two known
groups), name them and they are diffed too, read-only:

```sh
micproctl probe diff 0x1011 0x1013 0x1014 0x1015 0x1016 0x1018 0x1020
```

Tips for the cataloguing session:

* One setting per diff. If two bytes move, repeat — the app sometimes also
  updates a companion byte; the pattern will become obvious across runs.
* Compare the app's current values with `micproctl settings` output first:
  things like gain and noise reduction line up 1:1, which tells you what a
  "sane" mapping looks like before discovering the unmapped bytes.
* The vendor "bit depth" choice is very likely the known 32-bit-float byte
  (`set float32`) — test it with a diff before hunting for a new byte.
* If the mic will not come back to the Mac while the app is open, fully
  close the app (or toggle the phone's Bluetooth off) and run
  `micproctl connect-audio` — the TX accepts a new host page and drops the
  phone link.

When you know the byte and its values, add it to
`~/Library/Application Support/MicProMac/protocol-map.json`:

```json
{
  "pattern":  {"group": "0x1012", "index": 6, "values": {"omni": 0, "cardioid": 1, "figure8": 2, "stereo": 3}},
  "bitdepth": {"group": "0x1012", "index": 5, "values": {"16": 0, "24": 1, "32f": 2}},
  "mono":     {"group": "0x1012", "index": 1, "values": {"off": 0, "on": 1}}
}
```

…and it becomes a first-class verb:

```sh
micproctl set pattern figure8
micproctl set bitdepth 24
```

Mapped fields get the same whole-group guarded write as built-ins, and
`micproctl fields` lists everything currently known (built-in or mapped).

`micproctl probe read 0x1010 0x1011 0x1013 …` dumps arbitrary group envelopes
read-only (values shown as raw hex, including the trailing protocol bytes).

## Safety notes

* No network. No listeners. The binary talks Bluetooth only, and only to the
  configured device, only after the device itself re-confirms its identity.
* Writes are whole-group with full read-back and **never retried**; concurrent
  changes on the device abort the transaction rather than clobbering.
* The wallpaper BEGIN can erase the screen slot before the transfer finishes —
  that's why uploads insist on a fresh verified backup and re-read the panel
  at the end. Restoration material is kept in the backup directory
  (`restoration-plan.json`, proposed/original PNG + packed panel).
* Nothing here flashes or touches firmware paths.
* First control session per power cycle requires a physical confirmation: the
  CLI prints "single-press the power button now" when the device asks for it.

## Troubleshooting

**"the Mic Pro is not connected over Bluetooth right now"** — macOS tears the
audio link down whenever no app is capturing the mic, and the TX powers its
radio off when idle. Power the mic on and run `micproctl connect-audio`, or
start any app that captures its input. Settings/battery can also run over
`--transport ble` without the audio link (triple-press power if BLE discovery
finds nothing — the control broadcast only runs in pairing mode while idle).

**First control per power cycle asks for a button press** — the device
requires physical confirmation; the CLI prints
`AUTHORIZATION: single-press the power button…`. On the TX that same press
doubles as a noise-cancellation toggle; read the state afterwards with
`micproctl settings` and restore with `micproctl set noise …` if it moved.

**`RFCOMM channel 10 never opened`** — the link dropped mid-session, another
control client (vendor phone app) holds the session, or this firmware
publishes the settings serial elsewhere: `micproctl doctor` lists every
service and channel; retry with `--rfcomm-channel N` or `--transport ble`.

**First BLE use from a terminal** — macOS shows a Bluetooth permission prompt
for the terminal app once; approve it (headless/SSH sessions cannot show it —
grant access in System Settings → Privacy & Security → Bluetooth).

**Everything failing weirdly** — rerun with `MICPROCTL_DEBUG=1` and check
`micproctl doctor`.

## Development

```sh
python3 scripts/test-public.py        # upstream suites + the CLI suite (offline)
python3 scripts/test-public.py CLI    # CLI suite only
```

The CLI suite exercises field semantics, the runtime protocol map, the guarded
write ladder (ack/verify/abort/no-op/validation/timeouts) and raw group reads,
all offline, no Bluetooth.
