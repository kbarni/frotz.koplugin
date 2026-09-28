// twine/formats/harlowe.js — a Harlowe 2/3 interpreter (the common subset).
//
// Harlowe's language is not JavaScript, so this is a small interpreter:
//   1. a markup parser: text, [[links]], (macro:) calls, [hooks] with optional
//      |name> tags, $variables, ''bold'' //italic// and line markup;
//   2. an expression parser + evaluator for macro arguments ("is", "contains",
//      "'s", "to", lambdas, elided comparisons like `$a is 1 or 2`);
//   3. a renderer that applies changers ((if:), (link:), (live:), (replace:)…)
//      to hooks, using the engine's regions instead of a DOM.
// Unsupported macros render nothing and are logged once (see engine.warn).

import { parseLink } from "./common.js";
import { GotoSignal } from "../engine.js";
import { clone } from "../state.js";

// ── markup parser ────────────────────────────────────────────────────────────

const MACRO_RE = /\(([A-Za-z0-9_-]*[A-Za-z][A-Za-z0-9_-]*):/y;
const NAMETAG_BEFORE_RE = /\|([A-Za-z0-9_-]+)(>|\))\[/y;
const NAMETAG_AFTER_RE = /<([A-Za-z0-9_-]+)\||\(([A-Za-z0-9_-]+)\|/y;
const VAR_RE = /\$([A-Za-z_][\w]*)((?:'s\s+(?:\d+(?:st|nd|rd|th)(?:last)?|last|length|[A-Za-z_]\w*))*)/y;
const TEMP_RE = /_([A-Za-z][\w]*)/y;
const TAG_RE = /<\/?[A-Za-z][\w-]*(?:\s+[^\s"'>\/=]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>"']+))?)*\s*\/?>/y;
const HEADING_RE = /(#{1,6})[ \t]*/y;
const BULLET_RE = /[ \t]*(\*+)[ \t]+/y;
const NUMBERED_RE = /[ \t]*((?:0\.)+)[ \t]+/y;
const HR_RE = /[ \t]*-{3,}[ \t]*(?=\n|$)/y;
const ALIGN_RE = /[ \t]*(?=[=<>|]*=)[=<>|]{3,}[ \t]*(?=\n|$)/y;

function at(re, s, i) {
    re.lastIndex = i;
    return re.exec(s);
}

// Index of the ")" matching an already-consumed "(", string-aware; -1 if none.
function findClose(s, i) {
    let depth = 1;
    while (i < s.length) {
        const c = s[i];
        if (c === '"' || c === "'") {
            // A possessive 's is not a string opener — also after a call or a
            // hook: (passage:)'s tags.
            if (c === "'" && s[i + 1] === "s" && /[\w)\]]/.test(s[i - 1] || "") && !/\w/.test(s[i + 2] || "")) {
                i += 2;
                continue;
            }
            let j = i + 1;
            while (j < s.length && s[j] !== c) j += s[j] === "\\" ? 2 : 1;
            i = j + 1;
            continue;
        }
        if (c === "(") depth++;
        else if (c === ")" && --depth === 0) return i;
        i++;
    }
    return -1;
}

class MarkupParser {
    constructor(src) {
        this.s = src;
        this.i = 0;
    }

    parse() {
        return this.seq(null).nodes;
    }

    skipSpaces(j) {
        while (j < this.s.length && (this.s[j] === " " || this.s[j] === "\t")) j++;
        return j;
    }

    // A macro call at j: { node, end } or null.
    macroAt(j) {
        const m = at(MACRO_RE, this.s, j);
        if (!m) return null;
        const close = findClose(this.s, j + m[0].length);
        if (close < 0) return null;
        return { node: { name: m[1], src: this.s.slice(j + m[0].length, close) }, end: close + 1 };
    }

    // End of a [[link]] opening at j, or -1. As in Harlowe, link text holds no
    // "]": `[[Verse one]<v1|` is a named hook inside a hook, not a link running
    // on to some later "]]" (which left every enclosing hook unclosed, and
    // re-parsing those was exponential in their depth).
    linkEndAt(j) {
        const s = this.s;
        if (s[j] !== "[" || s[j + 1] !== "[" || s[j + 2] === "[") return -1;
        const e = s.indexOf("]", j + 2);
        return e >= 0 && s[e + 1] === "]" ? e : -1;
    }

    // A hook opening at j (a "[" that doesn't start a link), with optional tags.
    hookAt(j, name, hidden) {
        const s = this.s;
        if (s[j] !== "[" || this.linkEndAt(j) >= 0) return null;
        const save = this.i;
        this.i = j + 1;
        const r = this.seq("]");
        if (!r.closed) {
            this.i = save;
            return null;
        }
        const hook = { t: "hook", body: r.nodes, src: s.slice(j + 1, this.i - 1), name, hidden };
        const after = at(NAMETAG_AFTER_RE, s, this.i);
        if (after && !hook.name) {
            hook.name = after[1] || after[2];
            hook.hidden = !!after[2];
            this.i += after[0].length;
        }
        return hook;
    }

    // Parse until `close` ("]" or "}"), or to the end when close is null.
    seq(close) {
        const s = this.s;
        const nodes = [];
        let text = "";
        const flush = () => {
            if (text !== "") {
                nodes.push({ t: "text", v: text });
                text = "";
            }
        };
        const push = (n) => {
            flush();
            nodes.push(n);
        };

        while (this.i < s.length) {
            const i = this.i;
            const c = s[i];

            if (close !== null && c === close) {
                flush();
                this.i++;
                fixToggles(nodes);
                return { nodes, closed: true };
            }
            if (c === "\n") {
                push({ t: "br" });
                this.i++;
                if (s[this.i] === "\\") this.i++;   // line continuation
                continue;
            }
            if (c === "\\" && s[i + 1] === "\n") {
                this.i += 2;
                continue;
            }

            if (i === 0 || s[i - 1] === "\n") {
                let m;
                if ((m = at(ALIGN_RE, s, i))) {
                    this.i += m[0].length;
                    if (s[this.i] === "\n") this.i++;
                    continue;
                }
                if ((m = at(HR_RE, s, i))) {
                    push({ t: "hr" });
                    this.i += m[0].length;
                    continue;
                }
                if ((m = at(HEADING_RE, s, i))) {
                    push({ t: "heading", level: m[1].length });
                    this.i += m[0].length;
                    continue;
                }
                if ((m = at(BULLET_RE, s, i))) {
                    push({ t: "bullet", depth: m[1].length });
                    this.i += m[0].length;
                    continue;
                }
                if ((m = at(NUMBERED_RE, s, i))) {
                    push({ t: "numbered", depth: m[1].length / 2 });
                    this.i += m[0].length;
                    continue;
                }
            }

            if (c === "<") {
                if (s.startsWith("<!--", i)) {
                    const e = s.indexOf("-->", i + 4);
                    this.i = e < 0 ? s.length : e + 3;
                    continue;
                }
                // <style>/<script> bodies are not markup (CSS braces would
                // read as hooks): hand the whole element to the writer.
                const rawTag = at(/<(style|script)\b[^>]*>/iy, s, i);
                if (rawTag) {
                    const close = s.toLowerCase().indexOf("</" + rawTag[1].toLowerCase(), i + rawTag[0].length);
                    const gt = close < 0 ? -1 : s.indexOf(">", close);
                    const end = gt < 0 ? s.length : gt + 1;
                    text += s.slice(i, end);
                    this.i = end;
                    continue;
                }
                const m = at(TAG_RE, s, i);
                if (m) {                         // HTML: pass the tag through whole
                    text += m[0];
                    this.i += m[0].length;
                    continue;
                }
            }
            if (c === "`") {
                let n = 1;
                while (s[i + n] === "`") n++;
                const fence = "`".repeat(n);
                const e = s.indexOf(fence, i + n);
                if (e >= 0) {
                    push({ t: "verbatim", v: s.slice(i + n, e) });
                    this.i = e + n;
                    continue;
                }
            }
            if (c === "[" && s[i + 1] === "[") {
                const e = this.linkEndAt(i);
                if (e >= 0) {
                    push({ t: "link", body: s.slice(i + 2, e) });
                    this.i = e + 2;
                    continue;
                }
            }
            if (c === "(") {
                const first = this.macroAt(i);
                if (first) {
                    const chain = [first.node];
                    this.i = first.end;
                    for (;;) {                    // (a:)+(b:)
                        let j = this.skipSpaces(this.i);
                        if (s[j] !== "+") break;
                        j = this.skipSpaces(j + 1);
                        const next = this.macroAt(j);
                        if (!next) break;
                        chain.push(next.node);
                        this.i = next.end;
                    }
                    const hook = this.hookAt(this.skipSpaces(this.i), null, false);
                    push({ t: "call", chain, hook });
                    continue;
                }
            }
            if (c === "|") {
                const m = at(NAMETAG_BEFORE_RE, s, i);
                if (m) {
                    const hook = this.hookAt(i + m[0].length - 1, m[1], m[2] === ")");
                    if (hook) {
                        push(hook);
                        continue;
                    }
                }
            }
            if (c === "[") {
                const hook = this.hookAt(i, null, false);
                if (hook) {
                    push(hook);
                    continue;
                }
            }
            if (c === "{") {
                this.i = i + 1;
                const r = this.seq("}");
                if (r.closed) {
                    push({ t: "collapse", body: r.nodes });
                    continue;
                }
                this.i = i;
            }
            if (c === "$") {
                const m = at(VAR_RE, s, i);
                if (m) {
                    push({ t: "var", name: m[1], props: m[2] ? m[2].split(/'s\s+/).slice(1) : [], raw: m[0] });
                    this.i += m[0].length;
                    continue;
                }
            }
            if (c === "_" && !/\w/.test(s[i - 1] || "")) {
                const m = at(TEMP_RE, s, i);
                if (m) {
                    push({ t: "temp", name: m[1], raw: m[0] });
                    this.i += m[0].length;
                    continue;
                }
            }
            if ((c === "'" && s[i + 1] === "'") || (c === "*" && s[i + 1] === "*")) {
                push({ t: "toggle", k: "bold", raw: c + c });
                this.i += 2;
                continue;
            }
            if (c === "/" && s[i + 1] === "/" && s[i - 1] !== ":") {
                push({ t: "toggle", k: "italic", raw: "//" });
                this.i += 2;
                continue;
            }
            if (c === "*" && s[i + 1] !== " ") {
                push({ t: "toggle", k: "italic", raw: "*" });
                this.i++;
                continue;
            }
            if ((c === "~" && s[i + 1] === "~") || (c === "^" && s[i + 1] === "^")) {
                push({ t: "toggle", k: c === "~" ? "strike" : "sup", raw: c + c });
                this.i += 2;
                continue;
            }
            text += c;
            this.i++;
        }
        flush();
        fixToggles(nodes);
        return { nodes, closed: false };
    }
}

// An unpaired toggle is literal text (a lone "*" in "5 * 3").
function fixToggles(nodes) {
    const open = {};
    for (let i = 0; i < nodes.length; i++) {
        const n = nodes[i];
        if (n.t === "br") {
            // Emphasis never spans lines in practice; reset at each line.
            for (const k in open) if (open[k] !== undefined) { nodes[open[k]] = { t: "text", v: nodes[open[k]].raw }; }
            for (const k in open) open[k] = undefined;
            continue;
        }
        if (n.t !== "toggle") continue;
        if (open[n.k] === undefined) open[n.k] = i;
        else open[n.k] = undefined;
    }
    for (const k in open) {
        if (open[k] !== undefined) nodes[open[k]] = { t: "text", v: nodes[open[k]].raw };
    }
}

// ── expression tokenizer / parser ────────────────────────────────────────────

function tokenize(src) {
    const toks = [];
    let i = 0;
    const s = src;
    const valueEnd = () => {
        const p = toks[toks.length - 1];
        const before = toks[toks.length - 2];
        // A property name or position read by a 's can be read in turn:
        // (passage:)'s tags's length, $a's 1st's name.
        return p && (p.k === "var" || p.k === "temp" || p.k === ")" || p.k === "str"
                     || p.k === "hook" || p.k === "pos"
                     || (p.k === "id" && (/^(it|its)$/i.test(p.v) || (before && before.k === "'s"))));
    };
    while (i < s.length) {
        const c = s[i];
        if (/\s/.test(c)) { i++; continue; }
        if (c === "'" && s[i + 1] === "s" && !/\w/.test(s[i + 2] || "") && valueEnd()) {
            toks.push({ k: "'s" });
            i += 2;
            continue;
        }
        if (c === '"' || c === "'") {
            let j = i + 1, v = "";
            while (j < s.length && s[j] !== c) {
                if (s[j] === "\\" && j + 1 < s.length) { v += s[j + 1]; j += 2; }
                else v += s[j++];
            }
            toks.push({ k: "str", v });
            i = j + 1;
            continue;
        }
        let m;
        if ((m = at(/(\d+)(st|nd|rd|th)(last)?(?![\w])/y, s, i))) {
            toks.push({ k: "pos", v: parseInt(m[1], 10), last: !!m[3] });
            i += m[0].length;
            continue;
        }
        if ((m = at(/(\d+(?:\.\d+)?|\.\d+)(ms|s)?(?![\w])/y, s, i))) {
            let v = parseFloat(m[1]);
            if (m[2] === "s") v *= 1000;
            toks.push({ k: "num", v });
            i += m[0].length;
            continue;
        }
        if ((m = at(/\$([A-Za-z_]\w*)/y, s, i))) { toks.push({ k: "var", v: m[1] }); i += m[0].length; continue; }
        if ((m = at(/_([A-Za-z]\w*)/y, s, i))) { toks.push({ k: "temp", v: m[1] }); i += m[0].length; continue; }
        if ((m = at(/\?([A-Za-z_][\w-]*)/y, s, i))) { toks.push({ k: "hook", v: m[1] }); i += m[0].length; continue; }
        if ((m = at(MACRO_RE, s, i))) { toks.push({ k: "call", v: m[1] }); i += m[0].length; continue; }
        if (c === "[") {
            let depth = 0, j = i;
            for (; j < s.length; j++) {
                if (s[j] === "[") depth++;
                else if (s[j] === "]" && --depth === 0) break;
            }
            toks.push({ k: "code", v: s.slice(i + 1, j) });
            i = j + 1;
            continue;
        }
        if (s.startsWith("...", i)) { toks.push({ k: "..." }); i += 3; continue; }
        if ((m = at(/>=|<=|!=|==|[-+*\/%<>(),=]/y, s, i))) { toks.push({ k: m[0] }); i += m[0].length; continue; }
        if ((m = at(/[A-Za-z][A-Za-z0-9]*/y, s, i))) { toks.push({ k: "id", v: m[0] }); i += m[0].length; continue; }
        if (c === "#") {                                  // colour literal
            m = at(/#[0-9a-fA-F]+/y, s, i);
            if (m) { toks.push({ k: "str", v: m[0] }); i += m[0].length; continue; }
        }
        throw new Error(`I don't understand "${s.slice(i, i + 12)}"`);
    }
    return toks;
}

const TYPE_NAMES = new Set(["number", "num", "string", "str", "boolean", "bool", "array",
    "datamap", "dm", "dataset", "ds", "changer", "colour", "color", "lambda", "any", "even", "odd"]);

class ExprParser {
    constructor(toks) {
        this.t = toks;
        this.i = 0;
    }
    peek(o = 0) { return this.t[this.i + o]; }
    next() {
        const tok = this.t[this.i++];
        if (!tok) throw new Error("the expression ended unexpectedly");
        return tok;
    }
    kw(tok, word) { return tok && tok.k === "id" && tok.v.toLowerCase() === word; }
    expect(k) {
        const tok = this.next();
        if (tok.k !== k) throw new Error(`expected "${k}"`);
        return tok;
    }
    done() { return this.i >= this.t.length; }

    // Comma-separated arguments up to the end or a ")".
    args() {
        const list = [];
        if (this.done() || this.peek().k === ")") return list;
        for (;;) {
            if (this.peek() && this.peek().k === "...") {
                this.i++;
                list.push({ type: "spread", e: this.assign() });
            } else {
                list.push(this.lambdaOrAssign());
            }
            if (this.peek() && this.peek().k === ",") {
                this.i++;
                continue;
            }
            break;
        }
        return list;
    }

    lambdaOrAssign() {
        const p = this.peek(), p1 = this.peek(1);
        if (this.kw(p, "each")) {
            this.i++;
            const param = this.expect("temp").v;
            return this.lambdaTail({ type: "lambda", param });
        }
        if (p && p.k === "temp" && (this.kw(p1, "where") || this.kw(p1, "via") || this.kw(p1, "making"))) {
            this.i++;
            return this.lambdaTail({ type: "lambda", param: p.v });
        }
        if (this.kw(p, "where") || this.kw(p, "via") || this.kw(p, "when")) {
            return this.lambdaTail({ type: "lambda", param: null });
        }
        if (this.kw(p, "bind") || this.kw(p, "2bind")) {
            this.i++;
            return { type: "bind", target: this.postfix() };
        }
        return this.assign();
    }

    lambdaTail(lam) {
        for (;;) {
            const p = this.peek();
            if (this.kw(p, "where") || this.kw(p, "when")) { this.i++; lam.where = this.assign(); }
            else if (this.kw(p, "via")) { this.i++; lam.via = this.assign(); }
            else if (this.kw(p, "making")) { this.i++; lam.making = this.expect("temp").v; }
            else break;
        }
        return lam;
    }

    assign() {
        const l = this.logical();
        const p = this.peek();
        if (this.kw(p, "to") || this.kw(p, "into")) {
            this.i++;
            return { type: p.v.toLowerCase(), l, r: this.assign() };
        }
        return l;
    }

    logical() {
        let l = this.notE();
        let lastCmp = l.type === "cmp" ? l : null;
        for (;;) {
            const p = this.peek();
            if (!(this.kw(p, "and") || this.kw(p, "or"))) break;
            this.i++;
            const r = this.notE();
            const node = { type: p.v.toLowerCase(), l, r };
            if (r.type === "cmp") lastCmp = r;
            else if (lastCmp) node.elide = lastCmp;    // `$a is 1 or 2`
            l = node;
        }
        return l;
    }

    notE() {
        if (this.kw(this.peek(), "not")) {
            this.i++;
            return { type: "not", e: this.notE() };
        }
        return this.comparison();
    }

    comparison() {
        let l = this.additive();
        for (;;) {
            const p = this.peek();
            let op = null;
            if (this.kw(p, "is")) {
                this.i++;
                if (this.kw(this.peek(), "not")) {
                    this.i++;
                    if (this.kw(this.peek(), "in")) { this.i++; op = "notin"; }
                    else op = "isnot";
                } else if (this.kw(this.peek(), "in")) { this.i++; op = "in"; }
                else if (this.kw(this.peek(), "a") || this.kw(this.peek(), "an")) { this.i++; op = "isa"; }
                else op = "is";
            } else if (this.kw(p, "contains")) { this.i++; op = "contains"; }
            else if (this.kw(p, "does") && this.kw(this.peek(1), "not") && this.kw(this.peek(2), "contain")) {
                this.i += 3; op = "notcontains";
            } else if (p && (p.k === "<" || p.k === ">" || p.k === "<=" || p.k === ">=")) { this.i++; op = p.k; }
            else if (p && (p.k === "==" || p.k === "=")) { this.i++; op = "is"; }
            else if (p && p.k === "!=") { this.i++; op = "isnot"; }
            if (!op) break;
            const r = op === "isa" ? { type: "lit", v: this.next().v.toLowerCase() } : this.additive();
            l = { type: "cmp", op, l, r };
        }
        return l;
    }

    additive() {
        let l = this.mult();
        while (this.peek() && (this.peek().k === "+" || this.peek().k === "-")) {
            const op = this.next().k;
            l = { type: "bin", op, l, r: this.mult() };
        }
        return l;
    }

    mult() {
        let l = this.unary();
        while (this.peek() && (this.peek().k === "*" || this.peek().k === "/" || this.peek().k === "%")) {
            const op = this.next().k;
            l = { type: "bin", op, l, r: this.unary() };
        }
        return l;
    }

    unary() {
        if (this.peek() && this.peek().k === "-") {
            this.i++;
            return { type: "neg", e: this.unary() };
        }
        return this.postfix();
    }

    postfix() {
        let e = this.primary();
        while (this.peek() && this.peek().k === "'s") {
            this.i++;
            e = { type: "prop", obj: e, key: this.propKey() };
        }
        return e;
    }

    propKey() {
        const p = this.next();
        if (p.k === "pos") return { kind: "pos", n: p.v, last: p.last };
        if (p.k === "num") return { kind: "value", e: { type: "lit", v: p.v } };
        if (p.k === "str") return { kind: "name", v: p.v };
        if (p.k === "(") {
            const e = this.assign();
            this.expect(")");
            return { kind: "value", e };
        }
        if (p.k === "var" || p.k === "temp") {
            return { kind: "value", e: { type: p.k, name: p.v } };
        }
        if (p.k === "id") {
            const w = p.v.toLowerCase();
            if (w === "last") return { kind: "pos", n: 1, last: true };
            if (w === "length") return { kind: "length" };
            if (w === "random") return { kind: "random" };
            return { kind: "name", v: p.v };
        }
        throw new Error("that property name makes no sense");
    }

    primary() {
        const p = this.next();
        switch (p.k) {
            case "num": return { type: "lit", v: p.v };
            case "str": return { type: "lit", v: p.v };
            case "var": return { type: "var", name: p.v };
            case "temp": return { type: "temp", name: p.v };
            case "hook": return { type: "hookref", name: p.v };
            case "code": return { type: "code", v: p.v };
            case "call": {
                const args = this.args();
                this.expect(")");
                return { type: "call", name: p.v, args };
            }
            case "(": {
                const e = this.assign();
                this.expect(")");
                return e;
            }
            case "pos":
                if (this.kw(this.peek(), "of")) {
                    this.i++;
                    return { type: "prop", obj: this.unary(), key: { kind: "pos", n: p.v, last: p.last } };
                }
                return { type: "lit", v: p.v };
            case "id": {
                const w = p.v.toLowerCase();
                if (this.kw(this.peek(), "of") && w !== "it") {
                    this.i++;
                    const obj = this.unary();
                    const key = w === "last" ? { kind: "pos", n: 1, last: true }
                        : w === "length" ? { kind: "length" }
                        : w === "random" ? { kind: "random" }
                        : { kind: "name", v: p.v };
                    return { type: "prop", obj, key };
                }
                if (w === "true") return { type: "lit", v: true };
                if (w === "false") return { type: "lit", v: false };
                if (w === "it") return { type: "it" };
                if (w === "its") return { type: "prop", obj: { type: "it" }, key: this.propKey() };
                if (w === "time") return { type: "time" };
                if (w === "visits" || w === "visit") return { type: "visits" };
                if (w === "turns" || w === "turn") return { type: "turns" };
                if (w === "exits" || w === "exit") return { type: "lit", v: 0 };
                if (TYPE_NAMES.has(w)) return { type: "lit", v: w };
                return { type: "lit", v: p.v };   // colour names and the like
            }
            default:
                throw new Error(`unexpected "${p.k}"`);
        }
    }
}

// ── values ───────────────────────────────────────────────────────────────────

const isChanger = (v) => v !== null && typeof v === "object" && Array.isArray(v.changer);
const isCommand = (v) => v !== null && typeof v === "object" && typeof v.command === "function";
const changer = (...parts) => ({ changer: parts });
const command = (fn) => ({ command: fn });
const NOOP = command(() => {});

function deepEqual(a, b) {
    if (a === b) return true;
    if (Array.isArray(a) && Array.isArray(b)) {
        return a.length === b.length && a.every((x, i) => deepEqual(x, b[i]));
    }
    if (a instanceof Map && b instanceof Map) {
        if (a.size !== b.size) return false;
        for (const [k, v] of a) if (!b.has(k) || !deepEqual(v, b.get(k))) return false;
        return true;
    }
    if (a instanceof Set && b instanceof Set) {
        if (a.size !== b.size) return false;
        for (const v of a) if (![...b].some((x) => deepEqual(x, v))) return false;
        return true;
    }
    return false;
}

function typeName(v) {
    if (typeof v === "string") return "a string";
    if (typeof v === "number") return "a number";
    if (typeof v === "boolean") return "a boolean";
    if (Array.isArray(v)) return "an array";
    if (v instanceof Map) return "a datamap";
    if (v instanceof Set) return "a dataset";
    if (isChanger(v)) return "a changer";
    return "that";
}

function toText(v) {
    if (v === undefined || v === null) return "";
    if (Array.isArray(v)) return v.map(toText).join(",");
    if (v instanceof Set) return [...v].map(toText).join(",");
    if (v instanceof Map) return [...v].map(([k, x]) => `${k}: ${toText(x)}`).join(", ");
    if (isChanger(v) || isCommand(v)) return "";
    return String(v);
}

function flattenSpread(values) {
    const out = [];
    for (const v of values) {
        if (v && v.spread) {
            const x = v.value;
            if (typeof x === "string") out.push(...x);
            else if (x instanceof Set) out.push(...x);
            else if (Array.isArray(x)) out.push(...x);
            else out.push(x);
        } else out.push(v);
    }
    return out;
}

function compare(op, l, r) {
    switch (op) {
        case "is": return deepEqual(l, r);
        case "isnot": return !deepEqual(l, r);
        case "<": return l < r;
        case ">": return l > r;
        case "<=": return l <= r;
        case ">=": return l >= r;
        case "contains": return contains(l, r);
        case "notcontains": return !contains(l, r);
        case "in": return contains(r, l);
        case "notin": return !contains(r, l);
        case "isa": return isA(l, r);
    }
    throw new Error("unknown comparison " + op);
}

function contains(container, v) {
    if (typeof container === "string") return container.includes(String(v));
    if (Array.isArray(container)) return container.some((x) => deepEqual(x, v));
    if (container instanceof Map) return container.has(v);
    if (container instanceof Set) return [...container].some((x) => deepEqual(x, v));
    throw new Error(`I can't look inside ${typeName(container)}`);
}

function isA(v, type) {
    switch (type) {
        case "number": case "num": return typeof v === "number";
        case "string": case "str": return typeof v === "string";
        case "boolean": case "bool": return typeof v === "boolean";
        case "array": return Array.isArray(v);
        case "datamap": case "dm": return v instanceof Map;
        case "dataset": case "ds": return v instanceof Set;
        case "changer": return isChanger(v);
        case "even": return typeof v === "number" && v % 2 === 0;
        case "odd": return typeof v === "number" && Math.abs(v % 2) === 1;
        case "any": return true;
    }
    return false;
}

function arith(op, l, r) {
    if (op === "+") {
        if (typeof l === "number" && typeof r === "number") return l + r;
        if (typeof l === "string" || typeof r === "string") return toText(l) + toText(r);
        if (Array.isArray(l) && Array.isArray(r)) return l.concat(r);
        if (l instanceof Map && r instanceof Map) return new Map([...l, ...r]);
        if (l instanceof Set && r instanceof Set) return new Set([...l, ...r]);
        if (isChanger(l) && isChanger(r)) return { changer: l.changer.concat(r.changer) };
        throw new Error(`I can't add ${typeName(l)} and ${typeName(r)}`);
    }
    if (op === "-") {
        if (typeof l === "number" && typeof r === "number") return l - r;
        if (typeof l === "string" && typeof r === "string") return l.split(r).join("");
        if (Array.isArray(l) && Array.isArray(r)) return l.filter((x) => !r.some((y) => deepEqual(x, y)));
        if (l instanceof Set && r instanceof Set) return new Set([...l].filter((x) => !r.has(x)));
        throw new Error(`I can't subtract ${typeName(r)} from ${typeName(l)}`);
    }
    if (typeof l !== "number" || typeof r !== "number") {
        throw new Error(`I can only use ${op} on numbers`);
    }
    if (op === "*") return l * r;
    if (op === "/") {
        if (r === 0) throw new Error("I can't divide by zero");
        return l / r;
    }
    return l % r;
}

function num(v, what) {
    if (typeof v !== "number") throw new Error(`${what || "this"} should be a number, not ${typeName(v)}`);
    return v;
}

function sequenceIndex(len, key) {
    if (key.kind === "pos") return key.last ? len - key.n : key.n - 1;
    const n = key.v;
    if (typeof n !== "number") return undefined;
    return n < 0 ? len + n : n - 1;
}

function getProp(obj, key, rng) {
    if (key.kind === "length") {
        if (typeof obj === "string" || Array.isArray(obj)) return obj.length;
        if (obj instanceof Set || obj instanceof Map) return obj.size;
        throw new Error(`${typeName(obj)} has no length`);
    }
    if (typeof obj === "string" || Array.isArray(obj)) {
        const seq = typeof obj === "string" ? [...obj] : obj;
        if (key.kind === "random") return seq[rng.int(0, seq.length - 1)];
        if (key.kind === "name" && key.v.toLowerCase() === "length") return seq.length;
        const idx = sequenceIndex(seq.length, key);
        if (idx === undefined || idx < 0 || idx >= seq.length) {
            throw new Error(`there's nothing at position ${key.n || key.v} of ${typeName(obj)}`);
        }
        return seq[idx];
    }
    if (obj instanceof Map) {
        const k = key.kind === "name" ? key.v : key.v;
        if (obj.has(k)) return obj.get(k);
        if (typeof k === "number" && obj.has(String(k))) return obj.get(String(k));
        throw new Error(`the datamap has no "${k}"`);
    }
    if (obj instanceof Set && key.kind === "name" && key.v.toLowerCase() === "length") return obj.size;
    if (obj && typeof obj === "object" && key.kind === "name" && key.v in obj) return obj[key.v];
    throw new Error(`I can't get "${key.v ?? key.n}" of ${typeName(obj)}`);
}

function setProp(obj, key, value) {
    if (Array.isArray(obj)) {
        const idx = sequenceIndex(obj.length, key);
        if (idx === undefined || idx < 0) throw new Error("that array position doesn't exist");
        obj[idx] = value;
        return;
    }
    if (obj instanceof Map) {
        obj.set(key.v, value);
        return;
    }
    throw new Error(`I can't change a property of ${typeName(obj)}`);
}

function deleteProp(obj, key) {
    if (Array.isArray(obj)) {
        const idx = sequenceIndex(obj.length, key);
        if (idx !== undefined && idx >= 0 && idx < obj.length) obj.splice(idx, 1);
    } else if (obj instanceof Map) {
        obj.delete(key.v);
    }
}

const NOOP_CHANGERS = ["textcolour", "textcolor", "colour", "color", "textrotate", "textrotatex",
    "textrotatey", "textrotatez", "align", "css", "transition", "t8n", "transitiontime", "t8ntime",
    "transitiondelay", "t8ndelay", "transitionskip", "t8nskip", "transitiondepart", "t8ndepart",
    "transitionarrive", "t8narrive", "font", "background", "bg", "hoverstyle", "textsize", "size",
    "box", "floatbox", "border", "bordercolour", "bordercolor", "bordersize", "b4r", "b4rcolour",
    "b4rcolor", "b4rsize", "cornerradius", "opacity", "charstyle", "linestyle", "linkstyle",
    "textindent", "buttonbox", "button", "hidden2", "firstlinkcolour", "outline"];
const SILENT_COMMANDS = ["scroll", "iconundo", "iconredo", "iconfullscreen", "iconrestart",
    "iconcounter", "debug", "mockvisits", "mockturns", "animate", "enchant", "enchantin",
    "change", "meter", "sidebar", "replacewith", "appendwith", "prependwith", "pagerefresh",
    "fullscreen", "gotourl", "openurl", "alert", "savegame", "loadgame", "forgetundos",
    "forgetvisits", "redirect", "ignore", "storylet", "exclusivity", "urgency", "track",
    "startrecording", "stoprecording", "cleartimers", "hookrefs"];

// ── the format ───────────────────────────────────────────────────────────────

export class Harlowe {
    constructor(engine) {
        this.engine = engine;
        this.temps = {};
        this.cache = new Map();
        this.exprCache = new Map();
        this.depth = 0;
        this.bindings = [];
        const tagged = (tag) => [...engine.story.passages.values()].filter((p) => p.tags.includes(tag));
        this.startup = tagged("startup");
        this.headers = tagged("header");
        this.footers = tagged("footer");
    }

    init() {}

    parsed(src) {
        let nodes = this.cache.get(src);
        if (!nodes) {
            nodes = new MarkupParser(src).parse();
            if (this.cache.size > 500) this.cache.clear();
            this.cache.set(src, nodes);
        }
        return nodes;
    }

    render(passage, w) {
        this.temps = {};
        this.bindings = [];
        this.mores = [];
        this.depth = 0;
        if (this.engine.history.length === 1) {
            for (const p of this.startup) this.renderSource(p.text, w);
        }
        for (const p of this.headers) this.renderSource(p.text, w);
        this.renderSource(passage.text, w);
        for (const p of this.footers) this.renderSource(p.text, w);
        this.flushBindings();
    }

    renderSource(src, w) {
        if (++this.depth > 60) {
            this.depth--;
            throw new Error("too much nesting (does a passage display itself?)");
        }
        try {
            this.renderNodes(this.parsed(src), w, { lastCond: undefined, toggles: {}, heading: null, num: 0 });
        } finally {
            this.depth--;
        }
    }

    renderNodes(nodes, w, scope) {
        for (const n of nodes) {
            switch (n.t) {
                case "text": w.markup(n.v); break;
                case "verbatim": w.text(n.v); break;
                case "br":
                    if (scope.heading) { w.endStyle(scope.heading); scope.heading = null; }
                    w.newline();
                    break;
                case "toggle":
                    if (n.k === "bold" || n.k === "italic") {
                        if (scope.toggles[n.k]) { w.endStyle(n.k); scope.toggles[n.k] = false; }
                        else { w.beginStyle(n.k); scope.toggles[n.k] = true; }
                    }
                    break;
                case "heading":
                    scope.heading = n.level <= 3 ? "header" : "sub";
                    w.beginStyle(scope.heading);
                    break;
                case "bullet": w.text("\u00a0\u00a0".repeat(n.depth - 1) + "\u2022\u00a0"); break;
                case "numbered": w.text("\u00a0\u00a0".repeat(n.depth - 1) + (++scope.num) + ".\u00a0"); break;
                case "hr": w.text("\u2014 \u2014 \u2014"); break;
                case "link": this.renderLink(n, w); break;
                case "var": this.printVarNode(n, w); break;
                case "temp":
                    if (n.name in this.temps) this.printValue(this.temps[n.name], w);
                    else w.text(n.raw);
                    break;
                case "hook": this.applyChanger(null, n, w, scope); break;
                case "collapse":
                    w.beginStyle("collapse");
                    this.renderNodes(n.body, w, scope);
                    w.endStyle("collapse");
                    break;
                case "call": this.renderCall(n, w, scope); break;
            }
        }
        if (scope.heading) { w.endStyle(scope.heading); scope.heading = null; }
        for (const k of ["bold", "italic"]) {
            if (scope.toggles[k]) { w.endStyle(k); scope.toggles[k] = false; }
        }
    }

    renderLink(n, w) {
        let { label, target } = parseLink(n.body, false);
        // Harlowe itself doesn't split on "|"; only do it when the whole body
        // isn't a passage name.
        if (target === label && n.body.includes("|") && !this.engine.passage(n.body)) {
            ({ label, target } = parseLink(n.body, true));
        }
        target = target.trim();
        this.engine.addLink(w, (lw) => this.renderSource(label, lw), () => this.engine.goto(target));
    }

    printVarNode(n, w) {
        let v = this.engine.vars[n.name];
        if (v === undefined) v = 0;
        let consumed = "$" + n.name;
        for (const prop of n.props) {
            const key = /^\d+(st|nd|rd|th)(last)?$/.test(prop)
                ? { kind: "pos", n: parseInt(prop, 10), last: prop.endsWith("last") }
                : prop === "last" ? { kind: "pos", n: 1, last: true }
                : prop === "length" ? { kind: "length" } : { kind: "name", v: prop };
            if (!(Array.isArray(v) || v instanceof Map || v instanceof Set || (typeof v === "string" && key.kind !== "name"))) break;
            try {
                v = getProp(v, key, this.engine.rng);
                consumed += "'s " + prop;
            } catch (_) {
                break;
            }
        }
        this.printValue(v, w);
        if (consumed.length < n.raw.length) w.text(n.raw.slice(consumed.length));
    }

    printValue(v, w) {
        if (v === undefined || v === null || isChanger(v) || isCommand(v)) return;
        if (typeof v === "string") this.renderSource(v, w);
        else w.text(toText(v));
    }

    // ── macro calls ────────────────────────────────────────────────────────

    callNode(m) {
        if (!m.parsed) {
            try {
                const p = new ExprParser(tokenize(m.src));
                const args = p.args();
                if (!p.done()) throw new Error(`I don't understand "${m.src}"`);
                m.parsed = { type: "call", name: m.name, args };
            } catch (e) {
                m.parsed = { error: e.message };
            }
        }
        if (m.parsed.error) throw new Error(m.parsed.error);
        return m.parsed;
    }

    renderCall(n, w, scope) {
        let value;
        try {
            value = undefined;
            for (const m of n.chain) {
                const v = this.call(this.callNode(m), { w, scope });
                value = value === undefined ? v : arith("+", value, v);
            }
        } catch (e) {
            if (e instanceof GotoSignal) throw e;
            w.error(`(${n.chain[0].name}:) ${e.message}`);
            return;
        }
        if (n.hook) {
            if (isChanger(value)) return this.applyChanger(value, n.hook, w, scope);
            if (value === false) return;
            if (isCommand(value)) value.command(w, scope);
            else if (value !== true) this.printValue(value, w);
            return this.applyChanger(null, n.hook, w, scope);
        }
        if (isCommand(value)) return value.command(w, scope);
        if (isChanger(value)) return;
        this.printValue(value, w);
    }

    call(node, ctx) {
        const key = node.name.toLowerCase().replace(/[-_]/g, "");
        const impl = MACROS[key];
        if (impl) return impl.call(this, node, ctx);
        if (NOOP_CHANGERS.includes(key)) return changer({ type: "noop" });
        if (SILENT_COMMANDS.includes(key)) return NOOP;
        this.engine.warn(`Harlowe (${node.name}:)`);
        return NOOP;
    }

    // Evaluated arguments, spreads flattened.
    args(node, ctx) {
        return flattenSpread(node.args.map((a) =>
            a.type === "spread" ? { spread: true, value: this.eval(a.e, ctx) } : this.eval(a, ctx)));
    }

    // ── expressions ────────────────────────────────────────────────────────

    eval(node, ctx) {
        switch (node.type) {
            case "lit": return node.v;
            case "var": {
                const v = this.engine.vars[node.name];
                return v === undefined ? 0 : v;
            }
            case "temp":
                return node.name in this.temps ? this.temps[node.name] : 0;
            case "it": return ctx.it === undefined ? 0 : ctx.it;
            case "hookref": return { hookref: node.name.toLowerCase() };
            case "code": return { code: node.v };
            case "time": return this.engine.clock;
            case "visits": return this.engine.visits[this.engine.passageName] || 0;
            case "turns": return this.engine.history.length;
            case "call": return this.call(node, ctx);
            case "prop": {
                const obj = this.eval(node.obj, ctx);
                const key = node.key.kind === "value"
                    ? { kind: "value", v: this.eval(node.key.e, ctx) } : node.key;
                if (key.kind === "value" && typeof key.v === "string") {
                    return getProp(obj, { kind: "name", v: key.v }, this.engine.rng);
                }
                return getProp(obj, key, this.engine.rng);
            }
            case "neg": return -num(this.eval(node.e, ctx));
            case "not": return !this.bool(this.eval(node.e, ctx));
            case "and":
            case "or": {
                const l = this.bool(this.eval(node.l, ctx));
                if (node.type === "and" && !l) return false;
                if (node.type === "or" && l) return true;
                let r = this.eval(node.r, ctx);
                if (typeof r !== "boolean" && node.elide) {
                    r = compare(node.elide.op, this.eval(node.elide.l, ctx), r);
                }
                return this.bool(r);
            }
            case "cmp": return compare(node.op, this.eval(node.l, ctx), this.eval(node.r, ctx));
            case "bin": return arith(node.op, this.eval(node.l, ctx), this.eval(node.r, ctx));
            case "lambda": return { lambda: node };
            case "bind": return { bind: node.target };
            case "to":
            case "into":
                throw new Error(`"${node.type}" only makes sense inside (set:) or (put:)`);
            case "spread": return this.eval(node.e, ctx);
        }
        throw new Error("unknown expression");
    }

    bool(v) {
        if (typeof v === "boolean") return v;
        throw new Error(`I expected true or false, not ${typeName(v)}`);
    }

    // Store into $var / _temp / $var's prop.
    assign(target, value, ctx) {
        value = clone(value);
        if (target.type === "var") this.engine.vars[target.name] = value;
        else if (target.type === "temp") this.temps[target.name] = value;
        else if (target.type === "prop") {
            const obj = this.eval(target.obj, ctx);
            const key = target.key.kind === "value" ? { kind: "value", v: this.eval(target.key.e, ctx) } : target.key;
            if (key.kind === "value" && typeof key.v === "string") setProp(obj, { kind: "name", v: key.v }, value);
            else setProp(obj, key, value);
        } else if (target.type === "it" && ctx.itTarget) {
            this.assign(ctx.itTarget, value, ctx);
        } else {
            throw new Error("I can only store things in variables");
        }
    }

    lambda(v, what) {
        if (!v || !v.lambda) throw new Error(`${what} needs a lambda (like "each _x where ...")`);
        return v.lambda;
    }

    runLambda(lam, value, ctx, extra) {
        const saved = { ...this.temps };
        try {
            if (lam.param) this.temps[lam.param] = value;
            if (extra) Object.assign(this.temps, extra);
            const c = { ...ctx, it: value };
            if (lam.where && !this.bool(this.eval(lam.where, c))) return { pass: false };
            return { pass: true, value: lam.via ? this.eval(lam.via, c) : value };
        } finally {
            this.temps = saved;
        }
    }

    // ── changers and hooks ─────────────────────────────────────────────────

    applyChanger(value, hook, w, scope) {
        const opts = { styles: [], collapse: false, verbatim: false };
        let show = true, cond = null, hidden = !!hook.hidden;
        let link = null, target = null, timing = null, loop = null, click = null, more = false;
        for (const c of value ? value.changer : []) {
            switch (c.type) {
                case "cond": {
                    const prev = scope.lastCond;
                    if (c.kind === "if") { show = show && c.value; cond = c.value; }
                    else if (c.kind === "unless") { show = show && !c.value; cond = !c.value; }
                    else if (c.kind === "elseif") { show = show && prev === false && c.value; cond = prev !== false || c.value; }
                    else { show = show && prev === false; cond = true; }
                    break;
                }
                case "hidden": hidden = true; break;
                case "more": more = true; break;
                case "style": opts.styles.push(...c.styles); break;
                case "collapse": opts.collapse = true; break;
                case "verbatim": opts.verbatim = true; break;
                case "link": link = c; break;
                case "target": target = c; break;
                case "click": click = c; break;
                case "live": case "after": timing = c; break;
                case "for": loop = c; break;
                case "noop": break;
            }
        }
        if (cond !== null) scope.lastCond = cond;
        if (!show) return;

        const names = hook.name ? ["?" + hook.name.toLowerCase()] : [];
        const renderBody = (bw) => this.renderHook(hook, bw, opts);
        const engine = this.engine;

        if (target) {
            for (const t of target.targets) {
                const ids = t && t.hookref ? engine.regionsNamed("?" + t.hookref)
                    : t && t.text !== undefined ? engine.wrapText(t.text) : [];
                for (const id of ids) engine.fillRegion(id, renderBody, target.mode);
            }
            return;
        }
        if (click) {
            const anchor = w.openRegion([]);
            w.closeRegion(anchor);
            this.bindings.push({ c: click, anchor, render: renderBody });
            return;
        }
        if (link) return this.renderLinkChanger(link, hook, w, renderBody, names);
        if (more) {
            const rid = w.openRegion(names);
            w.closeRegion(rid);
            this.mores.push({ rid, render: renderBody });
            return;
        }
        if (timing) {
            const rid = w.openRegion(names);
            w.closeRegion(rid);
            engine.after(Math.max(timing.ms, 250), () => {
                engine.fillRegion(rid, renderBody, "replace");
                this.flushBindings();
            }, timing.type === "live");
            return;
        }
        if (loop) {
            const lam = loop.lambda;
            for (const v of loop.values) {
                const res = this.runLambda(lam, v, {}, null);
                if (!res.pass) continue;
                const saved = lam.param ? this.temps[lam.param] : undefined;
                if (lam.param) this.temps[lam.param] = v;
                renderBody(w);
                if (lam.param) this.temps[lam.param] = saved;
            }
            return;
        }
        const rid = names.length || hidden ? w.openRegion(names) : 0;
        if (rid) {
            const region = engine.regions.get(rid);
            region.rerender = renderBody;
            if (hidden) region.hiddenBody = renderBody;
        }
        if (!hidden) renderBody(w);
        if (rid) w.closeRegion(rid);
    }

    renderHook(hook, w, opts) {
        for (const s of opts.styles) w.beginStyle(s);
        if (opts.collapse) w.beginStyle("collapse");
        if (opts.verbatim) w.text(hook.src);
        else this.renderNodes(hook.body, w, { lastCond: undefined, toggles: {}, heading: null, num: 0 });
        if (opts.collapse) w.endStyle("collapse");
        for (const s of opts.styles) w.endStyle(s);
    }

    renderLinkChanger(c, hook, w, renderBody, names) {
        const engine = this.engine;
        const label = (lw) => this.renderSource(c.label, lw);
        const after = (fn) => () => { fn(); this.flushBindings(); };
        switch (c.mode) {
            case "replace": {
                const rid = w.openRegion(names);
                engine.addLink(w, label, after(() => engine.fillRegion(rid, renderBody, "replace")));
                w.closeRegion(rid);
                break;
            }
            case "reveal": {
                const rid = w.openRegion(names);
                engine.addLink(w, label, after(() => engine.fillRegion(rid, (bw) => {
                    label(bw);
                    renderBody(bw);
                }, "replace")));
                w.closeRegion(rid);
                break;
            }
            case "repeat":
            case "rerun": {
                engine.addLink(w, label, after(() => engine.fillRegion(rid, renderBody,
                    c.mode === "repeat" ? "append" : "replace")));
                const rid = w.openRegion(names);
                w.closeRegion(rid);
                break;
            }
            case "revealgoto": {
                const rid = w.openRegion(names);
                engine.addLink(w, label, () => {
                    engine.fillRegion(rid, renderBody, "replace");
                    engine.goto(c.target);
                });
                w.closeRegion(rid);
                break;
            }
        }
    }

    // After the page is drawn or changed: bind pending (click:) targets, then
    // show (more:) hooks when no link is left.
    flushBindings() {
        this.bindClicks();
        this.revealMores();
    }

    // (more:)[…]: hidden until the page has no links left (Harlowe shows it
    // when its `exits` count reaches 0).
    revealMores() {
        if (!this.mores || !this.mores.length || this.engine.runs.some((r) => r.link)) return;
        const pending = this.mores;
        this.mores = [];
        for (const m of pending) this.engine.fillRegion(m.rid, m.render, "replace");
        this.flushBindings();
    }

    // (click: ?hook)[…]: once the page exists, make the target's text a link.
    bindClicks() {
        const engine = this.engine;
        const pending = this.bindings;
        this.bindings = [];
        if (!pending.length) return;
        for (const b of pending) {
            const t = b.c.target;
            const ids = t && t.hookref ? engine.regionsNamed("?" + t.hookref)
                : typeof t === "string" ? engine.wrapText(t) : [];
            if (!ids.length) {
                // The target isn't on the page yet (it sits inside text a
                // later reveal will show): try again after the next change.
                this.bindings.push(b);
                continue;
            }
            const linkId = engine.registerAction(() => {
                for (const r of engine.runs) if (r.link === linkId) r.link = 0;
                if (b.c.mode === "click") engine.fillRegion(b.anchor, b.render, "replace");
                else for (const id of ids) engine.fillRegion(id, b.render, b.c.mode);
                if (b.c.goto) engine.goto(b.c.goto);
                this.flushBindings();
            });
            for (const id of ids) {
                const bounds = engine._bounds(id);
                if (!bounds) continue;
                for (let i = bounds[0] + 1; i < bounds[1]; i++) {
                    const r = engine.runs[i];
                    if (r.mark === undefined && r.text.trim() !== "") r.link = linkId;
                }
            }
        }
    }

    hookTargets(values) {
        return values.map((v) => (v && v.hookref ? v : { text: String(v) }));
    }

    displayPassage(name, w) {
        const p = this.engine.passage(name);
        if (!p) throw new Error(`there's no passage named "${name}"`);
        this.renderSource(p.text, w);
    }
}

// ── macro table ──────────────────────────────────────────────────────────────
// Each entry runs with `this` = the Harlowe format: fn(node, ctx) -> value.

function a1(self, node, ctx) {
    return self.args(node, ctx);
}

function str(v, what) {
    if (typeof v !== "string") throw new Error(`${what || "this"} should be a string, not ${typeName(v)}`);
    return v;
}

const MACROS = {
    // variables
    set(node, ctx) {
        for (const a of node.args) {
            if (a.type !== "to") throw new Error('I need "to", like (set: $x to 1)');
            const c = { ...ctx, itTarget: a.l };
            let current;
            try { current = this.eval(a.l, ctx); } catch (_) { current = 0; }
            c.it = current;
            this.assign(a.l, this.eval(a.r, c), ctx);
        }
        return NOOP;
    },
    put(node, ctx) {
        for (const a of node.args) {
            if (a.type !== "into") throw new Error('I need "into", like (put: 1 into $x)');
            this.assign(a.r, this.eval(a.l, ctx), ctx);
        }
        return NOOP;
    },
    move(node, ctx) {
        for (const a of node.args) {
            if (a.type !== "into") throw new Error('I need "into", like (move: $a into $b)');
            this.assign(a.r, this.eval(a.l, ctx), ctx);
            if (a.l.type === "var") delete this.engine.vars[a.l.name];
            else if (a.l.type === "temp") delete this.temps[a.l.name];
            else if (a.l.type === "prop") {
                const key = a.l.key.kind === "value" ? { kind: "value", v: this.eval(a.l.key.e, ctx) } : a.l.key;
                deleteProp(this.eval(a.l.obj, ctx), key.kind === "value" && typeof key.v === "string" ? { kind: "name", v: key.v } : key);
            }
        }
        return NOOP;
    },

    // conditions
    if(node, ctx) { return changer({ type: "cond", kind: "if", value: this.bool(a1(this, node, ctx)[0]) }); },
    unless(node, ctx) { return changer({ type: "cond", kind: "unless", value: this.bool(a1(this, node, ctx)[0]) }); },
    elseif(node, ctx) { return changer({ type: "cond", kind: "elseif", value: this.bool(a1(this, node, ctx)[0]) }); },
    else() { return changer({ type: "cond", kind: "else" }); },
    hidden() { return changer({ type: "hidden" }); },
    more() { return changer({ type: "more" }); },
    cond(node, ctx) {
        const v = a1(this, node, ctx);
        for (let i = 0; i + 1 < v.length; i += 2) if (this.bool(v[i])) return v[i + 1];
        return v.length % 2 ? v[v.length - 1] : 0;
    },

    // text
    print(node, ctx) {
        const v = a1(this, node, ctx)[0];
        return command((w) => this.printValue(v, w));
    },
    verbatimprint(node, ctx) {
        const v = a1(this, node, ctx)[0];
        return command((w) => w.text(toText(v)));
    },
    display(node, ctx) {
        const name = str(a1(this, node, ctx)[0], "the passage name");
        return command((w) => this.displayPassage(name, w));
    },
    textstyle(node, ctx) {
        const styles = [];
        for (const s of a1(this, node, ctx)) {
            for (const word of String(s).toLowerCase().split(/[\s,]+/)) {
                if (word === "bold") styles.push("bold");
                else if (word === "italic") styles.push("italic");
            }
        }
        return changer({ type: "style", styles });
    },
    collapse() { return changer({ type: "collapse" }); },
    nobr() { return changer({ type: "collapse" }); },
    verbatim() { return changer({ type: "verbatim" }); },
    dialog(node, ctx) {
        const v = a1(this, node, ctx);
        return command((w) => {
            w.paragraph();
            this.printValue(v[0], w);
            w.paragraph();
        });
    },

    // links
    link(node, ctx) { return changer({ type: "link", mode: "replace", label: toText(a1(this, node, ctx)[0]) }); },
    linkreveal(node, ctx) { return changer({ type: "link", mode: "reveal", label: toText(a1(this, node, ctx)[0]) }); },
    linkappend(node, ctx) { return changer({ type: "link", mode: "reveal", label: toText(a1(this, node, ctx)[0]) }); },
    linkrepeat(node, ctx) { return changer({ type: "link", mode: "repeat", label: toText(a1(this, node, ctx)[0]) }); },
    linkrerun(node, ctx) { return changer({ type: "link", mode: "rerun", label: toText(a1(this, node, ctx)[0]) }); },
    linkrevealgoto(node, ctx) {
        const v = a1(this, node, ctx);
        return changer({ type: "link", mode: "revealgoto", label: toText(v[0]), target: toText(v[1] ?? v[0]) });
    },
    linkgoto(node, ctx) {
        const v = a1(this, node, ctx);
        const label = toText(v[0]), target = toText(v.length > 1 ? v[1] : v[0]);
        return command((w) => this.engine.addLink(w, (lw) => this.renderSource(label, lw),
            () => this.engine.goto(target)));
    },
    linkundo(node, ctx) {
        const label = toText(a1(this, node, ctx)[0]);
        return command((w) => this.engine.addLink(w, (lw) => this.renderSource(label, lw),
            () => this.engine.undo()));
    },
    linkshow(node, ctx) {
        const v = a1(this, node, ctx);
        const label = toText(v[0]), targets = v.slice(1);
        return command((w) => {
            const rid = w.openRegion([]);
            this.engine.addLink(w, (lw) => this.renderSource(label, lw), () => {
                this.engine.fillRegion(rid, (bw) => this.renderSource(label, bw), "replace");
                MACROS.show.call(this, { args: [] }, ctx, targets).command();
            });
            w.closeRegion(rid);
        });
    },
    cyclinglink(node, ctx) { return cycling(this, node, ctx, true); },
    seqlink(node, ctx) { return cycling(this, node, ctx, false); },

    click(node, ctx) { return clickChanger(this, node, ctx, "click"); },
    mouseover(node, ctx) { return clickChanger(this, node, ctx, "click"); },
    mouseout(node, ctx) { return clickChanger(this, node, ctx, "click"); },
    clickreplace(node, ctx) { return clickChanger(this, node, ctx, "replace"); },
    mouseoverreplace(node, ctx) { return clickChanger(this, node, ctx, "replace"); },
    mouseoutreplace(node, ctx) { return clickChanger(this, node, ctx, "replace"); },
    clickappend(node, ctx) { return clickChanger(this, node, ctx, "append"); },
    mouseoverappend(node, ctx) { return clickChanger(this, node, ctx, "append"); },
    mouseoutappend(node, ctx) { return clickChanger(this, node, ctx, "append"); },
    clickprepend(node, ctx) { return clickChanger(this, node, ctx, "prepend"); },
    mouseoverprepend(node, ctx) { return clickChanger(this, node, ctx, "prepend"); },
    mouseoutprepend(node, ctx) { return clickChanger(this, node, ctx, "prepend"); },
    clickgoto(node, ctx) {
        const v = a1(this, node, ctx);
        this.bindings.push({ c: { target: v[0], mode: "click", goto: toText(v[1]) }, anchor: 0, render: () => {} });
        return NOOP;
    },
    mouseovergoto(node, ctx) { return MACROS.clickgoto.call(this, node, ctx); },

    // hooks elsewhere on the page
    replace(node, ctx) { return changer({ type: "target", mode: "replace", targets: this.hookTargets(a1(this, node, ctx)) }); },
    append(node, ctx) { return changer({ type: "target", mode: "append", targets: this.hookTargets(a1(this, node, ctx)) }); },
    prepend(node, ctx) { return changer({ type: "target", mode: "prepend", targets: this.hookTargets(a1(this, node, ctx)) }); },
    show(node, ctx, given) {
        const targets = given || a1(this, node, ctx);
        return command(() => {
            for (const t of targets) {
                if (!t || !t.hookref) continue;
                for (const id of this.engine.regionsNamed("?" + t.hookref)) {
                    const r = this.engine.regions.get(id);
                    if (r.hiddenBody) {
                        const body = r.hiddenBody;
                        r.hiddenBody = null;
                        this.engine.fillRegion(id, body, "replace");
                    }
                }
            }
        });
    },
    hide(node, ctx) {
        const targets = a1(this, node, ctx);
        return command(() => {
            for (const t of targets) {
                if (!t || !t.hookref) continue;
                for (const id of this.engine.regionsNamed("?" + t.hookref)) {
                    const r = this.engine.regions.get(id);
                    if (r.rerender) r.hiddenBody = r.rerender;
                    this.engine.fillRegion(id, () => {}, "replace");
                }
            }
        });
    },
    rerun(node, ctx) {
        const targets = a1(this, node, ctx);
        return command(() => {
            for (const t of targets) {
                if (!t || !t.hookref) continue;
                for (const id of this.engine.regionsNamed("?" + t.hookref)) {
                    const r = this.engine.regions.get(id);
                    if (r.rerender) this.engine.fillRegion(id, r.rerender, "replace");
                }
            }
        });
    },

    // time
    live(node, ctx) {
        const v = a1(this, node, ctx);
        return changer({ type: "live", ms: v.length ? num(v[0], "the delay") : 1000 });
    },
    after(node, ctx) {
        const v = a1(this, node, ctx);
        return changer({ type: "after", ms: v.length ? num(v[0], "the delay") : 1000 });
    },
    stop() { return command(() => this.engine.stopTimer()); },
    event() {
        this.engine.warn("Harlowe (event:)");
        return changer({ type: "cond", kind: "if", value: false });
    },

    // navigation
    goto(node, ctx) {
        const name = toText(a1(this, node, ctx)[0]);
        return command(() => this.engine.goto(name));
    },
    undo() {
        return command(() => {
            if (this.engine.canUndo()) {
                this.engine.warn("Harlowe (undo:) while rendering");
            }
        });
    },
    restart() { return NOOP; },
    reload() { return NOOP; },

    // loops
    for(node, ctx) {
        const v = a1(this, node, ctx);
        return changer({ type: "for", lambda: this.lambda(v[0], "(for:)"), values: v.slice(1) });
    },
    loop(node, ctx) { return MACROS.for.call(this, node, ctx); },

    // input
    prompt(node, ctx) {
        const v = a1(this, node, ctx);
        return this.engine.askLine(toText(v[0]), v.length > 1 ? toText(v[1]) : "");
    },
    confirm() {
        this.engine.warn("Harlowe (confirm:)");
        return true;
    },
    inputbox(node, ctx) { return inputBox(this, node, ctx); },
    forceinputbox(node, ctx) { return inputBox(this, node, ctx); },

    // data
    a(node, ctx) { return a1(this, node, ctx); },
    array(node, ctx) { return a1(this, node, ctx); },
    dm(node, ctx) {
        const v = a1(this, node, ctx);
        const m = new Map();
        for (let i = 0; i + 1 < v.length; i += 2) m.set(v[i], v[i + 1]);
        return m;
    },
    datamap(node, ctx) { return MACROS.dm.call(this, node, ctx); },
    ds(node, ctx) { return new Set(a1(this, node, ctx)); },
    dataset(node, ctx) { return new Set(a1(this, node, ctx)); },
    either(node, ctx) {
        const v = a1(this, node, ctx);
        if (!v.length) throw new Error("(either:) needs something to choose from");
        return v[this.engine.rng.int(0, v.length - 1)];
    },
    random(node, ctx) {
        const v = a1(this, node, ctx);
        const lo = Math.round(num(v[0])), hi = Math.round(num(v.length > 1 ? v[1] : 0));
        return this.engine.rng.int(Math.min(lo, hi), Math.max(lo, hi));
    },
    nth(node, ctx) {
        const v = a1(this, node, ctx);
        const n = num(v[0]), items = v.slice(1);
        return items[((Math.round(n) - 1) % items.length + items.length) % items.length];
    },
    range(node, ctx) {
        const [a, b] = a1(this, node, ctx).map((x) => Math.round(num(x)));
        const out = [];
        for (let i = Math.min(a, b); i <= Math.max(a, b); i++) out.push(i);
        return out;
    },
    count(node, ctx) {
        const [col, ...vals] = a1(this, node, ctx);
        let n = 0;
        for (const v of vals) {
            if (typeof col === "string") n += col.split(String(v)).length - 1;
            else if (Array.isArray(col)) n += col.filter((x) => deepEqual(x, v)).length;
            else throw new Error("(count:) needs a string or an array");
        }
        return n;
    },
    sorted(node, ctx) {
        let v = a1(this, node, ctx);
        if (v[0] && v[0].lambda) {
            const lam = v[0].lambda;
            return v.slice(1).map((x) => [x, this.runLambda(lam, x, ctx).value])
                .sort((p, q) => (p[1] < q[1] ? -1 : p[1] > q[1] ? 1 : 0)).map((p) => p[0]);
        }
        return v.slice().sort((p, q) => (typeof p === "number" && typeof q === "number" ? p - q
            : String(p).localeCompare(String(q), undefined, { numeric: true })));
    },
    shuffled(node, ctx) {
        const v = a1(this, node, ctx).slice();
        for (let i = v.length - 1; i > 0; i--) {
            const j = this.engine.rng.int(0, i);
            [v[i], v[j]] = [v[j], v[i]];
        }
        return v;
    },
    rotated(node, ctx) {
        const [n, ...v] = a1(this, node, ctx);
        const k = ((Math.round(num(n)) % v.length) + v.length) % v.length;
        return v.slice(-k).concat(v.slice(0, v.length - k));
    },
    reversed(node, ctx) { return a1(this, node, ctx).reverse(); },
    subarray(node, ctx) {
        const [arr, a, b] = a1(this, node, ctx);
        const seq = Array.isArray(arr) ? arr : [...String(arr)];
        const from = a < 0 ? seq.length + a : a - 1, to = b < 0 ? seq.length + b : b - 1;
        return seq.slice(Math.min(from, to), Math.max(from, to) + 1);
    },
    substring(node, ctx) {
        const [s, a, b] = a1(this, node, ctx);
        const seq = [...str(s)];
        const from = a < 0 ? seq.length + a : a - 1, to = b < 0 ? seq.length + b : b - 1;
        return seq.slice(Math.min(from, to), Math.max(from, to) + 1).join("");
    },
    repeated(node, ctx) {
        const [n, ...v] = a1(this, node, ctx);
        let out = [];
        for (let i = 0; i < n; i++) out = out.concat(v);
        return out;
    },
    interlaced(node, ctx) {
        const arrays = a1(this, node, ctx);
        const len = Math.min(...arrays.map((x) => x.length));
        const out = [];
        for (let i = 0; i < len; i++) for (const arr of arrays) out.push(arr[i]);
        return out;
    },
    find(node, ctx) {
        const [l, ...v] = a1(this, node, ctx);
        const lam = this.lambda(l, "(find:)");
        return v.filter((x) => this.runLambda(lam, x, ctx).pass);
    },
    altered(node, ctx) {
        const [l, ...v] = a1(this, node, ctx);
        const lam = this.lambda(l, "(altered:)");
        return v.map((x) => this.runLambda(lam, x, ctx).value);
    },
    allpass(node, ctx) {
        const [l, ...v] = a1(this, node, ctx);
        const lam = this.lambda(l, "(all-pass:)");
        return v.every((x) => this.runLambda(lam, x, ctx).pass);
    },
    pass(node, ctx) { return MACROS.allpass.call(this, node, ctx); },
    somepass(node, ctx) {
        const [l, ...v] = a1(this, node, ctx);
        const lam = this.lambda(l, "(some-pass:)");
        return v.some((x) => this.runLambda(lam, x, ctx).pass);
    },
    nonepass(node, ctx) { return !MACROS.somepass.call(this, node, ctx); },
    folded(node, ctx) {
        const [l, ...v] = a1(this, node, ctx);
        const lam = this.lambda(l, "(folded:)");
        let total = v.length ? v[v.length - 1] : 0;
        for (let i = v.length - 2; i >= 0; i--) {
            total = this.runLambda(lam, v[i], ctx, lam.making ? { [lam.making]: total } : null).value;
        }
        return total;
    },
    datanames(node, ctx) { return [...dm(a1(this, node, ctx)[0]).keys()].sort(); },
    dmnames(node, ctx) { return MACROS.datanames.call(this, node, ctx); },
    datavalues(node, ctx) {
        const m = dm(a1(this, node, ctx)[0]);
        return [...m.keys()].sort().map((k) => m.get(k));
    },
    dmvalues(node, ctx) { return MACROS.datavalues.call(this, node, ctx); },
    dataentries(node, ctx) {
        const m = dm(a1(this, node, ctx)[0]);
        return [...m.keys()].sort().map((k) => new Map([["name", k], ["value", m.get(k)]]));
    },
    dmentries(node, ctx) { return MACROS.dataentries.call(this, node, ctx); },

    // strings and numbers
    str(node, ctx) { return a1(this, node, ctx).map(toText).join(""); },
    string(node, ctx) { return MACROS.str.call(this, node, ctx); },
    text(node, ctx) { return MACROS.str.call(this, node, ctx); },
    num(node, ctx) {
        const v = a1(this, node, ctx)[0];
        const n = typeof v === "number" ? v : parseFloat(v);
        if (Number.isNaN(n)) throw new Error(`"${v}" isn't a number`);
        return n;
    },
    number(node, ctx) { return MACROS.num.call(this, node, ctx); },
    uppercase(node, ctx) { return str(a1(this, node, ctx)[0]).toUpperCase(); },
    lowercase(node, ctx) { return str(a1(this, node, ctx)[0]).toLowerCase(); },
    upperfirst(node, ctx) { const s = str(a1(this, node, ctx)[0]); return s.charAt(0).toUpperCase() + s.slice(1); },
    lowerfirst(node, ctx) { const s = str(a1(this, node, ctx)[0]); return s.charAt(0).toLowerCase() + s.slice(1); },
    words(node, ctx) { return str(a1(this, node, ctx)[0]).split(/\s+/).filter(Boolean); },
    trimmed(node, ctx) { return str(a1(this, node, ctx)[0]).trim(); },
    strrepeated(node, ctx) { const [n, s] = a1(this, node, ctx); return str(s).repeat(Math.max(0, n)); },
    stringrepeated(node, ctx) { return MACROS.strrepeated.call(this, node, ctx); },
    strreversed(node, ctx) { return [...str(a1(this, node, ctx)[0])].reverse().join(""); },
    stringreversed(node, ctx) { return MACROS.strreversed.call(this, node, ctx); },
    joined(node, ctx) { const [sep, ...v] = a1(this, node, ctx); return v.map(toText).join(toText(sep)); },
    round(node, ctx) { return Math.round(num(a1(this, node, ctx)[0])); },
    floor(node, ctx) { return Math.floor(num(a1(this, node, ctx)[0])); },
    ceil(node, ctx) { return Math.ceil(num(a1(this, node, ctx)[0])); },
    trunc(node, ctx) { return Math.trunc(num(a1(this, node, ctx)[0])); },
    abs(node, ctx) { return Math.abs(num(a1(this, node, ctx)[0])); },
    sign(node, ctx) { return Math.sign(num(a1(this, node, ctx)[0])); },
    sqrt(node, ctx) { return Math.sqrt(num(a1(this, node, ctx)[0])); },
    exp(node, ctx) { return Math.exp(num(a1(this, node, ctx)[0])); },
    log(node, ctx) { return Math.log(num(a1(this, node, ctx)[0])); },
    log10(node, ctx) { return Math.log10(num(a1(this, node, ctx)[0])); },
    log2(node, ctx) { return Math.log2(num(a1(this, node, ctx)[0])); },
    sin(node, ctx) { return Math.sin(num(a1(this, node, ctx)[0])); },
    cos(node, ctx) { return Math.cos(num(a1(this, node, ctx)[0])); },
    tan(node, ctx) { return Math.tan(num(a1(this, node, ctx)[0])); },
    pow(node, ctx) { const [a, b] = a1(this, node, ctx); return Math.pow(num(a), num(b)); },
    min(node, ctx) { return Math.min(...a1(this, node, ctx).map((x) => num(x))); },
    max(node, ctx) { return Math.max(...a1(this, node, ctx).map((x) => num(x))); },

    // story state
    history(node, ctx) {
        const past = this.engine.history.slice(0, -1);
        const v = a1(this, node, ctx);
        if (v[0] && v[0].lambda) {
            return past.filter((name) => this.runLambda(v[0].lambda, passageMap(this.engine, name), ctx).pass);
        }
        return past;
    },
    visited(node, ctx) {
        const v = a1(this, node, ctx);
        if (!v.length) return (this.engine.visits[this.engine.passageName] || 0) > 1;
        if (v[0] && v[0].lambda) {
            return this.engine.history.some((name) => this.runLambda(v[0].lambda, passageMap(this.engine, name), ctx).pass);
        }
        return (this.engine.visits[toText(v[0])] || 0) > 0;
    },
    passage(node, ctx) {
        const v = a1(this, node, ctx);
        const name = v.length ? toText(v[0]) : this.engine.passageName;
        if (!this.engine.passage(name)) throw new Error(`there's no passage named "${name}"`);
        return passageMap(this.engine, name);
    },
    passages(node, ctx) {
        const v = a1(this, node, ctx);
        const all = [...this.engine.story.passages.keys()].map((n) => passageMap(this.engine, n));
        return v[0] && v[0].lambda ? all.filter((p) => this.runLambda(v[0].lambda, p, ctx).pass) : all;
    },
    savedgames() { return new Map(); },
    currenttime() {
        const d = new Date();
        const h = d.getHours(), m = d.getMinutes();
        return `${((h + 11) % 12) + 1}:${String(m).padStart(2, "0")} ${h < 12 ? "AM" : "PM"}`;
    },
    currentdate() { return new Date().toDateString(); },
    monthday() { return new Date().getDate(); },
    weekday() { return ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][new Date().getDay()]; },
    source(node, ctx) { return toText(a1(this, node, ctx)[0]); },
};

function dm(v) {
    if (!(v instanceof Map)) throw new Error(`I expected a datamap, not ${typeName(v)}`);
    return v;
}

function passageMap(engine, name) {
    const p = engine.passage(name);
    return new Map([["name", p.name], ["source", p.text], ["tags", p.tags.slice()]]);
}

function clickChanger(self, node, ctx, mode) {
    const v = self.args(node, ctx);
    return changer({ type: "click", target: v[0], mode });
}

// (cycling-link: [bind $var,] "a", "b", …): a link whose label cycles.
function cycling(self, node, ctx, wrap) {
    const v = self.args(node, ctx);
    const bind = v[0] && v[0].bind ? v.shift().bind : null;
    const options = v.map(toText);
    return command((w) => {
        if (!options.length) return;
        let index = 0;
        const rid = w.openRegion([]);
        const draw = (bw) => {
            if (bind) self.assign(bind, options[index], ctx);
            const last = !wrap && index === options.length - 1;
            if (last) self.renderSource(options[index], bw);
            else self.engine.addLink(bw, (lw) => self.renderSource(options[index], lw), () => {
                index = (index + 1) % options.length;
                self.engine.fillRegion(rid, draw, "replace");
            });
        };
        draw(w);
        w.closeRegion(rid);
    });
}

// (input-box: bind $var, …): the plugin's command line fills the variable.
function inputBox(self, node, ctx) {
    const v = self.args(node, ctx);
    const bind = v.find((x) => x && x.bind);
    const initial = v.filter((x) => typeof x === "string").pop();
    return command((w) => {
        if (!bind) return;
        const rid = w.openRegion([]);
        const draw = (bw, value) => bw.text("[" + (value || "\u2026") + "]");
        if (initial !== undefined) self.assign(bind.bind, initial, ctx);
        draw(w, initial);
        w.closeRegion(rid);
        self.engine.requestLine((value) => {
            self.assign(bind.bind, value, ctx);
            self.engine.fillRegion(rid, (bw) => draw(bw, value), "replace");
        });
    });
}

// Exposed for tests.
export const _internal = { MarkupParser, tokenize, ExprParser };
