// twine/formats/plain.js — fallback for formats we don't interpret: links and
// HTML only, so a story in an unknown format is at least readable.

import { renderLinksAndHtml, stripHtmlComments } from "./common.js";

export class Plain {
    constructor(engine) {
        this.engine = engine;
    }
    init() {}
    render(passage, w) {
        renderLinksAndHtml(this.engine, w, stripHtmlComments(passage.text));
    }
}
