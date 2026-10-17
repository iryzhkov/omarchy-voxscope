// Voxtype daemon state, read from its state file.
//
// Adapted from voxtype-shared/StateReader.qml in Voxtype
// (https://github.com/peteonrails/voxtype), MIT licence, copyright (c) 2025
// Peter Jackson. Changes: the paths come from the caller, the file is
// read with a size bound, and an unknown state reads as idle.
//
// The daemon rewrites $XDG_RUNTIME_DIR/voxtype/state on every transition;
// it holds exactly one of idle, recording, streaming and transcribing. A
// recording started with `voxtype record start --no-osd` also creates the
// sibling marker osd_suppressed for as long as it runs, asking every OSD to
// stay hidden; the state itself is still reported truthfully.

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

    property FileView _stateFile: FileView {
        path: root.directory !== "" ? root.directory + "/state" : ""
        watchChanges: true
        printErrors: false

        onLoaded: {
            const raw = text();
            const next = raw.length <= 64 ? raw.trim() : "";
            const known = root.knownStates.indexOf(next) >= 0 ? next : "idle";
            if (known !== root.state) root.state = known;
        }
        onLoadFailed: {
            if (root.state !== "idle") root.state = "idle";
        }
        onFileChanged: reload()
    }

    // The marker is created and removed rather than rewritten, so both the
    // load and the failure carry meaning: present means suppress.
    property FileView _suppressedFile: FileView {
        path: root.directory !== "" ? root.directory + "/osd_suppressed" : ""
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
