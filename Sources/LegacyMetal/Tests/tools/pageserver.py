#!/usr/bin/env python3
# pageserver.py <port> <result file>: serves Tests/ on 127.0.0.1 and appends every POST /result body to the result file,
# for browsers whose console apps.sh can't read (Safari): open http://127.0.0.1:<port>/apps-page.html?report=1 there.
import http.server, os, sys

port, out = int(sys.argv[1]), sys.argv[2]
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_POST(self):
        if self.path != '/result':
            self.send_error(404)
            return
        body = self.rfile.read(int(self.headers.get('Content-Length', 0))).decode('utf-8', 'replace')
        with open(out, 'a') as f:
            f.write(body + '\n')
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(('127.0.0.1', port), Handler).serve_forever()
