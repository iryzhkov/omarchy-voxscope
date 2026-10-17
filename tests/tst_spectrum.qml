import QtQuick
import QtTest
import "../spectrum.js" as Spectrum

// The recording spectrum's calibration: seeding from saved values, the
// per-band reference and noise floor, and the height a level is drawn at.
TestCase {
    name: "Spectrum"

    // The constants tuned on real speech (e829b18); changing them changes
    // how the meter feels, so a change has to be deliberate.
    function test_tuned_constants_are_kept() {
        compare(Spectrum.RELEASE, 0.4);
        compare(Spectrum.CURVE, 0.5);
        compare(Spectrum.SEED_REF_MAX, 0.025);
        compare(Spectrum.HEADROOM, 1.3);
    }

    function test_seed_defaults_a_missing_calibration() {
        const s = Spectrum.seed(null, 32);
        compare(s.ref.length, 32);
        compare(s.noise.length, 32);
        for (let i = 0; i < 32; i++) {
            compare(s.noise[i], Spectrum.DEFAULT_NOISE);
            compare(s.ref[i], Spectrum.DEFAULT_REF);
        }
    }

    function test_seed_caps_a_reference_left_high_by_a_loud_session() {
        const ref = new Array(32).fill(0.3);
        const s = Spectrum.seed({ ref: ref, noise: new Array(32).fill(0.002) }, 32);
        for (let i = 0; i < 32; i++) compare(s.ref[i], Spectrum.SEED_REF_MAX);
    }

    function test_seed_clamps_and_defaults_malformed_values() {
        const ref = new Array(32).fill(0.01);
        const noise = new Array(32).fill(0.002);
        ref[0] = NaN;
        ref[1] = "0.5";
        noise[2] = 7;
        noise[3] = -1;
        const s = Spectrum.seed({ ref: ref, noise: noise }, 32);
        compare(s.ref[0], Spectrum.DEFAULT_REF);
        compare(s.ref[1], Spectrum.DEFAULT_REF);
        compare(s.noise[2], Spectrum.NOISE_MAX);
        compare(s.noise[3], 0);
        for (let i = 0; i < 32; i++) {
            verify(isFinite(s.ref[i]) && s.ref[i] > 0 && s.ref[i] <= 1);
            verify(isFinite(s.noise[i]) && s.noise[i] >= 0 && s.noise[i] <= Spectrum.NOISE_MAX);
        }
    }

    function test_seed_ignores_arrays_of_the_wrong_length() {
        const s = Spectrum.seed({ ref: [0.01], noise: [0.001] }, 32);
        compare(s.ref[0], Spectrum.DEFAULT_REF);
        compare(s.noise[0], Spectrum.DEFAULT_NOISE);
    }

    function test_reference_rises_quickly_to_speech_and_releases_slowly() {
        let c = Spectrum.seed(null, 1);
        for (let i = 0; i < 30; i++) c = Spectrum.calibrate(c.ref, c.noise, [0.5], 1 / 60);
        // Half a second of loud speech has caught the reference up.
        verify(c.ref[0] > 0.45);
        const before = c.ref[0];
        c = Spectrum.calibrate(c.ref, c.noise, [0], 1);
        fuzzyCompare(c.ref[0], before * (1 - Spectrum.RELEASE), 1e-9);
    }

    function test_noise_floor_falls_fast_and_rises_slowly() {
        let c = { ref: [0.02], noise: [0.01] };
        c = Spectrum.calibrate(c.ref, c.noise, [0], 0.5);
        verify(c.noise[0] < 0.001);
        let d = { ref: [0.02], noise: [0.002] };
        d = Spectrum.calibrate(d.ref, d.noise, [0.5], 0.1);
        verify(d.noise[0] < 0.003);
    }

    function test_calibrate_leaves_its_arguments_alone() {
        const ref = [0.02];
        const noise = [0.002];
        Spectrum.calibrate(ref, noise, [0.9], 0.1);
        compare(ref[0], 0.02);
        compare(noise[0], 0.002);
    }

    function test_level_gates_hiss_and_stays_in_range() {
        compare(Spectrum.level(0.002, 0.02, 0.002, 0.02), 0);
        compare(Spectrum.level(1, 0.02, 0.002, 0.02), 1);
        compare(Spectrum.level(NaN, 0.02, 0.002, 0.02), 0);
        const atRef = Spectrum.level(0.02, 0.02, 0.002, 0.02);
        verify(atRef > 0.5 && atRef < 1);
    }

    function test_a_quiet_band_is_not_stretched_to_the_top() {
        // The loudest band's reference keeps a band that never carries
        // speech from drawing its hiss full height.
        const alone = Spectrum.level(0.02, 0.008, 0.002, 0.008);
        const shared = Spectrum.level(0.02, 0.008, 0.002, 0.4);
        verify(shared < alone);
    }

    function test_loudest_ignores_malformed_values() {
        compare(Spectrum.loudest([0.1, NaN, 0.3, "0.9"]), 0.3);
        compare(Spectrum.loudest([]), 0);
    }
}
