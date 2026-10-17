#!/usr/bin/env python3
"""Runs examples/voxtype-clean against a stub Ollama server on loopback and
checks what it types and what it reports: the input and response caps, the
settings it accepts, the control and invisible formatting characters it
never types, the UTF-8 it always writes, the bound on an LLM answer, the deadline on a request, the proxy it never uses and the
status file it writes.

Run by scripts/test, which passes a scratch directory in
VOXSCOPE_TEST_SCRATCH. Every runtime directory the script writes to is made
inside it, and nothing is written at all unless that directory is one
scripts/test made.
"""

import http.server
import importlib.machinery
import importlib.util
import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
import unittest

# Loading the script as a module must not leave a __pycache__ beside it.
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "examples", "voxtype-clean")
MODEL = "test:1b"

SCRATCH = os.environ.get("VOXSCOPE_TEST_SCRATCH", "")
assert os.path.isabs(SCRATCH), "VOXSCOPE_TEST_SCRATCH must be an absolute path"
assert os.path.basename(SCRATCH).startswith("voxscope-test."), (
    f"not a scratch directory made by scripts/test: {SCRATCH}")
assert stat.S_ISDIR(os.lstat(SCRATCH).st_mode), SCRATCH
assert os.lstat(SCRATCH).st_uid == os.getuid(), SCRATCH

# What the script must never type: every C0 and C1 control character but the
# newline, the Unicode line and paragraph separators, and every invisible
# formatting character (category Cf, and the whole tag block) but the
# zero-width joiner.
FORBIDDEN = {chr(c) for c in [*range(0x00, 0x0a), *range(0x0b, 0x20), *range(0x7f, 0xa0), 0x2028, 0x2029]}
FORBIDDEN |= {chr(c) for c in range(0x80, 0x110000)
              if unicodedata.category(chr(c)) == "Cf" or 0xE0000 <= c <= 0xE007F} - {"\N{ZERO WIDTH JOINER}"}
# A sample of those formatting characters: right-to-left override, the
# isolates, the Arabic letter mark, zero-width space and non-joiner, word
# joiner, soft hyphen, byte order mark, and tag characters.
INVISIBLE = "".join(map(chr, [0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0x061C, 0x200B, 0x200C, 0x2060,
                               0x00AD, 0xFEFF, 0xE0001, 0xE0041, 0xE007F]))
# Emoji sequences that need the zero-width joiner and variation selector.
EMOJI = ("\U0001f468\N{ZERO WIDTH JOINER}\U0001f469\N{ZERO WIDTH JOINER}\U0001f467 "
         "\N{HEAVY BLACK HEART}\N{VARIATION SELECTOR-16}")


class Stub:
    """An HTTP server on 127.0.0.1 that records every request. As Ollama it
    reports MODEL as installed and loaded and answers /api/generate from
    `answer`, `body` or `drip`; as a proxy it answers everything with 502."""

    def __init__(self, proxy: bool = False):
        self.proxy = proxy
        self.reset()
        stub = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, format, *args):
                pass

            def reply(self, code: int, body: bytes) -> None:
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                stub.requests.append(("GET", self.path))
                if stub.proxy:
                    return self.reply(502, b"{}")
                if self.path == "/api/ps":
                    return self.reply(200, json.dumps(
                        {"models": [{"name": MODEL, "size": 100, "size_vram": 100}]}).encode())
                if self.path == "/api/tags":
                    return self.reply(200, json.dumps({"models": [{"name": MODEL}]}).encode())
                self.reply(404, b"{}")

            def do_POST(self):
                length = int(self.headers.get("Content-Length") or 0)
                self.rfile.read(length)
                stub.requests.append(("POST", self.path))
                if stub.proxy or self.path != "/api/generate":
                    return self.reply(502, b"{}")
                if stub.drip is not None:
                    # A valid answer, a byte at a time, each well inside any
                    # per-operation socket timeout.
                    body = json.dumps({"response": "Hello."}).encode().ljust(400)
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    try:
                        for i in range(len(body)):
                            self.wfile.write(body[i:i + 1])
                            self.wfile.flush()
                            time.sleep(stub.drip)
                    except OSError:
                        pass
                    return
                if stub.body is not None:
                    return self.reply(200, stub.body)
                self.reply(200, json.dumps({"response": stub.answer}).encode())

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.server.server_address[1]}"

    def reset(self) -> None:
        self.requests: list[tuple[str, str]] = []
        self.answer = "Hello."
        self.body: bytes | None = None
        self.drip: float | None = None

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()


def load(env: dict):
    """The script as a module, with its settings read from `env`."""
    saved = dict(os.environ)
    os.environ.clear()
    os.environ.update(env)
    try:
        loader = importlib.machinery.SourceFileLoader("voxtype_clean", SCRIPT)
        spec = importlib.util.spec_from_loader("voxtype_clean", loader)
        assert spec is not None
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
    finally:
        os.environ.clear()
        os.environ.update(saved)
    return module


class VoxtypeClean(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ollama = Stub()
        cls.proxy = Stub(proxy=True)

    @classmethod
    def tearDownClass(cls):
        cls.ollama.close()
        cls.proxy.close()

    def setUp(self):
        self.ollama.reset()
        self.proxy.reset()
        self.runtime = tempfile.mkdtemp(prefix="runtime.", dir=SCRATCH)
        assert os.path.dirname(self.runtime) == SCRATCH

    def run_script(self, stdin: bytes, **env) -> str:
        """The script's output for `stdin`, run with nothing from this
        environment but what is named here."""
        environment = {
            "PATH": "/usr/bin",
            "HOME": SCRATCH,
            "XDG_RUNTIME_DIR": self.runtime,
            "VOXTYPE_CLEAN_BASE": self.ollama.url,
            "VOXTYPE_CLEAN_MODEL": MODEL,
            "VOXTYPE_CLEAN_TIMEOUT": "3",
            **env,
        }
        r = subprocess.run([sys.executable, "-I", "-B", SCRIPT], input=stdin, capture_output=True,
                           env=environment, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr.decode(errors="replace"))
        return r.stdout.decode()

    def status(self) -> dict:
        with open(os.path.join(self.runtime, "voxtype", "postprocess.json"), encoding="utf-8") as f:
            return json.load(f)

    def assert_typeable(self, text: str) -> None:
        found = sorted(f"U+{ord(c):04X}" for c in set(text) & FORBIDDEN)
        self.assertEqual(found, [], f"control characters in {text!r}")

    def test_a_cleaned_answer_is_typed(self):
        self.ollama.answer = "Hello there."
        self.assertEqual(self.run_script(b"hello\nthere\n"), "Hello there.")
        self.assertEqual(self.status()["reason"], "ok")
        self.assertIn(("POST", "/api/generate"), self.ollama.requests)

    def test_settings_are_parsed_and_bounded(self):
        m = load({})
        self.assertEqual((m.OLLAMA_BASE, m.MODELS, m.TIMEOUT_SECS), ("http://localhost:11434", ["qwen3:4b"], 5.0))
        for base, want in [("http://host:1/ ", "http://host:1"), ("https://h", "https://h"),
                           ("ftp://h", "http://localhost:11434"), ("http://a b", "http://localhost:11434"),
                           ("http://" + "a" * 241, "http://localhost:11434")]:
            self.assertEqual(load({"VOXTYPE_CLEAN_BASE": base}).OLLAMA_BASE, want, base)
        self.assertEqual(load({"VOXTYPE_CLEAN_MODEL": " a:1 ,bad name,$(x),b "}).MODELS, ["a:1", "b"])
        self.assertEqual(len(load({"VOXTYPE_CLEAN_MODEL": ",".join("m%d" % i for i in range(20))}).MODELS), 8)
        self.assertEqual(load({"VOXTYPE_CLEAN_MODEL": ";"}).MODELS, ["qwen3:4b"])
        for raw, want in [("2.5", 2.5), ("0", 0.5), ("1e9", 60.0), ("nan", 5.0), ("inf", 5.0), ("x", 5.0)]:
            self.assertEqual(load({"VOXTYPE_CLEAN_TIMEOUT": raw}).TIMEOUT_SECS, want, raw)

    def test_control_characters_never_reach_the_output_from_an_answer(self):
        # A carriage return would be typed as a bare Return and submit the
        # prompt; the escape sequence would clear a terminal.
        self.ollama.answer = "hello\rrm -rf ~\r\x1b[2J\x0bworld x\x85y z\x00\x9b"
        out = self.run_script(b"hello rm rf world x y z")
        self.assertEqual(self.status()["reason"], "ok")
        self.assert_typeable(out)
        self.assertEqual(out, "hello\nrm -rf ~\n[2J\nworld x\ny\nz")

    def test_control_characters_never_reach_the_output_from_the_fallback(self):
        out = self.run_script(b"one\rtwo\x1b[2J three\x00 four\xc2\x85five\xe2\x80\xa8six\x7f",
                              VOXTYPE_CLEAN_LLM="0")
        self.assertEqual(out, "one two[2J three four five six")
        self.assertEqual(self.status()["reason"], "disabled")

    def test_invisible_formatting_never_reaches_the_output_from_an_answer(self):
        # A bidirectional override would make "txt.exe" read as "exe.txt";
        # tags and zero-width characters hide text altogether.
        self.ollama.answer = ("Hello" + INVISIBLE + " there \N{RIGHT-TO-LEFT OVERRIDE}exe.txt"
                              "\N{POP DIRECTIONAL FORMATTING} friend " + EMOJI + ".")
        out = self.run_script(b"hello there exe txt friend family")
        self.assertEqual(self.status()["reason"], "ok")
        self.assert_typeable(out)
        self.assertEqual(out, f"Hello there exe.txt friend {EMOJI}.")

    def test_invisible_formatting_never_reaches_the_output_from_the_fallback(self):
        out = self.run_script(("hello" + INVISIBLE + " there\N{ZERO WIDTH SPACE} friend " + EMOJI).encode(),
                              VOXTYPE_CLEAN_LLM="0")
        self.assert_typeable(out)
        self.assertEqual(out, f"hello there friend {EMOJI}")

    def test_invisible_formatting_never_reaches_the_output_of_an_oversized_transcript(self):
        data = ("a\N{RIGHT-TO-LEFT OVERRIDE}b\U000e0041 " + EMOJI + " ").encode() * 60000
        self.assertGreater(len(data), 1 << 20)
        out = self.run_script(data)
        self.assertEqual(out, f"ab {EMOJI} " * 60000)
        self.assertEqual(self.ollama.requests, [])

    def test_an_answer_with_a_lone_surrogate_falls_back(self):
        # Valid JSON, but no valid text: the surrogate cannot be written as
        # UTF-8, and writing it used to fail after the status said cleaned.
        text = b"hello there friend how are you today"
        self.ollama.body = b'{"response":"Hello \\ud800 there friend how are you today"}'
        self.assertEqual(self.run_script(text), text.decode())
        status = self.status()
        self.assertEqual((status["reason"], status["cleaned"]), ("rejected", False))

    def test_output_is_utf8_and_never_fails_to_encode(self):
        m = load({})
        raw = io.BytesIO()
        # A text layer that could encode neither character.
        ascii_out = io.TextIOWrapper(raw, encoding="ascii")
        saved = sys.stdout
        sys.stdout = ascii_out
        try:
            m.emit("caf\xe9 \ud800!")
        finally:
            sys.stdout = saved
            ascii_out.detach()
        self.assertEqual(raw.getvalue(), "caf\xe9 ?!".encode())

    def test_an_oversized_transcript_passes_through_filtered_and_unsent(self):
        data = b"a\r\nb\x1bc\xc2\x9b " * 300000
        self.assertGreater(len(data), 1 << 20)
        out = self.run_script(data)
        self.assertEqual(out, "a\nbc " * 300000)
        self.assertEqual(self.ollama.requests, [])
        self.assertFalse(os.path.exists(os.path.join(self.runtime, "voxtype")))

    def test_an_oversized_response_is_refused(self):
        self.ollama.body = b'{"response": "' + b"x" * (4 << 20) + b'"}'
        self.assertEqual(self.run_script(b"hello\nthere"), "hello there")
        self.assertEqual(self.status()["reason"], "rejected")

    def test_an_answer_out_of_proportion_to_the_transcript_is_refused(self):
        cases = [
            ("hi", "x" * (3 << 20)),                          # 3 MiB for one word
            ("hello", "Hello. " * 10),                          # nine more words than spoken
            ("one two three", "One " + "t" * 400 + " three."),  # far longer than spoken
            (" ".join(["word"] * 20), " ".join(["Word"] * 29)),  # within 1.5 times, but 9 more
            (" ".join(["word"] * 20), "Word word."),             # a summary
        ]
        for text, answer in cases:
            with self.subTest(text=text[:20], answer=answer[:20]):
                self.ollama.answer = answer
                self.assertEqual(self.run_script(text.encode()), text)
                self.assertEqual(self.status()["reason"], "rejected")

    def test_an_answer_in_proportion_is_used(self):
        for text, answer in [("hi", "Hi."), (" ".join(["word"] * 20), " ".join(["Word"] * 28) + ".")]:
            with self.subTest(text=text[:20]):
                self.ollama.answer = answer
                self.assertEqual(self.run_script(text.encode()), answer)

    def test_a_slow_answer_is_ended_by_the_deadline_as_a_whole(self):
        # Every byte arrives well inside the timeout, so only a deadline on
        # the whole request ends this one.
        self.ollama.drip = 0.1
        started = time.monotonic()
        out = self.run_script(b"hello there", VOXTYPE_CLEAN_TIMEOUT="1")
        self.assertLess(time.monotonic() - started, 6)
        self.assertEqual(out, "hello there")
        self.assertEqual(self.status()["reason"], "rejected")

    def test_a_proxy_in_the_environment_is_never_used(self):
        self.ollama.answer = "Hello there."
        proxies = {name: self.proxy.url for name in
                   ("http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY")}
        self.assertEqual(self.run_script(b"hello there", **proxies), "Hello there.")
        self.assertEqual(self.proxy.requests, [])
        self.assertIn(("GET", "/api/ps"), self.ollama.requests)
        self.assertIn(("POST", "/api/generate"), self.ollama.requests)

    def test_the_status_file_is_private_and_replaced_by_rename(self):
        self.ollama.answer = "Hello there."
        self.run_script(b"hello there")
        directory = os.path.join(self.runtime, "voxtype")
        self.assertEqual(stat.S_IMODE(os.lstat(directory).st_mode), 0o700)
        info = os.lstat(os.path.join(directory, "postprocess.json"))
        self.assertTrue(stat.S_ISREG(info.st_mode))
        self.assertEqual(stat.S_IMODE(info.st_mode), 0o600)
        self.assertEqual(info.st_nlink, 1)
        # No temporary file is left behind.
        self.assertEqual(os.listdir(directory), ["postprocess.json"])
        status = self.status()
        self.assertEqual((status["stage"], status["cleaned"], status["model"]), ("done", True, MODEL))
        self.assertEqual(status["words_in"], 2)


if __name__ == "__main__":
    unittest.main()
