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

def broadcast(ev):
    for q in list(EVENTS):
        q.put(ev)

def worker():
    while True:
        job_id, job = JOBS.get()
        STATE["busy"] = True
        broadcast({"type": "started", "job": job_id})
        try:
            jobs_dir = os.path.join(DRAFT, "jobs")
            os.makedirs(jobs_dir, exist_ok=True)
            job_path = os.path.join(jobs_dir, job_id + ".json")
            with open(job_path, "w") as f:
                json.dump(job, f, indent=1)
            prompt = ("Use the peon-ping-remix skill to execute the reroll job at %s. "
                      "Follow the skill exactly." % job_path)
            try:
                r = subprocess.run([CLAUDE_BIN, "-p", prompt], capture_output=True, text=True, timeout=1800)
            except subprocess.TimeoutExpired as e:
                detail = ((e.stderr or b"") if isinstance(e.stderr, (bytes, bytearray)) else (e.stderr or "")) or (e.stdout or "")
                if isinstance(detail, (bytes, bytearray)):
                    detail = detail.decode(errors="replace")
                broadcast({"type": "failed", "job": job_id, "detail": (detail or "timed out")[-500:]})
                continue
            if r.returncode == 0:
                broadcast({"type": "done", "job": job_id})
            else:
                broadcast({"type": "failed", "job": job_id, "detail": (r.stderr or r.stdout)[-500:]})
        except Exception as e:
            broadcast({"type": "failed", "job": job_id, "detail": str(e)[-500:]})
        finally:
            STATE["busy"] = False

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
        q = queue.Queue()
        EVENTS.append(q)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.end_headers()
        try:
            while True:
                try:
                    ev = q.get(timeout=15)
                    self.wfile.write(b"data: " + json.dumps(ev).encode() + b"\n\n")
                except queue.Empty:
                    self.wfile.write(b": keepalive\n\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            EVENTS.remove(q)

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
        if self.path == "/api/reroll":
            return self._reroll()
        return self._json({"error": "not found"}, 404)  # replaced in Task 8

    def _reroll(self):
        length = int(self.headers.get("content-length", 0))
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            return self._json({"error": "invalid json"}, 400)
        scope = body.get("scope")
        if scope not in ("sound", "pack"):
            return self._json({"error": "scope must be 'sound' or 'pack'"}, 400)
        category = body.get("category")
        index = body.get("index")
        caption = body.get("caption")
        if scope == "sound":
            m = manifest()
            cats = m.get("categories", {})
            if category not in cats:
                return self._json({"error": "unknown category"}, 400)
            sounds = cats[category].get("sounds", [])
            if not isinstance(index, int) or isinstance(index, bool) or index < 0 or index >= len(sounds):
                return self._json({"error": "index out of range"}, 400)
        if STATE["busy"]:
            return self._json({"error": "busy"}, 409)
        job_id = "%d" % int(time.time() * 1000)
        job = {"scope": scope, "category": category, "index": index, "caption": caption,
               "draft_dir": DRAFT, "pack_name": manifest().get("name")}
        JOBS.put((job_id, job))
        return self._json({"job": job_id}, 202)

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
    threading.Thread(target=worker, daemon=True).start()
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
