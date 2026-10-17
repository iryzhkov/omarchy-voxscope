import QtQuick
import QtTest
import ".."

// Card.qml without a shell: what it says at each stage, and that every text
// it draws is plain text, so nothing read from a post-process script can be
// rendered as markup.
TestCase {
    id: testCase
    name: "Card"
    width: 700
    height: 400
    when: windowShown

    QtObject {
        id: fakeHud
        property bool compact: false
        property bool reducedMotion: true
        property bool themeLight: false
        property color themeCard: "#16161e"
        property color themeAccent: "#7aa2f7"
        property color themeForeground: "#c0caf5"
        property color themeMuted: "#565f89"
        property color themeWarn: "#f7768e"
        property color themeSelection: "#33467c"
        property int stage: 0
        property bool stopWarning: false
        property real remaining: 100
        property bool silenceWarning: false
        property real silenceStopSecs: 10
        property real silentFor: 0
        property bool anyWarning: stopWarning || silenceWarning
        property real scanP1: 0
        property real scanP2: 0
        property var pp: ({})
        property bool ppFresh: false
        property real now: 0
        property real elapsed: 0
        property real stageElapsed: 0
        property bool micLit: false
        property bool voiceLit: false
        property bool clipLit: false
        property real energy: 0
        property int bands: 32
        property var level: []
        property var peak: []
        property var tape: []
        property real workSince: 0
        property var rawLens: []
        property var outLens: []
        function typingProgress() { return 1; }
    }

    Card {
        id: card
        hud: fakeHud
    }

    function init() {
        fakeHud.compact = false;
        fakeHud.stage = 0;
        fakeHud.stopWarning = false;
        fakeHud.silenceWarning = false;
        fakeHud.pp = ({});
        fakeHud.ppFresh = false;
    }

    function test_titles_follow_the_stage() {
        const titles = ["LISTENING", "TRANSCRIBING", "REFINING", "TYPING"];
        for (let i = 0; i < 4; i++) {
            fakeHud.stage = i;
            compare(card.title(), titles[i]);
        }
    }

    function test_subtitles() {
        compare(card.subtitle(), "MICROPHONE");
        fakeHud.stage = 1;
        compare(card.subtitle(), "SPEECH TO TEXT  ·  WHISPER");
        fakeHud.stage = 2;
        fakeHud.pp = { model: "qwen3:latest" };
        compare(card.subtitle(), "POST-PROCESSING  ·  QWEN3");
        fakeHud.stage = 3;
        compare(card.subtitle(), "OUTPUT");
        fakeHud.ppFresh = true;
        fakeHud.pp = { cleaned: true, model: "qwen3:4b", words: 20 };
        compare(card.subtitle(), "CLEANED BY QWEN3:4B  ·  20 WORDS");
        fakeHud.pp = { cleaned: false, reason: "disabled", words: 3 };
        compare(card.subtitle(), "LLM CLEANUP OFF  ·  3 WORDS");
        fakeHud.pp = { cleaned: false, reason: "loading" };
        compare(card.subtitle(), "MODEL WARMING UP  ·  RAW");
        fakeHud.pp = { cleaned: false };
        compare(card.subtitle(), "RAW TRANSCRIPT");
    }

    function test_warnings_take_the_subtitle() {
        fakeHud.stopWarning = true;
        fakeHud.remaining = 4.2;
        compare(card.subtitle(), "AUTO-STOP IN 5S");
        fakeHud.stopWarning = false;
        fakeHud.silenceWarning = true;
        fakeHud.silentFor = 7.5;
        compare(card.subtitle(), "NO VOICE  ·  STOPPING IN 3S");
    }

    function test_clock() {
        compare(card.fmtClock(0), "00:00.0");
        compare(card.fmtClock(75.34), "01:15.3");
        compare(card.fmtClock(600), "10:00.0");
    }

    function test_connector_lines_fill_with_the_scans() {
        fakeHud.stage = 1;
        fakeHud.scanP1 = 0.25;
        compare(card.connectorFill(1), 1);
        compare(card.connectorFill(2), 0.25);
        compare(card.connectorFill(3), 0);
        fakeHud.scanP1 = 7;
        compare(card.connectorFill(2), 1);
    }

    function test_compact_drops_the_title() {
        verify(card.implicitHeight > 200);
        fakeHud.compact = true;
        verify(card.implicitHeight < 200);
    }

    function texts(item, out) {
        for (let i = 0; i < item.children.length; i++) {
            const child = item.children[i];
            if (child.textFormat !== undefined && child.font !== undefined && child.text !== undefined)
                out.push(child);
            texts(child, out);
        }
        return out;
    }

    function test_every_text_is_plain() {
        fakeHud.stage = 3;
        fakeHud.ppFresh = true;
        fakeHud.pp = { cleaned: true, model: "<b>bold</b>", words: 2 };
        const found = texts(card, []);
        verify(found.length >= 8, "found " + found.length + " texts");
        for (let i = 0; i < found.length; i++)
            compare(found[i].textFormat, Text.PlainText, "text \"" + found[i].text + "\"");
    }
}
