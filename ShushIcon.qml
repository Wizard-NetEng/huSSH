import QtQuick

// Shush face: circle, two eyes, a mouth, and a finger laid vertically
// across the lips. Drawn rather than glyph-based so it inherits the theme
// colour — Nerd Font has no shushing face, and the emoji is fixed-colour.
Canvas {
    id: face
    property color strokeColor: "#e6e6e6"
    // Used to cut a gap where the finger crosses the mouth, so the two
    // shapes stay distinct. Must match whatever sits behind the icon.
    property color backgroundColor: "transparent"
    property real lw: Math.max(1, width * 0.075)

    onStrokeColorChanged: requestPaint()
    onBackgroundColorChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
        var ctx = getContext("2d");
        ctx.reset();
        var w = width, h = height;
        var cx = w / 2, cy = h / 2;
        var r = Math.min(w, h) / 2 - lw;

        ctx.strokeStyle = strokeColor;
        ctx.fillStyle = strokeColor;
        ctx.lineWidth = lw;
        ctx.lineCap = "round";
        ctx.lineJoin = "round";

        // head
        ctx.beginPath();
        ctx.arc(cx, cy, r, 0, Math.PI * 2);
        ctx.stroke();

        // eyes: open — hollow rings at larger sizes, solid dots once the ring
        // would collapse (stroke ~= radius). Same shape family either way.
        var eyeY = cy - r * 0.32;
        var eyeDX = r * 0.38;
        var eyeR = r * 0.155;
        var eyesCanBeHollow = eyeR > lw * 1.15;
        ctx.lineWidth = lw * 0.85;
        for (var s = -1; s <= 1; s += 2) {
            ctx.beginPath();
            ctx.arc(cx + s * eyeDX, eyeY, eyeR, 0, Math.PI * 2);
            if (eyesCanBeHollow) ctx.stroke(); else ctx.fill();
        }

        // mouth: a curved smile, drawn as the lower arc of a circle.
        var mouthY = cy + r * 0.06;
        var mouthR = r * 0.46;
        ctx.lineWidth = lw;
        ctx.beginPath();
        ctx.arc(cx, mouthY, mouthR, Math.PI * 0.18, Math.PI * 0.82);
        ctx.stroke();

        // shushing finger: a line rising from the very bottom of the face
        // circle, bisecting the smile, ending around mid-face. Drawn last so
        // it sits over the mouth; the background casing keeps the crossing
        // legible without erasing the smile.
        var fingerTop = cy - r * 0.02;
        var fingerBottom = cy + r;
        ctx.save();
        ctx.translate(cx, 0);
        ctx.rotate(0);
        ctx.strokeStyle = backgroundColor;
        ctx.lineWidth = lw * 1.9;
        ctx.beginPath();
        ctx.moveTo(0, fingerTop);
        ctx.lineTo(0, fingerBottom);
        ctx.stroke();
        ctx.strokeStyle = strokeColor;
        ctx.lineWidth = lw * 1.1;
        ctx.beginPath();
        ctx.moveTo(0, fingerTop);
        ctx.lineTo(0, fingerBottom);
        ctx.stroke();
        ctx.restore();
    }
}
