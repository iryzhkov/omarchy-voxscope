.pragma library

// Everything Voxscope reads from outside its own code, turned into values the
// HUD can trust: pure functions with no QML state, so they can be tested on
// their own (tests/tst_sanitize.qml).
//
// The rule throughout: a number is finite and clamped to a range, a string
// is length-capped and, where it selects behaviour, one of a fixed set, and
// an object's fields are looked up only when they are its own. Anything else
// is treated as absent and the caller keeps its default.

// Whether `key` is an own property of the plain object `o`.
function own(o, key) {
    return o !== null && typeof o === "object" && Object.prototype.hasOwnProperty.call(o, key);
}

// o[key] when it is o's own property, otherwise undefined.
function field(o, key) {
    return own(o, key) ? o[key] : undefined;
}

function isPlainObject(o) {
    return o !== null && typeof o === "object" && !Array.isArray(o);
}

// An environment value naming a directory: an absolute path with no control
// characters and no "." or ".." components, at most 512 characters, without
// a trailing slash. A relative or odd value counts as unset, as the XDG base
// directory specification asks; then `fallback` is returned.
function directory(value, fallback) {
    if (typeof value !== "string" || value.length < 2 || value.length > 512) return fallback;
    if (value.charAt(0) !== "/" || /[\x00-\x1f\x7f]/.test(value)) return fallback;
    if (/(^|\/)\.\.?(\/|$)/.test(value)) return fallback;
    return value.replace(/\/+$/, "") || fallback;
}

// The plugin's id from its manifest, or `fallback`.
function pluginId(manifest, fallback) {
    const id = field(manifest, "id");
    return typeof id === "string" && /^[A-Za-z0-9_.-]{1,128}$/.test(id) ? id : fallback;
}

// This plugin's settings from omarchy-shell's parsed shell.json: the entry
// in `plugins` whose id is `id`, each setting whitelisted, anything else the
// default.
function settings(shellConfig, id) {
    const out = { compact: false, position: "center", reducedMotion: false };
    const list = field(shellConfig, "plugins");
    if (!Array.isArray(list)) return out;
    for (let i = 0; i < list.length && i < 1024; i++) {
        const entry = list[i];
        if (!isPlainObject(entry) || field(entry, "id") !== id) continue;
        out.compact = field(entry, "compact") === true;
        out.position = field(entry, "position") === "bottom" ? "bottom" : "center";
        out.reducedMotion = field(entry, "reducedMotion") === true;
        break;
    }
    return out;
}

var DAEMON_STATES = ["idle", "recording", "streaming", "transcribing"];

// Voxtype's state file: one of DAEMON_STATES, "idle" for anything else, or
// "" for an empty or oversized read, most likely the file caught mid-write,
// which the caller ignores.
function daemonState(raw) {
    if (typeof raw !== "string" || raw.length > 64) return "";
    const s = raw.trim();
    if (s === "") return "";
    return DAEMON_STATES.indexOf(s) >= 0 ? s : "idle";
}

// Largest plausible time in ms since the epoch (the year 33658).
var MAX_EPOCH_MS = 1e15;

// The toggle wrapper's stamp, ms since the epoch, or 0.
function toggleStamp(raw) {
    if (typeof raw !== "string" || raw.length > 32) return 0;
    const s = raw.trim();
    if (!/^[0-9]{1,16}$/.test(s)) return 0;
    const n = Number(s);
    return n > 0 && n <= MAX_EPOCH_MS ? n : 0;
}

// audio.max_duration_secs from Voxtype's config.toml (`voxtype config
// schema` lists it under [audio]), clamped to a second up to a day, or null
// when it is not set. Only the key in the [audio] table counts, or the
// dotted key audio.max_duration_secs before any table; a key of the same
// name in another table is something else. The last assignment wins.
function maxRecordSecs(raw) {
    if (typeof raw !== "string") return null;
    const lines = raw.split("\n");
    let table = "";
    let found = null;
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i].trim();
        // A table header, [name] or [[name]], with optional spaces and a
        // trailing comment.
        const header = /^\[\[?\s*([^\[\]]*?)\s*\]\]?\s*(#.*)?$/.exec(line);
        if (header) {
            table = header[1].replace(/\s*\.\s*/g, ".").replace(/"/g, "");
            continue;
        }
        const key = table === "audio" ? "max_duration_secs"
            : table === "" ? "audio\\s*\\.\\s*max_duration_secs" : null;
        if (key === null) continue;
        const m = new RegExp("^" + key + "\\s*=\\s*(\\d{1,9})\\s*(#.*)?$").exec(line);
        if (m) found = Math.max(1, Math.min(86400, Number(m[1])));
    }
    return found;
}

// The colours Voxscope uses from a theme's colors.toml, each a "#rrggbb"
// string or null when missing, and mode "light", "dark" or null.
function themeColours(text) {
    const keys = ["background", "foreground", "bright_foreground", "accent", "dark_background",
                  "muted", "selection", "red"];
    const out = { mode: null };
    const t = typeof text === "string" && text.length <= 65536 ? text : "";
    for (let i = 0; i < keys.length; i++) {
        const m = new RegExp("^" + keys[i] + "\\s*=\\s*\"(#[0-9a-fA-F]{6})\"", "m").exec(t);
        out[keys[i]] = m ? m[1] : null;
    }
    const mode = /^mode\s*=\s*"(light|dark)"/m.exec(t);
    if (mode) out.mode = mode[1];
    return out;
}

// Learned rates from timing.json: { stt, llm, type }, each present only when
// it is a plausible measurement, between 0 and 10 seconds a unit.
function timingRates(text) {
    const out = {};
    if (typeof text !== "string" || text.length > 4096) return out;
    let c;
    try {
        c = JSON.parse(text);
    } catch (e) {
        return out;
    }
    if (!isPlainObject(c)) return out;
    const names = ["stt", "llm", "type"];
    for (let i = 0; i < names.length; i++) {
        const v = field(c, names[i]);
        if (typeof v === "number" && isFinite(v) && v > 0 && v < 10) out[names[i]] = v;
    }
    return out;
}

// The saved calibration from calibration.json as { ref, noise }, the arrays
// as found (spectrum.js clamps every value), or null.
function calibration(text) {
    if (typeof text !== "string" || text.length > 16384) return null;
    let c;
    try {
        c = JSON.parse(text);
    } catch (e) {
        return null;
    }
    if (!isPlainObject(c)) return null;
    const ref = field(c, "ref");
    const noise = field(c, "noise");
    return { ref: Array.isArray(ref) ? ref : [], noise: Array.isArray(noise) ? noise : [] };
}

// A level from the audio bridge, clamped to 0..1.
function unit(v) {
    return typeof v === "number" && isFinite(v) ? Math.max(0, Math.min(1, v)) : 0;
}

// Longest audio bridge line accepted.
var MAX_BRIDGE_LINE = 512;

// One line from voxtype-audio-bridge: { status: "connected" },
// { status: "disconnected" }, { peak, rms, vad, tsMs } or null.
function bridgeLine(line) {
    const trimmed = String(line || "").trim();
    if (trimmed.length === 0 || trimmed.length > MAX_BRIDGE_LINE) return null;
    let obj;
    try {
        obj = JSON.parse(trimmed);
    } catch (e) {
        return null;
    }
    if (!isPlainObject(obj)) return null;
    const status = field(obj, "status");
    if (status === "connected" || status === "disconnected") return { status: status };
    const peak = field(obj, "peak");
    const rms = field(obj, "rms");
    if (typeof peak !== "number" || typeof rms !== "number") return null;
    const ts = field(obj, "ts_ms");
    return {
        peak: unit(peak),
        rms: unit(rms),
        vad: !!field(obj, "vad"),
        tsMs: typeof ts === "number" && isFinite(ts) ? Math.max(0, Math.min(MAX_EPOCH_MS, ts)) : 0
    };
}

// Longest cava line accepted, and most bars in one.
var MAX_CAVA_LINE = 1024;
var MAX_CAVA_BARS = 64;

// One frame of cava's raw ASCII output ("12;0;530;...;"), each bar 0..1000
// scaled to 0..1, or null when it is not one.
function cavaLine(line) {
    if (typeof line !== "string" || line.length > MAX_CAVA_LINE) return null;
    const parts = line.split(";");
    if (parts.length > MAX_CAVA_BARS + 1) return null;
    const values = [];
    for (let i = 0; i < parts.length; i++) {
        if (parts[i].length === 0) continue;
        const v = Number(parts[i]) / 1000;
        values.push(isFinite(v) ? Math.max(0, Math.min(1, v)) : 0);
    }
    return values.length > 0 ? values : null;
}

// The default PipeWire source's node name from `pactl get-default-source`,
// or null when it is not a plain node name, which is all that may be
// written into cava's config.
function pipewireSource(text) {
    const s = typeof text === "string" ? text.trim() : "";
    return /^[A-Za-z0-9_.:@+-]{1,256}$/.test(s) ? s : null;
}
