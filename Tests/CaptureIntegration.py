import base64, gzip, http.server, json, os, pathlib, socket, ssl, subprocess, tempfile, threading, time, sys
SOURCE = pathlib.Path(__file__).resolve().parents[1]
ENGINE = pathlib.Path(sys.argv[1]).resolve()
PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=')
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = PNG if self.path != '/text' else b'hello'
        mime = 'image/png' if self.path != '/text' else 'text/plain'
        if self.path == '/sniff': mime = 'application/octet-stream'
        if self.path == '/svg': body = b'<svg xmlns="http://www.w3.org/2000/svg"/>'; mime = 'image/svg+xml'
        if self.path == '/gzip': body = gzip.compress(body)
        self.send_response(206 if self.path == '/partial' else 200)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body)))
        if self.path == '/gzip': self.send_header('Content-Encoding', 'gzip')
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *args): pass

def free_port():
    with socket.socket() as s: s.bind(('127.0.0.1',0)); return s.getsockname()[1]

with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    conf = root/'certificates'
    server = http.server.ThreadingHTTPServer(('127.0.0.1',0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(root/'key.pem'),'-out',str(root/'cert.pem'),'-days','1','-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost,IP:127.0.0.1'],check=True, stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    https = http.server.ThreadingHTTPServer(('127.0.0.1',0), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(root/'cert.pem',root/'key.pem')
    https.socket = ctx.wrap_socket(https.socket,server_side=True)
    threading.Thread(target=https.serve_forever, daemon=True).start()
    port = free_port()
    env = dict(os.environ, IMAGE_HARBOR_DATA=tmp, IMAGE_HARBOR_PARENT=str(os.getpid()))
    args = [str(ENGINE),'--listen-host','127.0.0.1','--listen-port',str(port),'--set',f'confdir={conf}','--set',f'ssl_verify_upstream_trusted_ca={root / "cert.pem"}','-s',str(SOURCE/'capture.py')]
    with (root/'engine.log').open('w') as log:
        p = subprocess.Popen(args,env=env,stdout=log,stderr=log)
        try:
            deadline = time.time()+25
            while not (root/'ready').exists():
                if p.poll() is not None or time.time()>deadline: raise RuntimeError((root/'engine.log').read_text())
                time.sleep(.1)
            for path in ['/png','/png?variant=2','/gzip','/sniff','/svg','/text','/partial']:
                result = subprocess.run(['curl','--silent','--show-error','--fail','--noproxy','','--proxy',f'http://127.0.0.1:{port}',f'http://127.0.0.1:{server.server_port}{path}'],capture_output=True,check=True)
            subprocess.run(['curl','--silent','--show-error','--fail','--noproxy','','--proxy',f'http://127.0.0.1:{port}','--cacert',str(conf/'mitmproxy-ca-cert.pem'),f'https://localhost:{https.server_port}/png'],capture_output=True,check=True)
            records = [json.loads(line) for line in (root/'records.jsonl').read_text().splitlines()]
            assert len(records)==7, records
            assert len({r['file'] for r in records})==7
            assert sum(r['partial'] for r in records)==1
            assert any(r['url'].startswith('https:') for r in records)
            assert any(r['format']=='svg' for r in records)
            for r in records:
                if r['format']=='png': assert (root/'images'/r['file']).read_bytes()==PNG
            conflict = subprocess.run(args,env=env,capture_output=True,timeout=15)
            assert conflict.returncode != 0
            assert b'address already in use' in (conflict.stderr + conflict.stdout).lower(), (conflict.stderr + conflict.stdout)
            print('PASS: HTTP, HTTPS CONNECT + trusted CA, gzip decoding, content sniffing, SVG, repeated URLs, non-image exclusion, partial labeling, port conflict')
        finally:
            p.terminate(); p.wait(timeout=10); server.shutdown(); https.shutdown()
