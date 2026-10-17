.pragma library

// Parsing for $XDG_RUNTIME_DIR/voxtype/postprocess.json, the status a
// post-process script writes for the HUD. docs/postprocess-protocol.md
// describes the format; this keeps only the fields it defines, each with
// the expected type and a sane range, so the drawing code can trust them.

// A status file larger than this is not one the protocol produces.
var MAX_CHARS = 65536;
// Word-length arrays are capped at this many entries.
var MAX_WORDS = 400;

var STAGES = ["start", "llm", "done"];

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

function shortString(v, max) {
    return typeof v === "string" && v.length > 0 && v.length <= max ? v : undefined;
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
    if (STAGES.indexOf(raw.stage) < 0 || !finite(raw.t, 0, 1e15)) return null;

    var pp = { stage: raw.stage, t: raw.t, raw_lens: lens(raw.raw_lens), lens: lens(raw.lens) };
    if (finite(raw.stt_t, 0, 1e15)) pp.stt_t = raw.stt_t;
    if (finite(raw.llm_t, 0, 1e15)) pp.llm_t = raw.llm_t;
    if (finite(raw.words_in, 0, 1e6)) pp.words_in = Math.round(raw.words_in);
    if (finite(raw.words, 0, 1e6)) pp.words = Math.round(raw.words);
    if (finite(raw.timeout, 0, 3600)) pp.timeout = raw.timeout;
    if (typeof raw.cleaned === "boolean") pp.cleaned = raw.cleaned;
    var model = shortString(raw.model, 128);
    if (model !== undefined) pp.model = model;
    var reason = shortString(raw.reason, 32);
    if (reason !== undefined) pp.reason = reason;
    return pp;
}
