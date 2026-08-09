#!/usr/bin/env python3
"""peon eval server: same-origin UI + API for judging a draft pack. Stdlib only."""
import argparse, json, os, sys, threading, queue, subprocess, time, webbrowser, shutil, signal
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DRAFT = None          # draft dir (abs)
CLAUDE_BIN = "claude"
EVENTS = []           # list of queue.Queue, one per connected SSE client
JOBS = queue.Queue()  # reroll jobs, drained by one worker (Task 7)
STATE = {"busy": False}
SERVER = None         # HTTP server instance, set in main()

def manifest():
    with open(os.path.join(DRAFT, "openpeon.json")) as f:
        return json.load(f)

def pack_summary():
    m = manifest()
    cats = {k: [{"file": s["file"], "label": s.get("label", "")} for s in v.get("sounds", [])]
            for k, v in m.get("categories", {}).items()}
    log_path = os.path.join(DRAFT, "eval-log.json")
    entries = 0
    if os.path.exists(log_path):
        try:
            entries = len(json.load(open(log_path)))
        except Exception:
            entries = 0
    return {"name": m.get("name"), "display_name": m.get("display_name", m.get("name")),
            "draft": bool(m.get("x_openpeon_draft")), "categories": cats,
            "eval_log_entries": entries, "busy": STATE["busy"],
            "claude_available": shutil.which(CLAUDE_BIN) is not None}

def shutdown_handler(signum, frame):
    """Handle SIGTERM by gracefully shutting down the server."""
    if SERVER:
        threading.Thread(target=SERVER.shutdown).start()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quiet
        pass

    def _json(self, obj, code=200):
        body = json.dumps(obj, indent=1).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _sse(self):
        return self._json({"error": "not ready"}, 501)

    def do_GET(self):
        if self.path == "/api/pack":
            return self._json(pack_summary())
        if self.path.startswith("/sounds/"):
            base = self.path[len("/sounds/"):]
            if "/" in base or ".." in base or not base.endswith(".wav"):
                return self._json({"error": "not found"}, 404)
            p = os.path.join(DRAFT, "sounds", base)
            if not os.path.isfile(p):
                return self._json({"error": "not found"}, 404)
            # Resolve symlinks and verify target is within sounds dir
            real_p = os.path.realpath(p)
            sounds_dir = os.path.realpath(os.path.join(DRAFT, "sounds"))
            if not real_p.startswith(sounds_dir + os.sep) and real_p != sounds_dir:
                return self._json({"error": "not found"}, 404)
            data = open(real_p, "rb").read()
            self.send_response(200)
            self.send_header("content-type", "audio/wav")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            return self.wfile.write(data)
        if self.path == "/":
            ui = os.path.join(os.path.dirname(os.path.abspath(__file__)), "eval-ui.html")
            body = open(ui, "rb").read() if os.path.exists(ui) else b"<h1>peon eval</h1>"
            self.send_response(200)
            self.send_header("content-type", "text/html; charset=utf-8")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            return self.wfile.write(body)
        if self.path == "/api/events":
            return self._sse()          # Task 7
        return self._json({"error": "not found"}, 404)

    def do_POST(self):
        return self._json({"error": "not found"}, 404)  # replaced in Task 7/8

def main():
    global DRAFT, CLAUDE_BIN, SERVER
    ap = argparse.ArgumentParser()
    ap.add_argument("--draft", required=True)
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--claude-bin", default="claude")
    ap.add_argument("--no-open", action="store_true")
    ap.add_argument("--print-port", action="store_true")
    args = ap.parse_args()
    DRAFT = os.path.abspath(args.draft)
    CLAUDE_BIN = args.claude_bin
    if not os.path.exists(os.path.join(DRAFT, "openpeon.json")):
        sys.stderr.write("no openpeon.json in %s\n" % DRAFT)
        sys.exit(1)
    SERVER = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    port = SERVER.server_address[1]
    lock = os.path.join(DRAFT, ".eval-server.json")
    with open(lock, "w") as f:
        json.dump({"port": port, "pid": os.getpid()}, f)
    signal.signal(signal.SIGTERM, shutdown_handler)
    if args.print_port:
        print("PORT=%d" % port, flush=True)
    if not args.no_open:
        webbrowser.open("http://127.0.0.1:%d/" % port)
    try:
        SERVER.serve_forever()
    finally:
        try:
            os.unlink(lock)
        except OSError:
            pass

if __name__ == "__main__":
    main()
