// twine/test/harness.js — build an engine without the protocol, for tests.

import * as std from "std";
import { extract } from "../extract.js";
import { Engine } from "../engine.js";
import { createFormat } from "../formats/index.js";

export function loadEngine(path, opts) {
    const html = std.loadFile(path);
    if (html === null) throw new Error("can't read " + path);
    return loadEngineFromHtml(html, opts);
}

export function loadEngineFromHtml(html, { seed = 1, answers = [] } = {}) {
    const story = extract(html);
    const io = {
        askLine(_eng, prompt, def) {
            const v = answers.length ? answers.shift() : def;
            print(`  [prompt] ${prompt} -> ${v}`);
            return v;
        },
    };
    const engine = new Engine(story, io, createFormat);
    engine.rng.setState(seed);
    Math.random = () => engine.rng.next();
    return engine;
}

// The screen as text: links shown as [label]{n}, styles as <style>…</>.
export function screenText(engine) {
    const runs = engine.screen();
    const links = [];
    let out = "";
    for (const r of runs) {
        let t = r.img ? `<img ${r.img.n}${r.img.alt ? ": " + r.img.alt : ""}>` : r.text;
        if (r.style !== "normal") t = `<${r.style}>${t}</>`;
        if (r.link) {
            if (!links.includes(r.link)) links.push(r.link);
            t = `[${t}]{${links.indexOf(r.link) + 1}}`;
        }
        out += t;
    }
    return { text: out, links, runs };
}

// Link id whose text contains `label` (case-insensitive), or "#n" for the nth.
export function findLink(engine, label) {
    const { links, runs } = screenText(engine);
    if (/^#\d+$/.test(label)) return links[parseInt(label.slice(1), 10) - 1];
    const text = new Map();
    for (const r of runs) if (r.link) text.set(r.link, (text.get(r.link) || "") + r.text);
    const want = label.toLowerCase();
    for (const id of links) if (text.get(id).toLowerCase().trim() === want) return id;
    for (const id of links) if (text.get(id).toLowerCase().includes(want)) return id;
    return undefined;
}
