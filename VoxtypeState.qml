// Voxtype daemon state, read from its state file.
//
// Adapted from voxtype-shared/StateReader.qml in Voxtype
// (https://github.com/peteonrails/voxtype), MIT licence, copyright (c) 2025
// Peter Jackson. Changes: the paths come from the caller, the file is
// read with a size bound, an unknown state reads as idle, an empty read
// is ignored, and a missing directory is waited for.
//
// A FileView watch notices a file being created only when its directory
// already exists (checked with Quickshell 0.3.2). Voxtype creates its
// runtime directory when it starts, which can be after the shell, so
// while the state file cannot be read both files are re-armed every two
// seconds; once the state file loads, the watches take over.
//
// The daemon rewrites $XDG_RUNTIME_DIR/voxtype/state on every transition;
// it holds exactly one of idle, recording, streaming and transcribing. A
// recording started with `voxtype record start --no-osd` also creates the
// sibling marker osd_suppressed, asking every OSD to stay hidden; the state
// itself is still reported truthfully. Voxtype 1.0.1 creates the marker
// just after writing the recording state and removes it when it writes
// idle, so the two files' changes can be seen in either order. Hud.qml
// remembers the marker for the whole dictation.

import QtQuick
import Quickshell
import Quickshell.Io

// QtObject rather than Item, so `state` does not collide with Item's own
// property of that name.
QtObject {
    id: root

    // Voxtype's runtime directory, normally $XDG_RUNTIME_DIR/voxtype.
    property string directory: ""

    // One of idle, recording, streaming, transcribing; idle when the file is
    // missing or holds anything else.
    property string state: "idle"

    // True while the in-flight recording asked for no OSD.
    property bool osdSuppressed: false

    readonly property var knownStates: ["idle", "recording", "streaming", "transcribing"]

    // Whether the state file could be read last time; while it cannot,
    // the poll below re-arms the watches.
    property bool _readable: false
    // Cleared and set again to re-arm both FileViews.
    property bool _armed: true

    property FileView _stateFile: FileView {
        path: root.directory !== "" && root._armed ? root.directory + "/state" : ""
        watchChanges: true
        printErrors: false

        onLoaded: {
            root._readable = true;
            const raw = text();
            const next = raw.length <= 64 ? raw.trim() : "";
            // An empty read is most likely the file caught mid-write, not
            // a state; the write that follows will be seen.
            if (next === "") return;
            const known = root.knownStates.indexOf(next) >= 0 ? next : "idle";
            if (known !== root.state) root.state = known;
        }
        onLoadFailed: {
            root._readable = false;
            if (root.state !== "idle") root.state = "idle";
        }
        onFileChanged: reload()
    }

    property Timer _rearm: Timer {
        interval: 2000
        repeat: true
        running: root.directory !== "" && !root._readable
        onTriggered: {
            root._armed = false;
            root._armed = true;
        }
    }

    // The marker is created and removed rather than rewritten, so both the
    // load and the failure carry meaning: present means suppress.
    property FileView _suppressedFile: FileView {
        path: root.directory !== "" && root._armed ? root.directory + "/osd_suppressed" : ""
        watchChanges: true
        printErrors: false

        onLoaded: {
            if (!root.osdSuppressed) root.osdSuppressed = true;
        }
        onLoadFailed: {
            if (root.osdSuppressed) root.osdSuppressed = false;
        }
        onFileChanged: reload()
    }
}
