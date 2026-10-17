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
// mapped until it has (see `fading`). A dictation that starts during the
// fade takes the window over as it would during the linger, the fade
// cancelled. A dictation that turns out to be suppressed, or a stale
// state, hides it at once instead, as does a marker arriving mid-fade.
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
// recording, at fixed gain and normalised here per band to how loud speech
// has recently been (spectrum.js). If cava is missing or silent, the bars
// are synthesised from the bridge's RMS instead.
//
// Outside input. Every program runs from a fixed absolute path with a
// cleared environment and a deadline (Helper.js), every file is read
// through a bounded helper with a byte cap (Bounded.qml), and everything
// read is clamped or whitelisted before use (Sanitize.js, postprocess.js,
// spectrum.js). No shell command is ever built from data.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "timing.js" as Timing
import "postprocess.js" as Postprocess
import "spectrum.js" as Spectrum
import "Helper.js" as Helper
import "Sanitize.js" as Sanitize

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
    // Each is whitelisted (Sanitize.settings): anything other than the
    // values below is the default.
    readonly property string pluginId: Sanitize.pluginId(manifest, "io.github.iryzhkov.voxscope")
    readonly property var settings: Sanitize.settings(shell ? shell.shellConfig : null, pluginId)
    // The visualisation strip and the stepper, without title and subtitle.
    readonly property bool compact: settings.compact
    // "center" of the focused screen, or "bottom", centred above its
    // bottom edge.
    readonly property string position: settings.position
    // No bloom pulse, scanlines, blinking or scaling; plain fades only.
    readonly property bool reducedMotion: settings.reducedMotion

    // External programs, each an absolute path and its arguments, run
    // through Helper.js. A test harness substitutes harmless fakes.
    property string bridgeExecutable: "/usr/bin/voxtype-audio-bridge"
    property var bridgeArgs: []
    property var stopCommand: ["/usr/bin/voxtype", "record", "stop"]
    property var sourceCommand: ["/usr/bin/pactl", "get-default-source"]
    property string cavaExecutable: "/usr/bin/cava"
    // Arguments before cava's own "-p <config>".
    property var cavaArgs: []

    // Directories from the environment, each an absolute path without "."
    // or ".." components, or unset (Sanitize.directory); every path below
    // is one of them plus a fixed name.
    readonly property string home: Sanitize.directory(Quickshell.env("HOME"), "")
    readonly property string runtimeDir: Sanitize.directory(Quickshell.env("XDG_RUNTIME_DIR"), "")
    readonly property string stateHome: Sanitize.directory(Quickshell.env("XDG_STATE_HOME"),
                                                           home !== "" ? home + "/.local/state" : "")
    readonly property string configHome: Sanitize.directory(Quickshell.env("XDG_CONFIG_HOME"),
                                                            home !== "" ? home + "/.config" : "")
    readonly property string voxtypeDir: runtimeDir !== "" ? runtimeDir + "/voxtype" : ""
    // Learned timing and calibration.
    readonly property string dataDir: stateHome !== "" ? stateHome + "/voxscope" : ""
    // The generated cava config, rewritten for every recording.
    readonly property string scratchDir: runtimeDir !== "" ? runtimeDir + "/voxscope" : dataDir
    readonly property string cavaConfigPath: scratchDir !== "" ? scratchDir + "/cava.conf" : ""
    property bool dataDirReady: false

    // The only variables the programs above see, besides PATH=/usr/bin and
    // LC_ALL=C: where home, the runtime directory and the configuration
    // are, and where PipeWire and Pulse listen if the session moved them.
    // Helper.envPrefix drops any that is unset or malformed.
    readonly property var childEnvironment: ({
        HOME: home,
        XDG_RUNTIME_DIR: runtimeDir,
        XDG_CONFIG_HOME: Quickshell.env("XDG_CONFIG_HOME") || "",
        PIPEWIRE_RUNTIME_DIR: Quickshell.env("PIPEWIRE_RUNTIME_DIR") || "",
        PULSE_SERVER: Quickshell.env("PULSE_SERVER") || ""
    })
    // The audio bridge and cava run only while recording, which cannot
    // last longer than Voxtype's cap; this deadline ends them a minute
    // after it even if nothing else does.
    readonly property int liveDeadlineSecs: Math.round(clamp(maxRecordSecs + 60, 60, 86460))

    // Byte caps on the files read; none of them is anywhere near its cap.
    readonly property int maxToggleBytes: 32
    readonly property int maxPostprocessBytes: Postprocess.MAX_CHARS
    readonly property int maxTimingBytes: 4096
    readonly property int maxCalibrationBytes: 16384
    readonly property int maxVoxtypeConfigBytes: 262144
    readonly property int maxThemeBytes: 65536
    readonly property int maxTemplateBytes: 4096
    readonly property int maxSourceBytes: 512

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
    // (recording again during its linger or its fade-out): the window stays
    // mapped and keeps that dictation's last frame (see heldFrame), so an
    // ordinary re-record neither unmaps it nor draws REC before the marker
    // could have appeared. A marker that appears meanwhile clears it at
    // once.
    property bool holding: false
    // Set while the card fades out after the dictation ended; the window
    // stays mapped, showing the last frame, until the fade has finished.
    // A new dictation or a marker cancels it.
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
    // Per-band calibration (spectrum.js): ref tracks how loud each band
    // gets in speech, noise the room's floor. Both persist in
    // calibration.json between dictations, so the meter starts from this
    // mic and room, with the reference capped at the start of each
    // recording so a loud session cannot flatten a quiet one.
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
        if (!markerPresent) return;
        // The marker belongs to a dictation that must not be shown, so the
        // window goes at once: no held frame and no fade. While settling
        // the marker is otherwise only looked at when that ends.
        if (settling) holding = false;
        else if (inDictation) suppressed = true;
        fading = false;
        updateWindow();
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
        // window is held before `shown` goes false, so it stays mapped. A
        // window still fading out is held too, and the fade cancelled, so
        // the held frame is fully visible again.
        if (starts) {
            holding = holding || wasShown || fading;
            fading = false;
            settling = true;
            settleTimer.restart();
        }
        if (prevState === "transcribing" && !isWorking && !isRecording && wasShown && !suppressed) {
            idleAt = t;
            typingDoneAt = null;
            typingSamplePending = true;
            lingering = true;
            // The final status may have landed since the last poll.
            ppRead.start();
        } else {
            endLinger();
        }
        inDictation = isRecording || isWorking || lingering;
        stalled = false;

        if (!(wasRecording && isRecording)) stateSince = t;
        prevState = daemonState;
        if (starts) {
            themeRead.start();
            configRead.start();
        }
        if (isRecording && !wasRecording) {
            workSince = t;
            lastVoiceMs = t;
            autoStopSent = false;
            toggleRead.start();
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
            const seeded = Spectrum.seed({ ref: bandRef, noise: bandNoise }, bands);
            bandRef = seeded.ref;
            bandNoise = seeded.noise;
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
        executable: root.bridgeExecutable
        args: root.bridgeArgs
        environment: root.childEnvironment
        deadlineSecs: root.liveDeadlineSecs
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
            const v = target[Math.floor(i * target.length / bands)] || 0;
            return Spectrum.level(v, bandRef[i], bandNoise[i], Spectrum.loudest(bandRef));
        }
        // Fallback: a speech-shaped envelope driven by the bridge RMS.
        const rms = audio.rms;
        const shape = Math.exp(-Math.pow((i - 8) / 10, 2));
        const jitter = 0.65 + 0.35 * Math.sin(t * 0.017 + i * 1.7) * Math.sin(t * 0.011 + i * 0.6);
        return clamp(rms * 7.0 * shape * jitter, 0, 1);
    }

    function calibrate(dt) {
        const start = bandRef.length === bands && bandNoise.length === bands
            ? { ref: bandRef, noise: bandNoise } : Spectrum.seed(null, bands);
        const values = new Array(bands);
        for (let i = 0; i < bands; i++) values[i] = target[Math.floor(i * target.length / bands)] || 0;
        const next = Spectrum.calibrate(start.ref, start.noise, values, dt);
        bandRef = next.ref;
        bandNoise = next.noise;
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
            stopper.start();
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

    // Creates the data and scratch directories once at startup, private to
    // this user; nothing is written until it has succeeded.
    Bounded {
        id: makeDirs
        build: function() {
            return Helper.run(["/usr/bin/mkdir", "-p", "-m", "700", "--", root.dataDir, root.scratchDir],
                              { seconds: 5, maxBytes: 4096 });
        }
        onSucceeded: root.dataDirReady = true
        onFailed: root.dataDirReady = false
    }

    Component.onCompleted: {
        if (dataDir !== "") {
            makeDirs.start();
            calibrationRead.start();
            timingRead.start();
        } else {
            calibrationLoaded = true;
        }
        templateRead.start();
        themeRead.start();
        configRead.start();
    }

    // The toggle stamp, watched and read again whenever it changes. A
    // missing stamp leaves the last one, which is too old to count.
    readonly property string togglePath: voxtypeDir !== "" ? voxtypeDir + "/toggle-start" : ""

    FileView {
        path: root.togglePath
        preload: false
        printErrors: false
        watchChanges: true
        onFileChanged: toggleRead.start()
    }

    Bounded {
        id: toggleRead
        build: function() {
            return root.togglePath !== "" ? Helper.read(root.togglePath, { maxBytes: root.maxToggleBytes }) : null;
        }
        onSucceeded: function(text) { root.toggleStamp = Sanitize.toggleStamp(text); }
        onFailed: function(exitCode) {
            if (exitCode === Helper.OVERFLOW_EXIT) root.toggleStamp = 0;
        }
    }

    Bounded {
        id: stopper
        build: function() {
            return Helper.run(root.stopCommand, { seconds: 10, maxBytes: 4096, env: root.childEnvironment });
        }
    }

    // Learned calibration and timing: read once at startup, written back as
    // they change. The writers never load anything.
    readonly property string calibrationPath: dataDir !== "" ? dataDir + "/calibration.json" : ""
    readonly property string timingPath: dataDir !== "" ? dataDir + "/timing.json" : ""

    FileView {
        id: calibrationFile
        path: root.calibrationPath
        preload: false
        printErrors: false
    }

    Bounded {
        id: calibrationRead
        build: function() {
            return root.calibrationPath !== ""
                ? Helper.read(root.calibrationPath, { maxBytes: root.maxCalibrationBytes }) : null;
        }
        onSucceeded: function(text) {
            // Every value is clamped, and malformed ones defaulted.
            const c = Sanitize.calibration(text);
            if (c !== null) {
                const seeded = Spectrum.seed(c, root.bands);
                root.bandRef = seeded.ref;
                root.bandNoise = seeded.noise;
            }
            root.calibrationLoaded = true;
        }
        onFailed: root.calibrationLoaded = true
    }

    FileView {
        id: timingFile
        path: root.timingPath
        preload: false
        printErrors: false
    }

    Bounded {
        id: timingRead
        build: function() {
            return root.timingPath !== "" ? Helper.read(root.timingPath, { maxBytes: root.maxTimingBytes }) : null;
        }
        onSucceeded: function(text) {
            // Rates outside (0, 10) are not plausible measurements.
            const rates = Sanitize.timingRates(text);
            if (Sanitize.own(rates, "stt")) root.sttRate = rates.stt;
            if (Sanitize.own(rates, "llm")) root.llmRate = rates.llm;
            if (Sanitize.own(rates, "type")) root.typeRate = rates.type;
        }
    }

    // Voxtype's configuration and the theme are the user's own files and
    // may be symlinks, as a dotfile manager makes them.
    Bounded {
        id: configRead
        build: function() {
            return root.configHome !== ""
                ? Helper.read(root.configHome + "/voxtype/config.toml",
                              { maxBytes: root.maxVoxtypeConfigBytes, follow: true }) : null;
        }
        onSucceeded: function(text) {
            const secs = Sanitize.maxRecordSecs(text);
            if (secs !== null) root.maxRecordSecs = secs;
        }
    }

    Bounded {
        id: themeRead
        build: function() {
            return root.stateHome !== ""
                ? Helper.read(root.stateHome + "/omarchy/current/theme/colors.toml",
                              { maxBytes: root.maxThemeBytes, follow: true }) : null;
        }
        onSucceeded: function(text) {
            const c = Sanitize.themeColours(text);
            const bg = c.background;
            const accent = c.accent;
            const fg = c.bright_foreground || c.foreground;
            if (bg && accent && fg) {
                // Without a mode, a background brighter than the text
                // makes a light theme.
                root.themeLight = c.mode ? c.mode === "light"
                    : Qt.color(bg).hslLightness > Qt.color(fg).hslLightness;
                root.themeBackground = bg;
                root.themeCard = c.dark_background || bg;
                root.themeAccent = accent;
                root.themeForeground = fg;
                root.themeMuted = c.muted || root.mix(Qt.color(bg), Qt.color(fg), 0.45);
                root.themeSelection = c.selection || root.mix(Qt.color(bg), Qt.color(accent), 0.2);
                root.themeWarn = c.red || root.mix(Qt.color(accent), Qt.color("#ff3b30"), 0.7);
            }
        }
    }

    // Post-process status, polled while transcribing and lingering: the
    // script replaces the file by rename, which a file watch would lose
    // track of. A read still in flight when the next poll comes is followed
    // by one more, not overlapped.
    Bounded {
        id: ppRead
        build: function() {
            return root.voxtypeDir !== ""
                ? Helper.read(root.voxtypeDir + "/postprocess.json", { maxBytes: root.maxPostprocessBytes }) : null;
        }
        onSucceeded: function(text) {
            const next = Postprocess.parse(text);
            if (next !== null) root.pp = next;
        }
    }

    Timer {
        interval: 100
        repeat: true
        running: root.shown && (root.working || root.lingering)
        triggeredOnStart: true
        onTriggered: ppRead.start()
    }

    // cava needs the microphone named in its config, so each time the HUD
    // shows a recording (`live`) it asks PipeWire for the default source,
    // writes a config from the cava.conf template beside this file, and only
    // then starts cava. Any step that fails leaves the spectrum on the RMS
    // fallback. A suppressed recording never starts it, and one suppressed
    // late stops it.
    property bool cavaReady: false
    property int cavaRequest: 0

    function startCava() {
        cavaReady = false;
        cavaRequest++;
        if (!dataDirReady || cavaConfigPath === "" || cavaTemplateText.indexOf("@SOURCE@") < 0) return;
        sourceQuery.start();
    }

    // The cava.conf template beside this file, read once at startup.
    property string cavaTemplateText: ""

    Bounded {
        id: templateRead
        build: function() {
            let path = "";
            try {
                path = decodeURIComponent(String(Qt.resolvedUrl("cava.conf")).replace(/^file:\/\//, ""));
            } catch (e) {}
            return Helper.read(path, { maxBytes: root.maxTemplateBytes, follow: true });
        }
        onSucceeded: function(text) { root.cavaTemplateText = text; }
    }

    Bounded {
        id: sourceQuery
        // The cava request this query answers, set as it starts.
        property int request: 0
        build: function() {
            sourceQuery.request = root.cavaRequest;
            return Helper.run(root.sourceCommand,
                              { seconds: 5, maxBytes: root.maxSourceBytes, env: root.childEnvironment });
        }
        onSucceeded: function(text) {
            if (sourceQuery.request !== root.cavaRequest || !root.live) return;
            // A PipeWire node name; anything else is not written into the
            // config.
            const source = Sanitize.pipewireSource(text);
            if (source === null) return;
            cavaConfig.request = sourceQuery.request;
            cavaConfig.setText(root.cavaTemplateText.split("@SOURCE@").join(source));
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

    // cava, through Helper.stream: env -i, a deadline, and TERM if the
    // shell dies, so a crashed shell does not leave it holding the
    // microphone.
    readonly property var cavaCommand: Helper.stream(
        [cavaExecutable].concat(cavaArgs || [], ["-p", cavaConfigPath]),
        { seconds: liveDeadlineSecs, env: childEnvironment })

    Process {
        id: cava
        running: root.live && root.cavaReady && root.cavaCommand !== null
        command: root.cavaCommand || []
        stdout: SplitParser {
            onRead: function(line) {
                const values = Sanitize.cavaLine(line);
                if (values !== null) {
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

        // Everything the window shows, in one item a test harness can
        // capture.
        Item {
            id: windowFrame
            anchors.fill: parent

            // Centred on whole device pixels, so the card's own snapping
            // holds.
            Card {
                id: card
                hud: root
                x: card.snap((parent.width - width) / 2)
                y: card.snap((parent.height - height) / 2)
                width: implicitWidth
                height: implicitHeight
            }

            // The card is drawn through this texture, which stops updating
            // while the window is held or fading, so the window keeps the
            // previous dictation's last frame although the card's bindings
            // already follow the new one.
            ShaderEffectSource {
                id: heldFrame
                anchors.fill: card
                sourceItem: card
                hideSource: true
                live: !root.holding && !root.fading
                opacity: 0
            }
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

    // The card, what the window shows of it, and the whole window, for a
    // test harness to capture frames from.
    readonly property Item cardItem: card
    readonly property Item windowItem: heldFrame
    readonly property Item windowFrameItem: windowFrame
}
