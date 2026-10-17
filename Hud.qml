// Voxscope: a dictation HUD for Voxtype, as an omarchy-shell panel plugin.
//
// The shell keeps this loaded for as long as the plugin is enabled
// (keepLoaded in manifest.json). It reads Voxtype's state file and audio
// bridge itself and shows its own overlay window, with the card (Card.qml)
// centred on the focused screen, while Voxtype is recording or
// transcribing, and for a moment after.
//
// Stage detection. Voxtype reports one "transcribing" state for both speech
// to text and the post-process command, so a post-process script can write
// $XDG_RUNTIME_DIR/voxtype/postprocess.json ({"stage": "start"|"llm"|"done",
// "t": ms, ...}); "start" marks the end of speech to text.
// docs/postprocess-protocol.md describes the format and
// examples/voxtype-clean writes it. A status written before the current
// transcription began is stale and ignored. Without a script the HUD still
// works; it just cannot tell the stages apart.
//
// Scan timing. Neither speech to text nor the LLM reports progress, so each
// scan runs for an estimated duration that learns from measured ones;
// timing.js holds the model. The displayed stage follows the scans, so it
// can lag the real one.
//
// Linger. When Voxtype goes idle after transcribing, the HUD stays up while
// any scan still running fast-forwards and the typing animation runs out,
// then hides; never longer than Timing.LINGER_MAX_MS after going idle.
// Recording again meanwhile starts over in the same window, which keeps the
// linger's last frame while the new dictation settles (see `holding`).
//
// Transitions. The card fades and scales in as the window appears, and
// fades out over its last frame when a dictation ends, the window staying
// mapped until it has (see `fading`). A dictation that turns out to be
// suppressed, or a stale state, hides it at once instead.
//
// Suppression. A dictation started with `voxtype record start --no-osd` is
// never shown, not even during the linger, although Voxtype removes its
// marker when it goes idle; see `suppressed`. Voxtype creates the marker
// just after writing the recording state, so every dictation waits a
// moment (`settling`) before it is drawn or the microphone is opened, and
// the marker as it is then decides.
//
// Stale state. If Voxtype stays recording or transcribing for longer than
// it could, it has died and left its state file behind; the HUD hides and
// stops its timer, the audio bridge and cava until the state changes.
//
// Persistent data. Learned timing and the spectrum calibration live in
// $XDG_STATE_HOME/voxscope (~/.local/state/voxscope), never in the plugin's
// own directory, which is a git checkout.
//
// Colour comes from the active Omarchy theme (colors.toml), re-read each
// time a dictation starts, so a theme switch shows on the next one. The
// accent carries the whole visualisation; the theme's red marks warnings,
// dark_background fills the card and selection lights the scan lanes, and
// a theme with mode = "light" gets its own mix ratios and no scanlines.
//
// Spectrum. Voxtype's audio bridge only carries peak and RMS, so the
// spectrum comes from cava reading the default PipeWire source while
// recording, at fixed gain and normalised here. If cava is missing or
// silent, the bars are synthesised from the bridge's RMS instead.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "timing.js" as Timing
import "postprocess.js" as Postprocess

Item {
    id: root

    // Injected by omarchy-shell. The shell carries the user's shell.json,
    // where the settings below live; the manifest names this plugin.
    property var shell: null
    property var manifest: null

    // Settings, read from this plugin's entry in ~/.config/omarchy/shell.json,
    // which omarchy-shell leaves alone apart from its `id`:
    //   { "id": "io.github.iryzhkov.voxscope", "compact": true,
    //     "position": "bottom", "reducedMotion": true }
    // Each is whitelisted: anything other than the values below is the
    // default.
    readonly property string pluginId: manifest && typeof manifest.id === "string"
        && /^[A-Za-z0-9_.-]{1,128}$/.test(manifest.id) ? manifest.id : "io.github.iryzhkov.voxscope"
    readonly property var settings: {
        const config = shell ? shell.shellConfig : null;
        const list = config && Array.isArray(config.plugins) ? config.plugins : [];
        for (let i = 0; i < list.length && i < 1024; i++) {
            const entry = list[i];
            if (entry && typeof entry === "object" && !Array.isArray(entry) && entry.id === pluginId)
                return entry;
        }
        return ({});
    }
    // The visualisation strip and the stepper, without title and subtitle.
    readonly property bool compact: settings.compact === true
    // "center" of the focused screen, or "bottom", centred above its
    // bottom edge.
    readonly property string position: settings.position === "bottom" ? "bottom" : "center"
    // No bloom pulse, scanlines, blinking or scaling; plain fades only.
    readonly property bool reducedMotion: settings.reducedMotion === true

    // External commands. A test harness substitutes harmless fakes.
    // setpriv ties the bridge's life to the shell's, as for cava below.
    property var bridgeCommand: ["/usr/bin/setpriv", "--pdeathsig", "TERM", "/usr/bin/voxtype-audio-bridge"]
    property var stopCommand: ["/usr/bin/voxtype", "record", "stop"]
    property var sourceCommand: ["/usr/bin/pactl", "get-default-source"]
    property string cavaExecutable: "/usr/bin/cava"

    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
    readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || home + "/.local/state"
    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || home + "/.config"
    readonly property string voxtypeDir: runtimeDir !== "" ? runtimeDir + "/voxtype" : ""
    // Learned timing and calibration.
    readonly property string dataDir: stateHome + "/voxscope"
    // The generated cava config, rewritten for every recording.
    readonly property string scratchDir: runtimeDir !== "" ? runtimeDir + "/voxscope" : dataDir
    readonly property string cavaConfigPath: scratchDir + "/cava.conf"
    property bool dataDirReady: false

    // Theme colours; neutral defaults until colors.toml loads.
    property color themeBackground: "#0b0d12"
    property color themeCard: "#0b0d12"
    property color themeAccent: "#7aa2f7"
    property color themeForeground: "#d8ddec"
    property color themeMuted: "#5c5e64"
    property color themeSelection: "#1d2433"
    property color themeWarn: "#f7768e"
    property bool themeLight: false

    function mix(a, b, t) {
        return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t,
                       a.b + (b.b - a.b) * t, 1);
    }
    function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }

    readonly property int bands: 32

    VoxtypeState {
        id: voxtype
        directory: root.voxtypeDir
    }

    readonly property string daemonState: voxtype.state
    readonly property bool recording: daemonState === "recording" || daemonState === "streaming"
    readonly property bool working: daemonState === "transcribing"
    readonly property bool markerPresent: voxtype.osdSuppressed
    // Set when Voxtype went idle after transcribing and the HUD is still
    // finishing its animation; idleAt is when that happened.
    property bool lingering: false
    property var idleAt: null
    property var typingDoneAt: null
    // Whether the typing-rate sample for the linger is still to be taken;
    // see updateLinger.
    property bool typingSamplePending: false
    // Voxtype is recording or transcribing, or the HUD is lingering after
    // it. Assigned once per state change, after `lingering`, so `shown`
    // never goes false for a moment while a handler is half way through.
    property bool inDictation: false
    // Whether this dictation asked for no OSD. Voxtype removes the marker
    // when it goes idle, and the marker and the state file can change in
    // either order, so this is decided from the marker when the dictation
    // has settled, set again whenever the marker is seen after that, and
    // only reset when the next dictation settles.
    property bool suppressed: false
    // True for settleMs after a dictation starts, so a marker created just
    // after the state is seen, and one left over from the previous
    // dictation is seen gone, before anything is drawn or the audio bridge
    // and cava start.
    property bool settling: false
    readonly property int settleMs: 80
    // Set while settling if the window was up for the previous dictation
    // (recording again during its linger): the window stays mapped and
    // keeps that dictation's last frame (see heldFrame), so an ordinary
    // re-record neither unmaps it nor draws REC before the marker could
    // have appeared. A marker that appears meanwhile clears it at once.
    property bool holding: false
    // Set while the card fades out after the dictation ended; the window
    // stays mapped, showing the last frame, until the fade has finished.
    property bool fading: false
    readonly property int appearMs: 120
    readonly property int fadeMs: 180
    // Set when Voxtype has stayed recording or transcribing for longer than
    // it could; cleared by the next state change.
    property bool stalled: false
    readonly property real transcribeLimitSecs: 120
    readonly property bool shown: inDictation && !suppressed && !settling && !stalled
    // What the shell reads to tell whether a panel is open.
    readonly property bool opened: shown
    // Recording with the HUD up; the audio bridge and cava run only then.
    readonly property bool live: shown && recording

    property real stateSince: Date.now()
    // When the current transcription began; post-process statuses written
    // before it are stale. Unlike stateSince it does not move when Voxtype
    // goes idle, so the linger still sees this dictation's status.
    property real workSince: Date.now()
    property real now: Date.now()

    // Latest post-process status, as parsed by postprocess.js.
    property var pp: ({})
    readonly property bool ppFresh: Timing.isFresh(pp, workSince)
    readonly property var rawLens: pp.raw_lens || []
    readonly property var outLens: pp.lens || []
    // Displayed stage, 0 REC, 1 STT, 2 LLM, 3 OUT. While transcribing and
    // lingering it follows the scans (updateScans), not the real stage.
    property int scanStage: 1
    property real scanStageSince: Date.now()
    property real scanP1: 0
    property real scanP2: 0
    readonly property int stage: recording ? 0 : (working || lingering) ? scanStage : 3
    readonly property real stageSince: recording ? stateSince : scanStageSince
    readonly property real elapsed: Math.max(0, (now - stateSince) / 1000)
    readonly property real stageElapsed: Math.max(0, (now - stageSince) / 1000)

    // Learned rates; see timing.js.
    property real sttRate: Timing.DEFAULT_RATES.stt
    property real llmRate: Timing.DEFAULT_RATES.llm
    property real typeRate: Timing.DEFAULT_RATES.type
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

    // Voxtype's recording cap, read from its config; the last ten seconds
    // before the cap show a countdown.
    property real maxRecordSecs: 300
    readonly property real remaining: maxRecordSecs - elapsed
    readonly property bool stopWarning: stage === 0 && remaining <= 10

    // Silence auto-stop, for recordings started by a toggle wrapper that
    // stamps $XDG_RUNTIME_DIR/voxtype/toggle-start (push-to-talk is ended by
    // releasing the key). After silenceStopSecs without voice the HUD stops
    // the recording itself, counting down for the last five. Voice is the
    // bridge's vad flag; silence is counted only while bridge frames are
    // arriving, so a missing or restarting bridge never stops a recording.
    readonly property real silenceStopSecs: 10
    property real toggleStamp: 0
    readonly property bool toggleMode: toggleStamp > 0 && Math.abs(toggleStamp - stateSince) < 3000
    property real lastVoiceMs: Date.now()
    property bool autoStopSent: false
    readonly property real silentFor: Math.max(0, (now - lastVoiceMs) / 1000)
    readonly property bool silenceWarning: stage === 0 && toggleMode && !stopWarning
        && silentFor >= silenceStopSecs - 5
    readonly property bool anyWarning: stopWarning || silenceWarning
    property real lastTickMs: Date.now()

    // The screen the window is on, chosen when the HUD appears.
    property var targetScreen: null
    property bool windowShown: false

    function focusedScreen() {
        const monitor = Hyprland.focusedMonitor;
        const name = monitor ? monitor.name : "";
        const screens = Quickshell.screens;
        for (let i = 0; i < screens.length; i++) {
            if (screens[i].name === name) return screens[i];
        }
        return screens.length > 0 ? screens[0] : null;
    }

    // The window follows `shown`, `holding` or `fading`, but only after its
    // screen is set, so it never maps on the wrong output first.
    function updateWindow() {
        const want = shown || holding || fading;
        if (want === windowShown) return;
        if (want) targetScreen = focusedScreen();
        windowShown = want;
    }

    onShownChanged: {
        if (!shown) {
            endLinger();
            // An ordinary end fades out; a suppressed or stale dictation,
            // or one held for the next, does not.
            fading = windowShown && !holding && !suppressed && !stalled;
        } else {
            fading = false;
        }
        updateWindow();
    }

    onFadingChanged: {
        if (fading) {
            appear.stop();
            disappear.restart();
        } else if (disappear.running) {
            // Shown again before the fade finished: back to full.
            disappear.stop();
            appear.restart();
        }
    }

    function fadeDone() {
        if (!fading) return;
        fading = false;
        updateWindow();
    }

    onWindowShownChanged: {
        if (!windowShown) return;
        disappear.stop();
        heldFrame.opacity = 0;
        heldFrame.scale = reducedMotion ? 1 : 0.96;
        appear.restart();
    }

    onHoldingChanged: updateWindow()

    onLiveChanged: {
        if (live) startCava();
        else cavaReady = false;
    }

    onMarkerPresentChanged: {
        // While settling the marker is only looked at when that ends.
        if (settling) {
            if (markerPresent) holding = false;
        } else if (markerPresent && inDictation) {
            suppressed = true;
        }
    }

    Timer {
        id: settleTimer
        interval: root.settleMs
        onTriggered: root.settle()
    }

    // Ends the settling: the marker as it is now decides whether this
    // dictation is suppressed. Assigned in this order so a held window that
    // goes on to show the new dictation never unmaps in between.
    function settle() {
        suppressed = markerPresent;
        settling = false;
        holding = false;
    }

    function endLinger() {
        lingering = false;
        idleAt = null;
        typingDoneAt = null;
        typingSamplePending = false;
    }

    onDaemonStateChanged: {
        // Derived from daemonState here, because the `recording` and
        // `working` bindings may not have been re-evaluated yet when this
        // handler runs.
        const t = Date.now();
        const isRecording = daemonState === "recording" || daemonState === "streaming";
        const isWorking = daemonState === "transcribing";
        const wasRecording = prevState === "recording" || prevState === "streaming";
        const wasShown = inDictation && !suppressed && !settling && !stalled;
        // A new dictation: recording begins (not a switch between recording
        // and streaming), or transcribing is seen straight after idle.
        const starts = (isRecording && !wasRecording) || (isWorking && prevState === "idle");
        if (wasRecording && !isRecording) recSecs = (t - stateSince) / 1000;

        // What `shown` is made of is assigned so that it can only go true
        // once everything is in place: settling first, stalled last. The
        // window is held before `shown` goes false, so it stays mapped.
        if (starts) {
            holding = holding || wasShown;
            settling = true;
            settleTimer.restart();
        }
        if (prevState === "transcribing" && !isWorking && !isRecording && wasShown && !suppressed) {
            idleAt = t;
            typingDoneAt = null;
            typingSamplePending = true;
            lingering = true;
            // The final status may have landed since the last poll.
            ppFile.reload();
        } else {
            endLinger();
        }
        inDictation = isRecording || isWorking || lingering;
        stalled = false;

        if (!(wasRecording && isRecording)) stateSince = t;
        prevState = daemonState;
        if (starts) {
            themeFile.reload();
            voxtypeConfig.reload();
        }
        if (isRecording && !wasRecording) {
            workSince = t;
            lastVoiceMs = t;
            autoStopSent = false;
            toggleFile.reload();
            target = [];
            lastCavaMs = 0;
            tape = [];
            tapeSum = 0;
            tapeCount = 0;
            tapeLastMs = t;
            level = [];
            peak = [];
            peakAge = [];
            energy = 0;
            voiceUntil = 0;
            clipUntil = 0;
            lastBridgeMs = 0;
        }
        if (isWorking) {
            workSince = t;
            scanStage = 1;
            scanStageSince = t;
            scanP1 = 0;
            scanP2 = 0;
        }
    }

    function updateScans(t) {
        if (!working && !lingering) return;
        const fresh = ppFresh;
        const s = Timing.scanState(t, workSince, recSecs, { stt: sttRate, llm: llmRate },
                                   fresh ? pp : null, lingering ? idleAt : null);
        scanP1 = s.p1;
        scanP2 = s.p2;
        scanStage = s.stage;
        scanStageSince = s.since;
        if (fresh && pp.stage === "done" && pp.t !== learnedFor) learnTiming();
    }

    // Fold this dictation's measured stage durations into the estimates.
    function learnTiming() {
        learnedFor = pp.t;
        const next = Timing.learnRates({ stt: sttRate, llm: llmRate, type: typeRate }, pp, workSince, recSecs);
        sttRate = next.stt;
        llmRate = next.llm;
        saveTiming();
    }

    function learnTyping(secs) {
        const next = Timing.learnTyping({ stt: sttRate, llm: llmRate, type: typeRate }, pp, secs);
        if (next.type === typeRate) return;
        typeRate = next.type;
        saveTiming();
    }

    function saveTiming() {
        if (!dataDirReady) return;
        timingFile.setText(JSON.stringify({ version: 1, stt: sttRate, llm: llmRate, type: typeRate }));
    }

    function typingProgress() {
        return Timing.typingProgress(now, ppFresh ? pp : null, scanStageSince, typeRate,
                                     lingering ? idleAt : null);
    }

    function updateLinger(t) {
        if (!lingering) return;
        // Voxtype types the output after the script's final status and goes
        // idle when done, so that gap is the typing time. It is taken here
        // rather than at idle, so a status that landed just before idle and
        // was not polled yet still counts.
        if (typingSamplePending && ppFresh && pp.stage === "done") {
            typingSamplePending = false;
            learnTyping((idleAt - pp.t) / 1000);
        }
        if (stage === 3 && typingDoneAt === null && typingProgress() >= 1) typingDoneAt = t;
        if (Timing.lingerOver(t, idleAt, typingDoneAt)) {
            endLinger();
            inDictation = false;
        }
    }

    // Whether Voxtype has been in its current state for longer than it
    // could be: recording past its cap with a grace period, or transcribing
    // for longer than the transcription limit or twice the recording.
    function isStale() {
        if (recording) return elapsed > maxRecordSecs + 30;
        if (working) return elapsed > Math.max(transcribeLimitSecs, recSecs * 2);
        return false;
    }

    // Save the calibration every couple of seconds while recording, rather
    // than relying on catching the end of one.
    Timer {
        interval: 2000
        repeat: true
        running: root.live && root.calibrationLoaded && root.dataDirReady
        onTriggered: {
            if (root.bandRef.length === root.bands) {
                calibrationFile.setText(JSON.stringify({ version: 1, ref: root.bandRef, noise: root.bandNoise }));
            }
        }
    }

    VoxtypeAudio {
        id: audio
        active: root.live
        command: root.bridgeCommand
        onFrameReceived: function(peak, rms, vad, tsMs) {
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

    function targetFor(i, t) {
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
        const rms = audio.rms;
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

        if (isStale()) {
            stalled = true;
            return;
        }

        if (recording && now - lastCavaMs < 400 && target.length > 0) calibrate(dt);
        // Silence counts only while the bridge is delivering frames: without
        // them there is no telling silence from speech.
        if (recording && t - lastBridgeMs >= 1000) lastVoiceMs = t;
        if (stage === 0 && toggleMode && !autoStopSent && silentFor >= silenceStopSecs) {
            autoStopSent = true;
            stopper.running = true;
        }

        const lv = level.length === bands ? level.slice() : new Array(bands).fill(0);
        const pk = peak.length === bands ? peak.slice() : new Array(bands).fill(0);
        const pa = peakAge.length === bands ? peakAge.slice() : new Array(bands).fill(0);
        let sum = 0;
        for (let i = 0; i < bands; i++) {
            const tg = recording ? targetFor(i, t) : 0;
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
        updateLinger(t);
        peakAge = pa;
        // Energy follows the voice while recording and drives the corner
        // brackets; afterwards it decays slowly.
        const e = sum / bands;
        energy = recording ? Math.max(e, energy - 1.2 * dt) : Math.max(0.15, energy - 0.12 * dt);

        // Once the linger has ended, keep its last frame rather than paint
        // one the window will not show.
        if (shown) card.repaint();
    }

    Timer {
        interval: 16
        repeat: true
        running: root.shown
        onTriggered: root.tick()
    }

    // Creates the data and scratch directories once at startup; nothing is
    // written until it has succeeded.
    Process {
        id: makeDirs
        command: ["/usr/bin/mkdir", "-p", "--", root.dataDir, root.scratchDir]
        onExited: function(exitCode) { root.dataDirReady = exitCode === 0; }
    }

    Component.onCompleted: {
        if (home !== "") makeDirs.running = true;
    }

    FileView {
        id: toggleFile
        path: root.voxtypeDir !== "" ? root.voxtypeDir + "/toggle-start" : ""
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            const raw = text();
            const n = raw.length <= 32 ? Number(raw.trim()) : 0;
            root.toggleStamp = isFinite(n) && n > 0 ? n : 0;
        }
    }

    Process {
        id: stopper
        command: root.stopCommand
    }

    FileView {
        id: calibrationFile
        path: root.dataDir + "/calibration.json"
        printErrors: false
        onLoaded: {
            try {
                const raw = text();
                const c = raw.length <= 16384 ? JSON.parse(raw) : null;
                const ok = function(a) {
                    return Array.isArray(a) && a.length === root.bands
                        && a.every(function(v) { return typeof v === "number" && v >= 0 && v <= 1; });
                };
                if (c && ok(c.ref) && ok(c.noise)) {
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
        path: root.dataDir + "/timing.json"
        printErrors: false
        onLoaded: {
            try {
                const raw = text();
                const c = raw.length <= 4096 ? JSON.parse(raw) : null;
                // Rates outside these bounds are not plausible measurements.
                const ok = function(v) { return typeof v === "number" && v > 0 && v < 10; };
                if (c && ok(c.stt)) root.sttRate = c.stt;
                if (c && ok(c.llm)) root.llmRate = c.llm;
                if (c && ok(c.type)) root.typeRate = c.type;
            } catch (e) {}
        }
    }

    FileView {
        id: voxtypeConfig
        path: root.configHome + "/voxtype/config.toml"
        printErrors: false
        onLoaded: {
            const raw = text();
            const m = raw.length <= 262144 ? /^max_duration_secs\s*=\s*(\d+)/m.exec(raw) : null;
            if (m) root.maxRecordSecs = root.clamp(Number(m[1]), 1, 86400);
        }
    }

    FileView {
        id: themeFile
        path: root.stateHome + "/omarchy/current/theme/colors.toml"
        printErrors: false
        onLoaded: {
            const t = text();
            if (t.length > 65536) return;
            function pick(key) {
                const m = new RegExp("^" + key + "\\s*=\\s*\"(#[0-9a-fA-F]{6})\"", "m").exec(t);
                return m ? m[1] : null;
            }
            const bg = pick("background");
            const accent = pick("accent");
            const fg = pick("bright_foreground") || pick("foreground");
            if (bg && accent && fg) {
                const mode = /^mode\s*=\s*"(light|dark)"/m.exec(t);
                // Without a mode, a background brighter than the text
                // makes a light theme.
                root.themeLight = mode ? mode[1] === "light"
                    : Qt.color(bg).hslLightness > Qt.color(fg).hslLightness;
                root.themeBackground = bg;
                root.themeCard = pick("dark_background") || bg;
                root.themeAccent = accent;
                root.themeForeground = fg;
                root.themeMuted = pick("muted") || root.mix(Qt.color(bg), Qt.color(fg), 0.45);
                root.themeSelection = pick("selection") || root.mix(Qt.color(bg), Qt.color(accent), 0.2);
                root.themeWarn = pick("red") || root.mix(Qt.color(accent), Qt.color("#ff3b30"), 0.7);
            }
        }
    }

    // Post-process status, polled while transcribing and lingering: the
    // script replaces the file by rename, which a file watch would lose
    // track of.
    FileView {
        id: ppFile
        path: root.voxtypeDir !== "" ? root.voxtypeDir + "/postprocess.json" : ""
        printErrors: false
        onLoaded: {
            const next = Postprocess.parse(text());
            if (next !== null) root.pp = next;
        }
    }

    Timer {
        interval: 100
        repeat: true
        running: root.shown && (root.working || root.lingering)
        triggeredOnStart: true
        onTriggered: ppFile.reload()
    }

    // cava needs the microphone named in its config, so each time the HUD
    // shows a recording (`live`) it asks PipeWire for the default source,
    // writes a config from the cava.conf template beside this file, and only
    // then starts cava. Any step that fails leaves the spectrum on the RMS
    // fallback. A suppressed recording never starts it, and one suppressed
    // late stops it.
    property bool cavaReady: false
    property int cavaRequest: 0
    readonly property int maxSpectrumBars: 64
    readonly property int maxSpectrumLineChars: 1024

    function startCava() {
        cavaReady = false;
        cavaRequest++;
        if (!dataDirReady || cavaTemplate.text().indexOf("@SOURCE@") < 0) return;
        sourceQuery.request = cavaRequest;
        sourceQuery.running = true;
    }

    FileView {
        id: cavaTemplate
        path: String(Qt.resolvedUrl("cava.conf")).replace(/^file:\/\//, "")
        printErrors: false
    }

    Process {
        id: sourceQuery
        property int request: 0
        command: root.sourceCommand
        stdout: StdioCollector {
            onStreamFinished: {
                const source = text.trim();
                if (sourceQuery.request !== root.cavaRequest || !root.live) return;
                // A PipeWire node name; anything else is not written into
                // the config.
                if (!/^[A-Za-z0-9_.:@+-]{1,256}$/.test(source)) return;
                cavaConfig.request = sourceQuery.request;
                cavaConfig.setText(cavaTemplate.text().split("@SOURCE@").join(source));
            }
        }
    }

    FileView {
        id: cavaConfig
        property int request: 0
        path: root.cavaConfigPath
        printErrors: false
        // Only ever written; there is nothing in it worth loading.
        preload: false
        onSaved: {
            if (request === root.cavaRequest && root.live) root.cavaReady = true;
        }
    }

    Process {
        id: cava
        running: root.live && root.cavaReady
        // setpriv ties cava's life to the shell's, so a crashed shell does
        // not leave it holding the microphone.
        command: ["/usr/bin/setpriv", "--pdeathsig", "TERM", root.cavaExecutable, "-p", root.cavaConfigPath]
        stdout: SplitParser {
            onRead: function(line) {
                if (line.length > root.maxSpectrumLineChars) return;
                const parts = line.split(";");
                if (parts.length > root.maxSpectrumBars + 1) return;
                const values = [];
                for (let i = 0; i < parts.length; i++) {
                    if (parts[i].length === 0) continue;
                    const v = Number(parts[i]) / 1000;
                    values.push(isFinite(v) ? root.clamp(v, 0, 1) : 0);
                }
                if (values.length > 0) {
                    root.target = values;
                    root.lastCavaMs = Date.now();
                }
            }
        }
    }

    // The overlay: no keyboard focus, click-through (an empty input mask),
    // ignoring exclusive zones. With no anchors the layer surface is centred
    // on the output, which is where the prototype drew the card; anchored
    // to the bottom alone it is centred above the bottom edge.
    PanelWindow {
        id: window
        visible: root.windowShown
        screen: root.targetScreen
        anchors.bottom: root.position === "bottom"
        margins.bottom: root.position === "bottom" ? 24 : 0
        implicitWidth: Math.ceil(card.implicitWidth) + 80
        implicitHeight: Math.ceil(card.implicitHeight) + 80
        color: "transparent"
        WlrLayershell.namespace: "voxscope"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        mask: Region {}

        // Centred on whole device pixels, so the card's own snapping holds.
        Card {
            id: card
            hud: root
            x: card.snap((parent.width - width) / 2)
            y: card.snap((parent.height - height) / 2)
            width: implicitWidth
            height: implicitHeight
        }

        // The card is drawn through this texture, which stops updating while
        // the window is held or fading, so the window keeps the previous
        // dictation's last frame although the card's bindings already
        // follow the new one.
        ShaderEffectSource {
            id: heldFrame
            anchors.fill: card
            sourceItem: card
            hideSource: true
            live: !root.holding && !root.fading
            opacity: 0
        }
    }

    ParallelAnimation {
        id: appear
        NumberAnimation {
            target: heldFrame
            property: "opacity"
            to: 1
            duration: root.appearMs
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: heldFrame
            property: "scale"
            to: 1
            duration: root.appearMs
            easing.type: Easing.OutCubic
        }
    }

    NumberAnimation {
        id: disappear
        target: heldFrame
        property: "opacity"
        to: 0
        duration: root.fadeMs
        easing.type: Easing.InQuad
        onFinished: root.fadeDone()
    }

    // The card, and what the window shows of it, for a test harness to
    // capture frames from.
    readonly property Item cardItem: card
    readonly property Item windowItem: heldFrame
}
