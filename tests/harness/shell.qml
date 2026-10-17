// Visual test harness for Voxscope; run it through run.sh, which sets up
// the scratch directories and environment this expects.
//
// It loads Hud.qml as the shell would, then plays a scripted dictation into
// the scratch runtime directory: it writes Voxtype's state file and
// postprocess.json at set times, feeds the HUD a fake audio bridge, grabs
// frames of the card, and logs the HUD's state every 50 ms (TRACE lines),
// the window mapping and unmapping (WINDOW), the audio bridge and cava
// being allowed to run or not (LIVE), the window being held (HOLD), what it saved (FRAME) and what it
// checked (CHECK, FAIL).

import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
    id: harness

    readonly property string scenario: Quickshell.env("HARNESS_SCENARIO") || "pipeline"
    readonly property string out: Quickshell.env("HARNESS_OUT")
    readonly property string runtime: Quickshell.env("XDG_RUNTIME_DIR")
    readonly property string bridge: Quickshell.env("HARNESS_BRIDGE")
    // Stands in for omarchy-shell, which the HUD reads its settings from:
    // the plugin's entry in shell.json, here made from HARNESS_SETTINGS.
    readonly property var fakeShell: {
        let settings = {};
        try {
            const parsed = JSON.parse(Quickshell.env("HARNESS_SETTINGS") || "{}");
            if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) settings = parsed;
        } catch (e) {
            console.log("FAIL HARNESS_SETTINGS is not JSON: " + e);
        }
        settings.id = "io.github.iryzhkov.voxscope";
        return { shellConfig: { version: 1, plugins: [settings] } };
    }

    property real t0: 0
    property int next: 0
    property var lens: [5, 3, 7, 2, 4, 9, 3, 5, 6, 2, 4, 8, 3, 5, 4, 6, 2, 7, 5, 3, 4, 6]
    // Fields reported so far, carried by every postprocess.json write as
    // the protocol requires.
    property var status: ({})
    property var idleWrittenAt: null
    property var lingerStartedAt: null
    property bool hiddenLogged: false
    // Seen since the last "clear" step: the HUD shown, the window mapped,
    // the audio bridge and cava allowed to run (`live`). Followed through
    // change signals rather than polled, so a single-frame flash counts.
    property bool sawShown: false
    property bool sawLive: false
    property int unmaps: 0
    property real mappedAt: 0
    // Whether the window was held for a settling dictation, and whether it
    // was then still mapped with nothing new drawn and no audio running.
    property bool sawHolding: false
    property bool heldCleanly: false
    // Frames saved so far, which numbers their files.
    property int grabs: 0
    // Whether the stop command is expected to have run by the "stopped"
    // check.
    property bool expectStopped: true

    // Each scenario is a list of [ms from start, action, argument].
    readonly property var scripts: ({
        pipeline: [
            [0, "state", "recording"],
            [1500, "grab", "rec"],
            [2400, "grab", "rec-late"],
            [2500, "state", "transcribing"],
            [2560, "grab", "collapse"],
            [2690, "pp", "start"],
            [2700, "grab", "stt"],
            [2730, "pp", "llm"],
            [3200, "grab", "llm-early"],
            [3700, "grab", "llm-late"],
            [3950, "pp", "done"],
            [4250, "grab", "typing"],
            [4550, "state", "idle"],
            [4620, "grab", "linger-a"],
            [4650, "check", "no-unmap"],
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
        // Recording again during the linger: the HUD starts over in the
        // same window, which must not unmap in between, and keeps the
        // linger's last frame while the new dictation settles.
        relinger: [
            [0, "state", "recording"],
            [2500, "state", "transcribing"],
            [2690, "pp", "start"],
            [2730, "pp", "llm"],
            [3950, "pp", "done"],
            [4550, "state", "idle"],
            [4600, "grab", "lingering"],
            [4650, "state", "recording"],
            [4850, "check", "holding"],
            [4850, "check", "rerecord"],
            [5000, "grab", "rerecord"],
            [6500, "state", "transcribing"],
            [6700, "pp", "start"],
            [7000, "pp", "done-raw"],
            [7300, "grab", "second-typing"],
            [7300, "check", "no-unmap"],
            [7400, "state", "idle"],
            [9500, "quit", ""]
        ],
        // Two `--no-osd` dictations, then an ordinary one. The first has
        // the marker created just after the recording state and removed just
        // after idle, as Voxtype 1.0.1 does; the second the other way round.
        // Neither may show, linger or run the bridge; the third must show.
        suppressed: [
            [0, "state", "recording"],
            [30, "marker", "on"],
            [1000, "check", "never-shown"],
            [2000, "state", "transcribing"],
            [2190, "pp", "start"],
            [2230, "pp", "llm"],
            [2600, "pp", "done"],
            [2900, "state", "idle"],
            [2920, "marker", "off"],
            [3600, "check", "never-shown"],
            [4000, "marker", "on"],
            [4030, "state", "recording"],
            [5000, "state", "transcribing"],
            [5200, "pp", "start"],
            [5300, "pp", "done-raw"],
            [5500, "marker", "off"],
            [5520, "state", "idle"],
            [6200, "check", "never-shown"],
            [6500, "state", "recording"],
            [7000, "check", "shown"],
            [7100, "grab", "unsuppressed"],
            [8000, "state", "transcribing"],
            [8200, "pp", "start"],
            [8300, "pp", "done-raw"],
            [8600, "state", "idle"],
            [11500, "quit", ""]
        ],
        // A `--no-osd` recording started during an ordinary dictation's
        // linger, its marker 30 ms after the state: the window, held for the
        // settling, hides without ever drawing REC or running the bridge.
        suppressedrelinger: [
            [0, "state", "recording"],
            [1000, "state", "transcribing"],
            [1150, "pp", "start-long"],
            [1200, "pp", "done-long"],
            [1300, "state", "idle"],
            [1320, "clear", ""],
            [1350, "state", "recording"],
            [1380, "marker", "on"],
            [1600, "check", "never-shown"],
            [1600, "check", "hidden-now"],
            [1800, "state", "transcribing"],
            [2100, "state", "idle"],
            [2120, "marker", "off"],
            [2400, "check", "never-shown"],
            [2500, "quit", ""]
        ],
        // An ordinary recording seen before the previous `--no-osd`
        // dictation's marker is seen gone; the marker goes during the
        // settling, so the new dictation shows.
        oldmarker: [
            [0, "state", "recording"],
            [30, "marker", "on"],
            [800, "state", "transcribing"],
            [1000, "state", "idle"],
            [1020, "check", "never-shown"],
            [1040, "state", "recording"],
            [1070, "marker", "off"],
            [1500, "check", "shown"],
            [1500, "check", "unsuppressed"],
            [1550, "grab", "unsuppressed"],
            [1800, "state", "transcribing"],
            [2100, "state", "idle"],
            [4500, "quit", ""]
        ],
        // A marker that arrives well into a shown recording hides the HUD
        // and stops the bridge and cava (`live`); the dictation stays hidden
        // through the rest of it.
        latemarker: [
            [0, "state", "recording"],
            [700, "check", "shown"],
            [800, "marker", "on"],
            [900, "check", "hidden-now"],
            [1000, "clear", ""],
            [1500, "state", "transcribing"],
            [1700, "pp", "start"],
            [1800, "pp", "done-raw"],
            [2000, "state", "idle"],
            [2020, "marker", "off"],
            [2700, "check", "never-shown"],
            [3000, "quit", ""]
        ],
        // A toggled recording whose audio bridge sends three seconds of
        // silence and then stops sending: the silence auto-stop must not
        // fire, because without frames there is no telling silence from
        // speech.
        nobridge: [
            [0, "toggle", ""],
            [20, "state", "recording"],
            [2000, "grab", "bridge-silent"],
            [9000, "grab", "bridge-gone"],
            [9000, "check", "no-countdown"],
            [12500, "check", "not-stopped"],
            [12600, "state", "idle"],
            [13500, "quit", ""]
        ],
        // Voxtype dies while recording and leaves its state file behind;
        // with a one-second cap the HUD gives up 31 s in.
        stale: [
            [0, "state", "recording"],
            [2000, "check", "shown"],
            [30000, "check", "shown"],
            [32000, "check", "stalled"],
            [32500, "state", "idle"],
            [33500, "quit", ""]
        ],
        // Voxtype's runtime directory does not exist when the HUD loads;
        // it is created half a second in, and the HUD must still follow the
        // state file and the marker.
        latedir: [
            [500, "mkdir", ""],
            [700, "state", "idle"],
            [3000, "state", "recording"],
            [3300, "check", "state-seen"],
            [3500, "marker", "on"],
            [3800, "check", "hidden-now"],
            [4000, "state", "idle"],
            [4020, "marker", "off"],
            [5000, "quit", ""]
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
        shell: harness.fakeShell
        bridgeCommand: ["/usr/bin/python3", "-I", harness.bridge,
                        harness.scenario === "silence" ? "silent"
                        : harness.scenario === "nobridge" ? "stall" : "speech"]
        onShownChanged: if (shown) harness.sawShown = true
        // Whether the hold is clean is looked at once the handler that began
        // it has finished. In "relinger" a frame of the held window is saved
        // then, which must be the previous dictation's last frame, not REC;
        // elsewhere grabbing would stall the event loop and delay the steps
        // that follow.
        onHoldingChanged: {
            if (holding) {
                harness.sawHolding = true;
                Qt.callLater(function() {
                    harness.heldCleanly = hud.holding && hud.windowShown && !hud.shown && !hud.live;
                    if (harness.scenario === "relinger") harness.grab(hud.windowItem, "held");
                });
            }
            console.log("HOLD " + (holding ? "started" : "ended") + " at " + (Date.now() - harness.t0) + " ms");
        }
        onLiveChanged: {
            if (live) harness.sawLive = true;
            console.log("LIVE " + (live ? "started" : "stopped") + " at " + (Date.now() - harness.t0) + " ms");
        }
        onWindowShownChanged: {
            const e = Date.now() - harness.t0;
            if (windowShown) {
                harness.sawShown = true;
                harness.mappedAt = e;
            } else {
                harness.unmaps++;
                // No dictation is that short; this is the window flapping.
                if (e - harness.mappedAt < 100) {
                    console.log("FAIL window flashed for " + (e - harness.mappedAt) + " ms");
                }
            }
            console.log("WINDOW " + (windowShown ? "mapped" : "unmapped") + " at "
                + (Date.now() - harness.t0) + " ms");
        }
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

    // Written as Voxtype writes it: "1", in place. A process rather than a
    // FileView, which skips writing text it already holds.
    Process {
        id: writeMarker
        command: ["/usr/bin/sh", "-c", "printf 1 >\"$1\"", "sh", harness.runtime + "/voxtype/osd_suppressed"]
    }

    Process {
        id: removeMarker
        command: ["/usr/bin/rm", "-f", "--", harness.runtime + "/voxtype/osd_suppressed"]
    }

    Process {
        id: makeVoxtypeDir
        command: ["/usr/bin/mkdir", "-p", "--", harness.runtime + "/voxtype"]
    }

    // Its path is set only when checked, which makes it load then.
    FileView {
        id: stoppedFile
        printErrors: false
        onLoaded: console.log((harness.expectStopped ? "CHECK" : "FAIL")
            + " silence auto-stop ran the stop command")
        onLoadFailed: console.log((harness.expectStopped ? "FAIL" : "CHECK")
            + " silence auto-stop did not run the stop command")
    }

    function longLens() {
        const out = [];
        for (let i = 0; i < 120; i++) out.push(lens[i % lens.length]);
        return out;
    }

    // Saves a frame of `item`: the card, or what the window shows of it,
    // which differs while the window is held.
    function grab(item, label) {
        const name = out + "/" + String(grabs++).padStart(2, "0") + "-" + label + ".png";
        const e = Date.now() - t0;
        item.grabToImage(function(r) {
            r.saveToFile(name);
            console.log("FRAME " + name + " at " + e + " ms, stage " + hud.stage);
        });
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
        } else if (action === "marker") {
            if (arg === "on") writeMarker.running = true;
            else removeMarker.running = true;
        } else if (action === "mkdir") {
            makeVoxtypeDir.running = true;
        } else if (action === "clear") {
            sawShown = false;
            sawLive = false;
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
            grab(hud.cardItem, arg);
        } else if (action === "check") {
            check(arg);
        } else if (action === "quit") {
            if (!hiddenLogged && hud.windowShown) console.log("FAIL the HUD was still shown at the end");
            Qt.quit();
        }
    }

    function check(what) {
        if (what === "rerecord") {
            const ok = hud.stage === 0 && !hud.lingering && hud.shown && hud.tape.length <= 2;
            console.log((ok ? "CHECK" : "FAIL") + " recording during the linger reset the HUD: stage "
                + hud.stage + ", lingering " + hud.lingering + ", shown " + hud.shown
                + ", tape " + hud.tape.length + " columns");
        } else if (what === "holding") {
            const ok = sawHolding && heldCleanly && unmaps === 0;
            console.log((ok ? "CHECK" : "FAIL") + " window held while the re-record settled: held "
                + sawHolding + ", mapped with nothing drawn or live " + heldCleanly
                + ", unmaps " + unmaps);
        } else if (what === "unsuppressed") {
            const ok = !hud.suppressed && !hud.markerPresent && hud.live;
            console.log((ok ? "CHECK" : "FAIL") + " marker removed during the settling left the"
                + " dictation unsuppressed: suppressed " + hud.suppressed + ", marker "
                + hud.markerPresent + ", live " + hud.live);
        } else if (what === "stopped") {
            stoppedFile.path = harness.runtime + "/stopped";
        } else if (what === "not-stopped") {
            expectStopped = false;
            stoppedFile.path = harness.runtime + "/stopped";
        } else if (what === "no-countdown") {
            const ok = hud.shown && !hud.silenceWarning && hud.silentFor < 2;
            console.log((ok ? "CHECK" : "FAIL") + " no silence countdown without bridge frames: silent for "
                + hud.silentFor.toFixed(1) + " s, warning " + hud.silenceWarning
                + ", last bridge frame " + (Date.now() - hud.lastBridgeMs) + " ms ago");
        } else if (what === "never-shown") {
            const ok = !sawShown && !sawLive && !hud.lingering;
            console.log((ok ? "CHECK" : "FAIL") + " suppressed dictation stayed hidden: shown seen "
                + sawShown + ", bridge/cava seen " + sawLive + ", lingering " + hud.lingering
                + ", state " + hud.daemonState);
        } else if (what === "shown") {
            const ok = hud.shown && hud.windowShown;
            console.log((ok ? "CHECK" : "FAIL") + " HUD shown in state " + hud.daemonState
                + ": shown " + hud.shown + ", window " + hud.windowShown);
        } else if (what === "hidden-now") {
            const ok = !hud.shown && !hud.windowShown && !hud.live && !hud.cavaReady && hud.suppressed;
            console.log((ok ? "CHECK" : "FAIL") + " late marker hid the HUD: shown " + hud.shown
                + ", window " + hud.windowShown + ", live " + hud.live + ", suppressed " + hud.suppressed);
        } else if (what === "no-unmap") {
            console.log((unmaps === 0 ? "CHECK" : "FAIL") + " window unmapped " + unmaps
                + " times before the last idle");
        } else if (what === "stalled") {
            const ok = hud.stalled && !hud.shown && !hud.windowShown && !hud.live;
            console.log((ok ? "CHECK" : "FAIL") + " stale recording state hidden after "
                + hud.elapsed.toFixed(1) + " s: stalled " + hud.stalled + ", shown " + hud.shown
                + ", live " + hud.live);
        } else if (what === "state-seen") {
            const ok = hud.daemonState === "recording";
            console.log((ok ? "CHECK" : "FAIL") + " state file followed after its directory appeared: "
                + hud.daemonState);
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
            if (harness.idleWrittenAt !== null && !hud.windowShown && !harness.hiddenLogged) {
                harness.hiddenLogged = true;
                const since = harness.lingerStartedAt !== null
                    ? ", " + (now - harness.lingerStartedAt) + " ms after the HUD saw idle" : ", no linger";
                console.log("CHECK hidden " + (now - harness.idleWrittenAt) + " ms after idle was written" + since);
            }
            if (harness.idleWrittenAt !== null && hud.windowShown) harness.hiddenLogged = false;
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
