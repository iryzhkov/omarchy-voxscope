// Voxtype's microphone levels, from its audio bridge.
//
// Adapted from voxtype-shared/AudioBridge.qml in Voxtype
// (https://github.com/peteonrails/voxtype), MIT licence, copyright (c) 2025
// Peter Jackson. Changes: the bridge runs only while `active`, from a
// fixed path through Helper.stream (env -i, a deadline, and TERM if the
// shell dies), and lines are length-bounded and their numbers clamped
// (Sanitize.bridgeLine).
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
import Quickshell.Io
import "Helper.js" as Helper
import "Sanitize.js" as Sanitize

Item {
    id: root

    // Run the bridge only while this is true.
    property bool active: false

    // The bridge, by absolute path, and its arguments; a test harness
    // substitutes a fake.
    property string executable: "/usr/bin/voxtype-audio-bridge"
    property var args: []
    // The variables it runs with (Helper.envPrefix names the ones that
    // pass), and the longest it may run.
    property var environment: ({})
    property int deadlineSecs: 3600

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

    function handleLine(line) {
        const msg = Sanitize.bridgeLine(line);
        if (msg === null) return;
        if (msg.status === "connected") {
            root.connected();
            return;
        }
        if (msg.status === "disconnected") {
            root.running = false;
            root.disconnected();
            return;
        }
        root.peak = msg.peak;
        root.rms = msg.rms;
        root.vad = msg.vad;
        root.running = true;
        root.frameReceived(msg.peak, msg.rms, msg.vad, msg.tsMs);
    }

    // Starts the bridge, unless its command is not acceptable.
    function launch() {
        const argv = Helper.stream([root.executable].concat(root.args || []),
                                   { seconds: root.deadlineSecs, env: root.environment });
        if (argv === null) return;
        bridge.command = argv;
        bridge.running = true;
    }

    Process {
        id: bridge

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
            if (root.active && !bridge.running) root.launch();
        }
    }

    // Started and stopped here rather than bound to `active`, because the
    // restart timer sets `running` too and would break a binding.
    onActiveChanged: {
        if (active) {
            launch();
            return;
        }
        restartTimer.stop();
        bridge.running = false;
        peak = 0;
        rms = 0;
        vad = false;
    }

    Component.onCompleted: {
        if (active) launch();
    }

    Component.onDestruction: bridge.running = false
}
