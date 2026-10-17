// Voxtype daemon state, read from its state file.
//
// Adapted from voxtype-shared/StateReader.qml in Voxtype
// (https://github.com/peteonrails/voxtype), MIT licence, copyright (c) 2025
// Peter Jackson. Changes: the paths come from the caller, both files are
// read through bounded helpers (Bounded.qml) instead of being loaded, an
// unknown state reads as idle, an empty read is ignored, and a missing
// directory is waited for.
//
// The FileViews only watch; they never load. Each change starts a read
// through Helper.read, which opens the file once, refuses anything but a
// regular file of this user's reached without a symlink, and passes at
// most a few dozen bytes; the state file holds one word and the marker
// "1".
//
// A FileView watch notices a file being created only when its directory
// already exists (checked with Quickshell 0.3.2). Voxtype creates its
// runtime directory when it starts, which can be after the shell, so
// while the state file cannot be read both files are re-armed every two
// seconds; once the state file reads, the watches take over.
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
import Quickshell.Io
import "Helper.js" as Helper
import "Sanitize.js" as Sanitize

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

    // Byte caps on the two reads: the state is one short word, the marker
    // "1".
    readonly property int maxStateBytes: 64
    readonly property int maxMarkerBytes: 64

    // Whether the state file could be read last time; while it cannot,
    // the poll below re-arms the watches.
    property bool _readable: false
    // Cleared and set again to re-arm both FileViews.
    property bool _armed: true

    readonly property string _statePath: directory !== "" && _armed ? directory + "/state" : ""
    readonly property string _markerPath: directory !== "" && _armed ? directory + "/osd_suppressed" : ""

    property FileView _stateWatch: FileView {
        path: root._statePath
        preload: false
        watchChanges: true
        printErrors: false
        onFileChanged: root._stateRead.start()
        onPathChanged: if (path !== "") root._stateRead.start()
    }

    property Bounded _stateRead: Bounded {
        build: function() {
            return root._statePath !== ""
                ? Helper.read(root._statePath, { maxBytes: root.maxStateBytes }) : null;
        }
        onSucceeded: function(text) {
            const wasReadable = root._readable;
            root._readable = true;
            // Re-arm once more, so the watches are certainly placed with
            // the directory in existence.
            if (!wasReadable) {
                root._armed = false;
                root._armed = true;
            }
            // An empty read is most likely the file caught mid-write, not
            // a state; the write that follows will be seen.
            const next = Sanitize.daemonState(text);
            if (next !== "" && next !== root.state) root.state = next;
        }
        onFailed: function(exitCode) {
            // An oversized file is there but holds no state; it is ignored
            // as an empty read is.
            if (exitCode === Helper.OVERFLOW_EXIT) {
                root._readable = true;
                return;
            }
            root._readable = false;
            if (root.state !== "idle") root.state = "idle";
        }
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

    // The marker is created and removed rather than rewritten, so both a
    // read and a failure carry meaning: present means suppress. An
    // oversized marker is still present.
    property FileView _markerWatch: FileView {
        path: root._markerPath
        preload: false
        watchChanges: true
        printErrors: false
        onFileChanged: root._markerRead.start()
        onPathChanged: if (path !== "") root._markerRead.start()
    }

    property Bounded _markerRead: Bounded {
        build: function() {
            return root._markerPath !== ""
                ? Helper.read(root._markerPath, { maxBytes: root.maxMarkerBytes }) : null;
        }
        onSucceeded: {
            if (!root.osdSuppressed) root.osdSuppressed = true;
        }
        onFailed: function(exitCode) {
            const present = exitCode === Helper.OVERFLOW_EXIT;
            if (root.osdSuppressed !== present) root.osdSuppressed = present;
        }
    }
}
