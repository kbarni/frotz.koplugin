// twine/test/crawl.js — random-walk stories and report what breaks.
//
//   qjs twine/test/crawl.js [--steps N] [--walks N] story.html…
// For each story: several seeded walks of N steps (links, typed lines, timer
// ticks, the odd undo). Counts screens showing "[Error", dead ends, and
// passages reached; unsupported features are logged on stderr by the engine.

import { loadEngine, screenText } from "./harness.js";

let steps = 60, walks = 4;
const files = [];
const argv = scriptArgs.slice(1);
for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--steps") steps = parseInt(argv[++i], 10);
    else if (argv[i] === "--walks") walks = parseInt(argv[++i], 10);
    else files.push(argv[i]);
}

for (const file of files) {
    const name = file.split("/").pop();
    const seen = new Set();
    const errors = new Map();
    let deadEnds = 0, crashed = null;
    let total = 0;
    try {
        for (let walk = 0; walk < walks; walk++) {
            const engine = loadEngine(file, { seed: 1000 + walk, answers: ["Alex", "yes", "42"] });
            engine.start();
            for (let s = 0; s < steps; s++) {
                seen.add(engine.passageName);
                const { text, links } = screenText(engine);
                for (const m of text.matchAll(/\[Error: ([^\]]*)\]|<alert>\[([^\]]*)\]<\/>/g)) {
                    const msg = (m[1] || m[2]).slice(0, 120);
                    errors.set(msg, (errors.get(msg) || 0) + 1);
                }
                if (engine.lineRequest) {
                    engine.submitLine("Alex");
                    continue;
                }
                if (!links.length) {
                    if (engine.nextTimerDelay() !== null) {
                        engine.fireTimers();
                        continue;
                    }
                    deadEnds++;
                    if (!engine.undo()) break;
                    continue;
                }
                const pick = links[Math.floor(Math.random() * links.length)];
                engine.activate(pick);
                total++;
            }
        }
    } catch (e) {
        crashed = (e && e.message) + "\n" + (e && e.stack);
    }
    print(`\n## ${name}: ${seen.size} passages, ${total} clicks, ${deadEnds} dead ends`);
    if (crashed) print("   CRASH: " + crashed);
    for (const [msg, n] of [...errors].sort((a, b) => b[1] - a[1]).slice(0, 12)) {
        print(`   ${n}x ${msg}`);
    }
}
