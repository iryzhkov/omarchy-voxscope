// Visual test harness for Voxscope; run it through run.sh, which sets up
// the scratch directories and environment this expects.
//
// It loads Hud.qml as the shell would, then plays a scripted dictation into
// the scratch runtime directory: it writes Voxtype's state file and
// postprocess.json at set times, feeds the HUD a fake audio bridge, grabs
// frames of the card, and logs the HUD's state every 50 ms (TRACE lines),
// what it saved (FRAME) and what it checked (CHECK, FAIL).

import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
    id: harness

    readonly property string scenario: Quickshell.env("HARNESS_SCENARIO") || "pipeline"
    readonly property string out: Quickshell.env("HARNESS_OUT")
    readonly property string runtime: Quickshell.env("XDG_RUNTIME_DIR")
    readonly property string bridge: Quickshell.env("HARNESS_BRIDGE")

    property real t0: 0
    property int next: 0
    property var lens: [5, 3, 7, 2, 4, 9, 3, 5, 6, 2, 4, 8, 3, 5, 4, 6, 2, 7, 5, 3, 4, 6]
    // Fields reported so far, carried by every postprocess.json write as
    // the protocol requires.
    property var status: ({})
    property var idleWrittenAt: null
    property var lingerStartedAt: null
    property bool hiddenLogged: false

    // Each scenario is a list of [ms from start, action, argument].
    readonly property var scripts: ({
        pipeline: [
            [0, "state", "recording"],
            [1500, "grab", "rec"],
            [2500, "state", "transcribing"],
            [2690, "pp", "start"],
            [2700, "grab", "stt"],
            [2730, "pp", "llm"],
            [3200, "grab", "llm-early"],
            [3700, "grab", "llm-late"],
            [3950, "pp", "done"],
            [4250, "grab", "typing"],
            [4550, "state", "idle"],
            [4620, "grab", "linger-a"],
            [4700, "grab", "linger-b"],
            [7000, "quit", ""]
        ],
        // A long transcript typed faster than estimated: voxtype goes idle
        // while the typing animation has far to go, so it fast-forwards.
        fastidle: [
            [0, "state", "recording"],
            [2000, "state", "transcribing"],
            [2190, "pp", "start-long"],
            [2230, "pp", "llm"],
            [3000, "pp", "done-long"],
            [3200, "grab", "typing"],
            [3300, "state", "idle"],
            [3400, "grab", "fast-forward-a"],
            [3550, "grab", "fast-forward-b"],
            [6000, "quit", ""]
        ],
        relinger: [
            [0, "state", "recording"],
            [2500, "state", "transcribing"],
            [2690, "pp", "start"],
            [2730, "pp", "llm"],
            [3950, "pp", "done"],
            [4550, "state", "idle"],
            [4700, "grab", "lingering"],
            [4800, "state", "recording"],
            [4900, "check", "rerecord"],
            [5000, "grab", "rerecord"],
            [6500, "state", "transcribing"],
            [6700, "pp", "start"],
            [7000, "pp", "done-raw"],
            [7100, "grab", "second-typing"],
            [7400, "state", "idle"],
            [9500, "quit", ""]
        ],
        noscript: [
            [0, "state", "recording"],
            [1500, "grab", "rec"],
            [2000, "state", "transcribing"],
            [2600, "grab", "stt"],
            [3500, "state", "idle"],
            [3560, "grab", "linger"],
            [5500, "quit", ""]
        ],
        silence: [
            [0, "toggle", ""],
            [20, "state", "recording"],
            [2000, "grab", "quiet"],
            [6500, "grab", "countdown"],
            [9000, "grab", "countdown-late"],
            [10600, "check", "stopped"],
            [10700, "state", "idle"],
            [11500, "quit", ""]
        ],
        cap: [
            [0, "state", "recording"],
            [1200, "grab", "before-cap"],
            [3000, "grab", "cap-countdown"],
            [6000, "grab", "cap-late"],
            [6200, "state", "idle"],
            [7000, "quit", ""]
        ],
        cava: [
            [0, "state", "recording"],
            [1500, "grab", "cava"],
            [3000, "check", "cava"],
            [3100, "grab", "cava-late"],
            [3500, "state", "idle"],
            [4500, "quit", ""]
        ]
    })

    Hud {
        id: hud
        bridgeCommand: ["/usr/bin/python3", "-I", harness.bridge,
                        harness.scenario === "silence" ? "silent" : "speech"]
        stopCommand: ["/usr/bin/touch", harness.runtime + "/stopped"]
        sourceCommand: harness.scenario === "cava" ? ["/usr/bin/pactl", "get-default-source"] : ["/usr/bin/false"]
    }

    FileView {
        id: stateFile
        path: harness.runtime + "/voxtype/state"
        atomicWrites: false
        preload: false
    }

    FileView {
        id: toggleFile
        path: harness.runtime + "/voxtype/toggle-start"
        preload: false
    }

    FileView {
        id: ppFile
        path: harness.runtime + "/voxtype/postprocess.json"
        preload: false
    }

    // Its path is set only when checked, which makes it load then.
    FileView {
        id: stoppedFile
        printErrors: false
        onLoaded: console.log("CHECK silence auto-stop ran the stop command")
        onLoadFailed: console.log("FAIL silence auto-stop did not run the stop command")
    }

    function longLens() {
        const out = [];
        for (let i = 0; i < 120; i++) out.push(lens[i % lens.length]);
        return out;
    }

    function report(stage, fields) {
        for (const k in fields) status[k] = fields[k];
        const obj = { stage: stage, t: Date.now() };
        for (const k in status) obj[k] = status[k];
        ppFile.setText(JSON.stringify(obj));
    }

    function run(action, arg) {
        const now = Date.now();
        if (action === "state") {
            stateFile.setText(arg);
            if (arg === "idle") idleWrittenAt = now;
            if (arg === "recording") status = {};
        } else if (action === "toggle") {
            toggleFile.setText(String(now));
        } else if (action === "pp") {
            if (arg === "start") {
                report("start", { stt_t: now, raw_lens: lens, words_in: lens.length });
            } else if (arg === "llm") {
                report("llm", { model: "qwen3:4b", timeout: 5, llm_t: now });
            } else if (arg === "done") {
                report("done", { cleaned: true, reason: "ok", words: 20, model: "qwen3:4b", lens: lens.slice(2) });
            } else if (arg === "start-long") {
                report("start", { stt_t: now, raw_lens: longLens(), words_in: 120 });
            } else if (arg === "done-long") {
                report("done", { cleaned: true, reason: "ok", words: 120, model: "qwen3:4b", lens: longLens() });
            } else if (arg === "done-raw") {
                report("done", { cleaned: false, reason: "disabled", words: lens.length, model: null, lens: lens });
            }
        } else if (action === "grab") {
            const name = out + "/" + String(next).padStart(2, "0") + "-" + arg + ".png";
            const e = now - t0;
            hud.cardItem.grabToImage(function(r) {
                r.saveToFile(name);
                console.log("FRAME " + name + " at " + e + " ms, stage " + hud.stage);
            });
        } else if (action === "check") {
            check(arg);
        } else if (action === "quit") {
            if (!hiddenLogged) console.log("FAIL the HUD was still shown at the end");
            Qt.quit();
        }
    }

    function check(what) {
        if (what === "rerecord") {
            const ok = hud.stage === 0 && !hud.lingering && hud.shown && hud.tape.length <= 2;
            console.log((ok ? "CHECK" : "FAIL") + " recording during the linger reset the HUD: stage "
                + hud.stage + ", lingering " + hud.lingering + ", shown " + hud.shown
                + ", tape " + hud.tape.length + " columns");
        } else if (what === "stopped") {
            stoppedFile.path = harness.runtime + "/stopped";
        } else if (what === "cava") {
            const ok = hud.lastCavaMs > 0 && Date.now() - hud.lastCavaMs < 500;
            console.log((ok ? "CHECK" : "FAIL") + " cava spectrum: " + hud.target.length
                + " bands, last frame " + (Date.now() - hud.lastCavaMs) + " ms ago");
        }
    }

    Timer {
        interval: 10
        repeat: true
        running: true
        onTriggered: {
            const now = Date.now();
            if (harness.t0 === 0) harness.t0 = now;
            const e = now - harness.t0;
            const script = harness.scripts[harness.scenario];
            while (harness.next < script.length && e >= script[harness.next][0]) {
                const step = script[harness.next];
                harness.next++;
                harness.run(step[1], step[2]);
            }
            if (hud.lingering && harness.lingerStartedAt === null) harness.lingerStartedAt = hud.idleAt;
            if (hud.shown && !hud.lingering) harness.lingerStartedAt = null;
            if (harness.idleWrittenAt !== null && !hud.shown && !harness.hiddenLogged) {
                harness.hiddenLogged = true;
                const since = harness.lingerStartedAt !== null
                    ? ", " + (now - harness.lingerStartedAt) + " ms after the HUD saw idle" : ", no linger";
                console.log("CHECK hidden " + (now - harness.idleWrittenAt) + " ms after idle was written" + since);
            }
            if (harness.idleWrittenAt !== null && hud.shown) harness.hiddenLogged = false;
        }
    }

    Timer {
        interval: 50
        repeat: true
        running: true
        onTriggered: {
            if (harness.t0 === 0) return;
            console.log("TRACE " + (Date.now() - harness.t0) + " state=" + hud.daemonState
                + " stage=" + hud.stage + " p1=" + hud.scanP1.toFixed(3) + " p2=" + hud.scanP2.toFixed(3)
                + " typing=" + hud.typingProgress().toFixed(3) + " lingering=" + hud.lingering
                + " shown=" + hud.shown + " window=" + hud.windowShown);
        }
    }
}
