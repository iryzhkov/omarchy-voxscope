.pragma library

// Parsing for $XDG_RUNTIME_DIR/voxtype/postprocess.json, the status a
// post-process script writes for the HUD. docs/postprocess-protocol.md
// describes the format; this keeps only the fields it defines, each with
// the expected type and a sane range, so the drawing code can trust them.
// Fields are taken only when they are the object's own, and the strings
// that choose what the HUD says are whitelisted.

// A status file larger than this is not one the protocol produces.
var MAX_CHARS = 65536;
// Word-length arrays are capped at this many entries.
var MAX_WORDS = 400;

var STAGES = ["start", "llm", "done"];
var REASONS = ["ok", "rejected", "loading", "unreachable", "disabled"];

function field(o, key) {
    return Object.prototype.hasOwnProperty.call(o, key) ? o[key] : undefined;
}

function finite(v, lo, hi) {
    return typeof v === "number" && isFinite(v) && v >= lo && v <= hi;
}

function lens(v) {
    if (!Array.isArray(v)) return [];
    var out = [];
    for (var i = 0; i < v.length && out.length < MAX_WORDS; i++) {
        if (finite(v[i], 0, 1000)) out.push(Math.round(v[i]));
    }
    return out;
}

// A model name: printable ASCII, at most 128 characters.
function modelName(v) {
    return typeof v === "string" && /^[\x20-\x7e]{1,128}$/.test(v) ? v : undefined;
}

// Parse the file's text. Returns the status with only known, well-typed
// fields, or null when the text is not a status at all.
function parse(text) {
    if (typeof text !== "string" || text.length === 0 || text.length > MAX_CHARS) return null;
    var raw;
    try {
        raw = JSON.parse(text);
    } catch (e) {
        return null;
    }
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null;
    var stage = field(raw, "stage");
    var t = field(raw, "t");
    if (STAGES.indexOf(stage) < 0 || !finite(t, 0, 1e15)) return null;

    var pp = { stage: stage, t: t, raw_lens: lens(field(raw, "raw_lens")), lens: lens(field(raw, "lens")) };
    var v = field(raw, "stt_t");
    if (finite(v, 0, 1e15)) pp.stt_t = v;
    v = field(raw, "llm_t");
    if (finite(v, 0, 1e15)) pp.llm_t = v;
    v = field(raw, "words_in");
    if (finite(v, 0, 1e6)) pp.words_in = Math.round(v);
    v = field(raw, "words");
    if (finite(v, 0, 1e6)) pp.words = Math.round(v);
    v = field(raw, "timeout");
    if (finite(v, 0, 3600)) pp.timeout = v;
    v = field(raw, "cleaned");
    if (typeof v === "boolean") pp.cleaned = v;
    v = modelName(field(raw, "model"));
    if (v !== undefined) pp.model = v;
    v = field(raw, "reason");
    if (REASONS.indexOf(v) >= 0) pp.reason = v;
    return pp;
}
