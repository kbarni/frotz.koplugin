// twine/writer.js — builds the styled text of a passage.
//
// Formats turn their markup into calls on a Writer: text with the current style,
// HTML tags, links, and named regions. The result is a flat list of runs
//   { text, style, link }          style = a Glk style name, link = id or 0
//   { mark: "open"|"close", region }  zero-width region boundaries
// Regions are how "change the page later" works without a DOM: a revealed link,
// a Harlowe named hook, a SugarCube <<replace "#id">> target, a timed insert —
// each is a region whose runs the engine can splice.

import { decodeEntities, parseAttrs } from "./extract.js";

const VOID = new Set(["br", "hr", "img", "input", "meta", "link", "source", "wbr",
    "col", "area", "embed", "track", "param", "base"]);
// Content we can't show at all.
const HIDE = new Set(["audio", "video", "iframe", "svg", "canvas", "object",
    "noscript", "template", "select", "textarea", "head", "title"]);
// Their content is not markup; skip it verbatim.
const RAW = new Set(["script", "style"]);
// Block elements: a blank line around PARA, a line break around LINE.
const PARA = new Set(["p", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6",
    "ul", "ol", "table", "pre", "dl"]);
const LINE = new Set(["div", "li", "tr", "section", "article", "header", "footer",
    "center", "dd", "dt", "figure", "figcaption", "nav", "aside", "main", "tw-align",
    "tw-column", "tw-dialog"]);

export class Writer {
    // base: a style snapshot to start from (a region re-rendered in place keeps
    // the look of where it sits).
    constructor(engine, base) {
        this.engine = engine;
        this.runs = [];
        this.st = { bold: 0, italic: 0, header: 0, sub: 0, pre: 0, quote: 0, hidden: 0, collapse: 0 };
        if (base) Object.assign(this.st, base);
        this.link = 0;
        this.tags = [];
    }

    snapshot() { return Object.assign({}, this.st); }

    style() {
        const s = this.st;
        if (s.header) return "header";
        if (s.sub) return "subheader";
        if (s.bold) return "alert";          // the plugin draws alert as bold
        if (s.italic) return "emphasized";   // …and emphasized as italic
        if (s.pre) return "preformatted";
        if (s.quote) return "blockquote";
        return "normal";
    }

    _push(text, link) {
        const style = this.style();
        const last = this.runs[this.runs.length - 1];
        if (last && last.mark === undefined && last.style === style && last.link === link) {
            last.text += text;
        } else {
            this.runs.push({ text, style, link });
        }
    }

    // Literal text (already free of markup and entities).
    text(t) {
        if (t === undefined || t === null || this.st.hidden > 0) return;
        t = String(t);
        if (this.st.collapse > 0) {
            // Harlowe {…} / SugarCube <<nobr>>: whitespace runs become one space.
            t = t.replace(/\s+/g, " ");
            if (t[0] === " " && this._endsWithSpace()) t = t.slice(1);
        }
        if (t !== "") this._push(t, this.link);
    }

    _endsWithSpace() {
        for (let i = this.runs.length - 1; i >= 0; i--) {
            const r = this.runs[i];
            if (r.mark !== undefined || r.text === "") continue;
            return /\s$/.test(r.text);
        }
        return true;
    }

    // A structural newline never belongs to a link (it would be underlined).
    // force: an explicit <br>, which survives whitespace collapsing.
    newline(force) {
        if (this.st.hidden > 0) return;
        if (this.st.collapse > 0 && !force) {
            this.text(" ");
            return;
        }
        this._push("\n", 0);
    }

    // Newlines at the end of what is written so far; -1 when nothing visible yet.
    trailingNewlines() {
        let n = 0;
        for (let i = this.runs.length - 1; i >= 0; i--) {
            const r = this.runs[i];
            if (r.mark !== undefined) continue;
            for (let j = r.text.length - 1; j >= 0; j--) {
                const c = r.text[j];
                if (c === "\n") n++;
                else if (c !== " " && c !== "\t") return n;
            }
        }
        return -1;
    }

    lineBreak() {
        if (this.st.hidden > 0) return;
        if (this.trailingNewlines() === 0) this._push("\n", 0);
    }

    paragraph() {
        if (this.st.hidden > 0) return;
        const n = this.trailingNewlines();
        if (n >= 0 && n < 2) this._push("\n".repeat(2 - n), 0);
    }

    error(message) {
        const prev = this.link;
        this.link = 0;
        this.st.bold++;
        this.text("[" + message + "]");
        this.st.bold--;
        this.link = prev;
    }

    beginStyle(key) { this.st[key]++; }
    endStyle(key) { if (this.st[key] > 0) this.st[key]--; }

    beginLink(id) {
        const prev = this.link;
        this.link = id;
        return prev;
    }
    endLink(prev) { this.link = prev || 0; }

    openRegion(names) {
        const id = this.engine.newRegion(names || [], this.snapshot());
        this.runs.push({ mark: "open", region: id });
        return id;
    }
    closeRegion(id) {
        this.runs.push({ mark: "close", region: id });
    }

    // Text that may contain HTML tags and entities.
    markup(s) {
        if (s === undefined || s === null || s === "") return;
        s = String(s);
        if (s.indexOf("<") < 0) {
            this.text(decodeEntities(s));
            return;
        }
        const re = /<!--[\s\S]*?-->|<(\/?)([a-zA-Z][\w-]*)((?:\s+[^\s"'>\/=]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>"']+))?)*)\s*(\/?)>/g;
        let last = 0, m;
        while ((m = re.exec(s)) !== null) {
            if (m.index > last) this.text(decodeEntities(s.slice(last, m.index)));
            last = re.lastIndex;
            if (m[2] === undefined) continue;             // comment
            const name = m[2].toLowerCase();
            if (m[1]) {
                this.closeTag(name);
                continue;
            }
            if (RAW.has(name) && !m[4]) {
                const end = s.toLowerCase().indexOf("</" + name, last);
                const gt = end < 0 ? -1 : s.indexOf(">", end);
                last = gt < 0 ? s.length : gt + 1;
                re.lastIndex = last;
                continue;
            }
            this.openTag(name, parseAttrs(m[3] || ""), !!m[4]);
        }
        if (last < s.length) this.text(decodeEntities(s.slice(last)));
    }

    openTag(name, attrs, selfClosing) {
        const st = this.st;
        if (name === "br") { this.newline(true); return; }
        if (name === "hr") {
            this.lineBreak();
            this.text("\u2014 \u2014 \u2014");
            this.newline();
            return;
        }
        if (name === "img") {
            const alt = (attrs.alt || attrs.title || "").trim();
            if (alt) this.text("[" + alt + "]");
            return;
        }
        if (VOID.has(name) || selfClosing) return;

        const undo = [];
        const hidden = HIDE.has(name) || "hidden" in attrs
            || /display\s*:\s*none|visibility\s*:\s*hidden/i.test(attrs.style || "");
        if (hidden) { st.hidden++; undo.push(() => { st.hidden--; }); }
        if (PARA.has(name)) {
            this.paragraph();
            undo.push(() => this.paragraph());
        } else if (LINE.has(name)) {
            this.lineBreak();
            undo.push(() => this.lineBreak());
        }
        const bump = (key) => { st[key]++; undo.push(() => { st[key]--; }); };
        switch (name) {
            case "b": case "strong": bump("bold"); break;
            case "i": case "em": case "cite": case "var": case "dfn": bump("italic"); break;
            case "h1": case "h2": case "h3": bump("header"); break;
            case "h4": case "h5": case "h6": bump("sub"); break;
            case "pre": case "code": case "tt": case "kbd": case "samp": bump("pre"); break;
            case "blockquote": bump("quote"); break;
            case "li": this.text("\u2022\u00a0"); break;
            case "td": case "th": this.text(" "); break;
        }

        // Twine links written as HTML: SugarCube's data-passage (on any element),
        // or a plain <a href> that names a passage.
        let target = attrs["data-passage"];
        if (target === undefined && name === "a" && attrs.href
                && !/^(?:[a-z][\w+.-]*:|#|\/|\.)/i.test(attrs.href)
                && this.engine.passage(attrs.href)) {
            target = attrs.href;
        }
        if (target !== undefined) {
            const id = this.engine.htmlLink(target, attrs);
            if (id) {
                const prev = this.beginLink(id);
                undo.push(() => this.endLink(prev));
            }
        }

        // Ids and classes become region names, so macros can target elements.
        const names = [];
        if (attrs.id) names.push("#" + attrs.id);
        if (attrs.class) {
            for (const c of attrs.class.split(/\s+/)) if (c) names.push("." + c);
        }
        if (names.length) {
            const rid = this.openRegion(names);
            undo.push(() => this.closeRegion(rid));
        }
        this.tags.push({ name, undo });
    }

    closeTag(name) {
        for (let i = this.tags.length - 1; i >= 0; i--) {
            if (this.tags[i].name !== name) continue;
            while (this.tags.length > i) this._popTag();
            return;
        }
    }

    _popTag() {
        const t = this.tags.pop();
        for (let k = t.undo.length - 1; k >= 0; k--) t.undo[k]();
    }

    // Close whatever the passage left open.
    finish() {
        while (this.tags.length) this._popTag();
    }
}

// The runs as they go on screen: region marks dropped, neighbours merged,
// leading/trailing blank lines stripped and blank lines capped at one.
function lastEndsSpace(out) {
    const last = out[out.length - 1];
    return !!last && /[ \t]$/.test(last.text);
}

export function visibleRuns(runs) {
    const out = [];
    let nl = -1;   // newlines just written; -1 = nothing written yet
    for (const r of runs) {
        if (r.mark !== undefined || !r.text) continue;
        let s = "";
        for (const ch of r.text) {
            if (ch === "\n") {
                if (nl === 0) s = s.replace(/[ \t]+$/, "");
                if (nl >= 0 && nl < 2) s += "\n";
                if (nl >= 0) nl++;
            } else if (ch === " " || ch === "\t") {
                // HTML whitespace: runs collapse to one space and vanish at the
                // start of a line. Indentation that matters uses U+00A0.
                if (nl === 0 && !/[ \t]$/.test(s) && !(s === "" && lastEndsSpace(out))) s += " ";
            } else {
                nl = 0;
                s += ch;
            }
        }
        if (s === "") continue;
        const last = out[out.length - 1];
        if (last && last.style === r.style && last.link === r.link) last.text += s;
        else out.push({ text: s, style: r.style, link: r.link });
    }
    while (out.length) {
        const last = out[out.length - 1];
        last.text = last.text.replace(/\s+$/, "");
        if (last.text !== "") break;
        out.pop();
    }
    return out;
}
