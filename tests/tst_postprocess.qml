import QtQuick
import QtTest
import "../postprocess.js" as Postprocess

// Parsing of postprocess.json (docs/postprocess-protocol.md): only the
// fields the protocol defines survive, each well-typed and in range.
TestCase {
    name: "Postprocess"

    function parse(obj) {
        return Postprocess.parse(JSON.stringify(obj));
    }

    function test_a_full_status_parses() {
        const pp = parse({ stage: "done", t: 1700000000000, stt_t: 1699999999000, llm_t: 1699999999500,
                           raw_lens: [3, 5], lens: [3, 4], words_in: 2, words: 2, timeout: 5,
                           cleaned: true, model: "qwen3:4b", reason: "ok" });
        compare(pp.stage, "done");
        compare(pp.t, 1700000000000);
        compare(pp.stt_t, 1699999999000);
        compare(pp.llm_t, 1699999999500);
        compare(pp.raw_lens, [3, 5]);
        compare(pp.lens, [3, 4]);
        compare(pp.words_in, 2);
        compare(pp.words, 2);
        compare(pp.timeout, 5);
        compare(pp.cleaned, true);
        compare(pp.model, "qwen3:4b");
        compare(pp.reason, "ok");
    }

    function test_what_is_not_a_status_is_refused() {
        compare(Postprocess.parse(""), null);
        compare(Postprocess.parse("not json"), null);
        compare(Postprocess.parse("[1, 2]"), null);
        compare(Postprocess.parse("null"), null);
        compare(Postprocess.parse(42), null);
        compare(parse({ stage: "other", t: 1 }), null);
        compare(parse({ stage: "done" }), null);
        compare(parse({ stage: "done", t: -1 }), null);
        compare(parse({ stage: "done", t: 1e16 }), null);
    }

    function test_an_oversized_file_is_refused() {
        const big = JSON.stringify({ stage: "done", t: 1, model: "x".repeat(Postprocess.MAX_CHARS) });
        compare(Postprocess.parse(big), null);
    }

    function test_out_of_range_fields_are_dropped() {
        const pp = parse({ stage: "llm", t: 1, stt_t: "5", llm_t: Infinity, words_in: 2e6, words: -1,
                           timeout: 4000, cleaned: "yes" });
        verify(pp !== null);
        verify(pp.stt_t === undefined);
        verify(pp.llm_t === undefined);
        verify(pp.words_in === undefined);
        verify(pp.words === undefined);
        verify(pp.timeout === undefined);
        verify(pp.cleaned === undefined);
    }

    function test_word_lengths_are_capped_and_cleaned() {
        const many = [];
        for (let i = 0; i < 1000; i++) many.push(4);
        compare(parse({ stage: "start", t: 1, raw_lens: many }).raw_lens.length, Postprocess.MAX_WORDS);
        compare(parse({ stage: "start", t: 1, raw_lens: [2.6, -1, "3", 5000, null, 7] }).raw_lens, [3, 7]);
        compare(parse({ stage: "start", t: 1, raw_lens: "3,4" }).raw_lens, []);
    }

    function test_reason_is_whitelisted() {
        const reasons = ["ok", "rejected", "loading", "unreachable", "disabled"];
        for (let i = 0; i < reasons.length; i++)
            compare(parse({ stage: "done", t: 1, reason: reasons[i] }).reason, reasons[i]);
        verify(parse({ stage: "done", t: 1, reason: "something else" }).reason === undefined);
        verify(parse({ stage: "done", t: 1, reason: 3 }).reason === undefined);
    }

    function test_model_is_printable_and_short() {
        compare(parse({ stage: "llm", t: 1, model: "hf.co/org/model:Q4_K_M" }).model, "hf.co/org/model:Q4_K_M");
        verify(parse({ stage: "llm", t: 1, model: "a\nb" }).model === undefined);
        verify(parse({ stage: "llm", t: 1, model: "" }).model === undefined);
        verify(parse({ stage: "llm", t: 1, model: "m".repeat(129) }).model === undefined);
        verify(parse({ stage: "llm", t: 1, model: null }).model === undefined);
    }

    function test_only_own_fields_count() {
        // JSON.parse makes "__proto__" an ordinary own key; nothing behind it
        // may be read as a field.
        compare(Postprocess.parse('{"__proto__": {"stage": "done", "t": 1}}'), null);
        const pp = Postprocess.parse('{"stage": "done", "t": 1, "__proto__": {"model": "evil"}}');
        verify(pp !== null);
        verify(pp.model === undefined);
    }
}
