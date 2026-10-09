"""Local stand-in for the upstream sources (helper, not a check).
usage: _standin.py <docroot> <portfile>
Serves files under docroot; a path listed in <docroot>/_status (lines "<code> <path>") answers that
status with an error body instead."""
import http.server, os, sys
root, portfile = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        path = self.path.split("?")[0]
        status = {}
        sf = os.path.join(root, "_status")
        if os.path.exists(sf):
            for line in open(sf):
                if line.strip():
                    c, p = line.split(None, 1); status[p.strip()] = int(c)
        if path in status:
            body = f"{status[path]}: error\n".encode()
            self.send_response(status[path])
        else:
            f = os.path.normpath(os.path.join(root, path.lstrip("/")))
            if not f.startswith(os.path.abspath(root)) or not os.path.isfile(f):
                body = b"404: Not Found"; self.send_response(404)
            else:
                body = open(f, "rb").read(); self.send_response(200)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(portfile + ".tmp", "w").write(str(s.server_address[1])); os.rename(portfile + ".tmp", portfile)
s.serve_forever()
