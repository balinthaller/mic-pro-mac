#!/usr/bin/env python3
"""Create a persistent, app-specific signing identity in a private local keychain."""
from pathlib import Path
import os, secrets, subprocess
root = Path(__file__).resolve().parent.parent
folder = root / '.signing'
folder.mkdir(mode=0o700, exist_ok=True)
os.chmod(folder, 0o700)
keychain = folder / 'MicPro.keychain-db'
password_file = folder / 'password'
if keychain.exists():
    print('Local signing keychain already exists; preserving it.')
    raise SystemExit(0)
os.umask(0o077)
password = secrets.token_urlsafe(32)
password_file.write_text(password)
config = folder / 'certificate.cnf'
config.write_text('''[req]
prompt = no
distinguished_name = dn
x509_extensions = extensions
[dn]
CN = Mic Pro Local Signing
[extensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
''')
key, cert, archive = folder / 'key.pem', folder / 'certificate.pem', folder / 'identity.p12'
def run(args):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode:
        # Never include arguments: they contain ephemeral keychain/archive passwords.
        raise RuntimeError(result.stderr.strip())
run(['/usr/bin/openssl','req','-new','-x509','-newkey','rsa:2048','-nodes','-days','3650','-config',str(config),'-keyout',str(key),'-out',str(cert)])
run(['/usr/bin/openssl','pkcs12','-export','-inkey',str(key),'-in',str(cert),'-name','Mic Pro Local Signing','-out',str(archive),'-passout','pass:'+password])
run(['/usr/bin/security','create-keychain','-p',password,str(keychain)])
run(['/usr/bin/security','set-keychain-settings','-lut','21600',str(keychain)])
run(['/usr/bin/security','unlock-keychain','-p',password,str(keychain)])
run(['/usr/bin/security','import',str(archive),'-k',str(keychain),'-P',password,'-T','/usr/bin/codesign'])
run(['/usr/bin/security','set-key-partition-list','-S','apple-tool:,apple:','-s','-k',password,str(keychain)])
key.unlink(); archive.unlink()
print('Created app-local signing identity; certificate and keychain will be reused.')
