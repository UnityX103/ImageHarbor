"""Image Harbor capture addon. Stores decoded image bodies without changing traffic."""
import asyncio
import hashlib
import json
import mimetypes
import os
from pathlib import Path
import time
import uuid
from mitmproxy import ctx

ROOT = Path(os.environ['IMAGE_HARBOR_DATA'])
ROOT.mkdir(parents=True, exist_ok=True)
(ROOT / 'images').mkdir(exist_ok=True)
MIME_EXT = {'image/jpeg':'jpg', 'image/png':'png', 'image/gif':'gif', 'image/webp':'webp',
            'image/svg+xml':'svg', 'image/avif':'avif', 'image/heic':'heic', 'image/heif':'heif',
            'image/x-icon':'ico', 'image/vnd.microsoft.icon':'ico', 'image/tiff':'tiff',
            'image/bmp':'bmp', 'image/apng':'apng', 'image/jxl':'jxl'}

def detect(body, mime):
    if body.startswith(b'\x89PNG\r\n\x1a\n'): return 'png'
    if body.startswith(b'\xff\xd8\xff'): return 'jpg'
    if body[:6] in (b'GIF87a', b'GIF89a'): return 'gif'
    if body[:4] == b'RIFF' and body[8:12] == b'WEBP': return 'webp'
    if body[:2] == b'BM': return 'bmp'
    if body[:4] in (b'II*\x00', b'MM\x00*'): return 'tiff'
    if body[:4] == b'\x00\x00\x01\x00': return 'ico'
    if body[4:8] == b'ftyp':
        brands = body[8:40]
        if b'avif' in brands or b'avis' in brands: return 'avif'
        if any(b in brands for b in (b'heic', b'heix', b'hevc', b'hevx')): return 'heic'
    if mime.startswith('image/'):
        ext = MIME_EXT.get(mime) or (mimetypes.guess_extension(mime) or '.img').lstrip('.')
        return ''.join(c for c in ext if c.isalnum())[:12] or 'img'
    return None

def append(record):
    with (ROOT / 'records.jsonl').open('a', encoding='utf8') as f:
        f.write(json.dumps(record, ensure_ascii=False) + '\n')

def running():
    (ROOT / 'ready').write_text('ready')
    asyncio.create_task(watch_parent())

async def watch_parent():
    parent = int(os.environ.get('IMAGE_HARBOR_PARENT', '0'))
    if not parent: return
    while True:
        await asyncio.sleep(2)
        try: os.kill(parent, 0)
        except ProcessLookupError:
            ctx.master.shutdown()
            return

def response(flow):
    if not flow.response or flow.request.method == 'HEAD': return
    r = flow.response
    if not 200 <= r.status_code < 300: return
    try:
        body = r.content
        if not body: return
        mime = r.headers.get('content-type', '').split(';')[0].strip().lower()
        ext = detect(body, mime)
        if not ext: return
        ident = str(uuid.uuid4())
        name = ident + '.' + ext
        path = ROOT / 'images' / name
        tmp = path.with_suffix('.tmp')
        tmp.write_bytes(body)
        tmp.replace(path)
        append({'id': ident, 'url': flow.request.pretty_url, 'host': flow.request.host,
                'format': ext, 'mime': mime, 'size': len(body), 'timestamp': time.time(),
                'file': name, 'sha256': hashlib.sha256(body).hexdigest(),
                'status': r.status_code, 'partial': r.status_code == 206})
    except Exception as exc:
        ctx.log.error('Image capture failed: ' + str(exc))
