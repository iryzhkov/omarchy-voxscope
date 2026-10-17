import QtQuick
import QtTest
import "../Helper.js" as Helper

// The shape of every command line the plugin builds. What they do when run
// (caps, refusals, deadlines) is checked by executing them, in
// tests/helper.test.mjs.
TestCase {
    name: "Helper"

    readonly property var env: ({
        HOME: "/home/tester",
        XDG_RUNTIME_DIR: "/run/user/1000",
        PULSE_SERVER: "unix:/run/user/1000/pulse/native",
        XDG_CONFIG_HOME: "relative",
        SECRET: "/should/not/pass"
    })

    function programs(argv) {
        // Every element that is not an assignment, a flag or a number and
        // starts with a slash is a program or a path; the programs are the
        // ones env, setpriv, timeout and bash are given to run.
        const out = [];
        for (let i = 0; i < argv.length; i++) {
            if (argv[i] === "/usr/bin/env" || argv[i] === "/usr/bin/setpriv" || argv[i] === "/usr/bin/timeout"
                || argv[i] === "/usr/bin/bash")
                out.push(argv[i]);
        }
        return out;
    }

    function test_every_command_clears_the_environment_first() {
        const cases = [Helper.run(["/usr/bin/true"], { env: env }), Helper.read("/tmp/x", {}),
                       Helper.stream(["/usr/bin/cava"], { env: env })];
        for (let i = 0; i < cases.length; i++) {
            compare(cases[i][0], "/usr/bin/env");
            compare(cases[i][1], "-i");
            compare(cases[i][2], "PATH=/usr/bin");
            compare(cases[i][3], "LC_ALL=C");
        }
    }

    function test_only_named_and_valid_variables_pass() {
        const argv = Helper.run(["/usr/bin/true"], { env: env });
        verify(argv.indexOf("HOME=/home/tester") > 0);
        verify(argv.indexOf("XDG_RUNTIME_DIR=/run/user/1000") > 0);
        verify(argv.indexOf("PULSE_SERVER=unix:/run/user/1000/pulse/native") > 0);
        for (let i = 0; i < argv.length; i++) {
            verify(argv[i].indexOf("SECRET") < 0);
            verify(argv[i].indexOf("XDG_CONFIG_HOME") < 0);
        }
        // A read needs nothing from the session.
        const read = Helper.read("/tmp/x", {});
        verify(read.indexOf("HOME=/home/tester") < 0);
    }

    function test_inherited_variables_are_ignored() {
        const vars = Object.create({ HOME: "/home/proto" });
        const argv = Helper.run(["/usr/bin/true"], { env: vars });
        verify(argv.indexOf("HOME=/home/proto") < 0);
    }

    function test_one_shot_runs_have_a_deadline_and_a_cap() {
        const argv = Helper.run(["/usr/bin/pactl", "get-default-source"], { seconds: 5, maxBytes: 512 });
        compare(programs(argv), ["/usr/bin/env", "/usr/bin/timeout", "/usr/bin/bash"]);
        const t = argv.indexOf("/usr/bin/timeout");
        compare(argv[t + 1], "--kill-after=2");
        compare(argv[t + 2], "5");
        const b = argv.indexOf("/usr/bin/bash");
        compare(argv.slice(b, b + 7), ["/usr/bin/bash", "--norc", "--noprofile", "-c", Helper.RUN_SCRIPT,
                                       "voxscope-run", "512"]);
        compare(argv.slice(b + 7), ["/usr/bin/pactl", "get-default-source"]);
    }

    function test_a_read_passes_the_path_as_an_argument() {
        const path = "/run/user/1000/voxtype/$(touch pwned) ; `x`";
        const argv = Helper.read(path, { maxBytes: 64 });
        const b = argv.indexOf("/usr/bin/bash");
        compare(argv.slice(b, b + 8), ["/usr/bin/bash", "--norc", "--noprofile", "-c", Helper.READ_SCRIPT,
                                       "voxscope-read", "64", "strict"]);
        compare(argv[b + 8], path);
        compare(argv.length, b + 9);
        compare(Helper.read("/x/y", { follow: true })[b + 7], "follow");
    }

    function test_streams_die_with_the_shell_and_at_their_deadline() {
        const argv = Helper.stream(["/usr/bin/cava", "-p", "/run/user/1000/voxscope/cava.conf"],
                                   { seconds: 360, env: env });
        compare(programs(argv), ["/usr/bin/env", "/usr/bin/setpriv", "/usr/bin/timeout"]);
        const s = argv.indexOf("/usr/bin/setpriv");
        compare(argv.slice(s, s + 7), ["/usr/bin/setpriv", "--pdeathsig", "TERM", "/usr/bin/timeout",
                                       "--kill-after=2", "360", "/usr/bin/cava"]);
    }

    function test_deadlines_and_caps_are_clamped() {
        const huge = Helper.run(["/usr/bin/true"], { seconds: 1e12, maxBytes: 1e12 });
        verify(huge.indexOf(String(Helper.MAX_SECONDS)) > 0);
        verify(huge.indexOf(String(Helper.MAX_BYTES)) > 0);
        const odd = Helper.run(["/usr/bin/true"], { seconds: NaN, maxBytes: "9" });
        const t = odd.indexOf("/usr/bin/timeout");
        compare(odd[t + 2], "5");
        verify(odd.indexOf("4096") > 0);
        compare(Helper.read("/x", { seconds: 9999 })[Helper.read("/x", {}).indexOf("/usr/bin/timeout") + 2], "60");
    }

    function test_programs_must_be_absolute_plain_paths() {
        compare(Helper.run(["pactl"]), null);
        compare(Helper.run(["./pactl"]), null);
        compare(Helper.run(["/usr/bin/../bin/sh"]), null);
        compare(Helper.run(["/usr/bin/pa ctl"]), null);
        compare(Helper.run(["/usr/bin/"]), null);
        compare(Helper.run([]), null);
        compare(Helper.run("/usr/bin/true"), null);
        compare(Helper.stream(["cava"]), null);
        compare(Helper.run(["/usr/bin/true", "a\u0000b"]), null);
        compare(Helper.run(["/usr/bin/true", 3]), null);
    }

    function test_read_paths_must_be_absolute_and_plain() {
        compare(Helper.read("relative", {}), null);
        compare(Helper.read("/a/../b", {}), null);
        compare(Helper.read("/a/./b", {}), null);
        compare(Helper.read("/a\nb", {}), null);
        compare(Helper.read("", {}), null);
        compare(Helper.read("/" + "a".repeat(2000), {}), null);
    }

    function test_usable() {
        verify(Helper.usable(0, 0));
        verify(!Helper.usable(1, 0));
        verify(!Helper.usable(Helper.OVERFLOW_EXIT, 0));
        verify(!Helper.usable(0, 1));
    }
}
