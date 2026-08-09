#!/usr/bin/env python3
"""peon eval server: same-origin UI + API for judging a draft pack. Stdlib only."""
import argparse, itertools, json, os, sys, threading, queue, subprocess, time, webbrowser, shutil, signal
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DRAFT = None          # draft dir (abs)
CLAUDE_BIN = "claude"
EVENTS = []           # list of queue.Queue, one per connected SSE client
JOBS = queue.Queue()  # reroll jobs, drained by one worker (Task 7)
STATE = {"busy": False, "proc": None}
BUSY_LOCK = threading.Lock()   # guards the check-and-set of STATE["busy"] on accept
JOB_COUNTER = itertools.count()  # collision-proof job id suffix
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

def _kill_proc_tree(proc, sig):
    """Send `sig` to proc's whole process group (it was started with start_new_session=True)
    so a spawned shell script's own children die too, not just the immediate child."""
    if proc is None:
        return
    try:
        pgid = os.getpgid(proc.pid)
        os.killpg(pgid, sig)
    except (ProcessLookupError, PermissionError, OSError):
        try:
            if sig == signal.SIGKILL:
                proc.kill()
            else:
                proc.terminate()
        except Exception:
            pass

def shutdown_handler(signum, frame):
    """Handle SIGTERM by gracefully shutting down the server. Also terminates any
    in-flight `claude -p` child (and its process tree) so it doesn't get orphaned."""
    proc = STATE.get("proc")
    if proc is not None and proc.poll() is None:
        _kill_proc_tree(proc, signal.SIGTERM)
    if SERVER:
        threading.Thread(target=SERVER.shutdown).start()

def broadcast(ev):
    for q in list(EVENTS):
        q.put(ev)

def worker():
    while True:
        job_id, job = JOBS.get()
        broadcast({"type": "started", "job": job_id})
        try:
            jobs_dir = os.path.join(DRAFT, "jobs")
            os.makedirs(jobs_dir, exist_ok=True)
            job_path = os.path.join(jobs_dir, job_id + ".json")
            with open(job_path, "w") as f:
                json.dump(job, f, indent=1)
            prompt = ("Use the peon-ping-remix skill to execute the reroll job at %s. "
                      "Follow the skill exactly." % job_path)
            proc = subprocess.Popen([CLAUDE_BIN, "-p", prompt],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     text=True, start_new_session=True)
            STATE["proc"] = proc
            try:
                out, err = proc.communicate(timeout=1800)
                rc = proc.returncode
            except subprocess.TimeoutExpired:
                _kill_proc_tree(proc, signal.SIGKILL)
                out, err = proc.communicate()
                rc = -1
                err = err or out or "timed out after 1800s"
            if rc == 0:
                broadcast({"type": "done", "job": job_id})
            else:
                broadcast({"type": "failed", "job": job_id, "detail": (err or out or "")[-500:]})
        except Exception as e:
            broadcast({"type": "failed", "job": job_id, "detail": str(e)[-500:]})
        finally:
            STATE["proc"] = None
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
            # DRAFT may have been moved away by a completed approve; a late poll
            # in the ~1s window before shutdown must get a clean 404, not a traceback.
            if not os.path.isdir(DRAFT):
                return self._json({"error": "not found"}, 404)
            return self._json(pack_summary())
        if self.path.startswith("/sounds/"):
            if not os.path.isdir(DRAFT):
                return self._json({"error": "not found"}, 404)
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
        if self.path == "/api/approve":
            return self._approve()
        return self._json({"error": "not found"}, 404)

    def _reroll(self):
        # DRAFT may have been moved away by a completed approve; a late/duplicate
        # request in the ~1s window before shutdown must get a clean 404, not a traceback.
        if not os.path.isdir(DRAFT):
            return self._json({"error": "not found"}, 404)
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
        m = manifest()
        if scope == "sound":
            cats = m.get("categories", {})
            if category not in cats:
                return self._json({"error": "unknown category"}, 400)
            sounds = cats[category].get("sounds", [])
            if not isinstance(index, int) or isinstance(index, bool) or index < 0 or index >= len(sounds):
                return self._json({"error": "index out of range"}, 400)
        # Atomic check-and-set: only one concurrent request can flip busy False->True.
        # The worker no longer sets STATE["busy"]; it only clears it after the terminal event.
        with BUSY_LOCK:
            if STATE["busy"]:
                return self._json({"error": "busy"}, 409)
            STATE["busy"] = True
        job_id = "%d-%d" % (int(time.time() * 1000), next(JOB_COUNTER))
        job = {"scope": scope, "category": category, "index": index, "caption": caption,
               "draft_dir": DRAFT, "pack_name": m.get("name")}
        JOBS.put((job_id, job))
        return self._json({"job": job_id}, 202)

    def _approve(self):
        """The only door out of draft state. Strips the draft stamp, moves the pack
        to the approved dir, optionally installs it, and schedules the eval session's
        own shutdown. Uses the same BUSY_LOCK check-and-set discipline as _reroll so
        an approve racing a reroll accept (or a second approve) can't interleave."""
        with BUSY_LOCK:
            if STATE["busy"]:
                return self._json({"error": "busy"}, 409)
            STATE["busy"] = True
        ok = False
        try:
            length = int(self.headers.get("content-length", 0))
            raw = self.rfile.read(length) if length else b""
            try:
                body = json.loads(raw) if raw else {}
            except json.JSONDecodeError:
                return self._json({"error": "invalid json"}, 400)
            m = manifest()
            m.pop("x_openpeon_draft", None)
            name = m.get("name") or os.path.basename(DRAFT)
            approved_root = os.environ.get("PEON_APPROVED_DIR",
                                            os.path.expanduser("~/.peon-ping/packs"))
            final = os.path.join(approved_root, name)
            if os.path.exists(final):
                return self._json({"error": "exists", "path": final}, 409)
            with open(os.path.join(DRAFT, "openpeon.json"), "w") as f:
                json.dump(m, f, indent=2)
            shutil.rmtree(os.path.join(DRAFT, "jobs"), ignore_errors=True)
            try:
                os.unlink(os.path.join(DRAFT, ".eval-server.json"))
            except OSError:
                pass
            os.makedirs(approved_root, exist_ok=True)
            shutil.move(DRAFT, final)
            installed = False
            if body.get("install"):
                peon_dir = os.environ.get("PEON_DIR", os.path.expanduser("~/.claude/hooks/peon-ping"))
                shutil.copytree(final, os.path.join(peon_dir, "packs", name), dirs_exist_ok=True)
                installed = True
            ok = True
            # The eval session is over — no further requests are expected.
            threading.Timer(1.0, self.server.shutdown).start()
            return self._json({"approved": final, "installed": installed})
        finally:
            # DRAFT still exists on any non-success path (busy/exists/bad-json/error):
            # release the lock so a retry isn't stuck behind a phantom "busy".
            if not ok:
                STATE["busy"] = False

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
