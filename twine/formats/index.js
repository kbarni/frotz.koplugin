// twine/formats/index.js — pick the interpreter for a story's format.

import { Harlowe } from "./harlowe.js";
import { SugarCube } from "./sugarcube.js";
import { Chapbook } from "./chapbook.js";
import { Snowman } from "./snowman.js";
import { Plain } from "./plain.js";

export function createFormat(engine) {
    const story = engine.story;
    const format = (story.format || "").toLowerCase();
    switch (format) {
        case "harlowe":
            return new Harlowe(engine);
        case "sugarcube":
            return new SugarCube(engine, { legacy: story.formatVersion === "1" });
        case "twine1":        // Sugarcane / Jonah: SugarCube's ancestors
            return new SugarCube(engine, { legacy: true, twine1: true });
        case "chapbook":
            return new Chapbook(engine);
        case "snowman":
            return new Snowman(engine);
        default:
            engine.warn("story format " + (story.format || "(none)"));
            return new Plain(engine);
    }
}
