"""Deterministic llama helper checks: no real model or llama-server is needed."""

import argparse
import http.server
import json
import os
from pathlib import Path
import shutil
import select
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest


def record(event):
    data = (json.dumps(event) + "\n").encode()
    fd = os.open(os.environ["FAKE_EVENTS"], os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)


def fake_server(args):
    parser = argparse.ArgumentParser()
    parser.add_argument("-m", required=True)
    parser.add_argument("--embeddings", action="store_true", required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("-c", required=True)
    parser.add_argument("-b", required=True)
    parser.add_argument("-ub", required=True)
    parser.add_argument("--log-disable", action="store_true", required=True)
    options = parser.parse_args(args)
    record({"type": "launch", "model": options.m, "pid": os.getpid()})
    mode = os.environ.get("FAKE_MODE", "matching")
    if mode == "exit":
        return
    if gate := os.environ.get("FAKE_GATE"):
        deadline = time.monotonic() + 10
        while not Path(gate).exists():
            if time.monotonic() > deadline:
                raise RuntimeError("startup gate was not released")
            time.sleep(0.01)

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def respond(self, status, value):
            body = json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            record({"type": "request", "method": "GET", "path": self.path})
            if self.path == "/health":
                self.respond(503 if mode == "loading" else 200, {"status": "ok"})
            elif self.path == "/props":
                if mode == "missing":
                    self.respond(200, {"total_slots": 1})
                elif mode == "unavailable":
                    self.respond(404, {})
                elif mode == "malformed":
                    self.respond(200, {"model_path": [options.m]})
                else:
                    model = options.m + ".other" if mode == "mismatched" else options.m
                    self.respond(200, {"model_path": model})
            else:
                self.respond(404, {})

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            record({"type": "request", "method": "POST", "path": self.path,
                    "body": body.decode()})
            self.respond(200, {"data": [{"embedding": [0.25, 0.75]}]})

    class Server(http.server.HTTPServer):
        allow_reuse_address = True

    with Server((options.host, options.port), Handler) as server:
        record({"type": "ready", "pid": os.getpid()})
        server.serve_forever(poll_interval=0.05)


def fake_flock(args):
    # Observe when both callers reach the real kernel lock before opening the
    # startup gate. This avoids relying on scheduler timing in the race check.
    record({"type": "lock", "args": args})
    os.execv(os.environ["REAL_FLOCK"], [os.environ["REAL_FLOCK"], *args])


class HelperCheck(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="akyuu-llama-check-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.runtime = self.root / "runtime"
        self.runtime.mkdir()
        self.gguf = self.root / "model.gguf"
        self.gguf.write_bytes(b"a fake model; never loaded")
        self.events_path = self.root / "events.jsonl"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        real_flock = shutil.which("flock")
        self.assertIsNotNone(real_flock, "the check requires the Nix flock package")
        for command, mode in [("llama-server", "--serve"), ("flock", "--flock")]:
            script = self.bin / command
            script.write_text(
                f"#!{sys.executable}\nimport runpy, sys\n"
                f"sys.argv = [{str(Path(__file__).resolve())!r}, {mode!r}, *sys.argv[1:]]\n"
                f"runpy.run_path({str(Path(__file__).resolve())!r}, run_name='__main__')\n"
            )
            script.chmod(0o755)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            self.port = sock.getsockname()[1]
        self.env = {
            **os.environ,
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "REAL_FLOCK": real_flock,
            "FAKE_EVENTS": str(self.events_path),
            "FAKE_MODE": "matching",
            "FAKE_GATE": "",
            "XDG_RUNTIME_DIR": str(self.runtime),
            "AKYUU_EMBED_GGUF": str(self.gguf),
            "AKYUU_EMBED_LLAMA_PORT": str(self.port),
            "AKYUU_EMBED_IDLE": "3600",
        }
        self.processes = []
        # Keep a live group owner until all cleanup signals have been sent.
        # Darwin can return EPERM for a zombie-only group after the helper
        # has been reaped. A live owner also prevents reuse of its group ID.
        self.group_owner = subprocess.Popen(
            [sys.executable, "-c",
             "import signal; signal.signal(signal.SIGTERM, signal.SIG_IGN); "
             "print('ready', flush=True); signal.pause()"],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, process_group=0,
        )
        self.addCleanup(self.cleanup)
        ready, _, _ = select.select([self.group_owner.stdout], [], [], 8)
        self.assertTrue(ready, "the process group owner did not start")
        self.assertEqual(self.group_owner.stdout.readline(), b"ready\n")
        self.group_owner.stdout.close()

    def cleanup(self):
        # Only this test's live owner supplies the group ID, never a reaped
        # helper, a PID file or a listening port. Keep permission errors fatal.
        try:
            os.killpg(self.group_owner.pid, signal.SIGTERM)
            for proc in self.processes:
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    break
        finally:
            # The owner ignores TERM, so even an otherwise empty group still
            # has a live target for KILL. Reap it only after the final signal.
            os.killpg(self.group_owner.pid, signal.SIGKILL)
            self.group_owner.wait(timeout=3)
            for proc in self.processes:
                proc.wait(timeout=3)
                proc.stdout.close()
                proc.stderr.close()

    def events(self, kind):
        if not self.events_path.exists():
            return []
        return [event for line in self.events_path.read_text().splitlines()
                if (event := json.loads(line))["type"] == kind]

    def wait_for(self, condition, message):
        deadline = time.monotonic() + 8
        while not condition():
            if time.monotonic() > deadline:
                self.fail(message)
            time.sleep(0.01)

    def spawn(self, argv, env, text=""):
        payload = self.root / f"input-{len(self.processes)}"
        payload.write_text(text)
        with payload.open("rb") as source:
            proc = subprocess.Popen(argv, env=env, stdin=source, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, process_group=self.group_owner.pid)
        self.processes.append(proc)
        return proc

    def external_server(self, mode="matching"):
        proc = self.spawn([
            str(self.bin / "llama-server"), "-m", str(self.gguf.resolve()),
            "--embeddings", "--host", "127.0.0.1", "--port", str(self.port),
            "-c", "2048", "-b", "2048", "-ub", "2048", "--log-disable",
        ], {**self.env, "FAKE_MODE": mode})
        self.wait_for(lambda: len(self.events("ready")) == 1, "external fake did not bind")
        return proc

    def helper(self, text="private text", **env):
        return self.spawn(["bash", "-euo", "pipefail", str(HELPER)],
                          {**self.env, **env}, text)

    def finish(self, proc, success):
        stdout, stderr = proc.communicate(timeout=12)
        if success:
            self.assertEqual(proc.returncode, 0, stderr.decode())
            self.assertEqual(json.loads(stdout), {"data": [{"embedding": [0.25, 0.75]}]})
        else:
            self.assertNotEqual(proc.returncode, 0, stdout.decode())
            self.assertEqual(stdout, b"")
        return stderr.decode()

    def posts(self):
        return [event for event in self.events("request") if event["method"] == "POST"]

    def test_matching_server_is_reused(self):
        server = self.external_server()
        # Canonical identity must also work for a relative symlink model argument.
        link = self.root / "linked.gguf"
        link.symlink_to(self.gguf)
        self.finish(self.helper(AKYUU_EMBED_GGUF=os.path.relpath(link)), True)
        self.assertEqual(len(self.events("launch")), 1)
        self.assertEqual(json.loads(self.posts()[0]["body"]), {"input": "private text"})
        self.assertIsNone(server.poll())

    def check_refused(self, mode, stale=False):
        server = self.external_server(mode)
        if stale:
            state = self.runtime / f"akyuu-embed-llama-{self.port}"
            (state / "lock").mkdir(parents=True)
            (state / "lock" / "pid").write_text(str(server.pid))
            (state / "model").write_text(str(self.gguf.resolve()))
            (state / "last").touch()
            (state / "start.lock").touch()
        error = self.finish(self.helper(), False)
        self.assertIn("different or unverifiable model", error)
        self.assertEqual(len(self.events("launch")), 1)
        self.assertEqual(self.posts(), [])
        self.assertIsNone(server.poll(), "an unknown server must never be stopped")

    def test_mismatched_server_is_refused(self):
        self.check_refused("mismatched")

    def test_missing_identity_is_refused(self):
        self.check_refused("missing")

    def test_unavailable_identity_is_refused(self):
        self.check_refused("unavailable")

    def test_malformed_identity_is_refused(self):
        self.check_refused("malformed")

    def test_occupied_loading_server_is_not_replaced(self):
        self.check_refused("loading")

    def test_stale_state_cannot_prove_identity(self):
        self.check_refused("mismatched", stale=True)

    def test_concurrent_startup_launches_once(self):
        gate = self.root / "start-gate"
        first = self.helper("first", FAKE_GATE=str(gate))
        self.wait_for(lambda: len(self.events("launch")) == 1, "first caller did not launch")
        second = self.helper("second", FAKE_GATE=str(gate))
        self.wait_for(lambda: len([event for event in self.events("lock")
                                  if event["args"] == ["-w", "95", "9"]]) == 2,
                      "both callers did not reach the startup lock")
        self.assertEqual(len(self.events("launch")), 1)
        gate.touch()
        self.finish(first, True)
        self.finish(second, True)
        self.assertEqual(len(self.events("launch")), 1)
        self.assertEqual({json.loads(event["body"])["input"] for event in self.posts()},
                         {"first", "second"})

    def test_concurrent_different_models_do_not_share_text(self):
        gate = self.root / "start-gate"
        other = self.root / "other.gguf"
        other.write_bytes(b"another fake model")
        first = self.helper("first", FAKE_GATE=str(gate))
        self.wait_for(lambda: len(self.events("launch")) == 1, "first caller did not launch")
        second = self.helper("must not be sent", AKYUU_EMBED_GGUF=str(other))
        self.wait_for(lambda: len([event for event in self.events("lock")
                                  if event["args"] == ["-w", "95", "9"]]) == 2,
                      "both callers did not reach the startup lock")
        gate.touch()
        self.finish(first, True)
        self.assertIn("different or unverifiable model", self.finish(second, False))
        self.assertEqual(len(self.events("launch")), 1)
        self.assertEqual([json.loads(event["body"])["input"] for event in self.posts()],
                         ["first"])

    def test_stale_pid_is_not_killed_or_treated_as_a_lock(self):
        unrelated = self.spawn([sys.executable, "-c", "import time; time.sleep(60)"], self.env)
        state = self.runtime / f"akyuu-embed-llama-{self.port}"
        (state / "lock").mkdir(parents=True)
        (state / "lock" / "pid").write_text(str(unrelated.pid))
        (state / "start.lock").touch()
        self.finish(self.helper(AKYUU_EMBED_IDLE="0"), True)
        self.assertEqual(len(self.events("launch")), 1)
        server = self.events("launch")[0]["pid"]

        def server_stopped():
            try:
                os.kill(server, 0)
                return False
            except ProcessLookupError:
                return True

        self.wait_for(server_stopped, "the idle timer did not stop its own server")
        self.assertIsNone(unrelated.poll())

    def test_failed_startup_releases_lock_for_next_call(self):
        self.finish(self.helper(FAKE_MODE="exit"), False)
        self.assertEqual(self.posts(), [])
        self.finish(self.helper(), True)
        self.assertEqual(len(self.events("launch")), 2)
        self.assertEqual(len(self.posts()), 1)

    def check_startup_identity(self, mode):
        error = self.finish(self.helper(FAKE_MODE=mode), False)
        self.assertIn("different or unverifiable model", error)
        self.assertEqual(self.posts(), [])
        # A retry must start its own server: failed identity cleanup stopped
        # only the server that this invocation launched.
        self.finish(self.helper(), True)
        self.assertEqual(len(self.events("launch")), 2)
        self.assertEqual(len(self.posts()), 1)

    def test_identity_is_checked_after_startup(self):
        self.check_startup_identity("mismatched")

    def test_missing_startup_identity_stops_owned_server(self):
        self.check_startup_identity("missing")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--serve":
        fake_server(sys.argv[2:])
    elif len(sys.argv) > 1 and sys.argv[1] == "--flock":
        fake_flock(sys.argv[2:])
    else:
        HELPER = Path(sys.argv[1]).resolve()
        unittest.main(argv=[sys.argv[0]])
