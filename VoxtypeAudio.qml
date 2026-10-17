// Voxtype's microphone levels, from its audio bridge.
//
// Adapted from voxtype-shared/AudioBridge.qml in Voxtype
// (https://github.com/peteonrails/voxtype), MIT licence, copyright (c) 2025
// Peter Jackson. Changes: the bridge runs only while `active`, from a
// fixed path, and lines are length-bounded and their numbers clamped.
//
// voxtype-audio-bridge reads the daemon's audio socket
// ($XDG_RUNTIME_DIR/voxtype/audio.sock) and prints one JSON object per
// line:
//
//   {"peak":0.421,"rms":0.180,"vad":1,"ts_ms":1234567}
//   {"status":"connected"}
//   {"status":"disconnected"}
//
// It carries only peak and RMS, no spectrum.

import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: root

    // Run the bridge only while this is true.
    property bool active: false

    // The bridge's command line; a test harness substitutes a fake.
    property var command: ["/usr/bin/voxtype-audio-bridge"]

    // Delay before restarting a bridge that exited while active, so a
    // crash-looping binary cannot spin the CPU.
    property int restartDelayMs: 1000

    // True once the bridge has delivered a frame since it last connected.
    property bool running: false

    // Latest frame: peak and RMS amplitude 0..1, voice activity.
    property real peak: 0
    property real rms: 0
    property bool vad: false

    signal frameReceived(real peak, real rms, bool vad, real tsMs)
    signal connected()
    signal disconnected()

    readonly property int maxLineChars: 512

    function level(v) {
        const n = Number(v);
        return isFinite(n) ? Math.max(0, Math.min(1, n)) : 0;
    }

    function handleLine(line) {
        const trimmed = String(line || "").trim();
        if (trimmed.length === 0 || trimmed.length > root.maxLineChars) return;
        let obj;
        try {
            obj = JSON.parse(trimmed);
        } catch (e) {
            return;
        }
        if (obj === null || typeof obj !== "object") return;
        if (obj.status === "connected") {
            root.connected();
            return;
        }
        if (obj.status === "disconnected") {
            root.running = false;
            root.disconnected();
            return;
        }
        if (typeof obj.peak === "number" && typeof obj.rms === "number") {
            root.peak = level(obj.peak);
            root.rms = level(obj.rms);
            root.vad = !!obj.vad;
            const ts = Number(obj.ts_ms);
            root.running = true;
            root.frameReceived(root.peak, root.rms, root.vad, isFinite(ts) ? ts : 0);
        }
    }

    Process {
        id: bridge
        command: root.command

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: function(data) { root.handleLine(data); }
        }

        onRunningChanged: {
            if (bridge.running) return;
            if (root.running) {
                root.running = false;
                root.disconnected();
            }
            if (root.active) restartTimer.restart();
        }
    }

    Timer {
        id: restartTimer
        interval: root.restartDelayMs
        onTriggered: {
            if (root.active && !bridge.running) bridge.running = true;
        }
    }

    // Started and stopped here rather than bound to `active`, because the
    // restart timer sets `running` too and would break a binding.
    onActiveChanged: {
        if (active) {
            bridge.running = true;
            return;
        }
        restartTimer.stop();
        bridge.running = false;
        peak = 0;
        rms = 0;
        vad = false;
    }

    Component.onCompleted: {
        if (active) bridge.running = true;
    }
}
