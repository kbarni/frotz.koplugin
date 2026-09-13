// twine/formats/markdown.js — the Markdown subset Chapbook and Snowman use.
//
// Blocks: paragraphs (blank lines), # headings, > quotes, - * + and 1. lists,
// --- rules, ``` fences. Inline: **bold** __bold__ *italic* _italic_ `code`
// ~~strike~~, [[links]], HTML, and a format hook for its own inserts ({…}).
// A single newline inside a paragraph is a space, as in Markdown.

import { parseLink } from "./common.js";

// inline(text, w) is called for plain text stretches (after links are cut out)
// so a format can expand its own syntax; default is markup().
export function renderMarkdown(engine, w, text, inline) {
    const lines = text.replace(/\r/g, "").split("\n");
    let para = [];
    const flushPara = () => {
        if (!para.length) return;
        w.paragraph();
        renderInline(engine, w, para.join(" "), inline);
        para = [];
        w.paragraph();
    };
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        let m;
        if (/^\s*$/.test(line)) { flushPara(); continue; }
        if (/^\s*```/.test(line)) {
            flushPara();
            const body = [];
            for (i++; i < lines.length && !/^\s*```/.test(lines[i]); i++) body.push(lines[i]);
            w.beginStyle("pre");
            w.text(body.join("\n"));
            w.endStyle("pre");
            w.paragraph();
            continue;
        }
        if ((m = /^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$/.exec(line))) {
            flushPara();
            const style = m[1].length <= 3 ? "header" : "sub";
            w.beginStyle(style);
            renderInline(engine, w, m[2], inline);
            w.endStyle(style);
            w.paragraph();
            continue;
        }
        if (/^\s{0,3}([-*_])(\s*\1){2,}\s*$/.test(line)) {
            flushPara();
            w.text("\u2014 \u2014 \u2014");
            w.paragraph();
            continue;
        }
        if ((m = /^\s{0,3}>\s?(.*)$/.exec(line))) {
            flushPara();
            w.beginStyle("quote");
            renderInline(engine, w, m[1], inline);
            w.endStyle("quote");
            w.newline();
            continue;
        }
        if ((m = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/.exec(line))) {
            flushPara();
            const indent = "\u00a0\u00a0".repeat(Math.floor(m[1].length / 2));
            w.text(indent + (/\d/.test(m[2]) ? m[2] + "\u00a0" : "\u2022\u00a0"));
            renderInline(engine, w, m[3], inline);
            w.newline();
            continue;
        }
        if (/ {2,}$/.test(line)) {                 // hard break
            para.push(line.trimEnd());
            renderInline(engine, w, para.join(" "), inline);
            para = [];
            w.newline();
            continue;
        }
        para.push(line.trim());
    }
    flushPara();
}

export function renderInline(engine, w, text, inline) {
    const re = /\[\[([\s\S]*?)\]\]|\*\*([\s\S]+?)\*\*|__([\s\S]+?)__|\*([^*\s][^*]*?)\*|(?<![\w])_([^_\s][^_]*?)_(?![\w])|`([^`]+)`|~~([\s\S]+?)~~/g;
    let last = 0, m;
    const plain = (s) => (inline ? inline(s, w) : w.markup(s));
    while ((m = re.exec(text)) !== null) {
        if (m.index > last) plain(text.slice(last, m.index));
        last = re.lastIndex;
        if (m[1] !== undefined) {
            const { label, target } = parseLink(m[1], true);
            engine.addLink(w, (lw) => renderInline(engine, lw, label, inline), () => engine.goto(target.trim()));
        } else if (m[2] !== undefined || m[3] !== undefined) {
            w.beginStyle("bold");
            renderInline(engine, w, m[2] ?? m[3], inline);
            w.endStyle("bold");
        } else if (m[4] !== undefined || m[5] !== undefined) {
            w.beginStyle("italic");
            renderInline(engine, w, m[4] ?? m[5], inline);
            w.endStyle("italic");
        } else if (m[6] !== undefined) {
            w.beginStyle("pre");
            w.text(m[6]);
            w.endStyle("pre");
        } else {
            renderInline(engine, w, m[7], inline);
        }
    }
    if (last < text.length) plain(text.slice(last));
}
