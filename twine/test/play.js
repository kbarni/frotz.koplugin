// twine/test/play.js — play a story from the command line.
//
//   qjs twine/test/play.js story.html [step…]
// Steps: link text (or "#2" for the second link), ">text" to type a line,
// "@timer", "@undo", "@save:FILE", "@load:FILE". Prints every screen.

import * as std from "std";
import { loadEngine, screenText, findLink } from "./harness.js";

const [path, ...steps] = scriptArgs.slice(1);
const engine = loadEngine(path);
engine.start();
show("start");

for (const step of steps) {
    if (step.startsWith(">")) {
        if (!engine.submitLine(step.slice(1))) print("!! no text field on this screen");
    } else if (step === "@timer") {
        if (!engine.fireTimers()) print("!! no timer pending");
    } else if (step === "@undo") {
        if (!engine.undo()) print("!! nothing to undo");
    } else if (step.startsWith("@save:")) {
        const f = std.open(step.slice(6), "w");
        f.puts(engine.saveData());
        f.close();
    } else if (step.startsWith("@load:")) {
        engine.loadData(std.loadFile(step.slice(6)));
    } else {
        const id = findLink(engine, step);
        if (id === undefined) {
            print(`!! no link "${step}"`);
            break;
        }
        engine.activate(id);
    }
    show(step);
}

function show(step) {
    const { text } = screenText(engine);
    print(`\n===== ${step} \u2192 ${engine.passageName} (timer: ${engine.nextTimerDelay()}, line: ${!!engine.lineRequest})`);
    print(text);
}
