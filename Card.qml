// The Voxscope card: everything the HUD draws, read off `hud` (Hud.qml).
//
// Each stage of the dictation pipeline has its own visualisation:
//   REC  a mirrored live spectrum of the mic in the same square cells as
//        the STT scan, with held peaks as brighter cells; meanwhile the
//        loudness is recorded as a timeline, one column per 100 ms
//   STT  the whole recording's timeline, drawn as a soft analog envelope,
//        with a scan line sweeping across it; behind the line the columns
//        are rebuilt from square cells
//   LLM  a second scan line over those cells, turning them into blocks the
//        length of the transcript's words
//   OUT  the words typed out as runs of cells behind a block cursor; the
//        subtitle gives the word count and whether the LLM cleaned the text
// A stepper across the top and a progress bar along the bottom track the
// same stages.
//
// Only the visualisation glows; the text and the stepper stay crisp. The
// visualisation is drawn on a grid of whole device pixels, and its layer
// sits on whole device pixels too, so cell edges stay sharp at fractional
// scaling.
//
// Colour comes from the active Omarchy theme, which Hud.qml re-reads each
// time the HUD appears. Everything is drawn in the theme's accent, mixed
// towards the background or the text; light themes mix further, because
// a pale tint of the accent all but vanishes on a light card. The type is
// the system monospace font (fontconfig's "monospace", which
// `omarchy font set` points at the chosen font).

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Window

Item {
    id: card

    // The Hud.qml instance whose state this card draws.
    property var hud: null

    // Device pixels per logical pixel on the screen the card is on.
    readonly property real dpr: Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1
    // A logical length or position rounded to whole device pixels.
    function snap(v) {
        return Math.round(v * dpr) / dpr;
    }

    implicitWidth: snap(580)
    implicitHeight: snap(268)

    function mix(a, b, t) {
        return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t,
                       a.b + (b.b - a.b) * t, 1);
    }

    readonly property bool light: hud.themeLight
    readonly property color cBg: hud.themeCard
    readonly property color cDim: mix(cBg, hud.themeAccent, light ? 0.3 : 0.2)
    readonly property color cMid: mix(cBg, hud.themeAccent, light ? 0.65 : 0.55)
    readonly property color cAccent: hud.themeAccent
    readonly property color cHot: mix(hud.themeAccent, hud.themeForeground, light ? 0.35 : 0.5)
    readonly property color cText: hud.themeForeground
    // Themes' muted colour is meant for borders and is too faint for
    // labels, more so on light themes.
    readonly property color cMuted: mix(hud.themeMuted, hud.themeForeground, light ? 0.45 : 0.25)
    readonly property color cWarn: hud.themeWarn
    readonly property color cLane: hud.themeSelection
    // Opacity of the cells left behind the LLM scan.
    readonly property real ghostAlpha: light ? 0.24 : 0.16
    readonly property string fontFamily: "monospace"

    readonly property int stage: hud.stage

    // The padding round the card's contents, and what the visualisation
    // leaves at the bottom for the progress bar.
    readonly property real pad: 24
    readonly property real footer: 15

    function repaint() {
        viz.requestPaint();
        progress.requestPaint();
        brackets.requestPaint();
    }

    function fmtClock(secs) {
        const tenths = Math.floor(secs * 10);
        const s = Math.floor(tenths / 10);
        const m = Math.floor(s / 60);
        return (m < 10 ? "0" : "") + m + ":" + (s % 60 < 10 ? "0" : "") + (s % 60) + "." + (tenths % 10);
    }

    function modelName() {
        return String(hud.pp.model || "llm").replace(/:latest$/, "");
    }

    function title() {
        return ["LISTENING", "TRANSCRIBING", "REFINING", "TYPING"][stage];
    }

    function subtitle() {
        if (hud.stopWarning) return "AUTO-STOP IN " + Math.max(0, Math.ceil(hud.remaining)) + "S";
        if (hud.silenceWarning) return "NO VOICE  ·  STOPPING IN " + Math.max(0, Math.ceil(hud.silenceStopSecs - hud.silentFor)) + "S";
        if (stage === 0) return "MICROPHONE";
        if (stage === 1) return "SPEECH TO TEXT  ·  WHISPER";
        if (stage === 2) return "POST-PROCESSING  ·  " + modelName().toUpperCase();
        if (!hud.ppFresh) return "OUTPUT";
        const pp = hud.pp;
        const words = typeof pp.words === "number" ? "  ·  " + pp.words + " WORDS" : "";
        if (pp.cleaned) return "CLEANED BY " + modelName().toUpperCase() + words;
        if (pp.reason === "disabled") return "LLM CLEANUP OFF" + words;
        if (pp.reason === "loading") return "MODEL WARMING UP  ·  RAW" + words;
        return "RAW TRANSCRIPT" + words;
    }

    function css(c, a) {
        return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + ","
            + Math.round(c.b * 255) + "," + (a === undefined ? 1 : a) + ")";
    }

    component Label: Text {
        textFormat: Text.PlainText
        font.family: card.fontFamily
        font.pixelSize: 12
        font.letterSpacing: 2
        color: card.cMuted
    }

    Rectangle {
        anchors.fill: parent
        radius: 6
        color: card.cBg
        border.width: card.snap(1)
        border.color: card.cDim
    }

    // The text and the stepper, drawn as they are.
    Item {
        id: chrome
        anchors.fill: parent
        anchors.margins: card.pad

        // Stepper: REC - STT - LLM - OUT.
        Row {
            id: stepper
            anchors.left: parent.left
            anchors.top: parent.top
            spacing: 0
            Repeater {
                model: ["REC", "STT", "LLM", "OUT"]
                Row {
                    id: step
                    required property int index
                    required property string modelData
                    spacing: 8
                    Rectangle {
                        visible: step.index > 0
                        width: 22
                        height: 1
                        anchors.verticalCenter: parent.verticalCenter
                        color: step.index <= card.stage ? card.cAccent : card.cDim
                    }
                    Rectangle {
                        width: 9
                        height: 9
                        radius: 4.5
                        anchors.verticalCenter: parent.verticalCenter
                        color: step.index < card.stage ? card.cAccent
                            : step.index === card.stage ? card.cHot
                            : "transparent"
                        border.width: 1
                        border.color: step.index <= card.stage ? card.cAccent : card.cDim
                        opacity: step.index === card.stage && card.stage < 3
                            ? 0.55 + 0.45 * Math.abs(Math.sin(card.hud.now / 320)) : 1
                    }
                    Label {
                        text: step.modelData
                        anchors.verticalCenter: parent.verticalCenter
                        font.bold: step.index === card.stage
                        color: step.index === card.stage ? card.cText
                            : step.index < card.stage ? card.cAccent
                            : card.cMuted
                    }
                    Item { width: 4; height: 1 }
                }
            }
        }

        Label {
            anchors.right: parent.right
            anchors.verticalCenter: stepper.verticalCenter
            text: card.fmtClock(card.stage === 0 ? card.hud.elapsed : card.hud.stageElapsed)
            font.pixelSize: 13
            color: card.hud.stopWarning ? card.cWarn : card.cText
        }

        Text {
            id: titleText
            anchors.left: parent.left
            anchors.top: stepper.bottom
            anchors.topMargin: 14
            textFormat: Text.PlainText
            text: card.title()
            font.family: card.fontFamily
            font.pixelSize: 26
            font.bold: true
            font.letterSpacing: 5
            color: card.cHot
        }

        Label {
            id: subtitleText
            anchors.left: parent.left
            anchors.top: titleText.bottom
            anchors.topMargin: 2
            text: card.subtitle()
            color: card.hud.anyWarning ? card.cWarn : card.cMuted
            font.bold: card.hud.anyWarning
        }

        // Indicator lights while recording: input alive, voice heard (held
        // so it doesn't flicker word to word), and clipping.
        Row {
            visible: card.stage === 0
            anchors.right: parent.right
            anchors.verticalCenter: subtitleText.verticalCenter
            spacing: 14
            Repeater {
                model: [
                    { name: "MIC", key: "mic" },
                    { name: "VOICE", key: "voice" },
                    { name: "CLIP", key: "clip" }
                ]
                Row {
                    required property var modelData
                    readonly property bool lit: modelData.key === "mic" ? card.hud.micLit
                        : modelData.key === "voice" ? card.hud.voiceLit
                        : card.hud.clipLit
                    readonly property color litColor: modelData.key === "clip" ? card.cWarn : card.cHot
                    spacing: 6
                    Rectangle {
                        width: 7
                        height: 7
                        radius: 1
                        anchors.verticalCenter: parent.verticalCenter
                        color: parent.lit ? parent.litColor : "transparent"
                        border.width: 1
                        border.color: parent.lit ? parent.litColor : card.cDim
                        Behavior on color { ColorAnimation { duration: 120 } }
                    }
                    Label {
                        text: parent.modelData.name
                        anchors.verticalCenter: parent.verticalCenter
                        font.pixelSize: 11
                        color: parent.lit ? card.cText : card.cMuted
                    }
                }
            }
        }

        // Progress, hidden while recording: the current scan's position
        // while transcribing and refining, full when done.
        Canvas {
            id: progress
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 3
            renderStrategy: Canvas.Cooperative

            onPaint: {
                const ctx = getContext("2d");
                ctx.reset();
                if (!card.hud) return;
                const hud = card.hud;
                const w = width;
                const h = height;
                // No bar while recording, so it doesn't read as a
                // countdown, until the last seconds before voxtype's cap or
                // the silence auto-stop, when it drains to zero.
                if (card.stage === 0) {
                    const left = hud.stopWarning ? hud.remaining / 10
                        : hud.silenceWarning ? (hud.silenceStopSecs - hud.silentFor) / 5
                        : -1;
                    if (left >= 0) {
                        ctx.fillStyle = card.css(card.cDim);
                        ctx.fillRect(0, 0, w, h);
                        ctx.fillStyle = card.css(card.cWarn);
                        ctx.fillRect(0, 0, Math.max(0, Math.min(1, left)) * w, h);
                    }
                    return;
                }
                ctx.fillStyle = card.css(card.cDim);
                ctx.fillRect(0, 0, w, h);

                const to = Math.min(w, card.stage === 1 ? hud.scanP1 * w
                    : card.stage === 2 ? hud.scanP2 * w
                    : w);
                if (to > 0) {
                    const g = ctx.createLinearGradient(0, 0, to, 0);
                    g.addColorStop(0, card.css(card.cAccent));
                    g.addColorStop(1, card.css(card.cHot));
                    ctx.fillStyle = g;
                    ctx.fillRect(0, 0, to, h);
                }
            }
        }
    }

    // The visualisation, drawn into its own layer on whole device pixels;
    // the MultiEffect below draws it again with a soft bloom.
    Item {
        id: glow
        x: card.snap(card.pad)
        y: card.snap(card.pad + subtitleText.y + subtitleText.height + 12)
        width: card.snap(card.width - 2 * card.pad)
        height: card.snap(card.height - card.pad - card.footer) - y
        layer.enabled: true
        visible: false

        Canvas {
            id: viz
            anchors.fill: parent
            renderStrategy: Canvas.Cooperative

            // Everything below is in device pixels: onPaint scales the
            // context to them, and every length is a whole number of them.
            readonly property real d: card.dpr
            function u(v) {
                return Math.max(1, Math.round(v * d));
            }

            // The cell grid shared by the live spectrum and the scans:
            // square cells cellW wide and cell tall, colPitch and pitch
            // apart, mirrored about the midline. A column of n rows is one
            // cell centred on the midline with n - 1 above and below it,
            // so a silent column is the centre cell alone.
            readonly property int gap: u(2)
            readonly property int cellW: Math.max(2, Math.round(5 * d))
            readonly property int colPitch: cellW + gap
            readonly property int cell: Math.max(2, Math.round(6 * d))
            readonly property int pitch: cell + gap

            // How many rows a column can have in height h, centre included.
            function rowsFor(h) {
                return Math.max(1, Math.floor(((h + gap) / pitch + 1) / 2));
            }

            // The top of the centre row in height h.
            function centreTop(h) {
                return Math.floor((h - cell) / 2);
            }

            // The midline, through the middle of the centre row.
            function drawMidline(ctx, w, h) {
                ctx.fillStyle = card.css(card.cDim);
                ctx.fillRect(0, centreTop(h) + Math.floor((cell - u(1)) / 2), w, u(1));
            }

            // Row j of a column at x: the centre cell for j = 0, otherwise
            // the pair j rows above and below it.
            function fillCellPair(ctx, x, wd, top, j) {
                if (j === 0) {
                    ctx.fillRect(x, top, wd, cell);
                    return;
                }
                ctx.fillRect(x, top - j * pitch, wd, cell);
                ctx.fillRect(x, top + j * pitch, wd, cell);
            }

            // Recording: the live spectrum in the scans' cells. Each band is
            // a column two cells wide, lit to its level, with its held peak
            // as one brighter cell at the top and bottom.
            function drawSpectrum(ctx, w, h) {
                const hud = card.hud;
                const n = hud.bands;
                const sub = 2;
                const bandW = sub * colPitch - gap;
                const bandGap = Math.max(gap, Math.floor((w - n * bandW) / Math.max(1, n - 1)));
                const left = Math.floor((w - (n * bandW + (n - 1) * bandGap)) / 2);
                const top = centreTop(h);
                const rows = rowsFor(h);

                drawMidline(ctx, w, h);

                for (let i = 0; i < n; i++) {
                    const x = left + i * (bandW + bandGap);
                    const count = Math.max(1, Math.min(rows, Math.round((hud.level[i] || 0) * rows)));
                    const pk = hud.peak[i] || 0;
                    // A peak in the centre row would only light the resting
                    // cell, so it is not shown.
                    const pkRow = Math.min(rows, Math.round(pk * rows)) - 1;
                    for (let j = 0; j < Math.max(count, pkRow + 1); j++) {
                        if (j === pkRow && j > 0) ctx.fillStyle = card.css(card.cHot);
                        else if (j < count) ctx.fillStyle = card.css(card.cAccent, 0.85);
                        else continue;
                        for (let k = 0; k < sub; k++) fillCellPair(ctx, x + k * colPitch, cellW, top, j);
                    }
                }
            }

            // The recording's timeline resampled to `n` columns, each the
            // loudest 100 ms in its slice, normalised to the loudest column
            // so quiet recordings still fill the height.
            function envelope(n) {
                const tape = card.hud.tape;
                const out = new Array(n).fill(0);
                if (tape.length === 0) return out;
                let top = 0.15;
                for (let i = 0; i < n; i++) {
                    const a = Math.floor(i * tape.length / n);
                    const b = Math.max(a + 1, Math.floor((i + 1) * tape.length / n));
                    let v = 0;
                    for (let k = a; k < b && k < tape.length; k++) v = Math.max(v, tape[k]);
                    out[i] = v;
                    top = Math.max(top, v);
                }
                for (let i = 0; i < n; i++) out[i] = out[i] / top;
                return out;
            }

            // Word blocks for the LLM scan: the transcript's words laid out
            // along the width, wrapped onto more lines when there are too
            // many to stay legible on one, centred on the centre row.
            function wordLayout(lens, w, h) {
                let total = 0;
                for (let i = 0; i < lens.length; i++) total += lens[i] + 1;
                const lines = Math.max(1, Math.ceil(total * u(2) / w));
                const unit = Math.min(u(6), w * lines / Math.max(1, total) * 0.95);
                const barH = lines === 1 ? cell : Math.max(u(2), Math.min(cell, Math.floor(h * 0.7 / lines) - gap));
                const pitchY = barH + (lines === 1 ? 0 : gap);
                const blocks = [];
                let x = 0;
                let line = 0;
                for (let i = 0; i < lens.length; i++) {
                    const bw = Math.max(1, lens[i] * unit - u(1));
                    if (x > 0 && x + bw > w) {
                        x = 0;
                        line++;
                    }
                    const left = Math.round(x);
                    blocks.push({ x: left, line: line, w: Math.max(1, Math.round(x + bw) - left) });
                    x += bw + u(1) + unit;
                }
                const top = centreTop(h) + Math.round((cell - ((line + 1) * pitchY - (pitchY - barH))) / 2);
                for (let i = 0; i < blocks.length; i++) blocks[i].y = top + blocks[i].line * pitchY;
                return { blocks: blocks, barH: barH };
            }

            // Speech to text and LLM: the recording's timeline with scan
            // lines over it. Ahead of the STT line the recording is a soft
            // analog envelope; behind it, columns of square cells. Behind
            // the LLM line those cells fade to a ghost under blocks the
            // length of the transcript's words.
            function drawScan(ctx, w, h, t) {
                const hud = card.hud;
                const n = Math.max(1, Math.floor((w + gap) / colPitch));
                const top = centreTop(h);
                const cy = top + cell / 2;
                const rows = rowsFor(h);
                const half = h / 2 - u(3);
                const env = envelope(n);
                const grow = Math.min(1, (t - hud.workSince) / 220);
                const x1 = Math.round(hud.scanP1 * w);
                const x2 = card.stage === 2 ? Math.round(hud.scanP2 * w) : -1;

                drawMidline(ctx, w, h);

                // Each scan line trails a lane in the theme's selection
                // colour, behind what it passes over.
                const lane = function(x) {
                    ctx.fillStyle = card.css(card.cLane, 0.85);
                    ctx.fillRect(x - u(10), 0, u(12), h);
                };
                if (card.stage === 1 && x1 < w) lane(x1);
                if (x2 >= 0 && x2 < w) lane(x2);

                // Analog envelope, right of the STT line.
                if (x1 < w) {
                    ctx.save();
                    ctx.beginPath();
                    ctx.rect(x1, 0, w - x1, h);
                    ctx.clip();
                    const px = function(i) { return i * colPitch + cellW / 2; };
                    const amp = function(i) { return Math.max(d, env[i] * half * grow); };
                    ctx.beginPath();
                    ctx.moveTo(0, cy);
                    for (let i = 0; i < n; i++) {
                        const j = Math.min(n - 1, i + 1);
                        ctx.quadraticCurveTo(px(i), cy - amp(i), (px(i) + px(j)) / 2, cy - (amp(i) + amp(j)) / 2);
                    }
                    ctx.lineTo(w, cy);
                    for (let i = n - 1; i >= 0; i--) {
                        const j = Math.max(0, i - 1);
                        ctx.quadraticCurveTo(px(i), cy + amp(i), (px(i) + px(j)) / 2, cy + (amp(i) + amp(j)) / 2);
                    }
                    ctx.closePath();
                    const grad = ctx.createLinearGradient(0, cy - half, 0, cy + half);
                    grad.addColorStop(0, card.css(card.cMid, 0.25));
                    grad.addColorStop(0.5, card.css(card.cAccent, 0.45));
                    grad.addColorStop(1, card.css(card.cMid, 0.25));
                    ctx.fillStyle = grad;
                    ctx.fill();
                    ctx.lineWidth = 1.2 * d;
                    ctx.strokeStyle = card.css(card.cAccent, 0.7);
                    ctx.stroke();
                    ctx.restore();
                }

                // Digital cells, left of the STT line; ghosted behind the
                // LLM line.
                for (let i = 0; i < n; i++) {
                    const x = i * colPitch;
                    if (x + cellW > x1) break;
                    const count = Math.max(1, Math.round(env[i] * rows));
                    const behind2 = x + cellW <= x2;
                    const near = (x1 - x) / colPitch < 3 && card.stage === 1;
                    ctx.fillStyle = behind2 ? card.css(card.cAccent, card.ghostAlpha)
                        : near ? card.css(card.cHot) : card.css(card.cAccent, 0.85);
                    for (let j = 0; j < count; j++) fillCellPair(ctx, x, cellW, top, j);
                }

                // Word blocks, left of the LLM line.
                if (x2 > 0) {
                    const lens = hud.rawLens;
                    const lay = wordLayout(lens, w, h);
                    for (let i = 0; i < lay.blocks.length; i++) {
                        const b = lay.blocks[i];
                        if (b.x >= x2) continue;
                        const bw = Math.min(b.w, x2 - b.x);
                        ctx.fillStyle = x2 - b.x < u(24) ? card.css(card.cText) : card.css(card.cHot);
                        ctx.fillRect(b.x, b.y, bw, lay.barH);
                    }
                }

                // Scan lines: a bright edge at the front of each lane.
                const line = function(x, colour) {
                    ctx.fillStyle = card.css(colour);
                    ctx.fillRect(x - u(1), 0, u(2), h);
                };
                if (card.stage === 1 && x1 < w) line(x1, card.cHot);
                if (x2 >= 0 && x2 < w) line(x2, card.cText);
            }

            // Output: the words being typed, as blocks. Each word is a run
            // of square cells as long as the typed word (or a random length
            // when the post-process script reported none), laid out in lines
            // behind a block cursor that scrolls the lines up when they
            // fill. It is paced to end with voxtype's real typing.
            function drawTyping(ctx, w, h, t) {
                const hud = card.hud;
                const cell = u(8);
                const pitch = cell + u(3);
                const lineGap = u(8);
                const linePitch = cell + lineGap;
                const cols = Math.floor(w / pitch);
                const visibleLines = Math.max(1, Math.floor((h + lineGap) / linePitch));
                const lens = hud.ppFresh && hud.outLens.length > 0 ? hud.outLens : null;
                const words = lens ? lens.length
                    : Math.max(1, hud.ppFresh && typeof hud.pp.words === "number" ? Math.min(400, hud.pp.words) : 12);
                const rnd = function(a) {
                    const x = Math.sin(a * 91.7 + 13.3) * 43758.5453;
                    return x - Math.floor(x);
                };

                // Lay the words out into cell positions.
                const layout = [];
                let col = 0;
                let line = 0;
                for (let i = 0; i < words; i++) {
                    const len = lens ? Math.max(1, Math.min(cols, Math.round(lens[i] * 0.7)))
                                     : 2 + Math.floor(rnd(i) * 6);
                    if (col > 0 && col + len > cols) {
                        col = 0;
                        line++;
                    }
                    for (let c = 0; c < len; c++) layout.push({ col: col + c, line: line });
                    col += len + 1;
                }

                const shown = Math.min(layout.length, Math.floor(hud.typingProgress() * layout.length));
                const cur = shown < layout.length ? layout[shown]
                    : { col: Math.min(cols - 1, col), line: line };
                const firstLine = Math.max(0, cur.line - visibleLines + 1);
                const usedLines = Math.min(visibleLines, line + 1);
                const top = Math.round((h - (usedLines * linePitch - lineGap)) / 2);

                for (let k = 0; k < shown; k++) {
                    const p = layout[k];
                    if (p.line < firstLine) continue;
                    const age = shown - k;
                    ctx.fillStyle = age < 6 ? card.css(card.cHot) : card.css(card.cAccent, 0.55 + 0.45 * Math.max(0, 1 - age / 60));
                    ctx.fillRect(p.col * pitch, top + (p.line - firstLine) * linePitch, cell, cell);
                }

                // Block cursor: solid while typing, blinking once done.
                const done = shown >= layout.length;
                if (!done || Math.floor(t / 450) % 2 === 0) {
                    ctx.fillStyle = card.css(card.cHot);
                    ctx.fillRect(cur.col * pitch, top + (cur.line - firstLine) * linePitch - u(2), cell, cell + u(4));
                }
            }

            onPaint: {
                const ctx = getContext("2d");
                ctx.reset();
                if (!card.hud) return;
                ctx.scale(1 / d, 1 / d);
                const w = Math.round(width * d);
                const h = Math.round(height * d);
                const t = card.hud.now;
                if (card.stage === 0) drawSpectrum(ctx, w, h);
                else if (card.stage <= 2) drawScan(ctx, w, h, t);
                else drawTyping(ctx, w, h, t);
            }
        }
    }

    MultiEffect {
        source: glow
        x: glow.x
        y: glow.y
        width: glow.width
        height: glow.height
        // Padding of whole device pixels, so the layer is not resampled.
        autoPaddingEnabled: false
        paddingRect: Qt.rect(card.snap(20), card.snap(20), card.snap(20), card.snap(20))
        shadowEnabled: true
        shadowColor: card.cAccent
        shadowBlur: 0.45
        // A glow on a light card reads as a smudge, so it is fainter.
        shadowOpacity: card.light ? 0.3 : 0.55
        shadowHorizontalOffset: 0
        shadowVerticalOffset: 0
        blurMax: 20
    }

    // Faint scanlines, on dark themes only: on a light card they read as
    // grey stripes. One device pixel in every three.
    Canvas {
        anchors.fill: parent
        anchors.margins: card.snap(1)
        visible: !card.light
        opacity: 0.12
        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            const d = card.dpr;
            ctx.scale(1 / d, 1 / d);
            const w = Math.round(width * d);
            const h = Math.round(height * d);
            const step = Math.max(2, Math.round(3 * d));
            const line = Math.max(1, Math.round(d));
            ctx.fillStyle = "#000000";
            for (let y = 0; y < h; y += step) ctx.fillRect(0, y, w, line);
        }
    }

    // HUD corner brackets, brightening with the voice.
    Canvas {
        id: brackets
        anchors.fill: parent
        anchors.margins: -card.snap(5)
        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            if (!card.hud) return;
            const hud = card.hud;
            const d = card.dpr;
            ctx.scale(1 / d, 1 / d);
            const w = Math.round(width * d);
            const h = Math.round(height * d);
            const L = Math.round(18 * d);
            // A stroke of whole device pixels, centred so its edges land
            // on pixel boundaries.
            const lw = Math.max(1, Math.round(2 * d));
            const o = lw / 2;
            const c = hud.anyWarning ? card.cWarn : card.cAccent;
            const a = hud.anyWarning ? (Math.floor(hud.now / 400) % 2 ? 1.0 : 0.35)
                : card.stage === 0 ? 0.5 + 0.5 * Math.min(1, hud.energy * 3) : 0.8;
            ctx.strokeStyle = card.css(c, a);
            ctx.lineWidth = lw;
            ctx.beginPath();
            ctx.moveTo(o, L); ctx.lineTo(o, o); ctx.lineTo(L, o);
            ctx.moveTo(w - L, o); ctx.lineTo(w - o, o); ctx.lineTo(w - o, L);
            ctx.moveTo(w - o, h - L); ctx.lineTo(w - o, h - o); ctx.lineTo(w - L, h - o);
            ctx.moveTo(L, h - o); ctx.lineTo(o, h - o); ctx.lineTo(o, h - L);
            ctx.stroke();
        }
    }
}
