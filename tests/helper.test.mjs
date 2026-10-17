// Executes the command lines Helper.js builds, exactly as the plugin runs
// them, and checks what each way a run can end reports: a clean read, an
// oversized file, a refused path, a deadline, a missing program.
//
// Run by scripts/test, which passes a scratch directory in
// VOXSCOPE_TEST_SCRATCH. Nothing is written anywhere else, and nothing is
// written at all unless that directory is one scripts/test made.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, linkSync, mkdirSync, readFileSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { basename, dirname, join, isAbsolute } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const here = dirname(fileURLToPath(import.meta.url));

// Helper.js is a QML `.pragma library` script: plain JavaScript once that
// line is gone.
const Helper = {};
vm.createContext(Helper);
vm.runInContext(readFileSync(join(here, "..", "Helper.js"), "utf8").replace(/^\.pragma library$/m, ""), Helper);

const scratch = process.env.VOXSCOPE_TEST_SCRATCH || "";
assert.ok(isAbsolute(scratch), "VOXSCOPE_TEST_SCRATCH must be an absolute path");
assert.ok(basename(scratch).startsWith("voxscope-test."), `not a scratch directory made by scripts/test: ${scratch}`);
assert.ok(statSync(scratch).isDirectory());
assert.equal(statSync(scratch).uid, process.getuid());

// Runs an argv with stdout on a real pipe, as QProcess gives it; Node's own
// stdio is a socket, which /dev/fd/4 cannot be reopened from. stdin is
// /dev/null.
function execute(argv, env = {}) {
    assert.ok(Array.isArray(argv), "Helper refused to build the command");
    const r = spawnSync("/usr/bin/bash", ["--norc", "--noprofile", "-c", '"$@" | /usr/bin/cat; exit "${PIPESTATUS[0]}"', "exec", ...argv],
        { stdio: ["ignore", "pipe", "pipe"], env: { PATH: "/usr/bin", ...env }, timeout: 20000 });
    return { status: r.status, out: r.stdout.toString() };
}

function file(name, content, mode) {
    const path = join(scratch, name);
    writeFileSync(path, content);
    if (mode !== undefined) chmodSync(path, mode);
    return path;
}

test("a read returns a small file whole", () => {
    const r = execute(Helper.read(file("state", "recording"), { maxBytes: 64 }));
    assert.equal(r.status, 0);
    assert.equal(r.out, "recording");
});

test("a read at exactly the cap passes and one byte over is refused", () => {
    const path = file("exact", "x".repeat(64));
    assert.equal(execute(Helper.read(path, { maxBytes: 64 })).status, 0);
    assert.equal(execute(Helper.read(path, { maxBytes: 63 })).status, Helper.OVERFLOW_EXIT);
});

test("the cap counts bytes, not characters", () => {
    // Forty two-byte characters: under a 64-character limit, over 64 bytes.
    const path = file("wide", "é".repeat(40));
    assert.equal(execute(Helper.read(path, { maxBytes: 64 })).status, Helper.OVERFLOW_EXIT);
});

test("an empty file reads as empty", () => {
    const r = execute(Helper.read(file("empty", ""), { maxBytes: 64 }));
    assert.equal(r.status, 0);
    assert.equal(r.out, "");
});

test("a symlinked file is refused unless links are followed", () => {
    const target = file("target", "idle");
    const link = join(scratch, "link");
    symlinkSync(target, link);
    assert.equal(execute(Helper.read(link, { maxBytes: 64 })).status, Helper.REFUSED_EXIT);
    const followed = execute(Helper.read(link, { maxBytes: 64, follow: true }));
    assert.equal(followed.status, 0);
    assert.equal(followed.out, "idle");
});

test("a file under a symlinked directory is read by its physical path", () => {
    mkdirSync(join(scratch, "real-dir"));
    writeFileSync(join(scratch, "real-dir", "state"), "idle");
    symlinkSync(join(scratch, "real-dir"), join(scratch, "linked-dir"));
    assert.equal(execute(Helper.read(join(scratch, "linked-dir", "state"), { maxBytes: 64 })).status, 0);
});

test("a hard-linked file is refused in strict mode", () => {
    const original = file("original", "idle");
    linkSync(original, join(scratch, "hardlink"));
    assert.equal(execute(Helper.read(original, { maxBytes: 64 })).status, Helper.REFUSED_EXIT);
    assert.equal(execute(Helper.read(original, { maxBytes: 64, follow: true })).status, 0);
});

test("a file anyone may write is refused", () => {
    const path = file("open", "idle", 0o666);
    chmodSync(path, 0o666);
    assert.equal(execute(Helper.read(path, { maxBytes: 64, follow: true })).status, Helper.REFUSED_EXIT);
});

test("what is not a regular file is refused", () => {
    assert.equal(execute(Helper.read(join(scratch, "missing"), { maxBytes: 64 })).status, Helper.REFUSED_EXIT);
    assert.equal(execute(Helper.read(scratch, { maxBytes: 64 })).status, Helper.REFUSED_EXIT);
    assert.equal(execute(Helper.read("/dev/zero", { maxBytes: 64, follow: true })).status, Helper.REFUSED_EXIT);
});

test("a FIFO is ended by the deadline", () => {
    const fifo = join(scratch, "fifo");
    assert.equal(spawnSync("/usr/bin/mkfifo", ["--", fifo]).status, 0);
    assert.equal(execute(Helper.read(fifo, { maxBytes: 64, seconds: 1 })).status, 124);
});

test("a path is data, never shell syntax", () => {
    const name = "$(touch pwned); `touch pwned2`";
    const r = execute(Helper.read(file(name, "idle"), { maxBytes: 64 }));
    assert.equal(r.status, 0);
    assert.equal(r.out, "idle");
    assert.ok(!existsSync(join(scratch, "pwned")) && !existsSync("pwned") && !existsSync("pwned2"));
});

test("a one-shot run publishes a clean answer", () => {
    const r = execute(Helper.run(["/usr/bin/echo", "alsa_input.mic"], { maxBytes: 512 }));
    assert.equal(r.status, 0);
    assert.equal(r.out, "alsa_input.mic\n");
});

test("a one-shot run that says too much is refused", () => {
    assert.equal(execute(Helper.run(["/usr/bin/yes"], { maxBytes: 512 })).status, Helper.OVERFLOW_EXIT);
});

test("a one-shot run keeps its producer's failure", () => {
    assert.equal(execute(Helper.run(["/usr/bin/false"], { maxBytes: 512 })).status, 1);
    assert.equal(execute(Helper.run(["/usr/bin/voxscope-no-such-program"], { maxBytes: 512 })).status, 127);
});

test("a one-shot run is ended by its deadline", () => {
    const started = Date.now();
    assert.equal(execute(Helper.run(["/usr/bin/sleep", "30"], { seconds: 1 })).status, 124);
    assert.ok(Date.now() - started < 5000);
});

test("a stream is ended by its deadline", () => {
    assert.equal(execute(Helper.stream(["/usr/bin/sleep", "30"], { seconds: 1 })).status, 124);
});

test("children see only the variables they are given", () => {
    const vars = { HOME: "/home/tester", XDG_RUNTIME_DIR: "/run/user/1000" };
    const leak = { VOXSCOPE_LEAK: "1", LD_PRELOAD: "/x.so", BASH_ENV: "/x" };
    for (const argv of [Helper.run(["/usr/bin/env"], { env: vars, maxBytes: 4096 }),
                        Helper.stream(["/usr/bin/env"], { env: vars, seconds: 5 })]) {
        const r = execute(argv, leak);
        assert.equal(r.status, 0);
        const names = r.out.trim().split("\n").map((line) => line.split("=")[0]).sort();
        // bash adds PWD, SHLVL and _ of its own for the run's producer.
        const allowed = new Set(["HOME", "LC_ALL", "PATH", "XDG_RUNTIME_DIR", "PWD", "SHLVL", "_"]);
        for (const name of names) assert.ok(allowed.has(name), `unexpected variable ${name}`);
        assert.ok(names.includes("HOME") && names.includes("XDG_RUNTIME_DIR"));
    }
});
