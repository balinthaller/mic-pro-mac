# Mic Pro Mac — CLI edition

Native macOS tools for the **Insta360 Mic Pro**. This repository contains two
things:

1. **`micproctl`** — a standalone command-line tool (added by this fork) that
   puts the mic's settings, battery and e-ink display under your control from
   the terminal. No vendor app, no menu bar, no restarts.
2. The original **menu-bar app** by [george-wyy](https://github.com/george-wyy/mic-pro-mac)
   — e-ink wallpaper editor, device status, recordings export (see below).

Unofficial interoperability project, not affiliated with Insta360. Verified on
one Mic Pro TX, firmware **2.0.2.4**; other devices/firmware may differ.
Licensed MIT (see [Credits](#credits--license)).

---

## micproctl

### Build

```sh
./cli/build.sh            # produces build/micproctl
```

Requires macOS with Xcode Command Line Tools (frameworks: IOBluetooth,
CoreBluetooth, AppKit — no vendor SDK, no third-party dependencies).

### First run

Pair your Mic Pro TX in macOS Bluetooth Settings once, then:

```sh
build/micproctl doctor                       # checks pairing + config, suggests next steps
build/micproctl configure --list             # lists paired Mic devices
build/micproctl configure --address AA:BB:CC:DD:EE:01 --suffix TEST01   # your values (fictional example)
```

If the device requests physical confirmation, follow the on-screen prompt
(single press of the TX power button).

### Daily use

```sh
micproctl status                # battery, charging, all settings, e-ink checksum
micproctl battery               # just the battery line
micproctl settings              # decoded settings groups (--raw for hex)

micproctl set pattern omni|cardioid|figure8|voicefocus   # sound direction
micproctl set stereo on|off     # off = mono
micproctl set float32 on|off    # bit depth (off = firmware enforces clipping protection)
micproctl set gain -12…12       # input level in dB
micproctl set noise off|on|high
micproctl set mute|lowcut|led|vibration|childlock on|off

micproctl connect-audio         # page the TX as the Mac audio device
micproctl disconnect-audio      # release it (e.g. to hand over to the phone app)

micproctl wallpaper backup      # verified backup of the e-ink image
micproctl wallpaper upload img.png
micproctl wallpaper restore --backup DIR
```

Add `--json` anywhere for machine-readable output; `fields` lists every known
setting; `probe read/diff` are read-only research commands (below).

### Mapped settings

| Setting | CLI | Location | Values |
|---|---|---|---|
| Recording state (read-only) | `status` | `0x1000[0]` | active/inactive |
| Mute | `set mute` | `0x1000[1]` | on/off |
| Input gain | `set gain` | `0x1000[2]` | −12…12 dB (Int8) |
| Noise reduction | `set noise` | `0x1000[3]` | off/on/high |
| 32-bit float (bit depth) | `set float32` | `0x1012[0]` | on/off |
| Stereo / mono | `set stereo` | `0x1012[1]` | on/off |
| Low-cut filter | `set lowcut` | `0x1012[4]` | on/off |
| Sound direction | `set pattern` | `0x1012[6]` | omni=0, cardioid=1, figure8=2, voicefocus=3 |
| Child lock | `set childlock` | `0x1012[8]` | on/off |
| Vibration alerts | `set vibration` | `0x1012[9]` | on/off |
| LED indicator | `set led` | `0x1012[10]` | on/off |
| Battery + charging | `battery` | BLE 180F + serial 0x1005 | percent, charging state |

All of these were mapped by live probe diffs and verified by write/read-back
round-trips on hardware. Bytes still unknown: `0x1000[4,5]`, `0x1012[2,3,5,7,11]`.

### How writes are kept safe

Every `set` is one transaction on a single settings group: **read → write →
full read-back verification** with a device acknowledgement; a mismatch fails
the command loudly. Writes are never auto-retried. Wallpaper uploads refuse to
run without a previously verified backup. The e-ink path always uses the
vendor's RFCOMM channel 10; settings/battery prefer RFCOMM when the mic is
connected as an audio device and fall back to BLE for read-only work. After a
reconnect, a failed open is retried once after 3 s to absorb the TX's serial
server settle time.

### Vendor behavior notes (observed on hardware, 2.0.2.4)

* **Gain mode couples to bit depth.** With 32-bit float **off** the firmware
  forces the "prevent audio clipping" limiter; toggling the app's gain mode
  moves no stored settings byte. With float32 **on**, manual gain applies.
  From the CLI: `set float32 on` + `set gain …`. The limiter may still engage
  on its own even in float32 mode.
* **One controller at a time.** The TX serves a single audio host, and the
  vendor app wants the audio link as well — hand the mic over explicitly with
  `disconnect-audio` / `connect-audio` instead of expecting simultaneous
  phone + Mac sessions.
* **The power-button confirmation doubles as a noise toggle** on the TX.
  After an authorization press, check `settings` and restore `noise` if moved.

### When the firmware changes

If a future firmware shifts bytes around, re-map without rebuilding:

```sh
micproctl probe diff        # snapshot 1 → disconnect-audio → change ONE setting
                            # in the app → close app → connect-audio → ENTER
```

The diff prints which byte moved; confirmed mappings go into
`~/Library/Application Support/MicProMac/protocol-map.json`
(e.g. `{"pattern":{"group":"0x1012","index":6,"values":{"omni":0,…}}}`)
or become built-ins in `cli/Sources/fields.swift`.

---

## The menu-bar app (upstream)

The original app by george-wyy — device status in the menu bar, e-ink
wallpaper import/preview/six-color quantization with verified backup and
upload, Bluetooth/USB recordings export, and a local `micpro` agent CLI.
Its original (Chinese-language) documentation lives at the
[upstream repository](https://github.com/george-wyy/mic-pro-mac) and the
[project page](https://george-wyy.github.io/mic-pro-mac/).

```sh
python3 scripts/setup-local-signing.py
./build.sh
open 'build/Mic Pro Probe.app'
```

Grant Bluetooth permission on first launch. Configuration requires a paired
device matched by address **and** name suffix; vendor protocol reads also
verify device identity. Config, logs, exported recordings and wallpaper
backups live in `~/Library/Application Support/MicProMac/` (`config.json`
is 0600; `MICPRO_CONFIG` overrides the path for testing).

## Development & tests

```sh
python3 scripts/test-public.py      # offline suite (13 jobs; no device contact)
```

The CLI is under `cli/` (`fields.swift` — mappings, `engine.swift` — session
state machine, `transport.swift` — RFCOMM/BLE, `main.swift` — argument
parsing) and reuses the app's protocol sources directly. Two one-line
expressions in `Sources/WallpaperRender.swift` were split into equivalent
sub-expressions so the file type-checks under `-O` on current toolchains;
behavior is unchanged.

## Credits & license

* Upstream app and protocol implementation: [george-wyy/mic-pro-mac](https://github.com/george-wyy/mic-pro-mac) (MIT).
* Protocol research builds on the sources listed in [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).
* `micproctl` and the mapping work documented here: this fork's contributors.
* Insta360, Mic Pro and Tencent are trademarks of their respective owners,
  used only to describe interoperability targets. MIT applies to this
  project's own source code.
