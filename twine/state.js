// twine/state.js — serialisable game state helpers.
//
// Saves, undo and replay all snapshot the story variables as JSON. Harlowe keeps
// datamaps/datasets as Map/Set, which plain JSON drops, so they are tagged.

const MAP = "\u0000map", SET = "\u0000set";

export function serialize(value) {
    return JSON.stringify(value === undefined ? null : value, function (_key, v) {
        if (v instanceof Map) return { [MAP]: [...v.entries()] };
        if (v instanceof Set) return { [SET]: [...v.values()] };
        if (typeof v === "function") return undefined;
        return v;
    });
}

export function deserialize(text) {
    if (text === null || text === undefined) return null;
    return JSON.parse(text, function (_key, v) {
        if (v && typeof v === "object" && !Array.isArray(v)) {
            if (MAP in v) return new Map(v[MAP]);
            if (SET in v) return new Set(v[SET]);
        }
        return v;
    });
}

// Deep copy through the same encoding, so copies never share mutable values.
export function clone(value) {
    return deserialize(serialize(value));
}

// mulberry32: tiny, fast, and — the point — its whole state is one integer, so a
// save or an undo step restores the exact random sequence the player saw.
export class Rng {
    constructor(seed) {
        this.s = (seed === undefined ? (Date.now() ^ 0x5bd1e995) : seed) | 0;
    }
    next() {
        let t = (this.s = (this.s + 0x6d2b79f5) | 0);
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    }
    // Integer in [min, max], both inclusive.
    int(min, max) {
        if (max < min) [min, max] = [max, min];
        return Math.floor(this.next() * (max - min + 1)) + min;
    }
    getState() { return this.s; }
    setState(s) { this.s = s | 0; }
}
