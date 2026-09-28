// twine/extract.js — pull a Twine story out of its published HTML file.
//
// A published Twine game is one HTML file: the story format's runtime (which we
// ignore) plus the story itself, stored as escaped text inside
//   Twine 2: <tw-storydata ...><tw-passagedata ...>text</tw-passagedata>...
//   Twine 1: <div id="storeArea"><div tiddler="Name" tags="...">text</div>...
// This module only reads that data; it knows nothing about markup.

const NAMED = {
    amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: "\u00a0",
    hellip: "\u2026", mdash: "\u2014", ndash: "\u2013", lsquo: "\u2018",
    rsquo: "\u2019", ldquo: "\u201c", rdquo: "\u201d", laquo: "\u00ab",
    raquo: "\u00bb", copy: "\u00a9", reg: "\u00ae", trade: "\u2122",
    middot: "\u00b7", bull: "\u2022", deg: "\u00b0", times: "\u00d7",
    eacute: "\u00e9", egrave: "\u00e8", agrave: "\u00e0", ccedil: "\u00e7",
    ouml: "\u00f6", uuml: "\u00fc", auml: "\u00e4", szlig: "\u00df",
};

export function decodeEntities(s) {
    if (s.indexOf("&") < 0) return s;
    return s.replace(/&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z][a-zA-Z0-9]*);/g, (m, e) => {
        if (e[0] === "#") {
            const hex = e[1] === "x" || e[1] === "X";
            const cp = parseInt(hex ? e.slice(2) : e.slice(1), hex ? 16 : 10);
            try { return String.fromCodePoint(cp); } catch (_) { return m; }
        }
        const v = NAMED[e] ?? NAMED[e.toLowerCase()];
        return v !== undefined ? v : m;
    });
}

export function parseAttrs(s) {
    const attrs = {};
    const re = /([\w:.-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>"']+)))?/g;
    let m;
    while ((m = re.exec(s)) !== null) {
        attrs[m[1].toLowerCase()] = decodeEntities(m[2] ?? m[3] ?? m[4] ?? "");
    }
    return attrs;
}

function splitTags(s) {
    return (s || "").split(/\s+/).filter((t) => t !== "");
}

function newStory() {
    return {
        format: null, formatVersion: null, name: null, ifid: null,
        start: null,            // passage object
        passages: new Map(),    // name -> { pid, name, tags, text }
        scripts: [],            // author JavaScript, in file order
        styles: [],             // author CSS (unused, kept for diagnostics)
    };
}

function addPassage(story, p) {
    // First definition wins, like the formats themselves.
    if (!story.passages.has(p.name)) story.passages.set(p.name, p);
}

function extractTwine2(html, at) {
    const story = newStory();
    const tagEnd = html.indexOf(">", at);
    const meta = parseAttrs(html.slice(at + "<tw-storydata".length, tagEnd));
    let close = html.indexOf("</tw-storydata>", tagEnd);
    if (close < 0) close = html.length;
    const body = html.slice(tagEnd + 1, close);

    story.name = meta.name || null;
    story.ifid = meta.ifid || null;
    story.format = (meta.format || "").toLowerCase() || null;
    story.formatVersion = meta["format-version"] || null;

    const byPid = new Map();
    const pre = /<tw-passagedata\b([^>]*)>([\s\S]*?)<\/tw-passagedata>/g;
    let m;
    while ((m = pre.exec(body)) !== null) {
        const a = parseAttrs(m[1]);
        const p = { pid: a.pid, name: a.name ?? "", tags: splitTags(a.tags),
                    text: decodeEntities(m[2]) };
        addPassage(story, p);
        if (a.pid !== undefined) byPid.set(a.pid, p);
    }
    const sre = /<script\b([^>]*)>([\s\S]*?)<\/script>/g;
    while ((m = sre.exec(body)) !== null) {
        if (/role\s*=\s*["']?script/i.test(m[1])) story.scripts.push(m[2]);
    }
    const cre = /<style\b([^>]*)>([\s\S]*?)<\/style>/g;
    while ((m = cre.exec(body)) !== null) {
        if (/role\s*=\s*["']?stylesheet/i.test(m[1])) story.styles.push(m[2]);
    }
    story.start = byPid.get(meta.startnode) || story.passages.get("Start")
                  || story.passages.values().next().value || null;
    return story;
}

// Twine 1 escapes passage text twice: backslash escapes for \n \t \\, then HTML.
function unescapeTwine1(s) {
    return decodeEntities(s).replace(/\\([nts\\])/g, (_, c) =>
        c === "n" ? "\n" : c === "t" ? "\t" : c === "s" ? " " : "\\");
}

function extractTwine1(html, at) {
    const story = newStory();
    const re = /<div\b([^>]*\btiddler\s*=[^>]*)>([\s\S]*?)<\/div>/g;
    re.lastIndex = at;
    let m;
    while ((m = re.exec(html)) !== null) {
        const a = parseAttrs(m[1]);
        const p = { pid: null, name: a.tiddler ?? "", tags: splitTags(a.tags),
                    text: unescapeTwine1(m[2]) };
        addPassage(story, p);
        if (p.tags.includes("script")) story.scripts.push(p.text);
        if (p.tags.includes("stylesheet")) story.styles.push(p.text);
    }
    // Twine 1 does not record the format; its macro language is the ancestor of
    // SugarCube's, which is how we play it.
    const head = html.slice(0, at);
    story.format = /SugarCube/.test(head) ? "sugarcube" : "twine1";
    story.formatVersion = "1";
    const title = story.passages.get("StoryTitle");
    story.name = title ? title.text.trim() : null;
    story.start = story.passages.get("Start") || null;
    return story;
}

// Returns a story, or throws Error with a player-readable message.
export function extract(html) {
    // A format's own runtime can contain "<tw-storydata" (Chapbook ships a
    // template with sample passages), so try every occurrence and prefer the
    // one Twine itself wrote: it names its format and IFID.
    let best = null, bestScore = -1;
    for (let at = html.indexOf("<tw-storydata"); at >= 0;
         at = html.indexOf("<tw-storydata", at + 1)) {
        const story = extractTwine2(html, at);
        const score = (story.format ? 2e6 : 0) + (story.ifid ? 1e6 : 0) + story.passages.size;
        if (story.passages.size > 0 && score > bestScore) {
            best = story;
            bestScore = score;
        }
    }
    if (best && best.passages.size > 0) return best;
    const t1 = html.search(/<div\b[^>]*\bid\s*=\s*["']?store-?area/i);
    if (t1 >= 0) {
        const story = extractTwine1(html, t1);
        if (story.passages.size > 0) return story;
    }
    throw new Error("This HTML file is not a Twine story.");
}
