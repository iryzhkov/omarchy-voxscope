// Signal: a themed HUD for the voxtype Quickshell OSD.
//
// The host (OsdSurface.qml) loads this item over a full-screen transparent
// layer surface while the daemon is not idle and injects daemonState and
// audio. The card centres itself on the screen.
//
// Each stage of the dictation pipeline has its own visualisation:
//   REC  a mirrored live spectrum of the mic, with held peaks; meanwhile the
//        loudness is recorded as a timeline, one column per 100 ms
//   STT  the whole recording's timeline, drawn as a soft analog envelope,
//        with a scan line sweeping across it; behind the line the columns
//        are rebuilt from square cells
//   LLM  a second scan line over those cells, turning them into blocks the
//        length of the transcript's words
//   OUT  the words typed out as runs of cells behind a block cursor; the
//        subtitle gives the word count and whether the LLM cleaned the text
// A stepper across the top and a progress bar along the bottom track the
// same stages.
//
// Stage detection. voxtype reports one "transcribing" state for both speech
// to text and the post-process command, so ~/.local/bin/voxtype-clean writes
// $XDG_RUNTIME_DIR/voxtype/postprocess.json ({"stage": "start"|"llm"|"done",
// "t": ms, ...}); "start" marks the end of speech to text. A status written
// before the current transcription began is stale and ignored.
//
// Scan timing. Neither whisper nor the LLM reports progress, so each scan
// runs for an estimated duration (audio seconds for STT, word count for the
// LLM), at least scanMinMs. When the real stage ends first, the line
// fast-forwards to the end; when it overruns, the line slows down near the
// end instead of stopping. The estimates learn from measured durations and
// persist in timing.json. The displayed stage follows the scans, so it can
// lag the real one; the host hides the OSD as soon as voxtype goes idle,
// which can cut the last scan short.
//
// Colour comes from the active Omarchy theme (colors.toml), re-read each
// time the OSD appears, so a theme switch shows on the next dictation.
//
// Spectrum. voxtype's audio bridge only carries peak and RMS, so the
// spectrum comes from cava reading the default PipeWire source while
// recording, at fixed gain and normalised here. If cava is missing or
// silent, the bars are synthesised from the bridge's RMS instead.

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io

Item {
    id: root

    // Injected by the host.
    property string daemonState: "idle"
    property var audio: null
    property var theme: null
    property var recipe: null
    property string assetRoot: ""

    // Theme colours; neutral defaults until colors.toml loads.
    property color themeBackground: "#0b0d12"
    property color themeAccent: "#7aa2f7"
    property color themeForeground: "#d8ddec"
    property color themeMuted: "#5c5e64"
    property string fontFamily: "JetBrainsMono Nerd Font"

    function mix(a, b, t) {
        return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t,
                       a.b + (b.b - a.b) * t, 1);
    }
    function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a); }

    readonly property color cBg: themeBackground
    readonly property color cDim: mix(themeBackground, themeAccent, 0.18)
    readonly property color cMid: mix(themeBackground, themeAccent, 0.55)
    readonly property color cAccent: themeAccent
    readonly property color cHot: mix(themeAccent, themeForeground, 0.5)
    readonly property color cText: themeForeground
    readonly property color cMuted: themeMuted

    readonly property int bands: 32
    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
    readonly property string packageDir: {
        const u = String(Qt.resolvedUrl("."));
        return u.indexOf("file://") === 0 ? u.substring(7) : u;
    }

    readonly property bool shown: daemonState !== "idle" && daemonState !== ""
    readonly property bool recording: daemonState === "recording" || daemonState === "streaming"
    readonly property bool working: daemonState === "transcribing"

    property real stateSince: Date.now()
    property real now: Date.now()

    // Latest post-process status from voxtype-clean.
    property var pp: ({})
    readonly property bool ppFresh: pp && pp.t !== undefined && pp.t >= stateSince - 250
    // Displayed stage, 0 REC, 1 STT, 2 LLM, 3 OUT. While transcribing it
    // follows the scans (updateScans), not the real stage.
    property int scanStage: 1
    property real scanStageSince: Date.now()
    property real scanP1: 0
    property real scanP2: 0
    readonly property int stage: recording ? 0 : !working ? 3 : scanStage
    readonly property real stageSince: recording ? stateSince : scanStageSince
    readonly property real elapsed: Math.max(0, (now - stateSince) / 1000)
    readonly property real stageElapsed: Math.max(0, (now - stageSince) / 1000)

    readonly property real scanMinMs: 500
    readonly property real scanFastForwardMs: 150
    // Learned seconds per unit: STT per audio second (plus sttOffsetSecs),
    // LLM per word (plus llmOffsetWords). Defaults fit the gaming-pc whisper
    // and a warm cleanup model.
    readonly property real sttOffsetSecs: 4
    readonly property real llmOffsetWords: 20
    property real sttRate: 0.016
    property real llmRate: 0.03
    // Typing, in seconds per character (plus typeOffsetChars), learned from
    // the time between voxtype-clean finishing and voxtype going idle, so
    // the typing animation ends when the real typing does.
    readonly property real typeOffsetChars: 20
    property real typeRate: 0.003
    property real learnedFor: 0

    // The recording as a timeline: mean level per 100 ms column.
    property var tape: []
    property real tapeSum: 0
    property int tapeCount: 0
    property real tapeLastMs: 0
    property real recSecs: 0
    property string prevState: "idle"

    // Spectrum state, 0..1 per band.
    property var target: []
    property real lastCavaMs: 0
    // Per-band calibration: ref tracks how loud each band gets in speech
    // (fast attack, release of about 1 % a second), noise tracks the room
    // floor (falls fast, creeps up slowly). Both persist in calibration.json
    // between dictations, so the meter settles to this mic and room over
    // time instead of starting from scratch each recording.
    property var bandRef: []
    property var bandNoise: []
    property bool calibrationLoaded: false
    property var level: []
    property var peak: []
    property var peakAge: []
    property real energy: 0

    // Indicator lights.
    property real lastBridgeMs: 0
    property real voiceUntil: 0
    property real clipUntil: 0
    readonly property bool micLit: now - lastBridgeMs < 500 || now - lastCavaMs < 500
    readonly property bool voiceLit: now < voiceUntil
    readonly property bool clipLit: now < clipUntil

    // voxtype's recording cap, read from its config; the last ten seconds
    // before the cap show a countdown.
    property real maxRecordSecs: 300
    readonly property real remaining: maxRecordSecs - elapsed
    readonly property bool stopWarning: stage === 0 && remaining <= 10

    // Silence auto-stop, for recordings started with the toggle key only
    // (~/.local/bin/voxtype-toggle stamps toggle-start; push-to-talk is
    // ended by releasing the key). After silenceStopSecs without voice the
    // OSD stops the recording itself, counting down for the last five.
    readonly property real silenceStopSecs: 10
    property real toggleStamp: 0
    readonly property bool toggleMode: toggleStamp > 0 && Math.abs(toggleStamp - stateSince) < 3000
    property real lastVoiceMs: Date.now()
    property bool autoStopSent: false
    readonly property real silentFor: Math.max(0, (now - lastVoiceMs) / 1000)
    readonly property bool silenceWarning: stage === 0 && toggleMode && !stopWarning
        && silentFor >= silenceStopSecs - 5
    readonly property bool anyWarning: stopWarning || silenceWarning
    readonly property color cWarn: mix(themeAccent, Qt.color("#ff3b30"), 0.7)
    property real lastTickMs: Date.now()

    onDaemonStateChanged: {
        // Derived from daemonState here, because the `recording` and
        // `working` bindings may not have been re-evaluated yet when this
        // handler runs.
        const t = Date.now();
        const isRecording = daemonState === "recording" || daemonState === "streaming";
        const isWorking = daemonState === "transcribing";
        if ((prevState === "recording" || prevState === "streaming") && !isRecording) {
            recSecs = (t - stateSince) / 1000;
        }
        if (prevState === "transcribing" && !isWorking && !isRecording
            && pp && pp.stage === "done" && pp.t >= stateSince - 250) {
            learnTyping((t - pp.t) / 1000);
        }
        prevState = daemonState;
        stateSince = t;
        if (shown) {
            themeFile.reload();
            voxtypeConfig.reload();
        }
        if (isRecording) {
            lastVoiceMs = t;
            autoStopSent = false;
            toggleFile.reload();
            target = [];
            lastCavaMs = 0;
            tape = [];
            tapeSum = 0;
            tapeCount = 0;
            tapeLastMs = t;
        }
        if (isWorking) {
            scanStage = 1;
            scanStageSince = t;
            scanP1 = 0;
            scanP2 = 0;
        }
    }

    // Progress of one scan at time t: it starts at `start`, is expected to
    // take `expected` ms (at least scanMinMs) and the work it shows ended at
    // `actual` (null while still running). Returns { p: 0..1, end: ms }, end
    // being Infinity until the work has ended.
    function scan(t, start, expected, actual) {
        const span = Math.max(expected, scanMinMs);
        const eased = function(at) {
            const r = Math.max(0, (at - start) / span);
            // Linear to 80 %, then easing toward 97 % with matching slope.
            return r < 0.8 ? r : 0.8 + 0.17 * (1 - Math.exp(-(r - 0.8) / 0.17));
        };
        if (actual === null) return { p: eased(t), end: Infinity };
        const a = Math.max(actual, start);
        const pa = eased(a);
        const end = Math.max(a + scanFastForwardMs, start + scanMinMs);
        const p = t <= a ? eased(t) : Math.min(1, pa + (1 - pa) * (t - a) / (end - a));
        return { p: p, end: end };
    }

    function updateScans(t) {
        if (!working) return;
        const fresh = ppFresh;
        const sttEnd = fresh && pp.stt_t ? pp.stt_t : null;
        const s1 = scan(t, stateSince, sttRate * (recSecs + sttOffsetSecs) * 1000, sttEnd);
        let stg = 1;
        let since = stateSince;
        let p2 = 0;
        if (t >= s1.end) {
            const done = fresh && pp.stage === "done";
            if (fresh && pp.llm_t) {
                const words = pp.words_in || 0;
                const expected = pp.llm_t + llmRate * (words + llmOffsetWords) * 1000 - s1.end;
                const s2 = scan(t, s1.end, expected, done ? pp.t : null);
                if (t < s2.end) {
                    stg = 2;
                    since = s1.end;
                    p2 = s2.p;
                } else {
                    stg = 3;
                    since = s2.end;
                    p2 = 1;
                }
            } else if (done) {
                stg = 3;
                since = s1.end;
            }
        }
        scanP1 = s1.p;
        scanP2 = p2;
        scanStage = stg;
        scanStageSince = since;
        if (fresh && pp.stage === "done" && pp.t !== learnedFor) learnTiming();
    }

    // Fold this dictation's measured stage durations into the estimates.
    function learnTiming() {
        learnedFor = pp.t;
        const fold = foldRate;
        if (pp.stt_t && recSecs > 0) {
            const secs = (pp.stt_t - stateSince) / 1000;
            if (secs > 0) sttRate = fold(sttRate, secs / (recSecs + sttOffsetSecs));
        }
        if (pp.llm_t && (pp.cleaned || pp.reason === "rejected")) {
            const secs = (pp.t - pp.llm_t) / 1000;
            // A timeout says nothing about the model's speed.
            if (secs > 0 && secs < 0.95 * (pp.timeout || 5)) {
                llmRate = fold(llmRate, secs / ((pp.words_in || 0) + llmOffsetWords));
            }
        }
        saveTiming();
    }

    function foldRate(old, sample) {
        return old + (clamp(sample, old * 0.25, old * 4) - old) * 0.3;
    }

    function saveTiming() {
        timingFile.setText(JSON.stringify({ version: 1, stt: sttRate, llm: llmRate, type: typeRate }));
    }

    // Characters voxtype types for the current output.
    function typedChars() {
        const lens = pp.lens || [];
        if (lens.length === 0) return (pp.words || 0) * 6;
        let n = lens.length - 1;
        for (let i = 0; i < lens.length; i++) n += lens[i];
        return n;
    }

    function learnTyping(secs) {
        if (secs <= 0 || secs > 30) return;
        typeRate = foldRate(typeRate, secs / (typedChars() + typeOffsetChars));
        saveTiming();
    }

    // Typing animation progress, 0..1: from when the scans hand over to the
    // estimated end of the real typing, or quickly when that has passed.
    function typingProgress() {
        if (!ppFresh || pp.stage !== "done") return 1;
        const start = scanStageSince;
        const end = Math.max(start + 150, pp.t + typeRate * (typedChars() + typeOffsetChars) * 1000);
        return clamp((now - start) / (end - start), 0, 1);
    }

    // Save the calibration every couple of seconds while recording; the
    // host does not reliably deliver the state change at the end of one.
    Timer {
        interval: 2000
        repeat: true
        running: root.recording && root.calibrationLoaded
        onTriggered: {
            if (root.bandRef.length === root.bands) {
                calibrationFile.setText(JSON.stringify({ version: 1, ref: root.bandRef, noise: root.bandNoise }));
            }
        }
    }

    Connections {
        target: root.audio
        enabled: root.audio !== null
        function onFrameReceived(peak, rms, vad, tsMs) {
            const t = Date.now();
            root.lastBridgeMs = t;
            // Hold the lights so they read as states rather than flicker.
            if (vad) {
                root.voiceUntil = t + 900;
                root.lastVoiceMs = t;
            }
            if (peak >= 0.98) root.clipUntil = t + 1200;
        }
    }

    function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }

    function fmtClock(secs) {
        const tenths = Math.floor(secs * 10);
        const s = Math.floor(tenths / 10);
        const m = Math.floor(s / 60);
        return (m < 10 ? "0" : "") + m + ":" + (s % 60 < 10 ? "0" : "") + (s % 60) + "." + (tenths % 10);
    }

    function modelName() {
        return String(pp.model || "llm").replace(/:latest$/, "");
    }

    function title() {
        return ["LISTENING", "TRANSCRIBING", "REFINING", "TYPING"][stage];
    }

    function subtitle() {
        if (stopWarning) return "AUTO-STOP IN " + Math.max(0, Math.ceil(remaining)) + "S";
        if (silenceWarning) return "NO VOICE  ·  STOPPING IN " + Math.max(0, Math.ceil(silenceStopSecs - silentFor)) + "S";
        if (stage === 0) return "MICROPHONE";
        if (stage === 1) return "SPEECH TO TEXT  ·  WHISPER";
        if (stage === 2) return "POST-PROCESSING  ·  " + modelName().toUpperCase();
        if (!ppFresh) return "OUTPUT";
        const words = pp.words !== undefined ? "  ·  " + pp.words + " WORDS" : "";
        if (pp.cleaned) return "CLEANED BY " + modelName().toUpperCase() + words;
        if (pp.reason === "disabled") return "LLM CLEANUP OFF" + words;
        if (pp.reason === "loading") return "MODEL WARMING UP  ·  RAW" + words;
        return "RAW TRANSCRIPT" + words;
    }

    function _targetFor(i, t) {
        if (now - lastCavaMs < 400 && target.length > 0) {
            const idx = Math.floor(i * target.length / bands);
            const v = target[idx] || 0;
            const floor = (bandNoise[i] || 0) * 1.5;
            let globalRef = 0;
            for (let k = 0; k < bandRef.length; k++) globalRef = Math.max(globalRef, bandRef[k]);
            // Quiet bands are not stretched all the way: their reference is
            // at least a quarter of the loudest band's, so hiss stays low.
            const ref = Math.max(bandRef[i] || 0.08, globalRef * 0.25, floor * 2, 0.02);
            return Math.pow(clamp((v - floor) / (ref - floor), 0, 1), 0.7);
        }
        // Fallback: a speech-shaped envelope driven by the bridge RMS.
        const rms = audio ? audio.rms || 0 : 0;
        const shape = Math.exp(-Math.pow((i - 8) / 10, 2));
        const jitter = 0.65 + 0.35 * Math.sin(t * 0.017 + i * 1.7) * Math.sin(t * 0.011 + i * 0.6);
        return clamp(rms * 7.0 * shape * jitter, 0, 1);
    }

    function calibrate(dt) {
        const ref = bandRef.length === bands ? bandRef.slice() : new Array(bands).fill(0.08);
        const noise = bandNoise.length === bands ? bandNoise.slice() : new Array(bands).fill(0.005);
        for (let i = 0; i < bands; i++) {
            const v = target[Math.floor(i * target.length / bands)] || 0;
            ref[i] = v > ref[i] ? ref[i] + (v - ref[i]) * Math.min(1, 3 * dt)
                                : Math.max(0.02, ref[i] - ref[i] * 0.01 * dt);
            noise[i] = v < noise[i] ? noise[i] + (v - noise[i]) * Math.min(1, 2 * dt)
                                    : noise[i] + (v - noise[i]) * 0.02 * dt;
        }
        bandRef = ref;
        bandNoise = noise;
    }

    function tick() {
        const t = Date.now();
        const dt = Math.min(0.1, Math.max(0.001, (t - lastTickMs) / 1000));
        lastTickMs = t;
        now = t;

        if (recording && now - lastCavaMs < 400 && target.length > 0) calibrate(dt);
        if (stage === 0 && toggleMode && !autoStopSent && silentFor >= silenceStopSecs) {
            autoStopSent = true;
            stopper.running = true;
        }

        const lv = level.length === bands ? level.slice() : new Array(bands).fill(0);
        const pk = peak.length === bands ? peak.slice() : new Array(bands).fill(0);
        const pa = peakAge.length === bands ? peakAge.slice() : new Array(bands).fill(0);
        let sum = 0;
        for (let i = 0; i < bands; i++) {
            const tg = recording ? _targetFor(i, t) : 0;
            lv[i] = tg >= lv[i] ? lv[i] + (tg - lv[i]) * 0.6 : Math.max(tg, lv[i] - 1.6 * dt);
            if (lv[i] >= pk[i]) {
                pk[i] = lv[i];
                pa[i] = 0;
            } else {
                pa[i] += dt;
                if (pa[i] > 0.15) pk[i] = Math.max(lv[i], pk[i] - 2.2 * dt);
            }
            sum += lv[i];
        }
        level = lv;
        peak = pk;
        if (recording) {
            tapeSum += sum / bands;
            tapeCount++;
            if (t - tapeLastMs >= 100 && tape.length < 3000) {
                tape.push(tapeSum / tapeCount);
                tapeSum = 0;
                tapeCount = 0;
                tapeLastMs = t;
            }
        }
        updateScans(t);
        peakAge = pa;
        // Energy follows the voice while recording and drives the corner
        // brackets; afterwards it decays slowly.
        const e = sum / bands;
        energy = recording ? Math.max(e, energy - 1.2 * dt) : Math.max(0.15, energy - 0.12 * dt);

        viz.requestPaint();
        progress.requestPaint();
        brackets.requestPaint();
    }

    Timer {
        interval: 16
        repeat: true
        running: root.shown
        onTriggered: root.tick()
    }

    FileView {
        id: toggleFile
        path: root.runtimeDir + "/voxtype/toggle-start"
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.toggleStamp = Number(text().trim()) || 0
    }

    Process {
        id: stopper
        command: ["voxtype", "record", "stop"]
    }

    FileView {
        id: calibrationFile
        path: root.packageDir + "/calibration.json"
        printErrors: false
        onLoaded: {
            try {
                const c = JSON.parse(text());
                if (c.ref && c.ref.length === root.bands && c.noise && c.noise.length === root.bands) {
                    root.bandRef = c.ref;
                    root.bandNoise = c.noise;
                }
            } catch (e) {}
            root.calibrationLoaded = true;
        }
        onLoadFailed: root.calibrationLoaded = true
    }

    FileView {
        id: timingFile
        path: root.packageDir + "/timing.json"
        printErrors: false
        onLoaded: {
            try {
                const c = JSON.parse(text());
                if (c.stt > 0) root.sttRate = c.stt;
                if (c.llm > 0) root.llmRate = c.llm;
                if (c.type > 0) root.typeRate = c.type;
            } catch (e) {}
        }
    }

    FileView {
        id: voxtypeConfig
        path: Quickshell.env("HOME") + "/.config/voxtype/config.toml"
        printErrors: false
        onLoaded: {
            const m = /^max_duration_secs\s*=\s*(\d+)/m.exec(text());
            if (m) root.maxRecordSecs = Number(m[1]);
        }
    }

    FileView {
        id: themeFile
        path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
        printErrors: false
        onLoaded: {
            const t = text();
            function pick(key) {
                const m = new RegExp("^" + key + "\\s*=\\s*\"(#[0-9a-fA-F]{6})\"", "m").exec(t);
                return m ? m[1] : null;
            }
            const bg = pick("background");
            const accent = pick("accent");
            const fg = pick("bright_foreground") || pick("foreground");
            if (bg && accent && fg) {
                root.themeBackground = bg;
                root.themeAccent = accent;
                root.themeForeground = fg;
                root.themeMuted = pick("muted") || root.mix(bg, fg, 0.45);
            }
        }
    }

    // Post-process status, polled while transcribing: voxtype-clean replaces
    // the file by rename, which a file watch would lose track of.
    FileView {
        id: ppFile
        path: root.runtimeDir + "/voxtype/postprocess.json"
        printErrors: false
        onLoaded: {
            try {
                root.pp = JSON.parse(text());
            } catch (e) {}
        }
    }

    Timer {
        interval: 100
        repeat: true
        running: root.working
        triggeredOnStart: true
        onTriggered: ppFile.reload()
    }

    Process {
        id: cava
        running: root.recording
        command: [
            "setpriv", "--pdeathsig", "TERM", "bash", "-c",
            "src=$(pactl get-default-source 2>/dev/null); "
                + "exec cava -p <(sed \"s|@SOURCE@|${src:-auto}|\" \"$1\")",
            "voxtype-signal-cava", root.packageDir + "/cava.conf"
        ]
        stdout: SplitParser {
            onRead: function(line) {
                const parts = line.split(";");
                const values = [];
                for (let i = 0; i < parts.length; i++) {
                    if (parts[i].length > 0) values.push(Number(parts[i]) / 1000);
                }
                if (values.length > 0) {
                    root.target = values;
                    root.lastCavaMs = Date.now();
                }
            }
        }
    }

    component Label: Text {
        textFormat: Text.PlainText
        font.family: root.fontFamily
        font.pixelSize: 12
        font.letterSpacing: 2
        color: root.cMuted
    }

    Item {
        id: card
        width: 580
        height: 268
        anchors.centerIn: parent

        Rectangle {
            anchors.fill: parent
            radius: 6
            color: root.cBg
            border.width: 1
            border.color: root.cDim
        }

        // Everything that glows is drawn into `screen`; the MultiEffect
        // below draws it again with a soft bloom.
        Item {
            id: screen
            anchors.fill: parent
            anchors.margins: 24
            layer.enabled: true
            visible: false

            // Stepper: REC - STT - LLM - OUT.
            Row {
                id: stepper
                anchors.left: parent.left
                anchors.top: parent.top
                spacing: 0
                Repeater {
                    model: ["REC", "STT", "LLM", "OUT"]
                    Row {
                        required property int index
                        required property string modelData
                        spacing: 8
                        Rectangle {
                            visible: index > 0
                            width: 22
                            height: 1
                            anchors.verticalCenter: parent.verticalCenter
                            color: index <= root.stage ? root.cAccent : root.cDim
                        }
                        Rectangle {
                            width: 9
                            height: 9
                            radius: 4.5
                            anchors.verticalCenter: parent.verticalCenter
                            color: index < root.stage ? root.cAccent
                                : index === root.stage ? root.cHot
                                : "transparent"
                            border.width: 1
                            border.color: index <= root.stage ? root.cAccent : root.cDim
                            opacity: index === root.stage && root.stage < 3
                                ? 0.55 + 0.45 * Math.abs(Math.sin(root.now / 320)) : 1
                        }
                        Label {
                            text: modelData
                            anchors.verticalCenter: parent.verticalCenter
                            font.bold: index === root.stage
                            color: index === root.stage ? root.cText
                                : index < root.stage ? root.cAccent
                                : root.cMuted
                        }
                        Item { width: 4; height: 1 }
                    }
                }
            }

            Label {
                anchors.right: parent.right
                anchors.verticalCenter: stepper.verticalCenter
                text: root.fmtClock(root.stage === 0 ? root.elapsed : root.stageElapsed)
                font.pixelSize: 13
                color: root.stopWarning ? root.cWarn : root.cText
            }

            Text {
                id: titleText
                anchors.left: parent.left
                anchors.top: stepper.bottom
                anchors.topMargin: 14
                textFormat: Text.PlainText
                text: root.title()
                font.family: root.fontFamily
                font.pixelSize: 26
                font.bold: true
                font.letterSpacing: 5
                color: root.cHot
            }

            Label {
                id: subtitleText
                anchors.left: parent.left
                anchors.top: titleText.bottom
                anchors.topMargin: 2
                text: root.subtitle()
                color: root.anyWarning ? root.cWarn : root.cMuted
                font.bold: root.anyWarning
            }

            // Indicator lights while recording: input alive, voice heard
            // (held so it doesn't flicker word to word), and clipping.
            Row {
                visible: root.stage === 0
                anchors.right: parent.right
                anchors.verticalCenter: subtitleText.verticalCenter
                spacing: 14
                Repeater {
                    model: [
                        { name: "MIC", key: "mic" },
                        { name: "VOICE", key: "voice" },
                        { name: "CLIP", key: "clip" }
                    ]
                    Row {
                        required property var modelData
                        readonly property bool lit: modelData.key === "mic" ? root.micLit
                            : modelData.key === "voice" ? root.voiceLit
                            : root.clipLit
                        readonly property color litColor: modelData.key === "clip" ? root.cWarn : root.cHot
                        spacing: 6
                        Rectangle {
                            width: 7
                            height: 7
                            radius: 1
                            anchors.verticalCenter: parent.verticalCenter
                            color: parent.lit ? parent.litColor : "transparent"
                            border.width: 1
                            border.color: parent.lit ? parent.litColor : root.cDim
                            Behavior on color { ColorAnimation { duration: 120 } }
                        }
                        Label {
                            text: parent.modelData.name
                            anchors.verticalCenter: parent.verticalCenter
                            font.pixelSize: 11
                            color: parent.lit ? root.cText : root.cMuted
                        }
                    }
                }
            }

            Canvas {
                id: viz
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: subtitleText.bottom
                anchors.topMargin: 12
                anchors.bottom: progress.top
                anchors.bottomMargin: 12
                renderStrategy: Canvas.Cooperative

                function css(c, a) {
                    return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + ","
                        + Math.round(c.b * 255) + "," + (a === undefined ? 1 : a) + ")";
                }

                function drawSpectrum(ctx, w, h) {
                    const n = root.bands;
                    const gap = 4;
                    const bw = (w - gap * (n - 1)) / n;
                    const cy = h / 2;
                    const half = h / 2 - 3;

                    ctx.fillStyle = css(root.cDim);
                    ctx.fillRect(0, Math.round(cy), w, 1);

                    const grad = ctx.createLinearGradient(0, cy - half, 0, cy + half);
                    grad.addColorStop(0, css(root.cMid));
                    grad.addColorStop(0.35, css(root.cAccent));
                    grad.addColorStop(0.5, css(root.cHot));
                    grad.addColorStop(0.65, css(root.cAccent));
                    grad.addColorStop(1, css(root.cMid));

                    for (let i = 0; i < n; i++) {
                        const x = i * (bw + gap);
                        const amp = Math.max(1, (root.level[i] || 0) * half);
                        ctx.fillStyle = grad;
                        ctx.fillRect(x, cy - amp, bw, amp * 2);
                        const pk = root.peak[i] || 0;
                        if (pk > 0.03) {
                            ctx.fillStyle = css(root.cHot);
                            ctx.fillRect(x, cy - pk * half - 3, bw, 2);
                            ctx.fillRect(x, cy + pk * half + 1, bw, 2);
                        }
                    }
                }

                // The recording's timeline resampled to `n` columns, each the
                // loudest 100 ms in its slice, normalised to the loudest
                // column so quiet recordings still fill the height.
                function envelope(n) {
                    const tape = root.tape;
                    const out = new Array(n).fill(0);
                    if (tape.length === 0) return out;
                    let top = 0.15;
                    for (let i = 0; i < n; i++) {
                        const a = Math.floor(i * tape.length / n);
                        const b = Math.max(a + 1, Math.floor((i + 1) * tape.length / n));
                        let v = 0;
                        for (let k = a; k < b && k < tape.length; k++) v = Math.max(v, tape[k]);
                        out[i] = v;
                        top = Math.max(top, v);
                    }
                    for (let i = 0; i < n; i++) out[i] = out[i] / top;
                    return out;
                }

                // Word blocks for the LLM scan: the transcript's words laid
                // out along the width, wrapped onto more lines when there are
                // too many to stay legible on one.
                function wordLayout(lens, w, h) {
                    let total = 0;
                    for (let i = 0; i < lens.length; i++) total += lens[i] + 1;
                    const lines = Math.max(1, Math.ceil(total * 2 / w));
                    const unit = Math.min(6, w * lines / Math.max(1, total) * 0.95);
                    const barH = lines === 1 ? 6 : Math.max(2, Math.min(6, h * 0.7 / lines - 2));
                    const pitchY = barH + (lines === 1 ? 0 : 2);
                    const blocks = [];
                    let x = 0;
                    let line = 0;
                    for (let i = 0; i < lens.length; i++) {
                        const bw = Math.max(1, lens[i] * unit - 1);
                        if (x > 0 && x + bw > w) {
                            x = 0;
                            line++;
                        }
                        blocks.push({ x: x, line: line, w: bw });
                        x += bw + 1 + unit;
                    }
                    const top = h / 2 - ((line + 1) * pitchY - (pitchY - barH)) / 2;
                    for (let i = 0; i < blocks.length; i++) blocks[i].y = top + blocks[i].line * pitchY;
                    return { blocks: blocks, barH: barH };
                }

                // Speech to text and LLM: the recording's timeline with scan
                // lines over it. Ahead of the STT line the recording is a
                // soft analog envelope; behind it, columns of square cells.
                // Behind the LLM line those cells fade to a ghost under
                // blocks the length of the transcript's words.
                function drawScan(ctx, w, h, t) {
                    const cellW = 5;
                    const colPitch = cellW + 2;
                    const n = Math.max(1, Math.floor((w + 2) / colPitch));
                    const cell = 6;
                    const pitch = cell + 2;
                    const cy = h / 2;
                    const rows = Math.max(1, Math.floor((h / 2 - 2) / pitch));
                    const half = h / 2 - 3;
                    const env = envelope(n);
                    const grow = Math.min(1, (t - root.stateSince) / 220);
                    const x1 = root.scanP1 * w;
                    const x2 = root.stage === 2 ? root.scanP2 * w : -1;

                    ctx.fillStyle = css(root.cDim);
                    ctx.fillRect(0, Math.round(cy), w, 1);

                    // Analog envelope, right of the STT line.
                    if (x1 < w) {
                        ctx.save();
                        ctx.beginPath();
                        ctx.rect(x1, 0, w - x1, h);
                        ctx.clip();
                        const px = function(i) { return i * colPitch + cellW / 2; };
                        const amp = function(i) { return Math.max(1, env[i] * half * grow); };
                        ctx.beginPath();
                        ctx.moveTo(0, cy);
                        for (let i = 0; i < n; i++) {
                            const j = Math.min(n - 1, i + 1);
                            ctx.quadraticCurveTo(px(i), cy - amp(i), (px(i) + px(j)) / 2, cy - (amp(i) + amp(j)) / 2);
                        }
                        ctx.lineTo(w, cy);
                        for (let i = n - 1; i >= 0; i--) {
                            const j = Math.max(0, i - 1);
                            ctx.quadraticCurveTo(px(i), cy + amp(i), (px(i) + px(j)) / 2, cy + (amp(i) + amp(j)) / 2);
                        }
                        ctx.closePath();
                        const grad = ctx.createLinearGradient(0, cy - half, 0, cy + half);
                        grad.addColorStop(0, css(root.cMid, 0.25));
                        grad.addColorStop(0.5, css(root.cAccent, 0.45));
                        grad.addColorStop(1, css(root.cMid, 0.25));
                        ctx.fillStyle = grad;
                        ctx.fill();
                        ctx.lineWidth = 1.2;
                        ctx.strokeStyle = css(root.cAccent, 0.7);
                        ctx.stroke();
                        ctx.restore();
                    }

                    // Digital cells, left of the STT line; ghosted behind the
                    // LLM line.
                    for (let i = 0; i < n; i++) {
                        const x = i * colPitch;
                        if (x + cellW > x1) break;
                        const count = Math.max(1, Math.round(env[i] * rows));
                        const behind2 = x + cellW <= x2;
                        const near = (x1 - x) / colPitch < 3 && root.stage === 1;
                        ctx.fillStyle = behind2 ? css(root.cAccent, 0.16)
                            : near ? css(root.cHot) : css(root.cAccent, 0.85);
                        for (let j = 0; j < count; j++) {
                            const off = j * pitch + pitch / 2;
                            ctx.fillRect(x, cy - off - cell, cellW, cell);
                            ctx.fillRect(x, cy + off, cellW, cell);
                        }
                    }

                    // Word blocks, left of the LLM line.
                    if (x2 > 0) {
                        const lens = root.pp.raw_lens || [];
                        const lay = wordLayout(lens, w, h);
                        for (let i = 0; i < lay.blocks.length; i++) {
                            const b = lay.blocks[i];
                            if (b.x >= x2) continue;
                            const bw = Math.min(b.w, x2 - b.x);
                            ctx.fillStyle = x2 - b.x < 24 ? css(root.cText) : css(root.cHot);
                            ctx.fillRect(b.x, b.y, bw, lay.barH);
                        }
                    }

                    // Scan lines: a lit lane with a bright edge.
                    const line = function(x, colour) {
                        ctx.fillStyle = css(root.cAccent, 0.12);
                        ctx.fillRect(x - 10, 0, 12, h);
                        ctx.fillStyle = css(colour);
                        ctx.fillRect(x - 1, 0, 2, h);
                    };
                    if (root.stage === 1 && x1 < w) line(x1, root.cHot);
                    if (x2 >= 0 && x2 < w) line(x2, root.cText);
                }

                // Output: the words being typed, as blocks. Each word is a
                // run of square cells as long as the typed word (or a random
                // length when voxtype-clean reported none), laid out in lines
                // behind a block cursor that scrolls the lines up when they
                // fill. It is paced to end with voxtype's real typing.
                function drawTyping(ctx, w, h, t) {
                    const cell = 8;
                    const pitch = cell + 3;
                    const lineGap = 8;
                    const linePitch = cell + lineGap;
                    const cols = Math.floor(w / pitch);
                    const visibleLines = Math.max(1, Math.floor((h + lineGap) / linePitch));
                    const lens = root.ppFresh && root.pp.lens && root.pp.lens.length > 0 ? root.pp.lens : null;
                    const words = lens ? lens.length : Math.max(1, root.ppFresh && root.pp.words ? root.pp.words : 12);
                    const rnd = function(a) {
                        const x = Math.sin(a * 91.7 + 13.3) * 43758.5453;
                        return x - Math.floor(x);
                    };

                    // Lay the words out into cell positions.
                    const layout = [];
                    let col = 0;
                    let line = 0;
                    for (let i = 0; i < words; i++) {
                        const len = lens ? Math.max(1, Math.min(cols, Math.round(lens[i] * 0.7)))
                                         : 2 + Math.floor(rnd(i) * 6);
                        if (col > 0 && col + len > cols) {
                            col = 0;
                            line++;
                        }
                        for (let c = 0; c < len; c++) layout.push({ col: col + c, line: line });
                        col += len + 1;
                    }

                    const shown = Math.min(layout.length, Math.floor(root.typingProgress() * layout.length));
                    const cur = shown < layout.length ? layout[shown]
                        : { col: Math.min(cols - 1, col), line: line };
                    const firstLine = Math.max(0, cur.line - visibleLines + 1);
                    const usedLines = Math.min(visibleLines, line + 1);
                    const top = Math.round((h - (usedLines * linePitch - lineGap)) / 2);

                    for (let k = 0; k < shown; k++) {
                        const p = layout[k];
                        if (p.line < firstLine) continue;
                        const age = shown - k;
                        ctx.fillStyle = age < 6 ? css(root.cHot) : css(root.cAccent, 0.55 + 0.45 * Math.max(0, 1 - age / 60));
                        ctx.fillRect(p.col * pitch, top + (p.line - firstLine) * linePitch, cell, cell);
                    }

                    // Block cursor: solid while typing, blinking once done.
                    const done = shown >= layout.length;
                    if (!done || Math.floor(t / 450) % 2 === 0) {
                        ctx.fillStyle = css(root.cHot);
                        ctx.fillRect(cur.col * pitch, top + (cur.line - firstLine) * linePitch - 2, cell, cell + 4);
                    }
                }

                onPaint: {
                    const ctx = getContext("2d");
                    ctx.reset();
                    const t = root.now;
                    if (root.stage === 0) drawSpectrum(ctx, width, height);
                    else if (root.stage <= 2) drawScan(ctx, width, height, t);
                    else drawTyping(ctx, width, height, t);
                }
            }

            // Progress, hidden while recording: the current scan's
            // position while transcribing and refining, full when done.
            Canvas {
                id: progress
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 3
                renderStrategy: Canvas.Cooperative

                onPaint: {
                    const ctx = getContext("2d");
                    ctx.reset();
                    const w = width;
                    const h = height;
                    const c = function(col, a) {
                        return "rgba(" + Math.round(col.r * 255) + "," + Math.round(col.g * 255) + ","
                            + Math.round(col.b * 255) + "," + a + ")";
                    };
                    // No bar while recording, so it doesn't read as a
                    // countdown, until the last ten seconds before voxtype's
                    // cap, when it drains to zero.
                    if (root.stage === 0) {
                        const left = root.stopWarning ? root.remaining / 10
                            : root.silenceWarning ? (root.silenceStopSecs - root.silentFor) / 5
                            : -1;
                        if (left >= 0) {
                            ctx.fillStyle = c(root.cDim, 1);
                            ctx.fillRect(0, 0, w, h);
                            ctx.fillStyle = c(root.cWarn, 1);
                            ctx.fillRect(0, 0, Math.max(0, Math.min(1, left)) * w, h);
                        }
                        return;
                    }
                    ctx.fillStyle = c(root.cDim, 1);
                    ctx.fillRect(0, 0, w, h);

                    let from = 0;
                    let to = 0;
                    if (root.stage === 1) {
                        to = root.scanP1 * w;
                    } else if (root.stage === 2) {
                        to = root.scanP2 * w;
                    } else {
                        to = w;
                    }
                    from = Math.max(0, from);
                    to = Math.min(w, to);
                    if (to > from) {
                        const g = ctx.createLinearGradient(from, 0, to, 0);
                        g.addColorStop(0, c(root.cAccent, 1));
                        g.addColorStop(1, c(root.cHot, 1));
                        ctx.fillStyle = g;
                        ctx.fillRect(from, 0, to - from, h);
                    }
                }
            }
        }

        MultiEffect {
            source: screen
            anchors.fill: screen
            autoPaddingEnabled: true
            shadowEnabled: true
            shadowColor: root.cAccent
            shadowBlur: 0.45
            shadowOpacity: 0.55
            shadowHorizontalOffset: 0
            shadowVerticalOffset: 0
            blurMax: 20
        }

        // Faint scanlines.
        Canvas {
            anchors.fill: parent
            anchors.margins: 1
            opacity: 0.12
            onPaint: {
                const ctx = getContext("2d");
                ctx.reset();
                ctx.fillStyle = "#000000";
                for (let y = 0; y < height; y += 3) ctx.fillRect(0, y, width, 1);
            }
        }

        // HUD corner brackets, brightening with the voice.
        Canvas {
            id: brackets
            anchors.fill: parent
            anchors.margins: -5
            onPaint: {
                const ctx = getContext("2d");
                ctx.reset();
                const L = 18;
                const w = width;
                const h = height;
                const c = root.anyWarning ? root.cWarn : root.cAccent;
                const a = root.anyWarning ? (Math.floor(root.now / 400) % 2 ? 1.0 : 0.35)
                    : root.stage === 0 ? 0.5 + 0.5 * Math.min(1, root.energy * 3) : 0.8;
                ctx.strokeStyle = "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + ","
                    + Math.round(c.b * 255) + "," + a + ")";
                ctx.lineWidth = 2;
                ctx.beginPath();
                ctx.moveTo(1, L); ctx.lineTo(1, 1); ctx.lineTo(L, 1);
                ctx.moveTo(w - L, 1); ctx.lineTo(w - 1, 1); ctx.lineTo(w - 1, L);
                ctx.moveTo(w - 1, h - L); ctx.lineTo(w - 1, h - 1); ctx.lineTo(w - L, h - 1);
                ctx.moveTo(L, h - 1); ctx.lineTo(1, h - 1); ctx.lineTo(1, h - L);
                ctx.stroke();
            }
        }
    }
}
