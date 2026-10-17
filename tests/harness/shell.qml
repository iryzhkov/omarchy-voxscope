// Visual test harness for Voxscope; run it through run.sh, which sets up
// the scratch directories and environment this expects.
//
// It loads Hud.qml as the shell would, then plays a scripted dictation into
// the scratch runtime directory: it writes Voxtype's state file and
// postprocess.json at set times, feeds the HUD a fake audio bridge, grabs
// frames of the card, and logs the HUD's state every 50 ms (TRACE lines),
// the window mapping and unmapping (WINDOW), the audio bridge and cava
// being allowed to run or not (LIVE), the window being held (HOLD), its
// fade-out starting and stopping (FADE), what it saved (FRAME) and what it
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
    readonly property bool fakeCava: scenario === "quiet" || scenario === "loud" || scenario === "demo"
    // "demo" saves what the overlay window shows, glow and corner brackets
    // included, every demoFrameMs while it is mapped, for capture.sh.
    readonly property bool demo: scenario === "demo"
    readonly property int demoFrameMs: 66
    property int demoFrames: 0
    // The spectrum while speech is being fed in by fake-cava.py: the
    // loudest band level seen, the largest share of bands at the top in any
    // one frame (overall, and after the first second of speech, by when
    // the reference has caught up with the speaker), and the share of
    // band-frames at the top.
    property real speechMaxLevel: 0
    property real speechMaxPinned: 0
    property real settledMaxPinned: 0
    property real pinnedSum: 0
    property int speechFrames: 0
    property real hissMaxLevel: 0
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
    // An "await" step pauses the script until the HUD starts fading out;
    // the steps after it are then timed as if the fade had started at the
    // await step's time, `shift` ms later than written.
    property real shift: 0
    property real fadeStartedAt: -1
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
        // A `--no-osd` recording started 10 ms into an ordinary dictation's
        // fade-out, its marker 30 ms after the state: the window, held for
        // the settling, hides as the marker arrives, without finishing the
        // fade, drawing REC or running the bridge.
        fadesuppressed: [
            [0, "state", "recording"],
            [2500, "state", "transcribing"],
            [2690, "pp", "start"],
            [2730, "pp", "llm"],
            [3950, "pp", "done"],
            [4550, "state", "idle"],
            [4600, "await", "fade"],
            [4600, "clear", ""],
            [4610, "state", "recording"],
            [4640, "marker", "on"],
            [4800, "check", "never-shown"],
            [4800, "check", "hidden-now"],
            [5200, "state", "transcribing"],
            [5500, "state", "idle"],
            [5520, "marker", "off"],
            [6000, "check", "never-shown"],
            [6200, "quit", ""]
        ],
        // An ordinary recording started 140 ms into the previous
        // dictation's 180 ms fade-out: the window must be held for the
        // settling, the fade cancelled, and never unmap before the last
        // idle.
        faderecord: [
            [0, "state", "recording"],
            [2500, "state", "transcribing"],
            [2690, "pp", "start"],
            [2730, "pp", "llm"],
            [3950, "pp", "done"],
            [4550, "state", "idle"],
            [4600, "await", "fade"],
            [4740, "state", "recording"],
            [4940, "check", "holding"],
            [4940, "check", "rerecord"],
            [4940, "check", "opaque"],
            [5000, "grab", "rerecord"],
            [6500, "state", "transcribing"],
            [6700, "pp", "start"],
            [7000, "pp", "done-raw"],
            [7300, "check", "no-unmap"],
            [7400, "state", "idle"],
            [9500, "quit", ""]
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
        // Soft speech from fake-cava.py, peaking at about 0.03 of cava's
        // range, after an earlier session saved a reference ten times
        // that: room hiss must rest at the centre cell, and the speech
        // must fill several cells within its first second.
        quiet: [
            [0, "state", "recording"],
            [500, "grab", "hiss"],
            [500, "check", "hiss"],
            [1500, "grab", "quiet-early"],
            [1600, "check", "speech-early"],
            [2600, "grab", "quiet"],
            [3400, "grab", "quiet-late"],
            [3500, "check", "quiet"],
            [3600, "state", "idle"],
            [4500, "quit", ""]
        ],
        // Loud speech, its loudest bands touching the top of cava's range:
        // it must fill the height without every column pinned there.
        loud: [
            [0, "state", "recording"],
            [1500, "grab", "loud-early"],
            [2600, "grab", "loud"],
            [3400, "grab", "loud-late"],
            [3500, "check", "loud"],
            [3600, "state", "idle"],
            [4500, "quit", ""]
        ],
        // One unhurried dictation for the publishing assets: a spoken
        // sentence from fake-cava.py, an STT scan long enough to watch, and a "hero"
        // frame of the window in the middle of the LLM scan.
        demo: [
            [0, "state", "recording"],
            [3000, "state", "transcribing"],
            [3700, "pp", "start"],
            [3740, "pp", "llm"],
            [4500, "window", "hero"],
            [4900, "pp", "done"],
            [5500, "state", "idle"],
            [7500, "quit", ""]
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
        bridgeExecutable: "/usr/bin/python3"
        bridgeArgs: ["-I", harness.bridge,
                     harness.scenario === "silence" || (harness.fakeCava && !harness.demo) ? "silent"
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
                    harness.heldCleanly = hud.holding && hud.windowShown && !hud.shown && !hud.live
                        && !hud.fading;
                    if (harness.scenario === "relinger" || harness.scenario === "faderecord")
                        harness.grab(hud.windowItem, "held");
                });
            }
            console.log("HOLD " + (holding ? "started" : "ended") + " at " + (Date.now() - harness.t0) + " ms");
        }
        onFadingChanged: {
            const e = Date.now() - harness.t0;
            if (fading) harness.fadeStartedAt = e;
            console.log("FADE " + (fading ? "started" : "stopped") + " at " + e + " ms, opacity "
                + hud.windowItem.opacity.toFixed(2));
        }
        // A marker hides the window at once, whatever it was doing.
        onMarkerPresentChanged: {
            if (!markerPresent) return;
            Qt.callLater(function() {
                const ok = !hud.windowShown && !hud.fading && !hud.holding;
                console.log((ok ? "CHECK" : "FAIL") + " marker hid the window at once: window "
                    + hud.windowShown + ", fading " + hud.fading + ", holding " + hud.holding);
            });
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
        sourceCommand: harness.scenario === "cava" ? ["/usr/bin/pactl", "get-default-source"]
            : harness.fakeCava ? ["/usr/bin/echo", "harness.fake.source"] : ["/usr/bin/false"]
        // The HUD clears the environment of everything it runs, so the fake
        // is told its level as an argument.
        cavaExecutable: harness.fakeCava ? "/usr/bin/python3" : "/usr/bin/cava"
        cavaArgs: harness.fakeCava
            ? ["-I", Quickshell.env("HARNESS_FAKE_CAVA"), harness.scenario] : []
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

    // Saves what the overlay window shows: the card as the window draws it
    // (heldFrame, with the fades) and everything round it, on a
    // transparent background.
    function grabWindow(name) {
        const e = Date.now() - t0;
        const file = out + "/" + name.replace("%t", String(e).padStart(5, "0")) + ".png";
        hud.windowFrameItem.grabToImage(function(r) {
            r.saveToFile(file);
            if (name.indexOf("%t") < 0) console.log("FRAME " + file + " at " + e + " ms, stage " + hud.stage);
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
        } else if (action === "window") {
            grabWindow(arg);
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
        } else if (what === "opaque") {
            const ok = !hud.fading && hud.windowItem.opacity >= 0.999 && hud.windowItem.scale >= 0.999;
            console.log((ok ? "CHECK" : "FAIL") + " fade-out cancelled by the re-record: fading "
                + hud.fading + ", opacity " + hud.windowItem.opacity.toFixed(3) + ", scale "
                + hud.windowItem.scale.toFixed(3));
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
        } else if (what === "hiss") {
            const ok = hud.lastCavaMs > 0 && hissMaxLevel < 0.06;
            console.log((ok ? "CHECK" : "FAIL") + " room hiss rests at the centre cell: loudest band "
                + hissMaxLevel.toFixed(3) + ", cava frames " + (hud.lastCavaMs > 0));
        } else if (what === "speech-early") {
            const ok = speechMaxLevel >= 0.35;
            console.log((ok ? "CHECK" : "FAIL") + " quiet speech moves in its first second: loudest band "
                + speechMaxLevel.toFixed(3) + " over " + speechFrames + " frames, reference now "
                + hud.bandRef.slice(0, 4).map(function(v) { return v.toFixed(3); }).join(" "));
        } else if (what === "quiet") {
            const ok = speechMaxLevel >= 0.5 && speechMaxPinned < 0.5;
            console.log((ok ? "CHECK" : "FAIL") + " quiet speech fills the spectrum: loudest band "
                + speechMaxLevel.toFixed(3) + ", most bands pinned at once "
                + (speechMaxPinned * 100).toFixed(0) + " %");
        } else if (what === "loud") {
            const mean = speechFrames > 0 ? pinnedSum / speechFrames : 0;
            const ok = speechMaxLevel >= 0.6 && settledMaxPinned < 0.25 && mean < 0.03;
            console.log((ok ? "CHECK" : "FAIL") + " loud speech is not pinned at the top: loudest band "
                + speechMaxLevel.toFixed(3) + ", most bands pinned at once "
                + (speechMaxPinned * 100).toFixed(0) + " % (" + (settledMaxPinned * 100).toFixed(0)
                + " % after the first second), bands pinned on average " + (mean * 100).toFixed(1) + " %");
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
            while (harness.next < script.length && e >= script[harness.next][0] + harness.shift) {
                const step = script[harness.next];
                if (step[1] === "await") {
                    if (harness.fadeStartedAt < 0) break;
                    harness.shift = harness.fadeStartedAt - step[0];
                    console.log("AWAIT fade seen at " + harness.fadeStartedAt + " ms, later steps "
                        + harness.shift + " ms late");
                    harness.next++;
                    continue;
                }
                harness.next++;
                harness.run(step[1], step[2]);
            }
            if (harness.fakeCava && hud.recording && hud.level.length > 0) {
                let top = 0;
                let pinned = 0;
                for (let i = 0; i < hud.level.length; i++) {
                    top = Math.max(top, hud.level[i]);
                    if (hud.level[i] >= 0.97) pinned++;
                }
                // fake-cava.py starts speaking 0.6 s in.
                if (e < 550) {
                    if (hud.lastCavaMs > 0) harness.hissMaxLevel = Math.max(harness.hissMaxLevel, top);
                } else if (e > 650) {
                    harness.speechFrames++;
                    harness.speechMaxLevel = Math.max(harness.speechMaxLevel, top);
                    harness.speechMaxPinned = Math.max(harness.speechMaxPinned, pinned / hud.level.length);
                    harness.pinnedSum += pinned / hud.level.length;
                    if (e > 1600) harness.settledMaxPinned = Math.max(harness.settledMaxPinned, pinned / hud.level.length);
                }
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
        interval: harness.demoFrameMs
        repeat: true
        running: harness.demo && harness.t0 > 0 && hud.windowShown
        onTriggered: {
            harness.grabWindow("demo-" + String(harness.demoFrames++).padStart(4, "0") + "-%t");
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
                + " shown=" + hud.shown + " window=" + hud.windowShown
                + " opacity=" + hud.windowItem.opacity.toFixed(2) + " scale=" + hud.windowItem.scale.toFixed(3));
        }
    }
}
