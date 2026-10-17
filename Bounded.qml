// One bounded helper: a file read or a one-shot command, built by Helper.js
// (fixed absolute executables, env -i, a deadline, a byte cap counted at
// the producer), whose output is handed on only if the run earned it.
//
// Runs are serialised. Asking for one while another is in flight marks it
// pending, and it starts again once the first has published, so the latest
// content is always read and no two runs of one helper overlap.
//
// The collector's streamFinished and the process's exited arrive in no
// guaranteed order, so each records what it knows and whichever lands
// second publishes. A run stays in flight until then, not only until its
// process exits: a run started between the old one's exit and its
// streamFinished would otherwise pair the old text with the new exit
// status. Each result therefore belongs to its own run: `succeeded` for a
// run that exited 0, `failed` with the exit code for anything else (a
// missing or refused file, a deadline, an overflow, a crash). The text of a
// failed run is never handed on.

import QtQuick
import Quickshell.Io
import "Helper.js" as Helper

Item {
    id: root

    // A function returning the argv for the next run (Helper.read or
    // Helper.run), or null when there is nothing to run. It is called as
    // each run starts, so the run uses the paths as they are then.
    property var build: null

    // Decoded output beyond this many characters is never handed on; the
    // byte cap in the argv is the real bound, this only a second layer.
    property int maxChars: 1048576

    signal succeeded(string text)
    signal failed(int exitCode)

    readonly property bool running: proc.running
    property bool pending: false

    function start() {
        // A run that is not running and never exited never started (the
        // fork failed); nothing will publish it, so it no longer counts.
        if (proc.inFlight && !proc.running && !proc.judged) proc.inFlight = false;
        if (proc.running || proc.inFlight) {
            pending = true;
            return;
        }
        pending = false;
        const argv = typeof build === "function" ? build() : null;
        if (!argv) {
            failed(Helper.REFUSED_EXIT);
            return;
        }
        proc.collected = "";
        proc.collectedReady = false;
        proc.judged = false;
        proc.exitCode = -1;
        proc.inFlight = true;
        proc.command = argv;
        proc.running = true;
    }

    function stop() {
        pending = false;
        proc.running = false;
    }

    Process {
        id: proc
        property string collected: ""
        // From a run's start until its result is published.
        property bool inFlight: false
        property bool collectedReady: false
        property bool judged: false
        property int exitCode: -1
        property bool clean: false

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                const s = String(text);
                proc.collected = s.length <= root.maxChars ? s : "";
                proc.collectedReady = true;
                proc.publish();
            }
        }

        onExited: function(exitCode, exitStatus) {
            proc.exitCode = exitCode;
            proc.clean = Helper.usable(exitCode, exitStatus);
            proc.judged = true;
            proc.publish();
        }

        function publish() {
            if (!proc.collectedReady || !proc.judged) return;
            const text = proc.collected;
            const clean = proc.clean;
            const code = proc.exitCode;
            proc.collected = "";
            proc.collectedReady = false;
            proc.judged = false;
            proc.inFlight = false;
            if (clean) root.succeeded(text);
            // A crash can report status 0; it is still a failure.
            else root.failed(code === 0 ? -1 : code);
            if (root.pending) Qt.callLater(root.start);
        }
    }

    Component.onDestruction: stop()
}
