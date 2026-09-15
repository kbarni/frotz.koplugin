// twine/test/regressions.js — Twine 2 format bugs found on real stories.
//
//   qjs --std twine/test/regressions.js      (exit status 1 on a failure)

import * as std from "std";
import { loadEngineFromHtml, screenText, findLink } from "./harness.js";

// A Twine 2 story file; the first passage starts. A passage is its text, or
// [text, tags].
function storyHtml(format, version, passages, script = "") {
    const esc = (t) => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
    const data = Object.entries(passages).map(([name, p], i) => {
        const [text, tags] = Array.isArray(p) ? p : [p, ""];
        return `<tw-passagedata pid="${i + 1}" name="${esc(name)}" tags="${esc(tags)}">${esc(text)}</tw-passagedata>`;
    }).join("");
    return `<html><body><tw-storydata name="Test" startnode="1" format="${format}" format-version="${version}" ifid="TEST">`
        + `<script role="script" id="twine-user-script" type="text/twine-javascript">${script}</script>${data}</tw-storydata></body></html>`;
}

let failures = 0;
function check(what, ok, got) {
    print((ok ? "ok    " : "FAIL  ") + what + (ok ? "" : `\n      got: ${JSON.stringify(got)}`));
    if (!ok) failures++;
}

function test(name, fn) {
    try {
        fn();
    } catch (e) {
        check(`${name}: ${e.message}`, false, e.stack);
    }
}

test("Harlowe hook starting with [[", () => {
    // Birdland: link text holds no "]", so `[[Verse]<v|` is a named hook in a hook.
    const e = loadEngineFromHtml(storyHtml("Harlowe", "3.3.8",
        { Start: "[[Verse one]<v1| and more]<verses|(click: ?v1)[(replace: ?verses)[Sung.]] [[Go->Two]]", Two: "" }));
    e.start();
    const { text, links } = screenText(e);
    check("Harlowe: `[[text]<name|` is a hook, `[[Go->Two]]` still a link",
        text === "[Verse one]{1} and more [Go]{2}" && links.length === 2, text);
});

test("Harlowe nesting stays fast", () => {
    let src = "x";
    for (let d = 0; d < 14; d++) src = `[[${src}]<h${d}| y]<g${d}|`;
    const e = loadEngineFromHtml(storyHtml("Harlowe", "3.3.8", { Start: src }));
    const t0 = Date.now();
    e.start();
    check("Harlowe: 14 nested `[[…]<name|` hooks render quickly", Date.now() - t0 < 1000, Date.now() - t0);
});

test("Harlowe 's after a call", () => {
    // Will Not Let Me Go, verses, Animalia, Tavern Crawler, Fabricationist.
    const cases = [
        ["(print: (passage:)'s name)", "Start"],
        [`(if: (passage:)'s tags contains "x")[tagged]`, "tagged"],
        ["(if: (passage:)'s tags's length > 0)[has tags]", "has tags"],
        ["(print: (a: 5, 6)'s 1st)", "5"],
        ["(set: $a to (a: (a: 7, 8)))(print: $a's 1st's last)", "8"],
        ["(set: $a to (a: 1, 2))(print: $a's length)", "2"],
    ];
    for (const [src, want] of cases) {
        const e = loadEngineFromHtml(storyHtml("Harlowe", "3.3.8", { Start: [src, "x"] }));
        e.start();
        check(`Harlowe: ${src}`, screenText(e).text === want, screenText(e).text);
    }
});

test("Harlowe (more:)", () => {
    // verses: the way on appears once the words to translate are all tapped.
    const e = loadEngineFromHtml(storyHtml("Harlowe", "3.3.8",
        { Start: `Tu ești.(click-replace: "Tu")[You](more:)[ [[Onward->Two]]]`, Two: "" }));
    e.start();
    check("Harlowe (more:): hidden while another link is on the page",
        screenText(e).links.length === 1 && findLink(e, "Onward") === undefined, screenText(e).text);
    e.activate(findLink(e, "Tu"));
    check("Harlowe (more:): shown when no link is left", findLink(e, "Onward") !== undefined, screenText(e).text);
});

test("SugarCube 2 with the Twine 1 revision library", () => {
    // Cozy Simulation 2999 ships the library; SugarCube 2 must keep its own <<cycle>>.
    const library = `(function(){var h=function(){};[{name:"cycle",flavour:"cycle",trigger:"revisemacro"},
        {name:"replace",flavour:"replace",trigger:"link"}].forEach(function(e){e.handler=h;macros[e.name]=e;});}());`;
    const e = loadEngineFromHtml(storyHtml("SugarCube", "2.36.1", {
        Start: `<<set $c to "a">>Pattern: <<cycle "$c" autoselect>><<option "a">><<option "b">><</cycle>>`,
    }, library));
    e.start();
    check("SugarCube 2: <<cycle>> is SugarCube's, not the library's", screenText(e).text === "Pattern: [a]{1}", screenText(e).text);
});

test("SugarCube `is not`", () => {
    const e = loadEngineFromHtml(storyHtml("SugarCube", "2.36.1",
        { Start: `<<if 1 is not 2>>differs<</if>><<if 1 is not 1>>same<</if>>` }));
    e.start();
    check("SugarCube: `is not` is !==", screenText(e).text === "differs", screenText(e).text);
});

if (failures) {
    print(`\n${failures} failed`);
    std.exit(1);
}
print("\nall passed");
