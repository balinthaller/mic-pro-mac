#!/usr/bin/env python3
"""Configure one explicitly selected, already-paired Mic Pro. No Bluetooth writes."""
import argparse, json, os, re, subprocess, tempfile
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--list',action='store_true',help='list paired Mic Pro devices using the built helper')
parser.add_argument('--address',help='Bluetooth address of your own paired Mic Pro')
parser.add_argument('--suffix',help='six-character suffix in your device name')
parser.add_argument('--output',type=Path,default=Path.home()/'Library/Application Support/MicProMac/config.json')
args=parser.parse_args()
if args.list:
    helper=Path(__file__).resolve().parent.parent/'build/Mic Pro Probe.app/Contents/MacOS/MicProBatteryReader'
    if not helper.is_file(): parser.error('build the app and open it once before listing paired devices')
    raise SystemExit(subprocess.run([str(helper),'--paired-devices']).returncode)
address=(args.address or '').upper().replace('-',':')
suffix=(args.suffix or '').upper()
if not re.fullmatch(r'[0-9A-F]{2}(:[0-9A-F]{2}){5}',address) or address in ('00:00:00:00:00:00','FF:FF:FF:FF:FF:FF'):
    parser.error('provide your own valid Bluetooth address with --address')
if not re.fullmatch(r'[A-Z0-9]{6}',suffix): parser.error('--suffix must contain exactly six letters/digits')
settings={'bluetooth_address':address,'serial_suffix':suffix,'codex_quota_enabled':False}
if args.output.exists():
    try: previous=json.loads(args.output.read_text())
    except (OSError,ValueError): parser.error('existing config is invalid; inspect it before replacing')
    settings['codex_quota_enabled']=previous.get('codex_quota_enabled') is True
args.output.parent.mkdir(parents=True,exist_ok=True)
fd,name=tempfile.mkstemp(prefix='.config-',dir=args.output.parent)
try:
    os.fchmod(fd,0o600)
    with os.fdopen(fd,'w') as handle: json.dump(settings,handle,indent=2);handle.write('\n')
    os.replace(name,args.output)
finally:
    if os.path.exists(name): os.unlink(name)
print('Saved device configuration. Restart Mic Pro Mac to apply it.')
