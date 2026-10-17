import QtQuick
import QtTest
import "../timing.js" as Timing

// The timing model: scan progress, the displayed stage, learning the rates
// and pacing the typing animation and the linger.
TestCase {
    name: "Timing"

    readonly property var rates: Timing.DEFAULT_RATES

    function test_scan_runs_linearly_to_eighty_percent() {
        compare(Timing.scan(1000, 1000, 2000, null).p, 0);
        fuzzyCompare(Timing.scan(2000, 1000, 2000, null).p, 0.5, 1e-9);
        fuzzyCompare(Timing.scan(2600, 1000, 2000, null).p, 0.8, 1e-9);
        compare(Timing.scan(2000, 1000, 2000, null).end, Infinity);
    }

    function test_scan_slows_near_the_end_but_never_stops_or_finishes() {
        const late = Timing.scan(1000 + 2000 * 1.2, 1000, 2000, null).p;
        const later = Timing.scan(1000 + 2000 * 3, 1000, 2000, null).p;
        verify(late > 0.8 && late < 0.97);
        verify(later > late && later < 0.97);
    }

    function test_scan_never_shorter_than_its_minimum() {
        // An estimate of 100 ms still takes SCAN_MIN_MS.
        fuzzyCompare(Timing.scan(1250, 1000, 100, null).p, 0.5, 1e-9);
        compare(Timing.scan(1000, 1000, 100, 1010).end, 1000 + Timing.SCAN_MIN_MS);
    }

    function test_scan_fast_forwards_when_the_work_ends_early() {
        const s = Timing.scan(2000, 1000, 10000, 2000);
        compare(s.end, 2000 + Timing.SCAN_FAST_FORWARD_MS);
        fuzzyCompare(s.p, 0.1, 1e-9);
        compare(Timing.scan(s.end, 1000, 10000, 2000).p, 1);
        compare(Timing.scan(s.end + 500, 1000, 10000, 2000).p, 1);
        const mid = Timing.scan(2000 + Timing.SCAN_FAST_FORWARD_MS / 2, 1000, 10000, 2000).p;
        verify(mid > 0.1 && mid < 1);
    }

    function test_stage_is_stt_without_a_status() {
        const s = Timing.scanState(5000, 1000, 3, rates, null, null);
        compare(s.stage, 1);
        compare(s.since, 1000);
        compare(s.p2, 0);
    }

    function test_stage_follows_the_status_through_llm_to_out() {
        const pp = { stage: "llm", t: 1500, stt_t: 1400, llm_t: 1500, words_in: 10 };
        const sttEnd = 1400 + Timing.SCAN_FAST_FORWARD_MS;
        compare(Timing.scanState(1450, 1000, 3, rates, pp, null).stage, 1);
        const during = Timing.scanState(sttEnd + 10, 1000, 3, rates, pp, null);
        compare(during.stage, 2);
        compare(during.since, sttEnd);
        compare(during.p1, 1);
        const done = { stage: "done", t: 2000, stt_t: 1400, llm_t: 1500, words_in: 10 };
        const out = Timing.scanState(2000 + Timing.SCAN_FAST_FORWARD_MS + 10, 1000, 3, rates, done, null);
        compare(out.stage, 3);
        compare(out.p2, 1);
    }

    function test_idle_ends_every_scan() {
        const s = Timing.scanState(1200 + Timing.SCAN_MIN_MS, 1000, 30, rates, null, 1200);
        compare(s.stage, 3);
        compare(s.p1, 1);
    }

    function test_fold_rate_moves_thirty_percent_and_clamps_the_sample() {
        fuzzyCompare(Timing.foldRate(1, 2), 1.3, 1e-9);
        // A sample a hundred times the rate counts as four times it.
        fuzzyCompare(Timing.foldRate(1, 100), 1.9, 1e-9);
        fuzzyCompare(Timing.foldRate(1, 0), 0.775, 1e-9);
    }

    function test_learn_rates_from_a_finished_dictation() {
        const pp = { stage: "done", t: 4000, stt_t: 2000, llm_t: 2500, words_in: 10, cleaned: true, timeout: 5 };
        const next = Timing.learnRates(rates, pp, 1000, 6);
        // STT took 1 s for 6 s of audio plus the offset.
        fuzzyCompare(next.stt, Timing.foldRate(rates.stt, 1 / (6 + Timing.STT_OFFSET_SECS)), 1e-12);
        fuzzyCompare(next.llm, Timing.foldRate(rates.llm, 1.5 / (10 + Timing.LLM_OFFSET_WORDS)), 1e-12);
        compare(next.type, rates.type);
    }

    function test_a_timeout_teaches_nothing_about_the_model() {
        const pp = { stage: "done", t: 7000, stt_t: 2000, llm_t: 2000, words_in: 10, cleaned: false,
                     reason: "rejected", timeout: 5 };
        compare(Timing.learnRates(rates, pp, 1000, 6).llm, rates.llm);
    }

    function test_typed_chars_counts_words_and_spaces() {
        compare(Timing.typedChars({ lens: [3, 4, 5] }), 14);
        compare(Timing.typedChars({ lens: [], words: 5 }), 30);
        compare(Timing.typedChars(null), 0);
    }

    function test_learn_typing_ignores_implausible_samples() {
        const pp = { stage: "done", t: 0, lens: [3, 4] };
        compare(Timing.learnTyping(rates, pp, 0).type, rates.type);
        compare(Timing.learnTyping(rates, pp, 31).type, rates.type);
        verify(Timing.learnTyping(rates, pp, 1).type > rates.type);
    }

    function test_typing_without_a_final_status_is_complete() {
        compare(Timing.typingProgress(1000, null, 0, rates.type, null), 1);
        compare(Timing.typingProgress(1000, { stage: "llm", t: 0 }, 0, rates.type, null), 1);
    }

    function test_typing_is_paced_to_the_estimate_and_fast_forwards_at_idle() {
        const pp = { stage: "done", t: 1000, lens: [5, 5, 5, 5] };
        const end = Math.max(1000 + Timing.TYPE_MIN_MS,
                             1000 + rates.type * (Timing.typedChars(pp) + Timing.TYPE_OFFSET_CHARS) * 1000);
        compare(Timing.typingProgress(1000, pp, 1000, rates.type, null), 0);
        fuzzyCompare(Timing.typingProgress((1000 + end) / 2, pp, 1000, rates.type, null), 0.5, 1e-9);
        compare(Timing.typingProgress(end + 1, pp, 1000, rates.type, null), 1);
        // Idle at 1010: the rest runs out within TYPE_FAST_FORWARD_MS.
        const ff = Timing.typingProgress(1010 + Timing.TYPE_FAST_FORWARD_MS, pp, 1000, 1, 1010);
        compare(ff, 1);
    }

    function test_linger_ends_after_the_hold_or_at_the_maximum() {
        verify(!Timing.lingerOver(1000, 1000, null));
        verify(Timing.lingerOver(1000 + Timing.LINGER_MAX_MS, 1000, null));
        verify(!Timing.lingerOver(1300, 1000, 1200));
        verify(Timing.lingerOver(1200 + Timing.LINGER_HOLD_MS, 1000, 1200));
    }

    function test_a_status_from_before_the_transcription_is_stale() {
        verify(Timing.isFresh({ t: 1000 }, 1000));
        verify(Timing.isFresh({ t: 1000 - Timing.PP_STALE_MS }, 1000));
        verify(!Timing.isFresh({ t: 1000 - Timing.PP_STALE_MS - 1 }, 1000));
        verify(!Timing.isFresh(null, 1000));
        verify(!Timing.isFresh({ t: "1000" }, 1000));
    }
}
