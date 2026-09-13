#!/usr/bin/env python3
"""Sign both architecture archives, verify with the committed public key, create release feeds."""
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NS)

def appcast(config, arch, archive_name, length, signature):
    assert arch in ('arm64', 'x86_64')
    assert re.fullmatch(r'\d+\.\d+\.\d+', config['version'])
    assert len(base64.b64decode(signature, validate=True)) == 64
    rss = ET.Element('rss', {'version':'2.0'})
    channel = ET.SubElement(rss, 'channel')
    ET.SubElement(channel, 'title').text = f'Image Harbor ({arch})'
    ET.SubElement(channel, 'link').text = f'https://github.com/{config["repository"]}'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = 'Image Harbor ' + config['version']
    ET.SubElement(item, 'pubDate').text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, f'{{{NS}}}version').text = config['build']
    ET.SubElement(item, f'{{{NS}}}shortVersionString').text = config['version']
    ET.SubElement(item, f'{{{NS}}}minimumSystemVersion').text = config['minimum_macos']
    ET.SubElement(item, 'description').text = '原生 macOS 图片采集、系统代理恢复、三种导出与签名更新。安装前会停止采集并恢复原系统代理。'
    ET.SubElement(item, 'enclosure', {
        'url': f'https://github.com/{config["repository"]}/releases/download/v{config["version"]}/{archive_name}',
        'length': str(length), 'type':'application/octet-stream', f'{{{NS}}}edSignature':signature,
        f'{{{NS}}}os':'macos'
    })
    return ET.tostring(rss, encoding='utf-8', xml_declaration=True)

def main():
    source, dest = map(lambda x: Path(x).resolve(), sys.argv[1:])
    config = json.loads((ROOT/'release/config.json').read_text())
    vendor = Path(os.environ.get('VENDOR_ROOT', ROOT/'work/vendor'))
    sign = vendor/'sparkle/bin/sign_update'
    verifier = ROOT/'work/verify-update'
    verifier.parent.mkdir(exist_ok=True)
    subprocess.run(['swiftc', str(ROOT/'scripts/VerifyUpdate.swift'), '-o', str(verifier)], check=True)
    dest.mkdir(parents=True, exist_ok=True)
    for arch in ['arm64', 'x86_64']:
        for ext in ['dmg', 'zip']:
            name = f'ImageHarbor-{config["version"]}-{arch}.{ext}'
            matches = list(source.rglob(name))
            if len(matches) != 1: raise RuntimeError(f'Expected exactly one {name}, got {len(matches)}')
            target = dest/name
            if matches[0] != target: shutil.copy2(matches[0], target)
        archive = dest/f'ImageHarbor-{config["version"]}-{arch}.zip'
        secret = os.environ.get('SPARKLE_PRIVATE_KEY')
        env = {k:v for k,v in os.environ.items() if k != 'SPARKLE_PRIVATE_KEY'}
        if os.environ.get('CI') == 'true' and not secret: raise RuntimeError('SPARKLE_PRIVATE_KEY must be configured for release')
        args = [str(sign), '--ed-key-file', '-', '-p', str(archive)] if secret else [str(sign), '--account', 'UnityX103.ImageHarbor', '-p', str(archive)]
        signature = subprocess.run(args, input=secret, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, check=True).stdout.strip()
        subprocess.run([str(verifier), str(ROOT/'release/sparkle-public-key.txt'), str(archive), signature], check=True)
        (dest/f'appcast-{arch}.xml').write_bytes(appcast(config, arch, archive.name, archive.stat().st_size, signature))
    files = sorted(p for p in dest.iterdir() if p.suffix in ['.dmg','.zip','.xml'])
    (dest/'SHA256SUMS.txt').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in files))
    print('Both architectures signed and feeds created.')
if __name__ == '__main__': main()
