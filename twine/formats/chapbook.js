// twine/formats/chapbook.js — Chapbook 1/2 subset.
//
// A passage is an optional vars section (`name: expression` lines ended by
// `--`), then Markdown split into blocks by modifier lines like [if x > 2],
// [else], [continue], [after 2s]; text holds {inserts}. Expressions are
// JavaScript over the story variables, which are in scope by bare name.

import { renderMarkdown } from "./markdown.js";
import { parseDuration } from "./common.js";

const VAR_LINE = /^\s*([A-Za-z_$][\w$.]*)\s*(?:\((.*)\))?\s*:\s*(.*)$/;

export class Chapbook {
    constructor(engine) {
        this.engine = engine;
        this.fnCache = new Map();
    }

    init() {
        for (const script of this.engine.story.scripts) {
            try {
                this.evalIn(script, true);
            } catch (e) {
                this.engine.warn("author script error: " + (e && e.message));
            }
        }
    }

    scope() {
        const engine = this.engine;
        const p = engine.passage(engine.passageName);
        return {
            passage: {
                name: engine.passageName,
                tags: p ? p.tags : [],
                visits: engine.visits[engine.passageName] || 0,
                get from() { return engine.history.length > 1 ? engine.history[engine.history.length - 2] : undefined; },
            },
            random: {
                get coinFlip() { return engine.rng.next() < 0.5; },
                get d4() { return engine.rng.int(1, 4); }, get d6() { return engine.rng.int(1, 6); },
                get d8() { return engine.rng.int(1, 8); }, get d10() { return engine.rng.int(1, 10); },
                get d12() { return engine.rng.int(1, 12); }, get d20() { return engine.rng.int(1, 20); },
                get d25() { return engine.rng.int(1, 25); }, get d50() { return engine.rng.int(1, 50); },
                get d100() { return engine.rng.int(1, 100); }, get fraction() { return engine.rng.next(); },
                integer: (a, b) => engine.rng.int(a, b),
            },
            config: {},
            engine: { state: { get: (k) => engine.vars[k], set: (k, v) => { engine.vars[k] = v; } } },
        };
    }

    // Expressions see story variables as globals; writes to plain names stick
    // to the variable table through `with`.
    evalIn(code, statement) {
        let fn = this.fnCache.get(code);
        if (!fn) {
            const body = statement
                ? "with (__scope) { with (__vars) {" + code + "\n} }"
                : "with (__scope) { with (__vars) { return (" + code + "\n); } }";
            fn = new Function("__vars", "__scope", body);
            this.fnCache.set(code, fn);
        }
        return fn(this.varsProxy(), this.scope());
    }

    // `with` only sees names that exist; a proxy that claims every name makes
    // assignments to new variables land in the variable table too.
    varsProxy() {
        const vars = this.engine.vars;
        return new Proxy(vars, {
            has: (t, k) => typeof k === "string" && (k in t || !(k in globalThis)),
            get: (t, k) => (k === Symbol.unscopables ? undefined : t[k]),
        });
    }

    setPath(path, value) {
        const parts = path.split(".");
        let obj = this.engine.vars;
        for (const p of parts.slice(0, -1)) {
            if (typeof obj[p] !== "object" || obj[p] === null) obj[p] = {};
            obj = obj[p];
        }
        obj[parts[parts.length - 1]] = value;
    }

    getPath(path) {
        let obj = this.engine.vars;
        for (const p of path.split(".")) {
            if (obj === undefined || obj === null) return undefined;
            obj = obj[p];
        }
        return obj;
    }

    render(passage, w) {
        this.renderPassageText(passage.text, w);
    }

    renderPassageText(text, w) {
        text = text.replace(/\r/g, "");
        let body = text;
        const sep = /^--\s*$/m.exec(text);
        if (sep) {
            const head = text.slice(0, sep.index);
            const lines = head.split("\n").filter((l) => l.trim() !== "");
            if (lines.length && lines.every((l) => VAR_LINE.test(l))) {
                for (const line of lines) {
                    const [, name, cond, expr] = VAR_LINE.exec(line);
                    try {
                        if (cond && !this.evalIn(cond)) continue;
                        this.setPath(name, this.evalIn(expr));
                    } catch (e) {
                        w.error(`${name}: ${e.message}`);
                    }
                }
                body = text.slice(sep.index + sep[0].length).replace(/^\n/, "");
            }
        }
        this.renderBlocks(body, w);
    }

    renderBlocks(body, w) {
        const blocks = [];
        let cur = { mods: [], lines: [] };
        for (const line of body.split("\n")) {
            const m = /^\[([^\[\]]+)\]\s*$/.exec(line);
            if (m && !line.startsWith("[[")) {
                blocks.push(cur);
                cur = { mods: m[1].split(";").map((s) => s.trim()), lines: [] };
            } else {
                cur.lines.push(line);
            }
        }
        blocks.push(cur);

        let lastIf = null;
        for (const b of blocks) {
            let show = true, delay = null;
            for (const mod of b.mods) {
                let m;
                if ((m = /^if\s+([\s\S]+)$/i.exec(mod))) { show = show && this.truthy(m[1], w); lastIf = show; }
                else if ((m = /^unless\s+([\s\S]+)$/i.exec(mod))) { show = show && !this.truthy(m[1], w); lastIf = show; }
                else if (/^else$/i.test(mod)) { show = show && lastIf === false; lastIf = null; }
                else if (/^(continue|cont'?d?|cont\.)$/i.test(mod)) { /* show */ }
                else if ((m = /^after\s+(.+)$/i.exec(mod))) { delay = parseDuration(m[1].trim()); }
                else if (/^note/i.test(mod) || /^n\.?b\.?$/i.test(mod)) { show = false; }
                else if (/^(align|append|fork|transition|t8n)/i.test(mod)) { /* presentation */ }
                else this.engine.warn(`Chapbook modifier [${mod}]`);
            }
            if (!show) continue;
            const text = b.lines.join("\n");
            if (delay) {
                const rid = w.openRegion([]);
                w.closeRegion(rid);
                this.engine.after(delay, () => this.engine.fillRegion(rid, (bw) => this.markdown(text, bw), "replace"));
            } else {
                this.markdown(text, w);
            }
        }
    }

    truthy(expr, w) {
        try {
            return !!this.evalIn(expr);
        } catch (e) {
            w.error(`[if ${expr}]: ${e.message}`);
            return false;
        }
    }

    markdown(text, w) {
        renderMarkdown(this.engine, w, text, (s, iw) => this.inserts(s, iw));
    }

    // Plain text with {inserts}.
    inserts(s, w) {
        const re = /\{([^{}]+)\}/g;
        let last = 0, m;
        while ((m = re.exec(s)) !== null) {
            if (m.index > last) w.markup(s.slice(last, m.index));
            last = re.lastIndex;
            try {
                if (!this.insert(m[1].trim(), w)) w.markup(m[0]);
            } catch (e) {
                w.error(`{${m[1]}}: ${e.message}`);
            }
        }
        if (last < s.length) w.markup(s.slice(last));
    }

    // Returns false when the braces weren't an insert at all.
    insert(src, w) {
        const engine = this.engine;
        if (/^[A-Za-z_$][\w$.]*$/.test(src)) {
            const v = this.getPath(src);
            if (v !== undefined && v !== null) w.markup(String(v));
            return true;
        }
        const m = /^([a-z][a-z ]*?)(?:\s*:\s*([\s\S]*?))?(?:\s*,\s*([\s\S]*))?$/i.exec(src);
        if (!m) return false;
        const name = m[1].trim().toLowerCase();
        let props = {};
        const rest = [m[2], m[3]].filter((x) => x !== undefined && x.trim() !== "");
        let main;
        if (m[2] !== undefined) {
            // "link to: 'X', label: 'Y'" → main = 'X', props = { label: 'Y' }
            const all = this.evalIn("[" + m[2] + (m[3] ? ", {" + m[3] + "}" : "") + "]");
            main = all[0];
            props = all[1] || {};
        } else if (rest.length) {
            props = this.evalIn("({" + rest.join(",") + "})");
        }
        switch (name) {
            case "back link":
                if (engine.history.length > 1) {
                    engine.addLink(w, props.label || "Back", () => engine.goto(engine.history[engine.history.length - 2]));
                }
                return true;
            case "restart link":
                engine.addLink(w, props.label || "Restart", () => engine.restart());
                return true;
            case "link to":
                engine.addLink(w, (lw) => this.markdownInline(String(props.label ?? main), lw), () => engine.goto(String(main)));
                return true;
            case "reveal link": {
                const rid = w.openRegion([]);
                engine.addLink(w, (lw) => this.markdownInline(String(main), lw), () => engine.fillRegion(rid, (bw) => {
                    if (props.passage) this.renderPassageText(engine.passage(props.passage).text, bw);
                    else this.markdownInline(String(props.text ?? ""), bw);
                }, "replace"));
                w.closeRegion(rid);
                return true;
            }
            case "cycling link": {
                const varName = String(main ?? props.for ?? "");
                const choices = props.choices || [];
                if (!choices.length) return true;
                let index = Math.max(0, choices.indexOf(this.getPath(varName)));
                if (varName) this.setPath(varName, choices[index]);
                const rid = w.openRegion([]);
                const draw = (bw) => engine.addLink(bw, String(choices[index]), () => {
                    index = (index + 1) % choices.length;
                    if (varName) this.setPath(varName, choices[index]);
                    engine.fillRegion(rid, draw, "replace");
                });
                draw(w);
                w.closeRegion(rid);
                return true;
            }
            case "embed passage":
            case "embed passage named": {
                const p = engine.passage(String(main));
                if (!p) throw new Error(`there's no passage named "${main}"`);
                this.renderPassageText(p.text, w);
                return true;
            }
            case "text input": {
                const varName = String(main ?? props.for ?? "");
                const rid = w.openRegion([]);
                const draw = (bw) => bw.text("[" + (this.getPath(varName) ?? "\u2026") + "]");
                draw(w);
                w.closeRegion(rid);
                engine.requestLine((value) => {
                    if (varName) this.setPath(varName, value);
                    engine.fillRegion(rid, draw, "replace");
                });
                return true;
            }
            case "embed image":
                engine.image(w, { src: main, alt: props.alt ?? props.description });
                return true;
            case "ambient sound": case "sound effect": case "embed youtube video":
            case "embed vimeo video": case "embed flickr image": case "embed unsplash image":
            case "party": case "fade in":
                return true;
            default:
                engine.warn(`Chapbook insert {${name}}`);
                return false;
        }
    }

    markdownInline(text, w) {
        this.inserts(text, w);
    }
}
