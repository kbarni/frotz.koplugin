// twine/formats/snowman.js — Snowman 1/2 subset.
//
// Passages are Underscore-style templates (<% code %>, <%= value %>,
// <%- value %>) producing Markdown with [[links]]. State lives in `s`
// (Snowman 1) / `window.story.state`; `story.show(name)` jumps.

import { renderMarkdown } from "./markdown.js";

export class Snowman {
    constructor(engine) {
        this.engine = engine;
        this.cache = new Map();
    }

    env() {
        const engine = this.engine;
        const story = {
            get state() { return engine.vars; },
            get name() { return engine.story.name; },
            get history() { return engine.history.slice(); },
            show: (name) => engine.requestGoto(name),
            passage: (name) => engine.passage(name),
            render: (name) => (engine.passage(name) || { text: "" }).text,
        };
        return {
            s: engine.vars,
            story,
            passage: { name: engine.passageName, tags: (engine.passage(engine.passageName) || { tags: [] }).tags },
            window: { story },
            $: () => ({ on() {}, off() {}, html() {}, text() {}, click() {}, hide() {}, show() {} }),
            _: { random: (a, b) => engine.rng.int(a, b), shuffle: (v) => v.slice() },
            either: (...v) => v.flat()[engine.rng.int(0, v.flat().length - 1)],
        };
    }

    init() {
        for (const script of this.engine.story.scripts) {
            try {
                const e = this.env();
                new Function(...Object.keys(e), script)(...Object.values(e));
            } catch (err) {
                this.engine.warn("author script error: " + (err && err.message));
            }
        }
    }

    template(src) {
        let fn = this.cache.get(src);
        if (fn) return fn;
        let code = "let __out = '';\n";
        const re = /<%([=-]?)([\s\S]*?)%>/g;
        let last = 0, m;
        while ((m = re.exec(src)) !== null) {
            code += "__out += " + JSON.stringify(src.slice(last, m.index)) + ";\n";
            if (m[1]) code += "__out += ((__v) => __v === undefined || __v === null ? '' : String(__v))(" + m[2] + ");\n";
            else code += m[2] + "\n";
            last = re.lastIndex;
        }
        code += "__out += " + JSON.stringify(src.slice(last)) + ";\nreturn __out;";
        const names = Object.keys(this.env());
        fn = new Function(...names, code);
        this.cache.set(src, fn);
        return fn;
    }

    render(passage, w) {
        const env = this.env();
        const text = this.template(passage.text)(...Object.values(env));
        renderMarkdown(this.engine, w, text);
    }
}
