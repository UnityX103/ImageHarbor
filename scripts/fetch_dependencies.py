#!/usr/bin/env python3
"""Fetch official binary dependencies with pinned checksums; never fetch unpinned latest."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

def sha256(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''): h.update(chunk)
    return h.hexdigest()

def fetch(url, archive, digest, destination, expected):
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.exists() or sha256(archive) != digest:
        temp = archive.with_suffix(archive.suffix + '.part')
        subprocess.run(['curl', '--fail', '--location', '--silent', '--show-error', '--retry', '3', '--proto', '=https', url, '-o', str(temp)], check=True)
        if sha256(temp) != digest:
            temp.unlink(missing_ok=True)
            raise RuntimeError('Dependency checksum mismatch: ' + archive.name)
        temp.replace(archive)
    marker = destination / '.verified-sha256'
    if not expected.exists() or not marker.exists() or marker.read_text() != digest:
        destination.mkdir(parents=True, exist_ok=True)
        subprocess.run(['tar', '-xf', str(archive), '-C', str(destination)], check=True)
        if not expected.exists(): raise RuntimeError('Archive did not contain ' + str(expected))
        marker.write_text(digest)
    print('Verified ' + archive.name)

def main():
    arch = sys.argv[1] if len(sys.argv) > 1 else os.uname().machine
    if arch not in ['arm64', 'x86_64']: raise SystemExit('Supported architectures: arm64, x86_64')
    config = json.loads((ROOT / 'release/config.json').read_text())
    vendor = Path(os.environ.get('VENDOR_ROOT', ROOT / 'work/vendor')).resolve()
    mitm = config['mitmproxy']; ver = mitm['version']
    name = f'mitmproxy-{ver}-macos-{arch}.tar.gz'
    dest = vendor / arch
    fetch(f'https://downloads.mitmproxy.org/{ver}/{name}', vendor / name, mitm[arch + '_sha256'], dest, dest / 'mitmproxy.app/Contents/MacOS/mitmdump')
    sparkle = config['sparkle']; ver = sparkle['version']; name = f'Sparkle-{ver}.tar.xz'
    dest = vendor / 'sparkle'
    fetch(f'https://github.com/sparkle-project/Sparkle/releases/download/{ver}/{name}', vendor / name, sparkle['sha256'], dest, dest / 'Sparkle.framework/Sparkle')

if __name__ == '__main__': main()
