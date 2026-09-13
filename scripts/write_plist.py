#!/usr/bin/env python3
import base64
import json
from pathlib import Path
import plistlib
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
def main():
    arch, output = sys.argv[1:]
    assert arch in ('arm64', 'x86_64')
    config = json.loads((ROOT/'release/config.json').read_text())
    assert re.fullmatch(r'\d+\.\d+\.\d+', config['version'])
    assert config['build'].isdigit()
    public_key = (ROOT/'release/sparkle-public-key.txt').read_text().strip()
    assert len(base64.b64decode(public_key, validate=True)) == 32
    info = {
        'CFBundleExecutable': 'ImageHarbor', 'CFBundleIdentifier': 'local.imageharbor.mac',
        'CFBundleName': 'Image Harbor', 'CFBundleDisplayName': 'Image Harbor', 'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': config['version'], 'CFBundleVersion': config['build'],
        'LSMinimumSystemVersion': config['minimum_macos'], 'LSArchitecturePriority': [arch],
        'CFBundleIconFile': 'AppIcon', 'NSHighResolutionCapable': True, 'NSPrincipalClass': 'NSApplication',
        'SUFeedURL': f'https://github.com/{config["repository"]}/releases/latest/download/appcast-{arch}.xml',
        'SUPublicEDKey': public_key, 'SUEnableAutomaticChecks': True,
        'SUAutomaticallyUpdate': False, 'SUAllowsAutomaticUpdates': False,
        'SUSendProfileInfo': False,
        'NSHumanReadableCopyright': 'Copyright © 2026 UnityX103. MIT License.'
    }
    with open(output, 'wb') as f: plistlib.dump(info, f)
if __name__ == '__main__': main()
