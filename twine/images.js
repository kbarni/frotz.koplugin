// twine/images.js — where a story's pictures come from.
//
// The plugin shows Twine images the way it shows Blorb illustrations (a
// tappable placeholder line, the picture in KOReader's viewer), but it can only
// open local files. This table turns an image source into one of:
//   file   — an absolute path: a file beside the story, or a data: image (also a
//            Twine 1 image passage) decoded once into the cache directory
//   remote — an http(s) URL, which the plugin can't fetch
//   none   — nothing usable (a script trick like src="!@#$", an expression the
//            format left unevaluated, a data: image with no cache directory)
// and numbers every distinct picture in order of first appearance. Numbers live
// as long as the process: undo, restart and restore keep them.

import * as std from "std";
import * as os from "os";
import { log } from "./protocol.js";

const NONE = { kind: "none", url: null };
const EXT = { png: "png", jpeg: "jpg", jpg: "jpg", gif: "gif", webp: "webp", "svg+xml": "svg", bmp: "bmp" };

const B64 = new Int16Array(128).fill(-1);
"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".split("")
    .forEach((c, i) => { B64[c.charCodeAt(0)] = i; });
B64["-".charCodeAt(0)] = 62;   // base64url
B64["_".charCodeAt(0)] = 63;

export function base64Decode(s) {
    const out = new Uint8Array(Math.floor(s.length * 3 / 4) + 3);
    let n = 0, acc = 0, bits = 0;
    for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        const v = c < 128 ? B64[c] : -1;
        if (v < 0) continue;              // whitespace, padding, junk
        acc = ((acc << 6) | v) & 0xffffff;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[n++] = (acc >> bits) & 0xff;
        }
    }
    return out.subarray(0, n);
}

function fnv1a(s) {
    let h = 0x811c9dc5;
    for (let i = 0; i < s.length; i++) {
        h ^= s.charCodeAt(i);
        h = Math.imul(h, 0x01000193);
    }
    return (h >>> 0).toString(16).padStart(8, "0");
}

function dirOf(path) {
    const i = path.lastIndexOf("/");
    if (i < 0) return ".";
    return i === 0 ? "" : path.slice(0, i);
}

function percentDecode(s) {
    try { return decodeURIComponent(s); } catch (_) { return s; }
}

export class ImageTable {
    // storyPath: the story file (relative sources are beside it);
    // cacheDir: where decoded data: images go (null: data: images are unusable).
    constructor(storyPath, cacheDir) {
        this.baseDir = storyPath ? dirOf(storyPath) : null;
        this.cacheDir = cacheDir || null;
        this.numbers = new Map();   // resolved url -> number
        this.resolved = new Map();  // source as written -> { kind, url }
        this._madeDir = false;
    }

    // passage: name -> passage or undefined, for Twine 1 image passages.
    resolve(src, passage) {
        src = String(src ?? "").trim();
        let r = this.resolved.get(src);
        if (!r) {
            r = this._resolve(src, passage);
            this.resolved.set(src, r);
        }
        return r;
    }

    number(url) {
        let n = this.numbers.get(url);
        if (!n) {
            n = this.numbers.size + 1;
            this.numbers.set(url, n);
        }
        return n;
    }

    _resolve(src, passage) {
        if (src === "") return NONE;
        if (passage && src.length < 256) {
            const p = passage(src);
            if (p && p.tags && p.tags.includes("Twine.image")) src = String(p.text).trim();
        }
        if (/^data:/i.test(src)) return this._data(src);
        if (/^https?:\/\//i.test(src)) return { kind: "remote", url: src };
        if (src.startsWith("//")) return { kind: "remote", url: "https:" + src };
        if (/^[a-z][\w+.-]*:/i.test(src) || /["'<>${}\\]/.test(src)) return NONE;
        if (this.baseDir === null) return NONE;
        const rel = percentDecode(src.replace(/[?#].*$/, "")).replace(/^(?:\.\/)+/, "");
        if (rel === "" || rel.startsWith("/")) return NONE;
        return { kind: "file", url: this.baseDir + "/" + rel };
    }

    _data(uri) {
        const m = /^data:([^;,]*)((?:;[^;,]*)*),/i.exec(uri);
        if (!m || !this.cacheDir) return NONE;
        const type = m[1].trim().toLowerCase();
        const ext = type.startsWith("image/") ? EXT[type.slice(6)] : undefined;
        if (!ext) return NONE;
        const path = `${this.cacheDir}/${fnv1a(uri)}-${uri.length.toString(36)}.${ext}`;
        const [, err] = os.stat(path);
        if (err !== 0) {
            try {
                this._write(path, uri.slice(m[0].length), /;\s*base64/i.test(m[2]));
            } catch (e) {
                log("can't cache an image: " + e.message);
                return NONE;
            }
        }
        return { kind: "file", url: path };
    }

    _write(path, payload, isBase64) {
        if (!this._madeDir) {
            os.mkdir(this.cacheDir, 0o755);   // fails harmlessly when it exists
            this._madeDir = true;
        }
        const tmp = path + ".part";
        const f = std.open(tmp, "wb");
        if (!f) throw new Error("can't write " + tmp);
        if (isBase64) {
            const bytes = base64Decode(payload);
            f.write(bytes.buffer, bytes.byteOffset, bytes.length);
        } else {
            f.puts(percentDecode(payload));
        }
        f.close();
        if (os.rename(tmp, path) !== 0) throw new Error("can't write " + path);
    }
}
