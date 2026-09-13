#!/usr/bin/env python3
import base64
from pathlib import Path
import plistlib
import subprocess
import sys

def verify(app, arch):
    app = Path(app)
    with (app/'Contents/Info.plist').open('rb') as f: info = plistlib.load(f)
    assert len(base64.b64decode(info['SUPublicEDKey'])) == 32
    assert info['SUFeedURL'].endswith(f'/appcast-{arch}.xml')
    assert info['LSArchitecturePriority'] == [arch]
    for binary in ['Contents/MacOS/ImageHarbor', 'Contents/MacOS/ImageHarborProxy', 'Contents/Resources/mitmproxy.app/Contents/MacOS/mitmdump', 'Contents/Frameworks/Sparkle.framework/Sparkle']:
        found = subprocess.check_output(['lipo', '-archs', str(app/binary)], text=True).split()
        assert arch in found, (binary, found, arch)
    assert not list(app.rglob('mitmproxy-ca.pem')), 'Never bundle a generated CA key'
    assert not list(app.rglob('proxy-restore.plist')), 'Never bundle user proxy settings'
    print(f'PASS: {arch} app, helper, engine, update framework, public key and architecture-specific feed')
if __name__ == '__main__': verify(*sys.argv[1:])
