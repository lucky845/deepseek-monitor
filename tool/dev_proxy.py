#!/usr/bin/env python3
"""Serve the web build and proxy DeepSeek's API so a browser can reach it.

A page may not call `platform.deepseek.com` directly: the platform answers
without a single `access-control-*` header, so the browser discards the
response ("TypeError: Failed to fetch"). Node projects solve this with a dev
server proxy; this is the same idea with no dependencies beyond the stdlib.

    python3 tool/dev_proxy.py --port 8787 --root build/web

    # point the app at it, either for one session
    http://127.0.0.1:8787/?api_base=http://127.0.0.1:8787/platform-api

    # ...or at build time
    flutter build web --dart-define=PLATFORM_API_BASE=http://127.0.0.1:8787/platform-api

Routes:
    /platform-api/<rest>  ->  https://platform.deepseek.com/<rest>
    /api-base/<rest>      ->  https://api.deepseek.com/<rest>

`--force-token-file` swaps whatever the client sent for the token in that file,
so the real credential never has to be typed into a dev browser.
"""

from __future__ import annotations

import argparse
import os
import posixpath
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = {
    '/platform-api': 'https://platform.deepseek.com',
    '/api-base': 'https://api.deepseek.com',
}

# The platform sits behind bot protection: a request without a browser
# User-Agent gets HTTP 429 and an HTML "Error - Request Blocked" page.
BROWSER_UA = (
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36'
)

FORWARDED = (
    'authorization',
    'accept',
    'content-type',
    'x-app-version',
    'x-client-platform',
    'x-client-version',
    'x-client-locale',
)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--port', type=int, default=8787)
    p.add_argument('--host', default='127.0.0.1')
    p.add_argument('--root', default='build/web', help='static files to serve')
    p.add_argument(
        '--force-token-file',
        default=None,
        help='file holding a platform token; replaces the client Authorization',
    )
    return p.parse_args()


ARGS = parse_args()
ROOT = os.path.abspath(ARGS.root)


def forced_token() -> str | None:
    if not ARGS.force_token_file:
        return None
    try:
        with open(ARGS.force_token_file, encoding='utf-8') as fh:
            raw = fh.read().strip()
    except OSError as exc:
        print(f'! cannot read token file: {exc}', file=sys.stderr, flush=True)
        return None
    if not raw:
        return None
    return raw if raw.lower().startswith('bearer ') else f'Bearer {raw}'


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, fmt: str, *args) -> None:  # noqa: D401 - quieter default
        return

    def do_GET(self) -> None:  # noqa: N802 - stdlib naming
        if self._proxy('GET'):
            return
        self._static()

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get('content-length') or 0)
        self._body = self.rfile.read(length) if length else b''
        if self._proxy('POST'):
            return
        self.send_error(404)

    # --- proxy ------------------------------------------------------------
    def _proxy(self, method: str) -> bool:
        for prefix, origin in UPSTREAM.items():
            if self.path == prefix or self.path.startswith(prefix + '/'):
                rest = self.path[len(prefix):] or '/'
                self._forward(method, origin + rest)
                return True
        return False

    def _forward(self, method: str, url: str) -> None:
        headers = {'User-Agent': BROWSER_UA, 'Accept': 'application/json'}
        for name in FORWARDED:
            value = self.headers.get(name)
            if value:
                headers[name] = value
        token = forced_token()
        if token:
            headers['Authorization'] = token

        body = getattr(self, '_body', None)
        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        started = time.time()
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                payload = resp.read()
                status = resp.status
                ctype = resp.headers.get('content-type', 'application/json')
        except urllib.error.HTTPError as exc:
            payload = exc.read()
            status = exc.code
            ctype = exc.headers.get('content-type', 'application/json')
        except Exception as exc:  # noqa: BLE001 - surfaced to the browser
            print(f'  {method} {url} -> proxy error: {exc}', file=sys.stderr, flush=True)
            self._send(502, b'proxy error', 'text/plain')
            return

        took = (time.time() - started) * 1000
        print(f'  {method} {self.path} -> {status} ({took:.0f}ms)', flush=True)
        self._send(status, payload, ctype)

    # --- static -----------------------------------------------------------
    def _static(self) -> None:
        path = urllib.request.url2pathname(self.path.split('?', 1)[0])
        if path.endswith('/'):
            path += 'index.html'
        target = os.path.abspath(os.path.join(ROOT, path.lstrip('/')))
        if not target.startswith(ROOT + os.sep) and target != ROOT:
            self.send_error(403)
            return
        if os.path.isdir(target):
            target = os.path.join(target, 'index.html')
        if not os.path.isfile(target):
            # Flutter's router lives in the page, so unknown paths still get it.
            target = os.path.join(ROOT, 'index.html')
            if not os.path.isfile(target):
                self.send_error(404)
                return
        ctype = _ctype(target)
        with open(target, 'rb') as fh:
            payload = fh.read()
        if target.endswith('.html'):
            payload = _inject_bases(payload)
        self._send(200, payload, ctype)

    def _send(self, status: int, payload: bytes, ctype: str) -> None:
        self.send_response(status)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(payload)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(payload)


def _inject_bases(payload: bytes) -> bytes:
    """Tell the app where the proxy lives, so no query string is needed.

    Without this you have to open `/?api_base=http://<host>:<port>/platform-api`
    — fine on a laptop, miserable on a phone, and easy to lose when the address
    is reopened from history. The injected value is a same-origin path, so it is
    correct for every host the page can be reached on.
    """
    html = payload.decode('utf-8', 'replace')
    if '__DS_PLATFORM_API_BASE__' in html:
        return payload
    script = (
        '<script>'
        "window.__DS_PLATFORM_API_BASE__='/platform-api';"
        "window.__DS_API_BASE__='/api-base';"
        '</script>'
    )
    marker = '</head>'
    if marker in html:
        html = html.replace(marker, script + marker, 1)
    else:
        html = script + html
    return html.encode('utf-8')


def _ctype(path: str) -> str:
    ext = posixpath.splitext(path)[1].lower()
    return {
        '.html': 'text/html; charset=utf-8',
        '.js': 'text/javascript; charset=utf-8',
        '.mjs': 'text/javascript; charset=utf-8',
        '.json': 'application/json; charset=utf-8',
        '.css': 'text/css; charset=utf-8',
        '.png': 'image/png',
        '.jpg': 'image/jpeg',
        '.jpeg': 'image/jpeg',
        '.webp': 'image/webp',
        '.svg': 'image/svg+xml',
        '.ico': 'image/x-icon',
        '.wasm': 'application/wasm',
        '.ttf': 'font/ttf',
        '.otf': 'font/otf',
        '.woff': 'font/woff',
        '.woff2': 'font/woff2',
    }.get(ext, 'application/octet-stream')


def main() -> int:
    if not os.path.isdir(ROOT):
        print(f'! {ROOT} does not exist — run `flutter build web` first', file=sys.stderr)
        return 2
    server = ThreadingHTTPServer((ARGS.host, ARGS.port), Handler)
    print(f'serving {ROOT}', flush=True)
    print(f'  http://{ARGS.host}:{ARGS.port}/', flush=True)
    print(f'  ?api_base=http://{ARGS.host}:{ARGS.port}/platform-api', flush=True)
    if ARGS.force_token_file:
        print(f'  Authorization forced from {ARGS.force_token_file}', flush=True)
    print('  /platform-api/* -> https://platform.deepseek.com/*', flush=True)
    print('  /api-base/*     -> https://api.deepseek.com/*', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\nstopped')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
