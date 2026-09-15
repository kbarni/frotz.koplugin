// twine/test/revision.js — Twine 1 legacy macros: the revision macro library
// (formats/revision.js), <<timedgoto>>, [[Back|previous()]] and `OR`/`AND`.
//
//   qjs --std twine/test/revision.js        (exit status 1 on a failure)

import * as std from "std";
import { loadEngineFromHtml, screenText, findLink } from "./harness.js";

// The registration half of Leon Arnott's library: the table SugarCube reads.
const LIBRARY = `(function(){var nullobj={handler:function(){}};function h(){}
[{name:"replace",flavour:"replace",trigger:"link"},{name:"insert",flavour:"insert",trigger:"link"},
 {name:"timedinsert",flavour:"insert",trigger:"time"},{name:"timedreplace",flavour:"replace",trigger:"time"},
 {name:"revision",flavour:"replace",trigger:"revisemacro"},{name:"once",flavour:"remove",trigger:"visited"},
 {name:"later",flavour:"insert",trigger:"visited"},{name:"continue",flavour:"continue",trigger:"link"}
].forEach(function(e){e.handler=h;macros[e.name]=e;macros["end"+e.name]=nullobj;});
macros.revert=macros.revise=macros.randomise=macros.randomize={handler:h};macros.instantrevise={handler:h};
}());`;

// A Twine 1 story file: passages in a storeArea, text escaped the Twine 1 way.
function storyHtml(passages) {
    const esc = (t) => t.replace(/\\/g, "\\\\").replace(/\n/g, "\\n").replace(/&/g, "&amp;")
        .replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
    const divs = Object.entries(passages).map(([name, text]) =>
        `<div tiddler="${name}" tags="${name === "Library" ? "script" : ""}">${esc(text)}</div>`);
    return `<html><body><div id="storeArea">${divs.join("\n")}</div></body></html>`;
}

function play(passages, library = true) {
    const e = loadEngineFromHtml(storyHtml(Object.assign(library ? { Library: LIBRARY } : {}, passages)));
    e.start();
    return e;
}

const text = (e) => screenText(e).text;

function tap(e, label) {
    const id = findLink(e, label);
    if (id === undefined) throw new Error(`no link "${label}" on: ${text(e)}`);
    e.activate(id);
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

test("replace", () => {
    const e = play({ Start: "Before <<replace>>old<<becomes>>new<<endreplace>> after." });
    check("replace: the first version is a link", text(e) === "Before [old]{1} after.", text(e));
    tap(e, "old");
    check("replace: a tap shows the next version as plain text", text(e) === "Before new after.", text(e));
});

test("insert", () => {
    const e = play({ Start: `Stir <<insert "the pot.">> It bubbles.<<endinsert>>` });
    check("insert: the argument is the link", text(e) === "Stir [the pot.]{1}", text(e));
    tap(e, "the pot.");
    check("insert: the link text stays and the body joins it", text(e) === "Stir the pot. It bubbles.", text(e));
});

test("timedinsert", () => {
    const e = play({ Start: "<<if true>>Wait.<<timedinsert 2s>> Then this.<<endtimedinsert>><<endif>> End." });
    check("timedinsert: hidden at first (closers inside <<if>>)", text(e) === "Wait. End.", text(e));
    check("timedinsert: a 2s timer", e.nextTimerDelay() === 2000, e.nextTimerDelay());
    e.fireTimers();
    check("timedinsert: shown after the timer", text(e) === "Wait. Then this. End.", text(e));
    check("timedinsert: no timer left", e.nextTimerDelay() === null, e.nextTimerDelay());
});

test("timedreplace", () => {
    const e = play({ Start: `<<timedreplace 1s>>One<<becomes>>Two<<becomes>><<goto "Next">><<endtimedreplace>>`,
        Next: "Arrived." });
    check("timedreplace: first version", text(e) === "One", text(e));
    e.fireTimers();
    check("timedreplace: second version", text(e) === "Two", text(e));
    e.fireTimers();
    check("timedreplace: the last version's <<goto>> jumps", e.passageName === "Next", e.passageName);
});

test("once/later", () => {
    const e = play({ Start: "<<once>>First time.<<endonce>><<later>>Back again.<<endlater>> [[Out]]",
        Out: "[[Start]]" });
    check("once/later: first visit", text(e) === "First time. [Out]{1}", text(e));
    tap(e, "Out");
    tap(e, "Start");
    check("once/later: second visit", text(e) === "Back again. [Out]{1}", text(e));
    e.undo();
    e.undo();
    check("once/later: undo restores the count", e.passageName === "Start" && text(e) === "First time. [Out]{1}", text(e));
});

test("remember", () => {
    // <<remember>> has no body: it must not swallow the rest of the passage.
    const e = play({ Start: "<<once>>Logged.<<remember $seen to true>><<endonce>> [[Out]]", Out: "" });
    check("remember: the rest of the passage stays", text(e) === "Logged. [Out]{1}", text(e));
});

test("revise", () => {
    const e = play({ Start: `He <<revise sit "sits">><<revision sit>> <<becomes>>sits <<endrevision>>quietly.` });
    check("revise: the link shows although its span comes later", text(e) === "He [sits]{1} quietly.", text(e));
    tap(e, "sits");
    check("revise: the span changes and the spent link goes", text(e) === "He sits quietly.", text(e));
});

test("revise end", () => {
    const e = play({ Start: `<<revision door>>Shut.<<becomes>>Open.<<endrevision>> <<revise door "Open it" end>>` });
    tap(e, "Open it");
    check("revise end: the last text stays as plain text", text(e) === "Open. Open it", text(e));
});

test("continue", () => {
    const e = play({ Start: `Part one. <<continue "More">> Part two.` });
    check("continue: the rest waits behind the link", text(e) === "Part one. [More]{1}", text(e));
    tap(e, "More");
    check("continue: a tap shows the rest", text(e) === "Part one. Part two.", text(e));
});

test("undo replay", () => {
    const e = play({ Start: "<<replace>>old<<becomes>>new<<endreplace>> [[Two]]", Two: "There." });
    tap(e, "old");
    tap(e, "Two");
    e.undo();
    check("undo replay: the page comes back as it was left", text(e) === "new [Two]{1}", text(e));
});

test("timedgoto", () => {
    const e = play({ Start: `<<timedgoto "Two" 1.5s>>Waiting.`, Two: "Here." }, false);
    check("timedgoto: a 1.5s timer", e.nextTimerDelay() === 1500, e.nextTimerDelay());
    e.fireTimers();
    check("timedgoto: jumps", e.passageName === "Two", e.passageName);
});

test("previous()", () => {
    const e = play({ Start: "[[Go|Two]]", Two: "[[Back|previous()]]" }, false);
    tap(e, "Go");
    tap(e, "Back");
    check("previous(): the link goes back", e.passageName === "Start", e.passageName);
});

test("operators", () => {
    const e = play({ Start: "<<if 1 is 2 OR 2 is 2>>yes<<endif>><<if 1 is 1 AND 2 is 3>>no<<endif>>" }, false);
    check("operators: OR/AND in capitals", text(e) === "yes", text(e));
});

test("Twine 1.4 expressions", () => {
    const e = play({ Start: `<<if $unset is 0>>zero<<endif>> <<if "1" is 1>>loose<<endif>> <<set $y to 2>><<print $y>>` }, false);
    check("Twine 1.4: an unset variable reads 0, `is` is loose", text(e) === "zero loose 2", text(e));
});

test("replaceMacro 1.0", () => {
    const e = play({ Library: "macros.replace = {handler: function () {}}; macros.endreplace = {handler: function () {}};",
        Start: `Look: <<replace "the lake">>something rises<<endreplace>>` }, false);
    check("replaceMacro 1.0: the argument is the link", text(e) === "Look: [the lake]{1}", text(e));
    tap(e, "the lake");
    check("replaceMacro 1.0: a tap replaces it", text(e) === "Look: something rises", text(e));
});

test("external links", () => {
    const e = play({ Start: "[[My site|http://example.com]] and [[Two]]", Two: "" }, false);
    check("external links: a web address is plain text", text(e) === "My site and [Two]{1}", text(e));
});

test("sound macros", () => {
    const e = play({ Library: "macros.playsound = {handler: function (a, b, c, d) { d.fullArgs(); }};",
        Start: `<<playsound "song.mp3">>quiet` }, false);
    check("sound macros: skipped without an error", text(e) === "quiet", text(e));
});

test("DOM walk", () => {
    const e = play({ Library: `var d = document.getElementById("storeArea").firstChild;
        while (d) { d = d.nextSibling; } setup.walked = "yes";`, Start: "<<print setup.walked>>" }, false);
    check("DOM walk: a loop over page nodes ends", text(e) === "yes", text(e));
});

if (failures) {
    print(`\n${failures} failed`);
    std.exit(1);
}
print("\nall passed");
