.pragma library

// How Voxscope runs anything outside the shell's own process, and how it
// reads files: pure functions that build argv arrays, with no dependency on
// Quickshell, so tests/helper.test.mjs can execute exactly what the plugin
// executes.
//
// Every argv built here:
//
//   - starts with /usr/bin/env -i, so the child sees only the variables
//     named here (PATH=/usr/bin, LC_ALL=C and what the caller passes), never
//     the shell's inherited login environment;
//   - restores SIGPIPE to its default action (env --default-signal), so a
//     child whose reader has gone dies at its next write even when the
//     shell ignores the signal and its children inherit that. A stream's
//     producer orphaned by a killed wrapper ends this way;
//   - names every program by a fixed absolute path; the caller's own
//     executable must be one too (isExecutable);
//   - runs under GNU timeout, which signals the child's own process group at
//     the deadline, TERM then KILL two seconds later;
//   - starts bash, where one is needed, with --norc and --noprofile, so no
//     startup file is read whatever bash guesses about how it was started;
//   - passes data (file paths, byte caps, arguments) as separate argv
//     elements. The bash scripts below are fixed text and read their inputs
//     as positional parameters, so nothing from a file, a process or the
//     environment is ever parsed as shell syntax.
//
// One-shot runs and file reads also bound their output at the producer: head
// passes at most maxBytes + 1 bytes, tee copies them to the real stdout while
// wc counts them, and a count above maxBytes exits OVERFLOW_EXIT, so an
// oversized answer is discarded whole rather than parsed truncated. The count
// is of raw bytes: a QML string holds UTF-16 code units, so its length cannot
// stand in for a byte count. A run's output is consumed only when usable()
// says it ended on its own terms.

// A producer wrote more than its byte cap.
var OVERFLOW_EXIT = 9;
// A file read refused the path: missing, not a regular file, owned by
// someone else, writable by others, or (unless links are followed) reached
// through a symlink or hard link.
var REFUSED_EXIT = 3;

// Variables the caller may pass through, and nothing else.
var ENV_NAMES = ["HOME", "XDG_RUNTIME_DIR", "XDG_CONFIG_HOME", "PIPEWIRE_RUNTIME_DIR", "PULSE_SERVER"];

// Longest deadline any run may ask for: a day and a minute, the longest
// recording Voxtype's cap allows plus a margin.
var MAX_SECONDS = 86460;
// Largest byte cap a run may ask for.
var MAX_BYTES = 1048576;

// A one-shot run: $1 is the byte cap, the rest is the producer's argv.
var RUN_SCRIPT =
      "set -o pipefail\n"
    + "cap=$1\n"
    + "shift\n"
    + "exec 4>&1\n"
    + "n=$(\"$@\" 2>/dev/null | /usr/bin/head -c \"$((cap + 1))\" | /usr/bin/tee /dev/fd/4 | /usr/bin/wc -c)\n"
    + "rc=$?\n"
    + "n=${n//[^0-9]/}\n"
    + "[ -n \"$n\" ] || exit " + OVERFLOW_EXIT + "\n"
    // Above the cap the producer was cut off by head, and its status is a
    // SIGPIPE that says nothing about whether it succeeded.
    + "[ \"$n\" -gt \"$cap\" ] && exit " + OVERFLOW_EXIT + "\n"
    + "exit \"$rc\"\n";

// A file read: $1 the byte cap, $2 "strict" or "follow", $3 the path.
//
// The path is opened once, into fd 3, and everything after that looks at
// the opened file through /proc/self/fd/3 rather than walking the path again,
// so nothing can be swapped in between a check and the read. It must be a
// regular file owned by this user or root and not writable by others. In
// strict mode, used for the files Voxtype and Voxscope write themselves, it
// must also have a single link, and the descriptor must resolve back to the
// physical form of the requested path, which refuses a symlinked leaf. User
// configuration (Voxtype's config.toml, the theme) may be a symlink, as a
// dotfile manager makes it. A FIFO blocks the open, and the deadline turns
// that into an ordinary failure. The bytes are then streamed from fd 3.
var READ_SCRIPT =
      "set -o pipefail\n"
    + "cap=$1\n"
    + "mode=$2\n"
    + "p=$3\n"
    + "case $p in /*) ;; *) exit " + REFUSED_EXIT + " ;; esac\n"
    + "{ exec 3<\"$p\"; } 2>/dev/null || exit " + REFUSED_EXIT + "\n"
    + "i=$(/usr/bin/stat -L -c '%F|%u|%h|%f' /proc/self/fd/3) || exit " + REFUSED_EXIT + "\n"
    + "ftype=${i%%|*}; i=${i#*|}; fuid=${i%%|*}; i=${i#*|}; fnlink=${i%%|*}; fmode=${i#*|}\n"
    + "case $ftype in 'regular file' | 'regular empty file') ;; *) exit " + REFUSED_EXIT + " ;; esac\n"
    + "[ \"$fuid\" = \"$(/usr/bin/id -u)\" ] || [ \"$fuid\" = 0 ] || exit " + REFUSED_EXIT + "\n"
    + "(( 0x$fmode & 0002 )) && exit " + REFUSED_EXIT + "\n"
    + "if [ \"$mode\" = strict ]; then\n"
    + "  [ \"$fnlink\" = 1 ] || exit " + REFUSED_EXIT + "\n"
    + "  real=$(/usr/bin/readlink /proc/self/fd/3) || exit " + REFUSED_EXIT + "\n"
    + "  want=$( { cd -P -- \"${p%/*}/\" && pwd -P; } 2>/dev/null ) || exit " + REFUSED_EXIT + "\n"
    + "  want=${want%/}/${p##*/}\n"
    + "  [ \"$real\" = \"$want\" ] || exit " + REFUSED_EXIT + "\n"
    + "fi\n"
    + "exec 4>&1\n"
    + "n=$(/usr/bin/head -c \"$((cap + 1))\" <&3 | /usr/bin/tee /dev/fd/4 | /usr/bin/wc -c)\n"
    + "rc=$?\n"
    + "n=${n//[^0-9]/}\n"
    + "[ -n \"$n\" ] || exit " + OVERFLOW_EXIT + "\n"
    + "[ \"$n\" -gt \"$cap\" ] && exit " + OVERFLOW_EXIT + "\n"
    + "exit \"$rc\"\n";

function clampInt(v, lo, hi, fallback) {
    var n = typeof v === "number" && isFinite(v) ? Math.round(v) : fallback;
    return Math.max(lo, Math.min(hi, n));
}

// An absolute path with no control characters and no "." or ".."
// components, at most `max` characters long.
function isPath(p, max) {
    if (typeof p !== "string" || p.length < 2 || p.length > (max || 1024)) return false;
    if (p.charAt(0) !== "/" || /[\x00-\x1f\x7f]/.test(p)) return false;
    return !/(^|\/)\.\.?(\/|$)/.test(p);
}

// An absolute path to a program: a plain path of the usual characters.
function isExecutable(p) {
    return isPath(p, 256) && /^\/[A-Za-z0-9_.+\/-]+$/.test(p) && p.charAt(p.length - 1) !== "/";
}

// One argument for a program: a string without NUL, at most 4096
// characters.
function isArgument(a) {
    return typeof a === "string" && a.length <= 4096 && a.indexOf("\x00") < 0;
}

// The env -i prefix with the named variables from `vars` that hold a value:
// a path for the directories, a short printable string for PULSE_SERVER.
function envPrefix(vars) {
    var argv = ["/usr/bin/env", "-i", "--default-signal=PIPE", "PATH=/usr/bin", "LC_ALL=C"];
    var v = vars && typeof vars === "object" ? vars : {};
    for (var i = 0; i < ENV_NAMES.length; i++) {
        var name = ENV_NAMES[i];
        if (!Object.prototype.hasOwnProperty.call(v, name)) continue;
        var value = v[name];
        var ok = name === "PULSE_SERVER"
            ? typeof value === "string" && /^[\x21-\x7e]{1,1024}$/.test(value)
            : isPath(value);
        if (ok) argv.push(name + "=" + value);
    }
    return argv;
}

// Whether `argv` is a program by absolute path and plain arguments.
function validArgv(argv) {
    if (!Array.isArray(argv) || argv.length === 0 || argv.length > 64) return false;
    if (!isExecutable(argv[0])) return false;
    for (var i = 1; i < argv.length; i++) {
        if (!isArgument(argv[i])) return false;
    }
    return true;
}

// A one-shot run of `argv` (absolute program path first) with opts
// { seconds, maxBytes, env }. Its stdout is at most maxBytes; a longer one
// exits OVERFLOW_EXIT. Returns null when argv is not acceptable.
function run(argv, opts) {
    if (!validArgv(argv)) return null;
    var o = opts || {};
    return envPrefix(o.env).concat([
        "/usr/bin/timeout", "--kill-after=2", String(clampInt(o.seconds, 1, MAX_SECONDS, 5)),
        "/usr/bin/bash", "--norc", "--noprofile", "-c", RUN_SCRIPT, "voxscope-run",
        String(clampInt(o.maxBytes, 0, MAX_BYTES, 4096))
    ]).concat(argv);
}

// A bounded read of the file at `path`, with opts { maxBytes, follow,
// seconds }: the file's bytes on stdout, or a non-zero exit. Returns null
// when the path is not acceptable.
function read(path, opts) {
    if (!isPath(path)) return null;
    var o = opts || {};
    return envPrefix(null).concat([
        "/usr/bin/timeout", "--kill-after=2", String(clampInt(o.seconds, 1, 60, 5)),
        "/usr/bin/bash", "--norc", "--noprofile", "-c", READ_SCRIPT, "voxscope-read",
        String(clampInt(o.maxBytes, 0, MAX_BYTES, 4096)), o.follow === true ? "follow" : "strict", path
    ]);
}

// A long-running producer, such as the audio bridge or cava, whose lines
// the caller reads as they come: `argv` with opts { seconds, env }. setpriv
// asks for TERM when the shell dies, which timeout passes on to the
// producer's group, so a crashed shell does not leave it holding the
// microphone; the deadline ends it even if nothing stops it. Returns null
// when argv is not acceptable.
function stream(argv, opts) {
    if (!validArgv(argv)) return null;
    var o = opts || {};
    return envPrefix(o.env).concat([
        "/usr/bin/setpriv", "--pdeathsig", "TERM",
        "/usr/bin/timeout", "--kill-after=2", String(clampInt(o.seconds, 1, MAX_SECONDS, 60))
    ]).concat(argv);
}

// Whether a finished run's output may be used: it exited on its own with
// status 0. A crash, a deadline, an overflow or a refusal never is.
function usable(exitCode, exitStatus) {
    return exitCode === 0 && exitStatus === 0;
}
