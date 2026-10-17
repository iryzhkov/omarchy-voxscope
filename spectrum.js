.pragma library

// Calibration of the recording spectrum: pure functions, no QML state, so
// they can be tested on their own.
//
// cava reports each band's level from 0 to 1 at a fixed gain (cava.conf),
// and how loud speech gets on that scale depends on the microphone, its
// gain and the room: at cava.conf's gain, soft speech into a laptop
// microphone peaks at a few tenths and normal speech at about half. So every band keeps two running estimates:
//
//   noise  the room's floor in that band: it falls quickly to anything
//          quieter, and creeps up slowly and only a little at a time, so
//          speech does not drag it up. Levels under a gate of twice the
//          noise floor are dropped, which keeps room hiss at the resting
//          centre cell.
//   ref    how loud speech gets in that band: it rises within a fraction
//          of a second to anything louder, and between peaks falls by
//          RELEASE of itself a second, never below a few times the noise
//          floor, so it follows the speaker's level within a dictation.
//
// A band's level is then its distance above the gate as a share of the
// reference plus HEADROOM, so the loudest syllables reach most of the
// height rather than all of it. Both estimates are saved between
// dictations; a saved reference is capped when a recording starts
// (SEED_REF_MAX), so one left high by a loud session cannot keep a quiet
// dictation flat.

// Gate: never below this, whatever the noise estimate.
var GATE_MIN = 0.003;
// The reference never falls below this many noise floors, nor below
// REF_MIN.
var REF_NOISE_FLOORS = 4;
var REF_MIN = 0.008;
// Highest reference a recording starts from: about soft speech, so that
// moves at once, and louder speech catches the reference up within a
// syllable.
var SEED_REF_MAX = 0.025;
// Reference and noise floor with nothing saved.
var DEFAULT_REF = 0.02;
var DEFAULT_NOISE = 0.002;
// Largest plausible noise floor; anything above it is clamped.
var NOISE_MAX = 0.05;
// Reference attack, in time constants a second, and release, as the share
// it loses a second.
var ATTACK = 20;
var RELEASE = 0.4;
// Noise floor fall rate and its slower rise, a second, and how far above
// itself one rise step may aim.
var NOISE_FALL = 2;
var NOISE_RISE = 0.3;
var NOISE_RISE_RATIO = 1.5;
var NOISE_RISE_STEP = 0.0005;
// A quiet band's reference is at least this share of the loudest band's,
// so hiss in bands that never carry speech is not stretched to the top.
var GLOBAL_SHARE = 0.25;
// Speech at the reference reaches 1 / HEADROOM of the scale (before the
// curve below), leaving room above it.
var HEADROOM = 1.3;
// Exponent of the curve from scale to height: below 1 lifts quiet levels.
var CURVE = 0.5;

function clamp(v, lo, hi) {
    return Math.max(lo, Math.min(hi, v));
}

// v if it is a finite number, clamped to [lo, hi]; otherwise fallback.
function finite(v, lo, hi, fallback) {
    return typeof v === "number" && isFinite(v) ? clamp(v, lo, hi) : fallback;
}

function gate(noise) {
    return Math.max(GATE_MIN, noise * 2);
}

function refFloor(noise) {
    return Math.max(REF_MIN, noise * REF_NOISE_FLOORS);
}

// The calibration a recording starts from, `bands` long, from a saved or
// previous one ({ ref, noise }, either may be missing or malformed): every
// value clamped, missing ones defaulted, and the reference capped at
// SEED_REF_MAX.
function seed(saved, bands) {
    const s = saved && typeof saved === "object" ? saved : {};
    const refIn = Array.isArray(s.ref) && s.ref.length === bands ? s.ref : [];
    const noiseIn = Array.isArray(s.noise) && s.noise.length === bands ? s.noise : [];
    const ref = new Array(bands);
    const noise = new Array(bands);
    for (let i = 0; i < bands; i++) {
        noise[i] = finite(noiseIn[i], 0, NOISE_MAX, DEFAULT_NOISE);
        const r = finite(refIn[i], 0, 1, DEFAULT_REF);
        ref[i] = clamp(r, refFloor(noise[i]), Math.max(refFloor(noise[i]), SEED_REF_MAX));
    }
    return { ref: ref, noise: noise };
}

// One step of `dt` seconds with the bands' current levels `values`; returns
// the new { ref, noise } and leaves its arguments alone.
function calibrate(ref, noise, values, dt) {
    const n = values.length;
    const nextRef = new Array(n);
    const nextNoise = new Array(n);
    for (let i = 0; i < n; i++) {
        const v = finite(values[i], 0, 1, 0);
        let nz = finite(noise[i], 0, NOISE_MAX, DEFAULT_NOISE);
        if (v < nz) {
            nz += (v - nz) * Math.min(1, NOISE_FALL * dt);
        } else {
            const aim = Math.min(v, nz * NOISE_RISE_RATIO + NOISE_RISE_STEP);
            nz += (aim - nz) * Math.min(1, NOISE_RISE * dt);
        }
        nz = clamp(nz, 0, NOISE_MAX);
        let r = finite(ref[i], 0, 1, DEFAULT_REF);
        if (v > r) r += (v - r) * Math.min(1, ATTACK * dt);
        else r -= r * Math.min(1, RELEASE * dt);
        nextRef[i] = clamp(r, refFloor(nz), 1);
        nextNoise[i] = nz;
    }
    return { ref: nextRef, noise: nextNoise };
}

// The loudest reference of all bands.
function loudest(ref) {
    let top = 0;
    for (let i = 0; i < ref.length; i++) top = Math.max(top, finite(ref[i], 0, 1, 0));
    return top;
}

// The height, 0 to 1, of a band at cava level v with reference ref and
// noise floor noise, given the loudest band's reference `top`.
function level(v, ref, noise, top) {
    const g = gate(finite(noise, 0, NOISE_MAX, DEFAULT_NOISE));
    const r = Math.max(finite(ref, 0, 1, DEFAULT_REF), top * GLOBAL_SHARE, refFloor(noise));
    const span = Math.max(1e-4, r * HEADROOM - g);
    return Math.pow(clamp((finite(v, 0, 1, 0) - g) / span, 0, 1), CURVE);
}
