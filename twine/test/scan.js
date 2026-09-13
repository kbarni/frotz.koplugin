// twine/test/scan.js — corpus survey: which formats and macros real games use.
// Usage: qjs twine/test/scan.js game1.html game2.html ...
import * as std from "std";
import { extract } from "../extract.js";

const totals = {};   // format -> Map(macro -> games using it)

function bump(map, key) { map.set(key, (map.get(key) || 0) + 1); }

for (const path of scriptArgs.slice(1)) {
    const html = std.loadFile(path);
    let story;
    try { story = extract(html); } catch (e) {
        print(`!! ${path}: ${e.message}`);
        continue;
    }
    const fmt = story.format + "-" + String(story.formatVersion || "?").split(".")[0];
    const used = new Set();
    for (const p of story.passages.values()) {
        const t = p.text;
        let m;
        if (/harlowe/.test(fmt)) {
            const re = /\(([\w-]+):/g;
            while ((m = re.exec(t)) !== null) used.add("(" + m[1].toLowerCase() + ":)");
            if (/\|[\w-]+>\[|\]<[\w-]+\|/.test(t)) used.add("named-hook");
            if (/\?[\w-]+/.test(t)) used.add("?hookref");
        } else if (/chapbook/.test(fmt)) {
            const re = /\{([a-z][\w ]*?)(?:[:}])/gi;
            while ((m = re.exec(t)) !== null) used.add("{" + m[1].toLowerCase() + "}");
            const mr = /^\[([^\]\n]+)\]\s*$/gm;
            while ((m = mr.exec(t)) !== null) used.add("[" + m[1].split(/\s/)[0].toLowerCase() + "]");
            if (/^\s*[\w.]+\s*(\(.*\))?\s*:.*\n[\s\S]*?^--\s*$/m.test(t)) used.add("vars-section");
        } else {
            const re = /<<\/?([\w-]+|=|-)/g;
            while ((m = re.exec(t)) !== null) used.add("<<" + m[1] + ">>");
        }
        const tags = /<(\/?)([a-zA-Z][\w-]*)/g;
        while ((m = tags.exec(t)) !== null) if (!m[1]) used.add("<" + m[2].toLowerCase() + ">");
    }
    const scripts = story.scripts.reduce((n, s) => n + s.trim().length, 0);
    print(`${fmt.padEnd(12)} passages=${String(story.passages.size).padEnd(4)} js=${String(scripts).padEnd(6)} start=${story.start && story.start.name} | ${story.name}`);
    const map = totals[fmt] || (totals[fmt] = new Map());
    map.set("#games", (map.get("#games") || 0) + 1);
    for (const u of used) bump(map, u);
}

for (const [fmt, map] of Object.entries(totals)) {
    const rows = [...map.entries()].sort((a, b) => b[1] - a[1]);
    print(`\n== ${fmt} ==`);
    print(rows.map(([k, v]) => `${k}:${v}`).join("  "));
}
