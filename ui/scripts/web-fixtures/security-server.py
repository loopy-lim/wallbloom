"""Loopback canary; a request from WebKit is a security failure, not a test skip."""
import http.server
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with (root / 'network-requests.log').open('a') as log:
            log.write(self.path + '\n')
        self.send_response(200)
        self.send_header('Content-Type', 'application/javascript')
        self.end_headers()
        self.wfile.write(b'window.remoteCodeRan=true;')

    def log_message(self, *args):
        pass

server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
(root / 'network-requests.log').touch()
(root / 'canary-port').write_text(str(server.server_port))
server.serve_forever()
