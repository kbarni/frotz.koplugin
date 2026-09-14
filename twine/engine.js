// twine/engine.js — the story engine every format plugs into.
//
// The engine owns what is common to all Twine formats: variables, visit counts,
// history, the current screen (Writer runs), link actions, regions, timers,
// typed input, undo and saves. A format only knows how to render its markup.
//
// Undo, saves and replay rest on one idea: a *moment*. Entering a passage
// snapshots the state as it was on entry (variables, visits, random seed), and
// every player action inside the passage (link, timer tick, typed line, prompt
// answer) is appended to the moment. Rebuilding a moment = restore the snapshot,
// render the passage again, replay the actions. Rendering is deterministic
// because the random generator is part of the snapshot.

import { Writer, visibleRuns } from "./writer.js";
import { serialize, deserialize, Rng } from "./state.js";
import { log } from "./protocol.js";
import { ImageTable } from "./images.js";

const MAX_UNDO = 100;
const MAX_JUMPS = 50;

// "640", "640px" → 640; "100%", "auto" → undefined.
function pixels(v) {
    const m = /^\s*(\d+(?:\.\d+)?)\s*(?:px)?\s*$/i.exec(String(v ?? ""));
    return m ? Math.round(Number(m[1])) : undefined;
}

// align="left" / style="float: right" → the Glk margin alignments.
function alignment(attrs) {
    const float = /float\s*:\s*(left|right)/i.exec(attrs.style || "");
    const side = (float ? float[1] : String(attrs.align || "")).toLowerCase();
    return side === "left" ? "marginleft" : side === "right" ? "marginright" : "inlineup";
}

// Thrown to stop rendering when the story jumps to another passage.
export class GotoSignal {
    constructor(target) { this.target = target; }
}

export class Engine {
    constructor(story, io, createFormat) {
        this.story = story;
        this.io = io || {};
        this.createFormat = createFormat;
        this.rng = new Rng();
        // The player replaces this with one that knows the story's folder and
        // the cache for data: images; without them only remote images resolve.
        this.images = new ImageTable(null, null);
        this._shown = new WeakMap();   // moment -> Set of image numbers it showed
        this._reset();
        this.format = createFormat(this);
    }

    _reset() {
        this.vars = {};          // story variables
        this.visits = {};        // passage name -> times entered
        this.history = [];       // passage names entered, oldest first
        this.moments = [];       // undo stack; the last one is on screen
        this.current = null;
        this.runs = [];          // the live screen (Writer runs, with region marks)
        this.actions = new Map();
        this.regions = new Map();
        this.timers = [];
        this.clock = 0;          // virtual ms since the passage was entered
        this.lineRequest = null;
        this.pendingGoto = null;
        this.replaying = false;
        this._prompts = [];
        this._linkIds = 0;
        this._regionIds = 0;
        this._warned = new Set();
    }

    // Exact name first; then ignoring surrounding spaces, which authors leave
    // in passage names (" GateUA") while the formats trim link targets.
    passage(name) {
        if (name === undefined || name === null) return undefined;
        name = String(name);
        const exact = this.story.passages.get(name);
        if (exact) return exact;
        if (!this._trimmed) {
            this._trimmed = new Map();
            for (const p of this.story.passages.values()) {
                const key = p.name.trim();
                if (!this._trimmed.has(key)) this._trimmed.set(key, p);
            }
        }
        return this._trimmed.get(name.trim());
    }

    get passageName() { return this.current ? this.current.passage : null; }

    // Log an unsupported feature once per run (stderr, not the story).
    warn(what) {
        if (this._warned.has(what)) return;
        this._warned.add(what);
        log("unsupported: " + what);
    }

    start() {
        this.format.init();
        const start = this.story.start;
        if (!start) throw new Error("The story has no starting passage.");
        this._enter(start.name);
        this._navigate();
    }

    restart() {
        this._reset();
        this.rng = new Rng();
        this.format = this.createFormat(this);
        this.start();
    }

    // ── navigation ─────────────────────────────────────────────────────────

    // Jump to a passage. Stops the code that called it (rendering or an action).
    goto(name) {
        this.pendingGoto = String(name);
        throw new GotoSignal(name);
    }

    // Jump once the current code finishes (for author JavaScript, which may
    // catch our signal).
    requestGoto(name) {
        this.pendingGoto = String(name);
    }

    _enter(name) {
        const p = this.passage(name);
        if (!p) {
            this._appendError(`There is no passage named "${name}".`);
            return false;
        }
        const m = {
            passage: p.name,
            vars: serialize(this.vars),
            visits: serialize(this.visits),
            rng: this.rng.getState(),
            hist: this.history.length,
            fmt: this.format.snapshot ? serialize(this.format.snapshot()) : null,
            actions: [],
            prompts: [],
        };
        this.moments.push(m);
        if (this.moments.length > MAX_UNDO) this.moments.shift();
        this._begin(m);
        return true;
    }

    _begin(m) {
        this.current = m;
        this.history.push(m.passage);
        this.visits[m.passage] = (this.visits[m.passage] || 0) + 1;
        this.actions = new Map();
        this.regions = new Map();
        this.timers = [];
        this.clock = 0;
        this.lineRequest = null;
        this._linkIds = 0;
        this._regionIds = 0;
        const w = new Writer(this);
        this.runs = w.runs;
        this._run(() => this.format.render(this.passage(m.passage), w), w);
        w.finish();
    }

    _navigate() {
        for (let n = 0; this.pendingGoto !== null; n++) {
            const target = this.pendingGoto;
            this.pendingGoto = null;
            if (n >= MAX_JUMPS) {
                this._appendError("Too many passage jumps in a row.");
                break;
            }
            this._enter(target);
        }
    }

    _restore(m) {
        this.vars = deserialize(m.vars) || {};
        this.visits = deserialize(m.visits) || {};
        this.rng.setState(m.rng);
        if (this.history.length > m.hist) this.history.length = m.hist;
        if (this.format.restore) this.format.restore(deserialize(m.fmt));
    }

    _replay(m) {
        this._restore(m);
        this.pendingGoto = null;
        this.replaying = true;
        this._prompts = m.prompts.slice();
        try {
            this._begin(m);
            for (const a of m.actions) {
                if (a[0] === "link") this.activate(a[1]);
                else if (a[0] === "timer") this.fireTimers();
                else if (a[0] === "line") this.submitLine(a[1]);
            }
        } finally {
            this.replaying = false;
            this.pendingGoto = null;
        }
    }

    // Run one player action, record it in the moment, then follow any jump.
    _act(record, fn) {
        const m = this.current;
        if (!this.replaying) m.actions.push(record);
        this._run(fn);
        if (this.pendingGoto === null) return;
        if (this.replaying) {
            this.pendingGoto = null;
            return;
        }
        // The action left the passage: undo should land just before it.
        const i = m.actions.lastIndexOf(record);
        if (i >= 0) m.actions.splice(i, 1);
        this._navigate();
    }

    _run(fn, w) {
        try {
            fn();
        } catch (e) {
            if (e instanceof GotoSignal) return;
            const msg = e && e.message ? e.message : String(e);
            log("error: " + msg + (e && e.stack ? "\n" + e.stack : ""));
            if (w) w.error("Error: " + msg);
            else this._appendError("Error: " + msg);
        }
    }

    _appendError(msg) {
        const w = new Writer(this);
        w.error(msg);
        this.runs.push({ text: "\n\n", style: "normal", link: 0 }, ...w.runs);
    }

    // ── links and regions ──────────────────────────────────────────────────

    registerAction(action) {
        const id = ++this._linkIds;
        this.actions.set(id, action);
        return id;
    }

    // label: plain text, or function(writer) for styled/markup labels.
    addLink(w, label, action) {
        const id = this.registerAction(action);
        const prev = w.beginLink(id);
        if (typeof label === "function") label(w);
        else w.text(label);
        w.endLink(prev);
        return id;
    }

    // An HTML element naming a passage (data-passage / href).
    htmlLink(target, attrs) {
        return this.registerAction(() => {
            if (this.format.onHtmlLink) this.format.onHtmlLink(target, attrs);
            this.goto(target);
        });
    }

    // A picture on the page (<img>, [img[…]], {embed image}, ![…](…)). attrs:
    // src, alt/title, width, height, align/style. Images that only carry a
    // script (onload/onerror tricks) are not pictures.
    image(w, attrs) {
        if (attrs.onload !== undefined || attrs.onerror !== undefined) return;
        const alt = String(attrs.alt ?? attrs.title ?? "").trim();
        const r = this.images.resolve(attrs.src, (name) => this.passage(name));
        if (r.kind === "none") {
            // What a browser shows for a broken image; a linked one needs a label.
            if (alt || w.link) w.text("[" + (alt || "Image") + "]");
            return;
        }
        w.imageRun({
            n: this.images.number(r.url), url: r.url, alt,
            width: pixels(attrs.width), height: pixels(attrs.height), align: alignment(attrs),
        });
    }

    // Annotate a screen's pictures with how often each was already shown: on
    // the earlier passage visits still on the undo stack, or earlier on this
    // page. The plugin drops repeats (an icon on every passage) like it drops a
    // Glulx game's redrawn ornaments, while a picture keeps its line when the
    // same page is sent again, undone to, or rebuilt.
    markSeen(runs) {
        const earlier = new Map();
        for (const m of this.moments) {
            if (m === this.current) break;
            const set = this._shown.get(m);
            if (set) for (const n of set) earlier.set(n, (earlier.get(n) || 0) + 1);
        }
        let shown = this.current ? this._shown.get(this.current) : null;
        if (!shown && this.current) {
            shown = new Set();
            this._shown.set(this.current, shown);
        }
        const onPage = new Map();
        for (const r of runs) {
            if (!r.img) continue;
            const k = onPage.get(r.img.n) || 0;
            r.img.seen = (earlier.get(r.img.n) || 0) + k;
            onPage.set(r.img.n, k + 1);
            if (shown) shown.add(r.img.n);
        }
        return runs;
    }

    activate(id) {
        const fn = this.actions.get(id);
        if (!fn) return false;
        this._act(["link", id], fn);
        return true;
    }

    newRegion(names, style) {
        const id = ++this._regionIds;
        this.regions.set(id, { names, style });
        return id;
    }

    regionsNamed(name) {
        const ids = [];
        for (const [id, r] of this.regions) if (r.names.includes(name)) ids.push(id);
        return ids;
    }

    _bounds(id) {
        let open = -1;
        for (let i = 0; i < this.runs.length; i++) {
            const r = this.runs[i];
            if (r.mark === undefined || r.region !== id) continue;
            if (r.mark === "open") open = i;
            else if (open >= 0) return [open, i];
        }
        return null;
    }

    regionExists(id) { return this._bounds(id) !== null; }

    // Put a new region around every occurrence of `text` in plain (unlinked)
    // runs, so text on the page can be targeted like a named hook (Harlowe's
    // (click: "word"), (replace: "word")). Returns the region ids.
    wrapText(text) {
        const ids = [];
        if (!text) return ids;
        for (let i = 0; i < this.runs.length; i++) {
            const r = this.runs[i];
            if (r.mark !== undefined || r.link) continue;
            const pos = r.text.indexOf(text);
            if (pos < 0) continue;
            const before = r.text.slice(0, pos);
            const after = r.text.slice(pos + text.length);
            const id = this.newRegion([], null);
            const pieces = [];
            if (before) pieces.push({ text: before, style: r.style, link: 0 });
            pieces.push({ mark: "open", region: id }, { text, style: r.style, link: 0 },
                        { mark: "close", region: id });
            if (after) pieces.push({ text: after, style: r.style, link: 0 });
            this.runs.splice(i, 1, ...pieces);
            ids.push(id);
            i += pieces.length - (after ? 2 : 1);   // rescan the remainder
        }
        return ids;
    }

    // Render into region `id`; mode "replace" | "append" | "prepend".
    fillRegion(id, render, mode = "replace") {
        const r = this.regions.get(id);
        if (!r || !this._bounds(id)) return false;
        const w = new Writer(this, r.style);
        this._run(() => render(w), w);
        w.finish();
        const b = this._bounds(id);   // rendering may have moved things
        if (!b) return false;
        const [open, close] = b;
        if (mode === "append") this.runs.splice(close, 0, ...w.runs);
        else if (mode === "prepend") this.runs.splice(open + 1, 0, ...w.runs);
        else this.runs.splice(open + 1, close - open - 1, ...w.runs);
        return true;
    }

    // Plain text of a region (for Harlowe's (source:)-ish needs and tests).
    regionText(id) {
        const b = this._bounds(id);
        if (!b) return "";
        return this.runs.slice(b[0] + 1, b[1]).map((r) => r.text || "").join("");
    }

    // ── timers ─────────────────────────────────────────────────────────────

    after(ms, fn, repeat = false) {
        ms = Math.max(1, Math.round(Number(ms) || 0));
        const t = { due: this.clock + ms, ms, fn, repeat, stopped: false };
        this.timers.push(t);
        return t;
    }

    // Stop a timer, or the one currently firing.
    stopTimer(t) {
        const x = t || this._timer;
        if (x) x.stopped = true;
    }

    nextTimerDelay() {
        let min = Infinity;
        for (const t of this.timers) if (!t.stopped && t.due < min) min = t.due;
        return min === Infinity ? null : Math.max(1, min - this.clock);
    }

    fireTimers() {
        const delay = this.nextTimerDelay();
        if (delay === null) return false;
        this._act(["timer"], () => {
            this.clock += delay;
            for (const t of this.timers.slice()) {
                if (t.stopped || t.due > this.clock) continue;
                this._timer = t;
                try {
                    t.fn();
                } finally {
                    this._timer = null;
                    if (t.repeat && !t.stopped) t.due = this.clock + t.ms;
                    else t.stopped = true;
                }
            }
            this.timers = this.timers.filter((t) => !t.stopped);
        });
        return true;
    }

    // ── typed input ────────────────────────────────────────────────────────

    // A text field on the page (SugarCube <<textbox>>): the plugin shows its
    // command line; the typed value arrives as a line event.
    requestLine(onLine) {
        this.lineRequest = { onLine };
    }

    submitLine(value) {
        const r = this.lineRequest;
        if (!r) return false;
        this._act(["line", value], () => r.onLine(value));
        return true;
    }

    // A blocking question asked mid-render (Harlowe's (prompt:)). Answers are
    // recorded so a replay gets the same ones without asking again.
    askLine(prompt, def) {
        if (this.replaying) return this._prompts.length ? this._prompts.shift() : def;
        let v = this.io.askLine ? this.io.askLine(this, prompt, def) : def;
        if (v === null || v === undefined) v = def;
        this.current.prompts.push(v);
        return v;
    }

    // ── screen, undo, saves ────────────────────────────────────────────────

    screen() { return visibleRuns(this.runs); }

    isDeadEnd(runs) {
        return !runs.some((r) => r.link) && !this.lineRequest && this.nextTimerDelay() === null;
    }

    canUndo() { return this.moments.length > 1; }

    undo() {
        if (!this.canUndo()) return false;
        this.moments.pop();
        this._replay(this.moments[this.moments.length - 1]);
        return true;
    }

    saveData() {
        const m = this.current;
        return JSON.stringify({
            kind: "twine-save", version: 1,
            ifid: this.story.ifid, story: this.story.name,
            moment: m, history: this.history.slice(0, m.hist),
        });
    }

    loadData(text) {
        let d;
        try { d = JSON.parse(text); } catch (_) { d = null; }
        if (!d || d.kind !== "twine-save" || !d.moment) throw new Error("Not a Twine save file.");
        if (d.ifid && this.story.ifid && d.ifid !== this.story.ifid) {
            throw new Error("That save belongs to a different story.");
        }
        if (!this.passage(d.moment.passage)) {
            throw new Error(`The saved passage "${d.moment.passage}" no longer exists.`);
        }
        this.history = Array.isArray(d.history) ? d.history : [];
        this.moments = [d.moment];
        this._replay(d.moment);
    }
}
