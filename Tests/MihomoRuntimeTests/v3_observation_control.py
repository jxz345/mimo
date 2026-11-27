#!/usr/bin/env python3
"""Private fixture control over an incoming SSH session, independent of PF denial.

Copy this script to the VM, then run on the host:
  python3 v3_observation_control.py host FIXTURE_JSON SSH_ALIAS REMOTE_SCRIPT
The guest fixture manifest uses control_host=127.0.0.1, control_port=19098.
No SSH forwarding permission or firewall exception is required. Stop the host
process after the campaign; EOF closes the guest listener. Never export manifests.
"""
import base64
import http.server
import ipaddress
import json
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time
import urllib.request


def guest():
    replies = []
    ready = threading.Event()

    class Handler(http.server.BaseHTTPRequestHandler):
        def forward(self, method):
            if self.path != '/':
                self.send_error(404)
                return
            try: length = int(self.headers.get('Content-Length', '0'))
            except ValueError:
                self.send_error(400)
                return
            if (method=='POST' and not 0 < length <= 4096) or (method=='GET' and length!=0):
                self.send_error(400)
                return
            print(json.dumps({'method':method, 'path':self.path,
                              'body': base64.b64encode(self.rfile.read(length)).decode(),
                              'authorization': self.headers.get('Authorization', '')}), flush=True)
            if not ready.wait(10):
                self.send_error(504)
                return
            reply = replies.pop(0)
            ready.clear()
            try: body=base64.b64decode(reply.get('body',''),validate=True)
            except (ValueError,TypeError):
                self.send_error(502)
                return
            if len(body)>1024*1024:
                self.send_error(502)
                return
            self.send_response(reply['status'])
            if method=='GET': self.send_header('Content-Type','application/json')
            self.send_header('Content-Length',str(len(body)))
            self.end_headers()
            if body: self.wfile.write(body)

        def do_POST(self):
            self.forward('POST')

        def do_GET(self):
            self.forward('GET')

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(('127.0.0.1', 19098), Handler)

    def read_replies():
        for line in iter(lambda:sys.stdin.readline(2*1024*1024), ''):
            if not line.endswith('\n'): break
            replies.append(json.loads(line))
            ready.set()
        replies.append({'status':503})
        ready.set()
        server.shutdown()

    threading.Thread(target=read_replies, daemon=True).start()
    try:
        server.serve_forever()
    finally:
        server.server_close()


def host(manifest, alias, remote_script):
    fixture = json.loads(Path(manifest).read_text())
    assert ipaddress.ip_address(fixture['bridge4']).is_private
    child = subprocess.Popen(['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ServerAliveInterval=1',
                              '-o', 'ServerAliveCountMax=2',
                              alias, '/usr/bin/python3', remote_script, 'guest'],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

    def stop(*args):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    try:
        for line in child.stdout:
            item = json.loads(line)
            status = 403
            if item.get('authorization') == 'Bearer ' + fixture['token']:
                try:
                    request = urllib.request.Request('http://%s:%s' % (fixture['bridge4'], fixture['control_port']),
                        data=base64.b64decode(item['body']), headers={'Authorization': item['authorization']})
                    with urllib.request.urlopen(request, timeout=5) as response:
                        status = response.status
                except Exception:
                    status = 502
            child.stdin.write(json.dumps({'status': status}) + '\n')
            child.stdin.flush()
    finally:
        child.stdin.close()
        try:
            child.wait(3)
        except subprocess.TimeoutExpired:
            child.terminate()
            child.wait(3)


if __name__ == '__main__':
    if sys.argv[1] == 'guest':
        guest()
    elif sys.argv[1] == 'host':
        while True:
            host(*sys.argv[2:5])
            print('Fixture control SSH session ended; reconnecting',file=sys.stderr,flush=True)
            time.sleep(1)
    else:
        raise ValueError('Expected host or guest')
