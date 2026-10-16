#!/usr/bin/env python3
"""Offline public-preview checks. Does not open, scan, or write a Bluetooth device."""
import json, os, subprocess, tempfile, sys
from pathlib import Path
root=Path(__file__).resolve().parent.parent
jobs={
 'DeviceConfig':['DeviceConfig'],
 'AppControl':['DeviceConfig','Protocol','BatteryInfo','AppControlReadPlan'],
 'AppPulse':['DeviceConfig','Protocol','BatteryInfo','AppControlReadPlan','AppControlPulsePlan'],
 'Charging':['DeviceConfig','Protocol','BatteryInfo','AppControlReadPlan'],
 'Power':['PowerInsights'],
 'Handoff':['DeviceHandoffState'],
 'HandoffObservation':['HandoffObservation'],
 'DiscoveryObserver':['DeviceConfig','DiscoveryObservationModel'],
 'Sidebar':['SidebarPresentation','EdgeDockIntent','DockMicAction','EdgeDockLayout'],
 'CodexQuota':['DeviceConfig','CodexQuota'],
 'Transfers':['Protocol','WallpaperReadPlan','RecordingTransfers'],
 'CLI':['DeviceConfig','Protocol','AppControlReadPlan','BatteryInfo','WallpaperReadPlan','WallpaperUploadPlan',
        'SystemBattery','cli/Sources/fields.swift','cli/Sources/engine.swift','cli/Sources/transport.swift'],
}
frameworks={'CLI':['-framework','AppKit','-framework','CoreBluetooth','-framework','IOBluetooth']}
def source_path(name):
 return str(root/'Sources'/f'{name}.swift') if '/' not in name else str(root/name)

with tempfile.TemporaryDirectory(prefix='micpro-public-tests-') as temporary:
 folder=Path(temporary);config=folder/'fixture.json'
 config.write_text(json.dumps({'bluetooth_address':'AA:BB:CC:DD:EE:01','serial_suffix':'TEST01','codex_quota_enabled':False}))
 selected=sys.argv[1:] or list(jobs)
 for name in selected:
  sources=jobs[name]
  print('Checking',name,flush=True)
  binary=folder/name
  subprocess.run(['swiftc','-module-cache-path',str(folder/'cache'),*[source_path(s) for s in sources],str(root/'Tests'/name/'main.swift'),'-o',str(binary)]+frameworks.get(name,[]),check=True)
  env=os.environ.copy();env['MICPRO_CONFIG']=str(folder/'missing.json' if name=='DeviceConfig' else config)
  subprocess.run([str(binary)],check=True,env=env)
 subprocess.run(['swiftc','-typecheck','-module-cache-path',str(folder/'cache'),*[str(p) for p in sorted((root/'Sources').glob('*.swift'))],'-framework','AppKit','-framework','Carbon','-framework','CoreBluetooth','-framework','CoreAudio','-framework','IOBluetooth'],check=True)
print('PASS: checked '+', '.join(selected)+' and full-source typecheck')
