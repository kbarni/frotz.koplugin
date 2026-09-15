// twine/formats/revision.js — Twine 1's "revision macros", done natively.
//
// Leon Arnott's macro library (replaceMacrosCombined) was the usual way to change
// a Twine 1 page in place: <<replace>>A<<becomes>>B<<endreplace>>, <<timedinsert
// 2s>>…<<endtimedinsert>>, <<once>>/<<later>>, <<revision name>> spans moved on
// by <<revise name "text">> links. Its handlers build and toggle DOM spans, so
// they can't run here. The library registers its macros from a table of
// { name, flavour, trigger }; SugarCube reads that table once the story scripts
// have run and plays those macros here, with one engine region per version.
//
//   flavour  insert (starts empty) · replace · remove (ends empty) · cycle ·
//            continue (the rest of the passage is the last version)
//   trigger  link / mouse / hover / key: a tap · time: every N seconds ·
//            visited: once per earlier showing (<<once>>, <<later>>) ·
//            revisemacro: <<revise>>/<<revert>>/<<randomise>> links, <<instantrevise>>
// A version introduced by <<gains>> keeps the one before it on show.

import { parseDuration } from "./common.js";

const TAP = new Set(["link", "mouse", "hover", "key"]);
// Triggers whose arguments are the first versions' text.
const SHORTHAND = new Set(["link", "mouse", "hover"]);
// The library's macros that aren't in its table.
const LINKS = new Set(["revise", "revert", "randomise", "randomize"]);
const HOVER = new Set(["hoverrevise", "mouserevise"]);
// Faster reveals would repaint an e-ink screen non-stop (as <<repeat>>).
const MIN_TICK_MS = 250;

// The library's macro arguments: quoted strings or bare words, not evaluated.
function words(raw) {
    const out = [];
    const re = /"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|(\S+)/g;
    let m;
    while ((m = re.exec(raw)) !== null) {
        if (m[3] !== undefined) out.push({ v: m[3], bare: true });
        else out.push({ v: (m[1] ?? m[2]).replace(/\\(.)/g, "$1"), bare: false });
    }
    return out;
}

// A span's name the way the library makes a class of it (first space only).
const className = (s) => String(s).replace(" ", "_");

// The versions on show at index i: i, and those before it kept by a <<gains>>.
function visibleAt(versions, i) {
    const set = new Set([i]);
    for (let k = i; k > 0 && versions[k - 1].end === "gains"; k--) set.add(k - 1);
    return set;
}

export class Revisions {
    // custom: SugarCube's registry of author macros. null when the story
    // doesn't load the library.
    static detect(format, custom) {
        const kinds = new Map();
        for (const [name, def] of custom) {
            if (def && typeof def.flavour === "string" && typeof def.trigger === "string") {
                kinds.set(name, { flavour: def.flavour, trigger: def.trigger });
            }
        }
        // The older replaceMacro 1.0 has no table: <<replace "link">>…<<endreplace>>
        // is this library's replace on a tap.
        if (!kinds.size && custom.has("replace") && custom.has("endreplace")) {
            kinds.set("replace", { flavour: "replace", trigger: "link" });
        }
        return kinds.size ? new Revisions(format, kinds, custom) : null;
    }

    constructor(format, kinds, custom) {
        this.format = format;
        this.engine = format.engine;
        this.kinds = kinds;
        this.extra = new Set([...LINKS, ...HOVER, "instantrevise"].filter((n) => custom.has(n)));
        // For the markup parser: bodies split by <<becomes>>/<<gains>>, closed
        // by <<endname>>.
        this.containers = new Map();
        for (const [name, k] of kinds) {
            this.containers.set(name, { clauses: ["becomes", "gains"], legacyEnd: true,
                bodylessWithArgs: k.flavour === "continue" });
        }
        for (const name of HOVER) {
            if (this.extra.has(name)) this.containers.set(name, { clauses: [], legacyEnd: true });
        }
        this.reset();
    }

    // A new page: forget the spans and links of the last one.
    reset() {
        this.spans = [];
        this.links = [];
    }

    handles(name) { return this.kinds.has(name) || this.extra.has(name); }

    takesRest(n) {
        const k = this.kinds.get(n.name);
        return !!k && k.flavour === "continue";
    }

    // rest: the nodes after this macro, for the continue flavour.
    macro(n, w, rest) {
        if (this.kinds.has(n.name)) return this.span(n, w, rest);
        if (LINKS.has(n.name)) return this.reviseLink(n, w);
        if (HOVER.has(n.name)) return this.hoverRevise(n, w);
        const first = words(n.args)[0];                    // <<instantrevise name>>
        if (first) {
            this.reviseAll("revise", className(first.v));
            this.refreshLinks();
        }
    }

    // After the page is drawn: <<revise>> links often come before their spans.
    afterRender() { this.refreshLinks(); }

    // ── spans ──────────────────────────────────────────────────────────────

    span(n, w, rest) {
        const kind = this.kinds.get(n.name);
        const engine = this.engine;
        const args = words(n.args).map((a) => a.v);
        const s = {
            kind,
            cycle: kind.flavour === "cycle",
            name: kind.trigger === "revisemacro" && args.length ? className(args[0]) : null,
            versions: this.versions(n, kind, args, rest),
            index: 0, shown: [], rids: [], rid: 0, linkId: 0,
        };
        if (!s.versions.length) return;
        if (kind.trigger === "visited") s.index = this.visitedIndex(s);
        if (TAP.has(kind.trigger)) {
            s.linkId = engine.registerAction(() => {
                this.revise(s, "revise");
                this.refreshLinks();
            });
        }
        const vis = visibleAt(s.versions, s.index);
        s.rid = w.openRegion([]);
        s.versions.forEach((_, k) => {
            s.rids[k] = w.openRegion([]);
            if (vis.has(k)) {
                this.write(s, k, w);
                s.shown[k] = true;
            }
            w.closeRegion(s.rids[k]);
        });
        w.closeRegion(s.rid);
        this.spans.push(s);
        if (kind.trigger === "time") {
            const ms = Math.max(parseDuration(args[0] ?? "") ?? 0, MIN_TICK_MS);
            engine.after(ms, () => {
                if (!engine.regionExists(s.rid) || !this.revise(s, "revise")) engine.stopTimer();
                this.refreshLinks();
            }, true);
        }
    }

    // The library's list of versions: each { nodes | text, src, end }, where
    // `end` is the tag that closed it — "gains" keeps it on show under the next.
    versions(n, kind, args, rest) {
        const { flavour, trigger } = kind;
        const v = [];
        const add = (x, end) => v.push(Object.assign(x, { end }));
        if (SHORTHAND.has(trigger) && args.length) {
            for (const a of args) add({ text: a, src: a }, flavour === "insert" ? "gains" : "becomes");
        } else if (flavour === "insert" || (flavour === "continue" && trigger === "time")) {
            add({ src: "" }, "becomes");
        }
        if (flavour === "continue" && args.length) {
            add({ nodes: rest || [], src: "" }, n.name);
        } else {
            const sections = n.sections || [];
            sections.forEach((sec, i) => add({ nodes: sec.nodes || [], src: sec.raw || "" },
                sections[i + 1] ? sections[i + 1].name : "end" + n.name));
            if (flavour === "continue") add({ nodes: rest || [], src: "" }, "");
        }
        if (flavour === "remove") add({ src: "" }, "becomes");
        return v;
    }

    // <<once>>/<<later>>: the library counts showings of the same text in the
    // story variables ("once seen"), so undo and saves keep the count.
    visitedIndex(s) {
        const vars = this.engine.vars;
        if (!vars["once seen"] || typeof vars["once seen"] !== "object") vars["once seen"] = {};
        const seen = vars["once seen"];
        const keyed = s.kind.flavour === "insert" ? s.versions[1] : s.versions[0];
        const key = keyed ? keyed.src : "";
        if (!Object.prototype.hasOwnProperty.call(seen, key)) {
            seen[key] = 1;
            return 0;
        }
        const count = seen[key];
        seen[key] = count + 1;
        return s.cycle ? count % s.versions.length : Math.min(count, s.versions.length - 1);
    }

    done(s) { return !s.cycle && s.index >= s.versions.length - 1; }

    // Draw version k; while a tapped span can still change, its text is the link.
    write(s, k, bw) {
        const ver = s.versions[k];
        const linked = s.linkId && !this.done(s);
        const prev = linked ? bw.beginLink(s.linkId) : 0;
        if (ver.nodes) this.format.renderNodes(ver.nodes, bw);
        else if (ver.text) this.format.renderText(ver.text, bw);
        if (linked) bw.endLink(prev);
    }

    // Move a span on ("revise"), back ("revert") or to a random version.
    // Returns whether it can still change afterwards, as the library's revise().
    revise(s, how) {
        const n = s.versions.length;
        if (n < 2 || !this.engine.regionExists(s.rid)) return false;
        let i = s.index;
        if (how === "revert") {
            if (i === 0 && !s.cycle) return false;
            i = (i - 1 + n) % n;
        } else if (how === "random") {
            i = (i + 1 + Math.floor(this.engine.rng.next() * (n - 1))) % n;
        } else {
            if (i === n - 1 && !s.cycle) return false;
            i = (i + 1) % n;
        }
        this.show(s, i);
        return s.cycle || (how === "revert" ? i > 0 : i < n - 1);
    }

    // Only versions whose visibility changes are drawn or cleared, so text kept
    // on show isn't rendered twice (no repeated <<set>>s or restarted timers).
    show(s, index) {
        s.index = index;
        const vis = visibleAt(s.versions, index);
        s.versions.forEach((_, k) => {
            const want = vis.has(k);
            if (want === !!s.shown[k]) return;
            s.shown[k] = want;
            this.engine.fillRegion(s.rids[k], want ? (bw) => this.write(s, k, bw) : () => {}, "replace");
        });
        if (s.linkId && this.done(s)) this.engine.unlinkRegion(s.rid, s.linkId);
    }

    reviseAll(how, name) {
        let more = false;
        for (const s of this.spans.slice()) {
            if (s.name === name && this.engine.regionExists(s.rid)) more = this.revise(s, how) || more;
        }
        return more;
    }

    canChange(name, how) {
        return this.spans.some((s) => s.name === name && s.versions.length > 1 && this.engine.regionExists(s.rid)
            && (s.cycle || (how === "revert" ? s.index > 0 : s.index < s.versions.length - 1)));
    }

    // ── links ──────────────────────────────────────────────────────────────

    // <<revise name "text"… [$var] [end|out]>>: a link that moves every span
    // called `name` on (<<revert>> back, <<randomise>> anywhere). Several texts
    // cycle, and $var holds the current one. The link only shows while a span
    // can still change; with "end" its last text stays as plain text, with
    // "out" it disappears.
    reviseLink(n, w) {
        const a = words(n.args);
        if (a.length < 2) throw new Error("needs 2 parameters");
        const how = n.name === "revise" ? "revise" : n.name === "revert" ? "revert" : "random";
        const name = className(a.shift().v);
        const variable = a.length > 1 && a[0].v[0] === "$" ? a.shift().v.slice(1) : "";
        const last = a[a.length - 1];
        const mode = last.bare && (last.v === "end" || last.v === "out") ? a.pop().v : "";
        const texts = a.map((x) => x.v);
        if (!texts.length) return;
        const L = { name, how, texts, mode, state: "live", rid: 0, id: 0,
            u: variable ? Math.max(texts.indexOf(this.engine.vars[variable]), 0) : 0 };
        if (variable) this.engine.vars[variable] = texts[L.u];
        L.id = this.engine.registerAction(() => {
            this.reviseAll(how, name);
            const m = texts.length;
            if (mode && L.u >= m - (mode === "end" ? 2 : 1)) {
                L.state = mode;
                L.u = Math.min(L.u + 1, m - 1);
            } else {
                L.u = (L.u + 1) % m;
                if (variable) this.engine.vars[variable] = texts[L.u];
            }
            this.refreshLinks();
        });
        L.rid = w.openRegion([]);
        this.drawLink(L, w);
        w.closeRegion(L.rid);
        this.links.push(L);
    }

    drawLink(L, bw) {
        if (L.state === "out") return;
        if (L.state === "end") {
            bw.text(L.texts[L.u]);
            return;
        }
        if (L.how !== "random" && !this.canChange(L.name, L.how)) return;
        const prev = bw.beginLink(L.id);
        bw.text(L.texts[L.u]);
        bw.endLink(prev);
    }

    refreshLinks() {
        for (const L of this.links) {
            if (this.engine.regionExists(L.rid)) this.engine.fillRegion(L.rid, (bw) => this.drawLink(L, bw), "replace");
        }
    }

    // <<hoverrevise name>>text<<endhoverrevise>>: hovering the text moved the
    // spans on; here tapping it does. <<mouserevise>> stops being a link when
    // nothing is left to change.
    hoverRevise(n, w) {
        const first = words(n.args)[0];
        if (!first) return;
        const name = className(first.v);
        const rid = w.openRegion([]);
        const id = this.engine.registerAction(() => {
            const more = this.reviseAll("revise", name);
            if (!more && n.name === "mouserevise") this.engine.unlinkRegion(rid, id);
            this.refreshLinks();
        });
        const prev = w.beginLink(id);
        this.format.renderSection((n.sections || [{}])[0], w);
        w.endLink(prev);
        w.closeRegion(rid);
    }
}
