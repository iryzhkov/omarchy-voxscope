.pragma library

// Timing model for the Voxscope HUD: pure functions, no QML state, so they
// can be tested on their own.
//
// Neither speech to text nor the LLM reports progress, so each scan runs for
// an estimated duration (audio seconds for STT, word count for the LLM), at
// least SCAN_MIN_MS. When the real stage ends first, the line fast-forwards
// to the end in SCAN_FAST_FORWARD_MS; when it overruns, the line slows down
// near the end instead of stopping. The estimates are learned rates, folded
// from measured durations after each dictation (foldRate), and the typing
// animation is paced to end when voxtype's real typing does.
//
// Times are milliseconds since the epoch, as Date.now() and the
// postprocess.json "t" fields give them. Rates are seconds per unit.

var SCAN_MIN_MS = 500;
var SCAN_FAST_FORWARD_MS = 150;

// Learned seconds per unit: STT per audio second (plus STT_OFFSET_SECS),
// LLM per word (plus LLM_OFFSET_WORDS), typing per character (plus
// TYPE_OFFSET_CHARS). The defaults fit a GPU whisper server and a warm
// cleanup model.
var STT_OFFSET_SECS = 4;
var LLM_OFFSET_WORDS = 20;
var TYPE_OFFSET_CHARS = 20;
var DEFAULT_RATES = { stt: 0.016, llm: 0.03, type: 0.003 };

// The typing animation never runs shorter than this.
var TYPE_MIN_MS = 150;
// Once voxtype has gone idle the real typing is over, and the animation
// finishes within this long of the later of going idle and the scans
// handing over to it.
var TYPE_FAST_FORWARD_MS = 400;

// After voxtype goes idle the HUD stays up until the typing animation has
// finished, plus LINGER_HOLD_MS so the finished frame registers, but never
// longer than LINGER_MAX_MS after going idle.
var LINGER_HOLD_MS = 200;
var LINGER_MAX_MS = 1500;

// A post-process status written more than this long before the current
// transcription began belongs to an earlier dictation.
var PP_STALE_MS = 250;

function clamp(v, lo, hi) {
    return Math.max(lo, Math.min(hi, v));
}

// True when a post-process status belongs to the transcription that began
// at `since`.
function isFresh(pp, since) {
    return !!pp && typeof pp.t === "number" && pp.t >= since - PP_STALE_MS;
}

// Progress of one scan at time t: it starts at `start`, is expected to take
// `expected` ms (at least SCAN_MIN_MS) and the work it shows ended at
// `actual` (null while still running). Returns { p: 0..1, end: ms }, end
// being Infinity until the work has ended.
function scan(t, start, expected, actual) {
    var span = Math.max(expected, SCAN_MIN_MS);
    var eased = function(at) {
        var r = Math.max(0, (at - start) / span);
        // Linear to 80 %, then easing toward 97 % with matching slope.
        return r < 0.8 ? r : 0.8 + 0.17 * (1 - Math.exp(-(r - 0.8) / 0.17));
    };
    if (actual === null || actual === undefined) return { p: eased(t), end: Infinity };
    var a = Math.max(actual, start);
    var pa = eased(a);
    var end = Math.max(a + SCAN_FAST_FORWARD_MS, start + SCAN_MIN_MS);
    var p = t <= a ? eased(t) : Math.min(1, pa + (1 - pa) * (t - a) / (end - a));
    return { p: p, end: end };
}

// The displayed pipeline stage while transcribing, and after it while the
// HUD lingers. It follows the scans, not the real stage, so it can lag.
//
//   t        now
//   start    when the transcribing state began
//   recSecs  length of the recording in seconds
//   rates    { stt, llm } learned rates
//   pp       the post-process status if fresh, else null
//   idleAt   when voxtype went idle after transcribing, else null; all
//            work has ended by then, so it ends any scan still running
//
// Returns { stage: 1 STT | 2 LLM | 3 OUT, since: ms the stage began,
// p1: STT scan 0..1, p2: LLM scan 0..1 }.
function scanState(t, start, recSecs, rates, pp, idleAt) {
    var idle = idleAt === undefined ? null : idleAt;
    var sttEnd = pp && pp.stt_t ? pp.stt_t : idle;
    var s1 = scan(t, start, rates.stt * (recSecs + STT_OFFSET_SECS) * 1000, sttEnd);
    var out = { stage: 1, since: start, p1: s1.p, p2: 0 };
    if (t < s1.end) return out;
    var done = !!pp && pp.stage === "done";
    if (pp && pp.llm_t) {
        var words = pp.words_in || 0;
        var expected = pp.llm_t + rates.llm * (words + LLM_OFFSET_WORDS) * 1000 - s1.end;
        var s2 = scan(t, s1.end, expected, done ? pp.t : idle);
        if (t < s2.end) {
            out.stage = 2;
            out.since = s1.end;
            out.p2 = s2.p;
        } else {
            out.stage = 3;
            out.since = s2.end;
            out.p2 = 1;
        }
    } else if (done || idle !== null) {
        out.stage = 3;
        out.since = s1.end;
    }
    return out;
}

// Move a learned rate 30 % of the way toward a new sample, the sample first
// clamped to a quarter to four times the old rate so one odd dictation
// cannot throw the estimate off.
function foldRate(old, sample) {
    return old + (clamp(sample, old * 0.25, old * 4) - old) * 0.3;
}

// Fold one dictation's measured stage durations into the STT and LLM rates.
// `pp` is the final ("done") status, `start` when transcribing began and
// `recSecs` the recording's length. Returns new { stt, llm, type }.
function learnRates(rates, pp, start, recSecs) {
    var next = { stt: rates.stt, llm: rates.llm, type: rates.type };
    if (pp.stt_t && recSecs > 0) {
        var sttSecs = (pp.stt_t - start) / 1000;
        if (sttSecs > 0) next.stt = foldRate(rates.stt, sttSecs / (recSecs + STT_OFFSET_SECS));
    }
    if (pp.llm_t && (pp.cleaned || pp.reason === "rejected")) {
        var llmSecs = (pp.t - pp.llm_t) / 1000;
        // A timeout says nothing about the model's speed.
        if (llmSecs > 0 && llmSecs < 0.95 * (pp.timeout || 5)) {
            next.llm = foldRate(rates.llm, llmSecs / ((pp.words_in || 0) + LLM_OFFSET_WORDS));
        }
    }
    return next;
}

// Characters voxtype types for the output: the words' lengths plus the
// spaces between them, or six per word when no lengths were reported.
function typedChars(pp) {
    var lens = pp && pp.lens ? pp.lens : [];
    if (lens.length === 0) return ((pp && pp.words) || 0) * 6;
    var n = lens.length - 1;
    for (var i = 0; i < lens.length; i++) n += lens[i];
    return n;
}

// Fold the measured typing time (from the post-process finishing to voxtype
// going idle, in seconds) into the typing rate. Returns new rates; a sample
// outside 0..30 s is ignored.
function learnTyping(rates, pp, secs) {
    var next = { stt: rates.stt, llm: rates.llm, type: rates.type };
    if (secs <= 0 || secs > 30) return next;
    next.type = foldRate(rates.type, secs / (typedChars(pp) + TYPE_OFFSET_CHARS));
    return next;
}

// Typing animation progress, 0..1: from `start`, when the scans hand over,
// to the estimated end of the real typing, or quickly when that has passed.
// Once voxtype has gone idle (idleAt), the rest runs out within
// TYPE_FAST_FORWARD_MS. Without a final post-process status there is
// nothing to pace, and the animation is complete at once.
function typingProgress(t, pp, start, typeRate, idleAt) {
    if (!pp || pp.stage !== "done") return 1;
    var end = Math.max(start + TYPE_MIN_MS, pp.t + typeRate * (typedChars(pp) + TYPE_OFFSET_CHARS) * 1000);
    var linear = function(at) { return clamp((at - start) / (end - start), 0, 1); };
    if (idleAt === null || idleAt === undefined) return linear(t);
    var a = Math.max(idleAt, start);
    if (t <= a) return linear(t);
    var pa = linear(a);
    var ffEnd = Math.max(a + 1, Math.min(end, a + TYPE_FAST_FORWARD_MS));
    return Math.min(1, pa + (1 - pa) * (t - a) / (ffEnd - a));
}

// Whether a linger that began when voxtype went idle at `idleAt` is over at
// t. `doneAt` is when the typing animation finished, or null while it runs.
function lingerOver(t, idleAt, doneAt) {
    if (t >= idleAt + LINGER_MAX_MS) return true;
    return doneAt !== null && doneAt !== undefined && t >= doneAt + LINGER_HOLD_MS;
}
