// twine/player.js — entry point: qjs player.js story.html
//
// Runs as the plugin's child process exactly like bocfel/git: JSON events on
// stdin, RemGlk-shaped JSON updates on stdout (see protocol.js). Every update
// re-sends the whole passage with clear:true, so the plugin never has to patch
// its transcript when a link reveals text in the middle of a page.

import * as std from "std";
import { extract } from "./extract.js";
import { Engine } from "./engine.js";
import { Protocol } from "./protocol.js";
import { visibleRuns } from "./writer.js";
import { createFormat } from "./formats/index.js";

// Links the player adds itself at a dead end. Far above any per-passage id.
const SYS_UNDO = 1000001;
const SYS_RESTART = 1000002;

const proto = new Protocol();
let engine = null;
let lastMoment = null;
let titleSent = false;

// Extension fields on an update: the story's own title (once), and whether this
// page is the same passage visit changed in place (a reveal, a timed insert, a
// text field) — the plugin then keeps the reader's position instead of starting
// the passage over. A new passage, an undo or a restore is a different moment.
function pageExtra(extra) {
    const out = Object.assign({}, extra);
    if (engine.current === lastMoment) out.samepage = true;
    lastMoment = engine.current;
    if (!titleSent && engine.story.name) {
        out.title = engine.story.name;
        titleSent = true;
    }
    return out;
}

function screenRuns() {
    const runs = engine.screen();
    if (engine.isDeadEnd(runs)) {
        runs.push({ text: "\n\n", style: "normal", link: 0 });
        runs.push({ text: "The End", style: "subheader", link: 0 });
        runs.push({ text: "\n", style: "normal", link: 0 });
        if (engine.canUndo()) {
            runs.push({ text: "Undo", style: "normal", link: SYS_UNDO });
            runs.push({ text: "    ", style: "normal", link: 0 });
        }
        runs.push({ text: "Restart", style: "normal", link: SYS_RESTART });
    }
    return runs;
}

function sendScreen(extra) {
    proto.update({
        runs: screenRuns(),
        line: !!engine.lineRequest,
        timer: engine.nextTimerDelay(),
        extra: pageExtra(extra),
    });
}

const io = {
    // Blocks until the player types an answer. The passage is half rendered,
    // so saving or undoing is refused until the question is answered.
    askLine(eng, prompt, def) {
        const runs = visibleRuns(eng.runs);
        runs.push({ text: "\n\n", style: "normal", link: 0 });
        runs.push({ text: String(prompt), style: "alert", link: 0 });
        if (def) runs.push({ text: ` (${def})`, style: "normal", link: 0 });
        let extra;
        for (;;) {
            proto.update({ runs, line: true, timer: null, extra: pageExtra(extra) });
            extra = undefined;
            const ev = proto.read();
            if (ev === null) std.exit(0);
            if (ev.type === "line") {
                const v = String(ev.value ?? "");
                return v === "" && def !== undefined ? def : v;
            }
            if (ev.type === "savestate" || ev.type === "restorestate" || ev.type === "undo") {
                extra = { [ev.type]: { ok: false, message: "Answer the question first." } };
            }
        }
    },
};

function saveTo(path) {
    try {
        const f = std.open(path, "w");
        if (!f) throw new Error("can't write " + path);
        f.puts(engine.saveData());
        f.close();
        return { ok: true };
    } catch (e) {
        return { ok: false, message: e.message };
    }
}

function restoreFrom(path) {
    try {
        const text = std.loadFile(path);
        if (text === null) throw new Error("can't read " + path);
        engine.loadData(text);
        return { ok: true };
    } catch (e) {
        return { ok: false, message: e.message };
    }
}

function main() {
    // Like a Glk VM, say nothing until the display layer's init arrives.
    for (;;) {
        const ev = proto.read();
        if (ev === null) return;
        if (ev.type === "init") break;
    }

    let story;
    try {
        const path = scriptArgs[1];
        if (!path) throw new Error("usage: qjs player.js story.html");
        const html = std.loadFile(path);
        if (html === null) throw new Error("Can't read " + path);
        story = extract(html);
    } catch (e) {
        proto.error(e.message);
        return;
    }

    engine = new Engine(story, io, createFormat);
    // Author JavaScript calls Math.random directly; route it through the
    // engine's seeded generator so undo and saves replay the same rolls.
    Math.random = () => engine.rng.next();
    try {
        engine.start();
    } catch (e) {
        proto.error(e.message);
        return;
    }
    sendScreen();

    for (;;) {
        const ev = proto.read();
        if (ev === null) return;
        const extra = {};
        switch (ev.type) {
            case "hyperlink":
                if (ev.value === SYS_UNDO) engine.undo();
                else if (ev.value === SYS_RESTART) engine.restart();
                else engine.activate(ev.value);
                break;
            case "line":
                engine.submitLine(String(ev.value ?? ""));
                break;
            case "timer":
                engine.fireTimers();
                break;
            case "savestate":
                extra.savestate = saveTo(ev.path);
                break;
            case "restorestate":
                extra.restorestate = restoreFrom(ev.path);
                break;
            case "undo":
                extra.undo = { ok: engine.undo() };
                break;
            default:
                break;
        }
        sendScreen(extra);
    }
}

main();
