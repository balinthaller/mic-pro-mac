#!/usr/bin/env python3
"""Use the same certificate and designated requirement for every local build."""
from pathlib import Path
import subprocess, sys
root = Path(__file__).resolve().parent.parent
folder = root / '.signing'
keychain = folder / 'MicPro.keychain-db'
if not keychain.exists():
    raise SystemExit('Local signing identity missing. Run scripts/setup-local-signing.py first.')
password = (folder / 'password').read_text()
unlock = subprocess.run(['/usr/bin/security','unlock-keychain','-p',password,str(keychain)], capture_output=True, text=True)
if unlock.returncode:
    raise SystemExit('Cannot unlock app-local signing keychain: '+unlock.stderr.strip())
fingerprint = subprocess.check_output(['/usr/bin/openssl','x509','-in',str(folder / 'certificate.pem'),'-noout','-fingerprint','-sha1'], text=True).strip().split('=')[1].replace(':','')
requirement = 'designated => identifier "org.micpromac.public-preview" and certificate leaf = H"'+fingerprint+'"'
target = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'build/Mic Pro Probe.app'
helper = target / 'Contents/MacOS/MicProBatteryReader'
if helper.exists():
    helper_id = 'org.micpromac.public-preview.battery'
    helper_req = 'designated => identifier "'+helper_id+'" and certificate leaf = H"'+fingerprint+'"'
    subprocess.run(['/usr/bin/codesign','--force','--sign',fingerprint,'--keychain',str(keychain),'--timestamp=none','--identifier',helper_id,'--requirements','='+helper_req,str(helper)], check=True)
subprocess.run(['/usr/bin/codesign','--force','--sign',fingerprint,'--keychain',str(keychain),'--timestamp=none','--requirements','='+requirement,str(target)], check=True)
subprocess.run(['/usr/bin/codesign','--verify','--strict',str(target)], check=True)
