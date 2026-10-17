import QtQuick
import QtTest
import "../Sanitize.js" as Sanitize

// Everything read from outside the plugin's own code: environment paths,
// settings, Voxtype's files, the theme, the audio bridge and cava.
TestCase {
    name: "Sanitize"

    function test_directories_from_the_environment() {
        compare(Sanitize.directory("/home/me", ""), "/home/me");
        compare(Sanitize.directory("/run/user/1000/", ""), "/run/user/1000");
        compare(Sanitize.directory("relative/path", "/fallback"), "/fallback");
        compare(Sanitize.directory("/home/me/../root", "/fallback"), "/fallback");
        compare(Sanitize.directory("/home/./me", "/fallback"), "/fallback");
        compare(Sanitize.directory("/home/me\n/x", "/fallback"), "/fallback");
        compare(Sanitize.directory("/" + "a".repeat(600), "/fallback"), "/fallback");
        compare(Sanitize.directory(undefined, ""), "");
        compare(Sanitize.directory("/", "/fallback"), "/fallback");
    }

    function test_plugin_id() {
        compare(Sanitize.pluginId({ id: "io.github.x.y" }, "d"), "io.github.x.y");
        compare(Sanitize.pluginId({ id: "bad id" }, "d"), "d");
        compare(Sanitize.pluginId(null, "d"), "d");
    }

    function test_settings_are_whitelisted() {
        const id = "io.github.iryzhkov.voxscope";
        const config = { plugins: [{ id: "other", compact: true },
                                   { id: id, compact: true, position: "bottom", reducedMotion: true }] };
        compare(Sanitize.settings(config, id), { compact: true, position: "bottom", reducedMotion: true });
        const odd = { plugins: [{ id: id, compact: "true", position: "top", reducedMotion: 1 }] };
        compare(Sanitize.settings(odd, id), { compact: false, position: "center", reducedMotion: false });
        compare(Sanitize.settings(null, id), { compact: false, position: "center", reducedMotion: false });
        compare(Sanitize.settings({ plugins: "x" }, id).position, "center");
    }

    function test_settings_ignore_inherited_values() {
        const id = "io.github.iryzhkov.voxscope";
        const entry = Object.create({ compact: true });
        entry.id = id;
        compare(Sanitize.settings({ plugins: [entry] }, id).compact, false);
    }

    function test_daemon_state() {
        compare(Sanitize.daemonState("recording\n"), "recording");
        compare(Sanitize.daemonState("transcribing"), "transcribing");
        compare(Sanitize.daemonState("weird"), "idle");
        compare(Sanitize.daemonState(""), "");
        compare(Sanitize.daemonState("  \n"), "");
        compare(Sanitize.daemonState("x".repeat(65)), "");
    }

    function test_toggle_stamp() {
        compare(Sanitize.toggleStamp("1792266872377\n"), 1792266872377);
        compare(Sanitize.toggleStamp("-5"), 0);
        compare(Sanitize.toggleStamp("1e12"), 0);
        compare(Sanitize.toggleStamp("Infinity"), 0);
        compare(Sanitize.toggleStamp("99999999999999999"), 0);
        compare(Sanitize.toggleStamp(""), 0);
    }

    function test_max_record_secs() {
        compare(Sanitize.maxRecordSecs("[audio]\nmax_duration_secs = 12\n"), 12);
        compare(Sanitize.maxRecordSecs("max_duration_secs = 0"), 1);
        compare(Sanitize.maxRecordSecs("max_duration_secs = 999999999"), 86400);
        compare(Sanitize.maxRecordSecs("max_duration_secs = 9999999999"), null);
        compare(Sanitize.maxRecordSecs("# max_duration_secs = 5"), null);
        compare(Sanitize.maxRecordSecs(""), null);
    }

    function test_theme_colours() {
        const c = Sanitize.themeColours('accent = "#7aa2f7"\nbackground = "#1a1b26"\nforeground = "#a9b1d6"\n'
                                        + 'red = "#f7768e"\nselection = "url(x)"\nmode = "dark"\n');
        compare(c.accent, "#7aa2f7");
        compare(c.background, "#1a1b26");
        compare(c.foreground, "#a9b1d6");
        compare(c.red, "#f7768e");
        compare(c.selection, null);
        compare(c.dark_background, null);
        compare(c.mode, "dark");
        compare(Sanitize.themeColours('accent = "#7aa2f7"\n' + " ".repeat(70000)).accent, null);
    }

    function test_timing_rates() {
        compare(Sanitize.timingRates('{"stt": 0.02, "llm": 0.04, "type": 0.003}'), { stt: 0.02, llm: 0.04, type: 0.003 });
        compare(Sanitize.timingRates('{"stt": 0, "llm": 10, "type": "0.1"}'), {});
        compare(Sanitize.timingRates("not json"), {});
        compare(Sanitize.timingRates("[0.1]"), {});
    }

    function test_calibration() {
        compare(Sanitize.calibration('{"ref": [0.1], "noise": [0.01]}'), { ref: [0.1], noise: [0.01] });
        compare(Sanitize.calibration('{"ref": 3}'), { ref: [], noise: [] });
        compare(Sanitize.calibration("[]"), null);
        compare(Sanitize.calibration("{"), null);
    }

    function test_bridge_lines() {
        compare(Sanitize.bridgeLine('{"status":"connected"}'), { status: "connected" });
        compare(Sanitize.bridgeLine('{"status":"disconnected"}'), { status: "disconnected" });
        compare(Sanitize.bridgeLine('{"peak":0.4,"rms":0.2,"vad":1,"ts_ms":1234}'),
                { peak: 0.4, rms: 0.2, vad: true, tsMs: 1234 });
        compare(Sanitize.bridgeLine('{"peak":7,"rms":-1,"vad":0,"ts_ms":"x"}'),
                { peak: 1, rms: 0, vad: false, tsMs: 0 });
        compare(Sanitize.bridgeLine('{"peak":"0.4","rms":0.2}'), null);
        compare(Sanitize.bridgeLine("[1]"), null);
        compare(Sanitize.bridgeLine("garbage"), null);
        compare(Sanitize.bridgeLine(""), null);
        compare(Sanitize.bridgeLine('{"peak":0.1,"rms":0.1,"pad":"' + "x".repeat(600) + '"}'), null);
    }

    function test_cava_lines() {
        compare(Sanitize.cavaLine("0;500;1000;"), [0, 0.5, 1]);
        compare(Sanitize.cavaLine("2000;-5;x;"), [1, 0, 0]);
        compare(Sanitize.cavaLine(""), null);
        compare(Sanitize.cavaLine(";;;"), null);
        compare(Sanitize.cavaLine(new Array(70).fill("1").join(";")), null);
        compare(Sanitize.cavaLine("1;".repeat(600)), null);
    }

    function test_pipewire_source() {
        compare(Sanitize.pipewireSource("alsa_input.pci-0000_00_1f.3.analog-stereo\n"),
                "alsa_input.pci-0000_00_1f.3.analog-stereo");
        compare(Sanitize.pipewireSource("bad\nsource = evil"), null);
        compare(Sanitize.pipewireSource("has space"), null);
        compare(Sanitize.pipewireSource(""), null);
    }
}
