// twine/formats/sugarcube.js — SugarCube 2 (and Twine 1 / SugarCube 1) subset.
//
// SugarCube's expressions are JavaScript with a little sugar ($var, `to`, `eq`,
// `is`…), so after desugaring they run as real JS under QuickJS. The markup is
// parsed into nodes; container macros (<<if>>…<</if>>) carry their clauses.
// The DOM and jQuery do not exist: author scripts get inert stand-ins, and
// macros that only style or animate the page do nothing.

import { parseLink, parseDuration } from "./common.js";
import { GotoSignal } from "../engine.js";
import { clone } from "../state.js";
import { Writer } from "../writer.js";

// ── markup parser ────────────────────────────────────────────────────────────

// Container macros and the clause tags that split their bodies.
const CONTAINERS = {
    if: ["elseif", "else"], for: [], switch: ["case", "default"], link: [], button: [],
    linkappend: [], linkprepend: [], linkreplace: [], nobr: [], silently: [], capture: [],
    script: [], widget: [], timed: ["next"], repeat: [], type: [], done: [], append: [],
    prepend: [], replace: [], cycle: ["option", "optionsfrom"], listbox: ["option", "optionsfrom"],
    click: [], createaudiogroup: ["track"], createplaylist: ["track"], do: [], choice: [],
    message: [], remember: [], linkrevealgoto: [],
    // The popular third-party "replace/revise" macro set, done natively because
    // its own implementation is DOM manipulation.
    replacelink: ["becomes", "gains"], cyclinglink: ["becomes", "gains"],
};
// Twine 1 closers.
const LEGACY_CLOSE = { endif: "if", endfor: "for", endnobr: "nobr", endsilently: "silently",
    endclick: "click", endlink: "link", endbutton: "button", endwidget: "widget" };
// Macros whose body is raw text, not markup.
const RAW_BODY = new Set(["script"]);

const MACRO_RE = /<<(\/?)([A-Za-z][\w-]*|=|-)/y;
const NAKED_VAR_RE = /[$_][A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*|\[(?:\d+|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[$_][A-Za-z_$][\w$]*)\])*/y;
const TAG_RE = /<\/?[A-Za-z][\w-]*(?:\s+[^\s"'>\/=]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>"']+))?)*\s*\/?>/y;

function at(re, s, i) {
    re.lastIndex = i;
    return re.exec(s);
}

// End of a macro's arguments: index of the ">>" that closes it.
function argsEnd(s, i) {
    while (i < s.length) {
        const c = s[i];
        if (c === '"' || c === "'" || c === "`") {
            let j = i + 1;
            while (j < s.length && s[j] !== c) j += s[j] === "\\" ? 2 : 1;
            i = j + 1;
            continue;
        }
        if (c === "[" && s[i + 1] === "[") {
            const e = s.indexOf("]]", i + 2);
            if (e >= 0) { i = e + 2; continue; }
        }
        if (c === ">" && s[i + 1] === ">") return i;
        i++;
    }
    return -1;
}

class Parser {
    constructor(src, customContainers) {
        this.s = src;
        this.i = 0;
        this.custom = customContainers;
    }

    parse() {
        return this.seq(null).nodes;
    }

    isContainer(name) {
        if (name in CONTAINERS || this.custom.has(name)) return true;
        // An unknown macro with a matching closing tag later on is a container.
        return this.s.indexOf("<</" + name + ">>", this.i) >= 0;
    }

    // Read a macro tag at i: { close, name, args, end } or null.
    tagAt(i) {
        const m = at(MACRO_RE, this.s, i);
        if (!m) return null;
        const e = argsEnd(this.s, i + m[0].length);
        if (e < 0) return null;
        let name = m[2];
        let args = this.s.slice(i + m[0].length, e).trim();
        let close = !!m[1];
        if (LEGACY_CLOSE[name]) { close = true; name = LEGACY_CLOSE[name]; }
        if (name === "else" && /^if\b/.test(args)) { name = "elseif"; args = args.slice(2).trim(); }
        return { close, name, args, end: e + 2 };
    }

    // ctx: { name, clauses } of the container being filled, or null.
    seq(ctx) {
        const s = this.s;
        const nodes = [];
        let text = "";
        const flush = () => {
            if (text !== "") { nodes.push({ t: "text", v: text }); text = ""; }
        };
        const push = (n) => { flush(); nodes.push(n); };

        while (this.i < s.length) {
            const i = this.i, c = s[i];
            const lineStart = i === 0 || s[i - 1] === "\n";

            if (c === "<" && s[i + 1] === "<") {
                const tag = this.tagAt(i);
                if (tag) {
                    if (ctx && tag.close && tag.name === ctx.name) {
                        flush();
                        this.i = tag.end;
                        return { nodes, end: "close" };
                    }
                    if (ctx && !tag.close && ctx.clauses.includes(tag.name)) {
                        flush();
                        this.i = tag.end;
                        return { nodes, end: "clause", clause: tag };
                    }
                    if (tag.close) {                 // stray closer: ignore it
                        this.i = tag.end;
                        continue;
                    }
                    this.i = tag.end;
                    push(this.macroNode(tag));
                    continue;
                }
            }
            // Line continuation: a backslash ending a line (trailing spaces
            // allowed) or starting the next one joins the two lines.
            if (c === "\\") {
                const m = at(/\\[ \t]*\n[ \t]*\\?/y, s, i);
                if (m) { this.i += m[0].length; continue; }
                if (lineStart) { this.i++; continue; }   // "\" opening the passage
            }
            if (c === "\n") {
                const m = at(/\n[ \t]*\\/y, s, i);
                if (m) { this.i += m[0].length; continue; }
                push({ t: "br" });
                this.i++;
                continue;
            }
            if (c === "/" && (s[i + 1] === "*" || s[i + 1] === "%")) {
                const closer = s[i + 1] === "*" ? "*/" : "%/";
                const e = s.indexOf(closer, i + 2);
                if (e >= 0) { this.i = e + 2; continue; }
            }
            if (c === "<") {
                if (s.startsWith("<!--", i)) {
                    const e = s.indexOf("-->", i + 4);
                    this.i = e < 0 ? s.length : e + 3;
                    continue;
                }
                if (s.startsWith("<nowiki>", i)) {
                    const e = s.indexOf("</nowiki>", i);
                    if (e >= 0) { push({ t: "verbatim", v: s.slice(i + 8, e) }); this.i = e + 9; continue; }
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
                if (m) { text += m[0]; this.i += m[0].length; continue; }
            }
            if (s.startsWith('"""', i)) {
                const e = s.indexOf('"""', i + 3);
                if (e >= 0) { push({ t: "verbatim", v: s.slice(i + 3, e) }); this.i = e + 3; continue; }
            }
            if (s.startsWith("{{{", i)) {
                const e = s.indexOf("}}}", i + 3);
                if (e >= 0) { push({ t: "code", v: s.slice(i + 3, e) }); this.i = e + 3; continue; }
            }
            if (lineStart) {
                let m;
                if ((m = at(/(!{1,6})[ \t]*/y, s, i))) { push({ t: "heading", level: m[1].length }); this.i += m[0].length; continue; }
                if ((m = at(/-{4,}[ \t]*(?=\n|$)/y, s, i))) { push({ t: "hr" }); this.i += m[0].length; continue; }
                if ((m = at(/([*#]+)[ \t]+/y, s, i))) { push({ t: "bullet", depth: m[1].length, numbered: m[1][0] === "#" }); this.i += m[0].length; continue; }
            }
            if (c === "[" && (s[i + 1] === "[" || s.startsWith("[img[", i))) {
                const link = this.linkAt(i);
                if (link) { push(link.node); this.i = link.end; continue; }
            }
            if (c === "@" && s[i + 1] === "@") {
                const e = s.indexOf("@@", i + 2);
                if (e >= 0) {
                    const inner = s.slice(i + 2, e);
                    const semi = inner.indexOf(";");
                    const body = semi >= 0 ? inner.slice(semi + 1) : inner;
                    push({ t: "inline", nodes: new Parser(body, this.custom).parse() });
                    this.i = e + 2;
                    continue;
                }
            }
            if (c === "$" || (c === "_" && !/[\w$]/.test(s[i - 1] || ""))) {
                const m = at(NAKED_VAR_RE, s, i);
                if (m && m[0].length > 1 && !(c === "$" && s[i + 1] === "$")) {
                    push({ t: "naked", expr: m[0] });
                    this.i += m[0].length;
                    continue;
                }
                if (c === "$" && s[i + 1] === "$") { text += "$"; this.i += 2; continue; }
            }
            const pairs = { "''": "bold", "//": "italic", "__": "underline", "==": "strike", "^^": "sup", "~~": "sub" };
            const two = s.slice(i, i + 2);
            if (pairs[two] && !(two === "//" && s[i - 1] === ":")) {
                push({ t: "toggle", k: pairs[two], raw: two });
                this.i += 2;
                continue;
            }
            text += c;
            this.i++;
        }
        flush();
        return { nodes, end: "eof" };
    }

    // [[text|target][setter]] and [img[title|src][target][setter]]
    linkAt(i) {
        const s = this.s;
        if (s.startsWith("[img[", i)) {
            const m = at(/\[img\[((?:[^\]]|\](?!\]))*?)\](?:\[((?:[^\]])*)\])?(?:\[((?:[^\]])*)\])?\]/y, s, i);
            if (!m) return null;
            const pipe = m[1].indexOf("|");
            const title = pipe >= 0 ? m[1].slice(0, pipe) : "";
            const src = pipe >= 0 ? m[1].slice(pipe + 1) : m[1];
            return { node: { t: "image", title, src, target: m[2], setter: m[3] }, end: i + m[0].length };
        }
        const e = s.indexOf("]]", i + 2);
        if (e < 0) return null;
        const inner = s.slice(i + 2, e);
        const split = inner.indexOf("][");
        const body = split >= 0 ? inner.slice(0, split) : inner;
        const setter = split >= 0 ? inner.slice(split + 2) : null;
        const { label, target } = parseLink(body, true);
        return { node: { t: "link", label, target: target.trim(), setter }, end: e + 2 };
    }

    macroNode(tag) {
        const node = { t: "macro", name: tag.name, args: tag.args, sections: null };
        if (!this.isContainer(tag.name)) return node;
        const clauses = CONTAINERS[tag.name] || [];
        const sections = [{ name: tag.name, args: tag.args }];
        if (RAW_BODY.has(tag.name)) {
            const closer = "<</" + tag.name + ">>";
            const e = this.s.indexOf(closer, this.i);
            const end = e < 0 ? this.s.length : e;
            sections[0].raw = this.s.slice(this.i, end);
            sections[0].nodes = [];
            this.i = e < 0 ? end : end + closer.length;
            node.sections = sections;
            return node;
        }
        for (;;) {
            const start = this.i;
            const r = this.seq({ name: tag.name, clauses });
            const cur = sections[sections.length - 1];
            cur.nodes = r.nodes;
            cur.raw = this.s.slice(start, r.end === "eof" ? this.i : this.s.lastIndexOf("<<", this.i - 1));
            if (r.end === "clause") {
                sections.push({ name: r.clause.name, args: r.clause.args });
                continue;
            }
            break;
        }
        node.sections = sections;
        return node;
    }
}

// ── expressions ──────────────────────────────────────────────────────────────

const SUGAR = { to: "=", eq: "==", neq: "!=", is: "===", isnot: "!==", gt: ">", gte: ">=",
    lt: "<", lte: "<=", and: "&&", or: "||", not: "!",
    def: '"undefined" !== typeof', ndef: '"undefined" === typeof' };

// SugarCube's TwineScript → JavaScript, respecting strings and property names.
export function desugar(src) {
    let out = "";
    let i = 0;
    const s = src;
    while (i < s.length) {
        const c = s[i];
        if (c === '"' || c === "'" || c === "`") {
            let j = i + 1;
            while (j < s.length && s[j] !== c) j += s[j] === "\\" ? 2 : 1;
            out += s.slice(i, j + 1);
            i = j + 1;
            continue;
        }
        if (c === "$" && /[A-Za-z_]/.test(s[i + 1] || "") && !/[\w$.]/.test(s[i - 1] || "")) {
            const m = at(/\$([A-Za-z_$][\w$]*)/y, s, i);
            out += "State.variables." + m[1];
            i += m[0].length;
            continue;
        }
        if (c === "_" && /[A-Za-z]/.test(s[i + 1] || "") && !/[\w$.]/.test(s[i - 1] || "")) {
            const m = at(/_([A-Za-z_$][\w$]*)/y, s, i);
            out += "State.temporary." + m[1];
            i += m[0].length;
            continue;
        }
        if (/[A-Za-z]/.test(c) && !/[\w$.]/.test(s[i - 1] || "")) {
            const m = at(/[A-Za-z_$][\w$]*/y, s, i);
            const w = m[0];
            out += Object.prototype.hasOwnProperty.call(SUGAR, w) ? SUGAR[w] : w;
            i += w.length;
            continue;
        }
        out += c;
        i++;
    }
    return out;
}

class LoopSignal {
    constructor(kind) { this.kind = kind; }
}

// Something that swallows any use: jQuery calls, document lookups, UI APIs.
function inert(onWiki) {
    const fn = function () { return proxy; };
    const proxy = new Proxy(fn, {
        get(_t, prop) {
            if (prop === "wiki" && onWiki) return (text) => { onWiki(String(text)); return proxy; };
            if (prop === "length") return 0;
            if (prop === Symbol.toPrimitive) return () => "";
            if (prop === "then" || prop === Symbol.iterator) return undefined;
            if (prop === "toString" || prop === "valueOf") return () => "";
            return proxy;
        },
        set() { return true; },
        apply() { return proxy; },
        construct() { return proxy; },
    });
    return proxy;
}

// ── the format ───────────────────────────────────────────────────────────────

export class SugarCube {
    constructor(engine, opts) {
        this.engine = engine;
        this.legacy = !!(opts && opts.legacy);
        this.temps = {};
        this.cache = new Map();
        this.fnCache = new Map();
        this.widgets = new Map();       // name -> { nodes, container }
        this.custom = new Map();        // Macro.add definitions
        this.depth = 0;
        this.outputs = [];              // writer stack for custom macros' output
        this.done = [];
        this.buildEnv();
    }

    buildEnv() {
        const self = this, engine = this.engine;
        const story = engine.story;
        const passageObj = (p) => p && ({ title: p.name, name: p.name, text: p.text, tags: p.tags.slice(),
            description() { return p.text.slice(0, 100); }, processText() { return p.text; } });
        const State = {
            get variables() { return engine.vars; },
            get temporary() { return self.temps; },
            get passage() { return engine.passageName; },
            get turns() { return engine.history.length; },
            get length() { return engine.history.length; },
            get size() { return engine.history.length; },
            get active() { return { title: engine.passageName, variables: engine.vars }; },
            hasPlayed(name) { return (engine.visits[name] || 0) > 0; },
            getVar(name) { return self.evaluate(name); },
            setVar(name, value) { self.run(`${name} = __value`, { __value: value }); return true; },
            random() { return engine.rng.next(); },
            prng: { get isEnabled() { return true; }, get pull() { return 0; }, get seed() { return 0; } },
            metadata: new Map(),
            restart() { engine.warn("State.restart()"); },
        };
        State.metadata.get = State.metadata.get.bind(State.metadata);
        const passageNamed = (name) => passageObj(engine.passage(name));
        this.env = {
            State,
            setup: {},
            settings: {},
            Setting: inert(),
            Config: new Proxy({}, { get: (t, k) => (k in t ? t[k] : (t[k] = inert())), set: () => true }),
            Story: {
                get title() { return story.name; },
                get ifId() { return story.ifid; },
                has: (name) => engine.passage(name) !== undefined,
                get: passageNamed,
                lookup: (prop, value) => [...story.passages.values()]
                    .filter((p) => (prop === "tags" ? p.tags.includes(value) : p[prop] === value)).map(passageObj),
                filter: (fn) => [...story.passages.values()].map(passageObj).filter(fn),
            },
            Engine: {
                play: (name) => engine.requestGoto(name),
                show: () => {},
                backward: () => engine.warn("Engine.backward()"),
                forward: () => {},
                restart: () => engine.warn("Engine.restart()"),
                get state() { return "idle"; },
                isIdle: () => true,
            },
            // SugarCube 1's macro registry; libraries probe it before Macro.add.
            macros: new Proxy({}, {
                set: (t, k, v) => {
                    t[k] = v;
                    if (v && typeof v.handler === "function") self.custom.set(String(k), v);
                    return true;
                },
            }),
            Macro: {
                add(names, def) {
                    for (const n of [].concat(names)) self.custom.set(n, def);
                },
                has: (n) => self.custom.has(n) || n in CONTAINERS,
                tags: { register() {}, unregister() {}, get: () => null, has: () => false },
                get: (n) => self.custom.get(n),
                delete: (n) => self.custom.delete(n),
            },
            random: (a, b) => {
                if (b === undefined) { b = a; a = 0; }
                return engine.rng.int(Math.floor(a), Math.floor(b));
            },
            randomFloat: (a, b) => {
                if (b === undefined) { b = a; a = 0; }
                return a + engine.rng.next() * (b - a);
            },
            either: (...v) => {
                const flat = v.flat();
                return flat[engine.rng.int(0, flat.length - 1)];
            },
            visited: (...names) => {
                if (!names.length) names = [engine.passageName];
                return Math.min(...names.flat().map((n) => engine.visits[n] || 0));
            },
            visitedTags: (...tags) => engine.history.filter((n) => {
                const p = engine.passage(n);
                return p && tags.flat().every((t) => p.tags.includes(t));
            }).length,
            lastVisited: (...names) => {
                const h = engine.history;
                return Math.max(...names.flat().map((n) => {
                    const i = h.lastIndexOf(n);
                    return i < 0 ? -1 : h.length - 1 - i;
                }));
            },
            previous: () => {
                const h = engine.history;
                for (let i = h.length - 2; i >= 0; i--) if (h[i] !== engine.passageName) return h[i];
                return "";
            },
            passage: () => engine.passageName,
            tags: (name) => (engine.passage(name || engine.passageName) || { tags: [] }).tags.slice(),
            turns: () => engine.history.length,
            time: () => engine.clock,
            memorize: (k, v) => { self.env.setup["__mem_" + k] = v; },
            recall: (k, d) => { const v = self.env.setup["__mem_" + k]; return v === undefined ? d : v; },
            forget: (k) => { delete self.env.setup["__mem_" + k]; },
            clone: (v) => clone(v),
            UI: inert(), UIBar: inert(), Dialog: inert(), Save: inert(), SimpleAudio: inert(),
            LoadScreen: inert(), L10n: inert(), l10nStrings: {},
            Wikifier: function (_dest, text) { self.wikiIntoCurrent(String(text)); },
            importScripts: () => Promise.resolve(), importStyles: () => Promise.resolve(),
            $: inert(), jQuery: inert(), document: inert(), window: globalThis,
            prehistory: {}, predisplay: {}, prerender: {}, postdisplay: {}, postrender: {},
            // Author scripts and macro libraries check this before loading.
            version: {
                title: "SugarCube", major: 2, minor: 36, patch: 1, prerelease: null, build: 0,
                extensions: {},
                short() { return "2.36.1"; }, long() { return "SugarCube v2.36.1"; },
                toString() { return "2.36.1"; },
            },
        };
        this.env.SugarCube = { version: this.env.version, Config: this.env.Config, Engine: this.env.Engine,
            Macro: this.env.Macro, State: State, Story: this.env.Story, setup: this.env.setup };
        this.env.V = State.variables;
        this.env.T = this.temps;
        this.env.Wikifier.wikifyEval = (text) => { self.wikiIntoCurrent(String(text)); return inert(); };
        this.envNames = Object.keys(this.env);
    }

    envValues() {
        this.env.V = this.engine.vars;
        this.env.T = this.temps;
        return this.envNames.map((n) => this.env[n]);
    }

    compile(body) {
        let fn = this.fnCache.get(body);
        if (!fn) {
            fn = new Function(...this.envNames, "__locals", body);
            this.fnCache.set(body, fn);
        }
        return fn;
    }

    evaluate(expr, locals) {
        const js = desugar(expr);
        return this.compile("with (__locals || {}) { return (" + js + "\n); }")(...this.envValues(), locals);
    }

    run(code, locals) {
        const js = desugar(code);
        return this.compile("with (__locals || {}) {" + js + "\n}")(...this.envValues(), locals);
    }

    runScript(code) {
        return this.compile(code)(...this.envValues(), null);
    }

    parsed(src) {
        let nodes = this.cache.get(src);
        if (!nodes) {
            nodes = new Parser(src, this.containerWidgets()).parse();
            if (this.cache.size > 500) this.cache.clear();
            this.cache.set(src, nodes);
        }
        return nodes;
    }

    containerWidgets() {
        const set = new Set();
        for (const [n, w] of this.widgets) if (w.container) set.add(n);
        for (const [n, d] of this.custom) if (d && d.tags) set.add(n);
        return set;
    }

    // ── lifecycle ──────────────────────────────────────────────────────────

    init() {
        const engine = this.engine;
        for (const script of engine.story.scripts) {
            try {
                this.runScript(script);
            } catch (e) {
                engine.warn("author script error: " + (e && e.message));
            }
        }
        for (const p of engine.story.passages.values()) {
            if (p.tags.includes("widget")) this.silently(p.text);
        }
        const init = engine.passage("StoryInit");
        if (init) this.silently(init.text);
    }

    // Variables set by StoryInit live in the first moment's snapshot, but
    // `setup` and widgets live here: they're rebuilt by init, not saved.
    render(passage, w) {
        this.temps = {};
        this.done = [];
        this.depth = 0;
        const engine = this.engine;
        const special = (name) => engine.passage(name);
        if (special("PassageReady")) this.silently(special("PassageReady").text);
        if (special("PassageHeader")) this.renderText(special("PassageHeader").text, w);
        this.renderPassage(passage, w);
        if (special("PassageFooter")) this.renderText(special("PassageFooter").text, w);
        if (special("PassageDone")) this.silently(special("PassageDone").text);
        for (const fn of this.done) fn(w);
    }

    renderPassage(p, w) {
        const nobr = p.tags.includes("nobr");
        if (nobr) w.beginStyle("collapse");
        this.renderText(p.text, w);
        if (nobr) w.endStyle("collapse");
    }

    renderText(src, w) {
        if (++this.depth > 60) {
            this.depth--;
            throw new Error("too much nesting (does a passage include itself?)");
        }
        try {
            this.renderNodes(this.parsed(src), w);
        } finally {
            this.depth--;
        }
    }

    silently(src) {
        const w = new Writer(this.engine);
        w.beginStyle("hidden");
        this.renderText(src, w);
    }

    wikiIntoCurrent(text) {
        const w = this.outputs[this.outputs.length - 1];
        if (w) this.renderText(text, w);
    }

    onHtmlLink(_target, attrs) {
        if (attrs["data-setter"]) this.run(attrs["data-setter"]);
    }

    // ── rendering ──────────────────────────────────────────────────────────

    renderNodes(nodes, w) {
        const toggles = {};
        let heading = null;
        for (const n of nodes) {
            switch (n.t) {
                case "text": w.markup(n.v); break;
                case "verbatim": w.text(n.v); break;
                case "code": w.beginStyle("pre"); w.text(n.v); w.endStyle("pre"); break;
                case "br":
                    if (heading) { w.endStyle(heading); heading = null; }
                    w.newline();
                    break;
                case "toggle":
                    if (n.k === "bold" || n.k === "italic") {
                        if (toggles[n.k]) { w.endStyle(n.k); toggles[n.k] = false; }
                        else { w.beginStyle(n.k); toggles[n.k] = true; }
                    }
                    break;
                case "heading":
                    heading = n.level <= 3 ? "header" : "sub";
                    w.beginStyle(heading);
                    break;
                case "bullet": w.text("\u00a0\u00a0".repeat(n.depth - 1) + "\u2022\u00a0"); break;
                case "hr": w.text("\u2014 \u2014 \u2014"); break;
                case "inline": this.renderNodes(n.nodes, w); break;
                case "link": this.renderLinkNode(n, w); break;
                case "image": {
                    // [img[$var]]: a source that is a variable is looked up.
                    const draw = (iw) => this.guard(iw, "[img[" + n.src + "]]", () => {
                        const src = /^[$_][\w$.]*$/.test(n.src.trim()) ? this.evaluate(n.src.trim()) : n.src;
                        this.engine.image(iw, { src, alt: n.title });
                    });
                    if (n.target) {
                        this.engine.addLink(w, draw, () => {
                            if (n.setter) this.run(n.setter);
                            this.engine.goto(n.target);
                        });
                    } else {
                        draw(w);
                    }
                    break;
                }
                case "naked": this.guard(w, n.expr, () => this.printValue(this.evaluate(n.expr), w, false)); break;
                case "macro": this.guard(w, "<<" + n.name + ">>", () => this.macro(n, w)); break;
            }
        }
        if (heading) w.endStyle(heading);
        for (const k in toggles) if (toggles[k]) w.endStyle(k);
    }

    guard(w, what, fn) {
        try {
            fn();
        } catch (e) {
            if (e instanceof GotoSignal || e instanceof LoopSignal) throw e;
            w.error(`${what}: ${e && e.message}`);
        }
    }

    renderLinkNode(n, w) {
        let target = n.target;
        // [[Go|$destination]]: a target that is a variable is evaluated.
        if (/^[$_][A-Za-z]/.test(target) && !this.engine.passage(target)) {
            try { target = String(this.evaluate(target)); } catch (_) { /* keep literal */ }
        }
        this.engine.addLink(w, (lw) => this.renderText(n.label, lw), () => {
            if (n.setter) this.run(n.setter);
            this.engine.goto(target);
        });
    }

    printValue(v, w, wiki) {
        if (v === undefined || v === null) return;
        const text = typeof v === "object" ? (Array.isArray(v) ? v.join(", ") : JSON.stringify(v)) : String(v);
        if (wiki) this.renderText(text, w);
        else w.text(text);
    }

    // SugarCube's macro argument syntax: space separated strings, [[links]],
    // `expressions`, $variables, numbers and bare words.
    parseArgs(raw) {
        const out = [];
        let i = 0;
        const s = raw;
        while (i < s.length) {
            const c = s[i];
            if (/\s/.test(c)) { i++; continue; }
            if (c === '"' || c === "'") {
                let j = i + 1, v = "";
                while (j < s.length && s[j] !== c) {
                    if (s[j] === "\\") { v += s[j + 1]; j += 2; } else v += s[j++];
                }
                out.push(v);
                i = j + 1;
                continue;
            }
            if (c === "`") {
                const e = s.indexOf("`", i + 1);
                out.push(this.evaluate(s.slice(i + 1, e < 0 ? s.length : e)));
                i = e < 0 ? s.length : e + 1;
                continue;
            }
            if (c === "[" && (s[i + 1] === "[" || s.startsWith("[img[", i))) {
                const e = s.indexOf("]]", i);
                const inner = s.slice(i + 2, e < 0 ? s.length : e);
                const split = inner.indexOf("][");
                const { label, target } = parseLink(split >= 0 ? inner.slice(0, split) : inner, true);
                out.push({ isLink: true, text: label, link: target.trim(), setter: split >= 0 ? inner.slice(split + 2) : null });
                i = e < 0 ? s.length : e + 2;
                continue;
            }
            const m = at(/[^\s]+/y, s, i);
            const word = m[0];
            i += word.length;
            if (/^[$_][A-Za-z]/.test(word) || /^(setup|settings)\./.test(word)) out.push(this.evaluate(word));
            else if (word === "true" || word === "false") out.push(word === "true");
            else if (word === "null") out.push(null);
            else if (word === "undefined") out.push(undefined);
            else if (word === "NaN") out.push(NaN);
            else if (/^-?\d+(\.\d+)?$/.test(word)) out.push(Number(word));
            else out.push(word);
        }
        return out;
    }

    // A passage name from a macro argument (string or [[link]]).
    passageArg(v) {
        return v && v.isLink ? v.link : String(v);
    }

    renderSection(section, w) {
        this.renderNodes(section.nodes || [], w);
    }

    silentSection(section) {
        const w = new Writer(this.engine);
        w.beginStyle("hidden");
        this.renderSection(section, w);
    }

    macro(n, w) {
        const impl = MACROS[n.name];
        if (impl) return impl.call(this, n, w);
        if (this.widgets.has(n.name)) return this.callWidget(n, w);
        if (this.custom.has(n.name)) return this.callCustom(n, w);
        if (SILENT.has(n.name)) return;
        this.engine.warn(`SugarCube <<${n.name}>>`);
    }

    callWidget(n, w) {
        const widget = this.widgets.get(n.name);
        const args = this.parseArgs(n.args);
        args.raw = n.args;
        args.full = n.args;
        const saved = { args: this.temps.args, contents: this.temps.contents };
        this.temps.args = args;
        this.temps._args = args;
        if (n.sections) this.temps.contents = n.sections[0].raw || "";
        try {
            this.renderNodes(widget.nodes, w);
        } finally {
            this.temps.args = saved.args;
            this.temps.contents = saved.contents;
        }
    }

    callCustom(n, w) {
        const def = this.custom.get(n.name);
        const args = this.parseArgs(n.args);
        args.raw = n.args;
        args.full = desugar(n.args);
        const self = this;
        const output = inert((text) => self.renderText(text, w));
        const ctx = {
            name: n.name, args, self: def, output,
            payload: (n.sections || [{ name: n.name, args: n.args, raw: "" }]).map((s) => ({
                name: s.name, args: this.parseArgs(s.args || ""), contents: s.raw || "",
            })),
            error: (msg) => { w.error(`<<${n.name}>>: ${msg}`); return false; },
            addShadow() {}, createShadowWrapper: (fn) => fn, createDebugView() {},
            parser: inert(), parent: null, contextHas: () => false, contextSelect: () => null,
        };
        this.outputs.push(w);
        try {
            def.handler.call(ctx);
        } finally {
            this.outputs.pop();
        }
    }

    // A region target of <<replace>>/<<append>>/<<remove>>: "#id", ".class".
    selectorRegions(selector) {
        const ids = [];
        for (const part of String(selector).split(",")) {
            const sel = part.trim();
            if (sel.startsWith("#") || sel.startsWith(".")) ids.push(...this.engine.regionsNamed(sel));
            else if (sel) this.engine.warn(`SugarCube selector "${sel}"`);
        }
        return ids;
    }
}

// Macros that only affect presentation, sound or the browser.
const SILENT = new Set(["audio", "cacheaudio", "createaudiogroup", "createplaylist", "masteraudio",
    "playlist", "removeaudiogroup", "removeplaylist", "waitforaudio", "track", "addclass",
    "removeclass", "toggleclass", "copy", "redo", "stopallaudio", "unsetaudio", "css", "addstyle",
    "savesettings", "loadsettings", "bookmark", "saves", "restart", "theme"]);

function linkLabelAndTarget(self, args) {
    const first = args[0];
    if (first && first.isLink) return { label: first.text, target: first.link, setter: first.setter };
    return { label: String(first ?? ""), target: args.length > 1 ? self.passageArg(args[1]) : null };
}

function loopGuard(fn) {
    try {
        fn();
        return "ok";
    } catch (e) {
        if (e instanceof LoopSignal) return e.kind;
        throw e;
    }
}

const MACROS = {
    if(n, w) {
        for (const s of n.sections) {
            if (s.name === "else" || this.evaluate(s.args)) {
                this.renderSection(s, w);
                return;
            }
        }
    },
    set(n) { this.run(n.args); },
    run(n) { this.run(n.args); },
    remember(n) { this.run(n.args); },
    unset(n) {
        for (const name of n.args.split(/[\s,]+/)) {
            if (name.startsWith("$")) delete this.engine.vars[name.slice(1)];
            else if (name.startsWith("_")) delete this.temps[name.slice(1)];
        }
    },
    print(n, w) { this.printValue(this.evaluate(n.args), w, true); },
    "="(n, w) { this.printValue(this.evaluate(n.args), w, true); },
    "-"(n, w) { this.printValue(this.evaluate(n.args), w, false); },
    include(n, w) {
        const args = this.parseArgs(n.args);
        const p = this.engine.passage(this.passageArg(args[0]));
        if (!p) throw new Error(`there is no passage named "${this.passageArg(args[0])}"`);
        this.renderPassage(p, w);
    },
    display(n, w) { MACROS.include.call(this, n, w); },
    nobr(n, w) {
        w.beginStyle("collapse");
        this.renderSection(n.sections[0], w);
        w.endStyle("collapse");
    },
    silently(n) { this.silentSection(n.sections[0]); },
    capture(n, w) { this.renderSection(n.sections[0], w); },
    type(n, w) { this.renderSection(n.sections[0], w); },
    do(n, w) { this.renderSection(n.sections[0], w); },
    done(n) {
        const section = n.sections[0];
        this.done.push(() => this.silentSection(section));
    },
    script(n) { this.runScript(n.sections[0].raw || ""); },
    widget(n) {
        const args = this.parseArgs(n.args);
        this.widgets.set(String(args[0]), { nodes: n.sections[0].nodes, container: args.includes("container") });
    },
    goto(n) {
        const args = this.parseArgs(n.args);
        this.engine.goto(this.passageArg(args[0]));
    },
    back(n, w) {
        const args = this.parseArgs(n.args);
        const label = args[0] && args[0].isLink ? args[0].text : (args[0] ?? (this.legacy ? "Back" : "Back"));
        if (!this.engine.canUndo()) return;
        this.engine.addLink(w, String(label), () => this.engine.undo());
    },
    return(n, w) {
        const args = this.parseArgs(n.args);
        const label = args[0] && args[0].isLink ? args[0].text : (args[0] ?? "Return");
        const prev = this.env.previous();
        if (!prev) return;
        this.engine.addLink(w, String(label), () => this.engine.goto(prev));
    },
    link(n, w) {
        const args = this.parseArgs(n.args);
        const { label, target, setter } = linkLabelAndTarget(this, args);
        const section = n.sections ? n.sections[0] : null;
        this.engine.addLink(w, (lw) => this.renderText(label, lw), () => {
            if (setter) this.run(setter);
            if (section) this.silentSection(section);
            if (target) this.engine.goto(target);
        });
    },
    button(n, w) { MACROS.link.call(this, n, w); },
    click(n, w) { MACROS.link.call(this, n, w); },
    choice(n, w) {
        const args = this.parseArgs(n.args);
        const { label, target } = args[0] && args[0].isLink
            ? { label: args[0].text, target: args[0].link }
            : { label: String(args[1] ?? args[0]), target: String(args[0]) };
        this.engine.addLink(w, (lw) => this.renderText(label, lw), () => this.engine.goto(target));
    },
    actions(n, w) {
        for (const a of this.parseArgs(n.args)) {
            const target = this.passageArg(a);
            if (this.engine.visits[target]) continue;
            w.text("\u2022 ");
            this.engine.addLink(w, a && a.isLink ? a.text : target, () => this.engine.goto(target));
            w.newline();
        }
    },
    linkreplace(n, w) {
        const label = String(this.parseArgs(n.args)[0] ?? "");
        const section = n.sections[0];
        const rid = w.openRegion([]);
        this.engine.addLink(w, (lw) => this.renderText(label, lw), () =>
            this.engine.fillRegion(rid, (bw) => this.renderSection(section, bw), "replace"));
        w.closeRegion(rid);
    },
    linkappend(n, w) { linkAdd(this, n, w, false); },
    linkprepend(n, w) { linkAdd(this, n, w, true); },
    message(n, w) { linkAdd(this, n, w, false); },
    textbox(n, w) { textField(this, n, w, false); },
    textarea(n, w) { textField(this, n, w, false); },
    numberfield(n, w) { textField(this, n, w, true); },
    textinput(n, w) { textField(this, n, w, false); },
    cycle(n, w) { cycleMacro(this, n, w); },
    listbox(n, w) { cycleMacro(this, n, w); },
    checkbox(n, w) {
        const [name, off, on, ...rest] = this.parseArgs(n.args);
        const get = () => this.evaluate(String(name));
        if (rest.includes("checked") && get() === undefined) this.run(`${name} = __v`, { __v: on });
        const rid = w.openRegion([]);
        const draw = (bw) => {
            const checked = get() === on;
            this.engine.addLink(bw, (checked ? "[x] " : "[ ] ") + (rest.find((x) => typeof x === "string" && x !== "checked") || ""), () => {
                this.run(`${name} = __v`, { __v: checked ? off : on });
                this.engine.fillRegion(rid, draw, "replace");
            });
        };
        draw(w);
        w.closeRegion(rid);
    },
    radiobutton(n, w) {
        const [name, value] = this.parseArgs(n.args);
        this.engine.addLink(w, "( ) " + String(value), () => this.run(`${name} = __v`, { __v: value }));
    },
    timed(n, w) {
        let delay = 0;
        for (const s of n.sections) {
            delay += parseDuration(this.parseArgs(s.args || "")[0] ?? "0s") || 0;
            const rid = w.openRegion([]);
            w.closeRegion(rid);
            this.engine.after(delay, () => this.engine.fillRegion(rid, (bw) => this.renderSection(s, bw), "replace"));
        }
    },
    repeat(n, w) {
        const ms = parseDuration(this.parseArgs(n.args)[0] ?? "1s") || 1000;
        const rid = w.openRegion([]);
        w.closeRegion(rid);
        const section = n.sections[0];
        this.engine.after(Math.max(ms, 250), () => this.engine.fillRegion(rid, (bw) => this.renderSection(section, bw), "append"), true);
    },
    stop() { this.engine.stopTimer(); },
    switch(n, w) {
        const value = this.evaluate(n.sections[0].args);
        for (const s of n.sections.slice(1)) {
            if (s.name === "default" || this.parseArgs(s.args).some((v) => v === value)) {
                this.renderSection(s, w);
                return;
            }
        }
    },
    for(n, w) {
        const section = n.sections[0];
        const head = n.args.trim();
        let count = 0;
        const body = () => {
            if (++count > 10000) throw new Error("the loop ran too long");
            return loopGuard(() => this.renderSection(section, w));
        };
        const range = /^(?:([$_][\w$]+)\s*,\s*)?([$_][\w$]+)\s+range\s+([\s\S]+)$/.exec(head);
        if (range) {
            const collection = this.evaluate(range[3]);
            const entries = collection instanceof Map ? [...collection.entries()]
                : collection instanceof Set ? [...collection].map((v, i) => [i, v])
                : typeof collection === "number" ? Array.from({ length: collection }, (_, i) => [i, i])
                : Array.isArray(collection) || typeof collection === "string" ? [...collection].map((v, i) => [i, v])
                : Object.entries(collection || {});
            for (const [k, v] of entries) {
                if (range[1]) this.run(`${range[1]} = __k`, { __k: k });
                this.run(`${range[2]} = __v`, { __v: v });
                if (body() === "break") break;
            }
            return;
        }
        const parts = head.split(";");
        if (parts.length === 3) {
            if (parts[0].trim()) this.run(parts[0]);
            while (!parts[1].trim() || this.evaluate(parts[1])) {
                if (body() === "break") break;
                if (parts[2].trim()) this.run(parts[2]);
            }
            return;
        }
        while (!head || this.evaluate(head)) {
            if (body() === "break") break;
        }
    },
    break() { throw new LoopSignal("break"); },
    continue() { throw new LoopSignal("continue"); },
    replace(n) { targetMacro(this, n, "replace"); },
    append(n) { targetMacro(this, n, "append"); },
    prepend(n) { targetMacro(this, n, "prepend"); },
    replacelink(n, w) { revisionLink(this, n, w, false); },
    cyclinglink(n, w) { revisionLink(this, n, w, true); },
    remove(n) {
        for (const id of this.selectorRegions(this.parseArgs(n.args)[0])) {
            this.engine.fillRegion(id, () => {}, "replace");
        }
    },
};

function linkAdd(self, n, w, prepend) {
    const label = String(self.parseArgs(n.args)[0] ?? "");
    const section = n.sections ? n.sections[0] : null;
    const rid = w.openRegion([]);
    self.engine.addLink(w, (lw) => self.renderText(label, lw), () =>
        self.engine.fillRegion(rid, (bw) => {
            if (prepend && section) self.renderSection(section, bw);
            self.renderText(label, bw);
            if (!prepend && section) self.renderSection(section, bw);
        }, "replace"));
    w.closeRegion(rid);
}

// <<textbox "$name" "default" ["Passage"]>>: the plugin's command line fills it.
function textField(self, n, w, numeric) {
    const args = self.parseArgs(n.args);
    const name = String(args[0]);
    const initial = args[1];
    const passage = args.slice(2).find((a) => (a && a.isLink) || (typeof a === "string" && self.engine.passage(a)));
    if (initial !== undefined) self.run(`${name} = __v`, { __v: initial });
    const rid = w.openRegion([]);
    const draw = (bw) => {
        let v;
        try { v = self.evaluate(name); } catch (_) { v = ""; }
        bw.text("[" + (v === undefined || v === "" ? "\u2026" : String(v)) + "]");
    };
    draw(w);
    w.closeRegion(rid);
    self.engine.requestLine((value) => {
        self.run(`${name} = __v`, { __v: numeric ? Number(value) : value });
        self.engine.fillRegion(rid, draw, "replace");
        if (passage) self.engine.goto(self.passageArg(passage));
    });
}

// <<cycle "$var">><<option "Label" value>>…<</cycle>>
function cycleMacro(self, n, w) {
    const name = String(self.parseArgs(n.args)[0]);
    const options = [];
    for (const s of n.sections.slice(1)) {
        if (s.name === "option") {
            const a = self.parseArgs(s.args);
            options.push({ label: String(a[0]), value: a.length > 1 ? a[1] : a[0], selected: a.includes("selected") });
        } else if (s.name === "optionsfrom") {
            const src = self.evaluate(s.args);
            const entries = src instanceof Map ? [...src.entries()]
                : Array.isArray(src) ? src.map((v) => [v, v]) : Object.entries(src || {});
            for (const [k, v] of entries) options.push({ label: String(k), value: v });
        }
    }
    if (!options.length) return;
    let current;
    try { current = self.evaluate(name); } catch (_) { current = undefined; }
    let index = Math.max(0, options.findIndex((o) => o.value === current));
    const sel = options.findIndex((o) => o.selected);
    if (current === undefined && sel >= 0) index = sel;
    self.run(`${name} = __v`, { __v: options[index].value });
    const rid = w.openRegion([]);
    const draw = (bw) => {
        self.engine.addLink(bw, options[index].label, () => {
            index = (index + 1) % options.length;
            self.run(`${name} = __v`, { __v: options[index].value });
            self.engine.fillRegion(rid, draw, "replace");
        });
    };
    draw(w);
    w.closeRegion(rid);
}

function targetMacro(self, n, mode) {
    const section = n.sections ? n.sections[0] : { nodes: [] };
    for (const id of self.selectorRegions(self.parseArgs(n.args)[0])) {
        self.engine.fillRegion(id, (bw) => self.renderSection(section, bw), mode);
    }
}

// <<replacelink>>A<<becomes>>B<<gains>>C<</replacelink>>: each tap shows the
// next section in place (<<gains>> keeps what came before); <<cyclinglink>>
// wraps around instead of settling on the last one.
function revisionLink(self, n, w, cycle) {
    const sections = n.sections;
    let index = 0;
    const rid = w.openRegion([]);
    const draw = (bw) => {
        let from = index;
        while (from > 0 && sections[from].name === "gains") from--;
        for (let k = from; k < index; k++) self.renderSection(sections[k], bw);
        const last = index === sections.length - 1;
        if (last && !cycle) {
            self.renderSection(sections[index], bw);
            return;
        }
        self.engine.addLink(bw, (lw) => self.renderSection(sections[index], lw), () => {
            index = (index + 1) % sections.length;
            self.engine.fillRegion(rid, draw, "replace");
        });
    };
    draw(w);
    w.closeRegion(rid);
}

export const _internal = { Parser };
