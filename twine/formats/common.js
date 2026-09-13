// twine/formats/common.js — pieces several formats share.

// Split the inside of [[...]] into { label, target }.
//   [[label->target]]  rightmost ->        [[target<-label]]  leftmost <-
//   [[label|target]]   (SugarCube, Chapbook; Harlowe tolerates it too)
//   [[target]]
export function parseLink(body, pipeFirst) {
    const r = splitLink(body, pipeFirst);
    // [[->Start]]: an empty label would make an invisible link.
    if (r.label.trim() === "") r.label = r.target;
    return r;
}

function splitLink(body, pipeFirst) {
    let i;
    if (pipeFirst && (i = body.indexOf("|")) >= 0) {
        return { label: body.slice(0, i), target: body.slice(i + 1) };
    }
    if ((i = body.lastIndexOf("->")) >= 0) {
        return { label: body.slice(0, i), target: body.slice(i + 2) };
    }
    if ((i = body.indexOf("<-")) >= 0) {
        return { label: body.slice(i + 2), target: body.slice(0, i) };
    }
    if (!pipeFirst && (i = body.lastIndexOf("|")) >= 0) {
        return { label: body.slice(0, i), target: body.slice(i + 1) };
    }
    return { label: body, target: body };
}

// Index just past the "]]" closing a link opened at `start` ("[["), or -1.
export function linkEnd(text, start) {
    const end = text.indexOf("]]", start + 2);
    return end < 0 ? -1 : end + 2;
}

export function stripHtmlComments(text) {
    return text.replace(/<!--[\s\S]*?-->/g, "");
}

// Parse a duration like "2s", "500ms", "1.5 s" → milliseconds (or null).
export function parseDuration(v) {
    if (typeof v === "number") return v;
    const m = /^\s*([\d.]+)\s*(ms|s)?\s*$/i.exec(String(v));
    if (!m) return null;
    const n = parseFloat(m[1]);
    return (m[2] || "s").toLowerCase() === "ms" ? n : n * 1000;
}

// Render text that holds only [[links]] and HTML (no macros).
export function renderLinksAndHtml(engine, w, text) {
    const re = /\[\[([\s\S]*?)\]\]/g;
    let last = 0, m;
    while ((m = re.exec(text)) !== null) {
        w.markup(text.slice(last, m.index));
        const { label, target } = parseLink(m[1], true);
        engine.addLink(w, (lw) => lw.markup(label), () => engine.goto(target.trim()));
        last = re.lastIndex;
    }
    w.markup(text.slice(last));
}
