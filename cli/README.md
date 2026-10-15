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

Find them in two guided reads:

```sh
micproctl probe diff
# …change exactly ONE setting on the device (vendor app or hardware buttons)…
# press ENTER; the CLI re-reads and prints the byte that moved
```

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

## Development

```sh
python3 scripts/test-public.py        # upstream suites + the CLI suite (offline)
python3 scripts/test-public.py CLI    # CLI suite only
```

The CLI suite exercises field semantics, the runtime protocol map, the guarded
write ladder (ack/verify/abort/no-op/validation/timeouts) and raw group reads,
all offline, no Bluetooth.
