// twine/protocol.js — the RemGlk JSON subset the plugin already speaks.
//
// Shapes follow remglk/rgdata.c exactly, so the plugin's engine cannot tell this
// player from a Glk VM:
//   update:  {type:"update", gen, windows?, content:[{id, clear, text:[lines]}],
//             input:[{id, gen, type?:"line", maxlen?, hyperlink:true}], timer?}
//   line:    {content:[{style, text, hyperlink?}]}   or {} for a blank line
// Events in: init, hyperlink {value}, line {value}, timer — plus three
// extensions only this player understands: savestate / restorestate {path},
// undo. Their result rides back on the next update under the same key.

import * as std from "std";

export const WINDOW = 1;

export class Protocol {
    constructor() {
        this.gen = 0;
        this.sentWindows = false;
        this.lastTimer = null;
    }

    // Next event object, or null at end of input (the plugin closed the pipe).
    read() {
        for (;;) {
            const line = std.in.getline();
            if (line === null) return null;
            const t = line.trim();
            if (t === "") continue;
            try {
                return JSON.parse(t);
            } catch (_) {
                log("ignoring malformed event: " + t);
            }
        }
    }

    send(obj) {
        std.out.puts(JSON.stringify(obj) + "\n");
        std.out.flush();
    }

    error(message) {
        this.send({ type: "error", message: String(message) });
    }

    // runs: visible runs; line: also ask for a typed line; timer: ms or null.
    update({ runs, line, timer, extra }) {
        this.gen++;
        const u = { type: "update", gen: this.gen };
        if (!this.sentWindows) {
            u.windows = [{ id: WINDOW, type: "buffer", rock: 0,
                           left: 0, top: 0, width: 80, height: 200 }];
            this.sentWindows = true;
        }
        u.content = [{ id: WINDOW, clear: true, text: toLines(runs) }];
        const input = { id: WINDOW, gen: this.gen, hyperlink: true };
        if (line) {
            input.type = "line";
            input.maxlen = 256;
        }
        u.input = [input];
        const t = timer === undefined ? null : timer;
        if (t !== this.lastTimer) {
            u.timer = t;
            this.lastTimer = t;
        }
        if (extra) Object.assign(u, extra);
        this.send(u);
    }
}

function toLines(runs) {
    const lines = [[]];
    for (const r of runs) {
        const parts = r.text.split("\n");
        for (let i = 0; i < parts.length; i++) {
            if (i > 0) lines.push([]);
            if (parts[i] === "") continue;
            const span = { style: r.style, text: parts[i] };
            if (r.link) span.hyperlink = r.link;
            lines[lines.length - 1].push(span);
        }
    }
    return lines.map((content) => (content.length ? { content } : {}));
}

export function log(message) {
    std.err.puts("[twine] " + message + "\n");
    std.err.flush();
}
