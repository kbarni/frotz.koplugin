# *Frotz* interactive fiction plugin for Koreader

This plugin allows to play interactive fiction games in Koreader.

![Screenshot](Screenshot_frotz2.png)

It uses RemGlk-linked interpreters that speak a structured JSON protocol, so the plugin renders a native KOReader UI (real status bar, styled text, single-key and line input). Two virtual machines are driven by the one engine, selected by file extension:

- **Bocfel** — [Z-machine](https://www.ifwiki.org/Z-machine) games: `.z1`–`.z8`, `.zblorb`, `.zlb`, `.dat` (the most common interactive-fiction format)
- **Git** — Glulx games (modern Inform 7): `.ulx`, `.gblorb`, `.blb`, `.blorb`

The plugin is text-focused. Illustrations packed into a game's blorb *are* available — the story shows a tappable `[Illustration 3]` line where the game draws a picture, and tapping it (or the menu's **Illustrations** entry) opens it full screen with pan and zoom. What the plugin does not do is lay pictures out inside the text or paint the graphics windows some Glulx games use for maps and borders; for that, use the **[Gargoyle application](https://github.com/kbarni/garglk)** for Kindle instead.

## Features

- Should work on most platforms where Koreader is available
- Z-machine **and** Glulx (modern Inform 7) games support
- Native KOReader rendering: status bar, styled text, single-key and line input
- Simple save and restore mechanism (per game and with slots), including autosave at closing
- Game history, so you can resume the last played games
- Illustrations from the game's blorb, opened full screen from the story or the menu
- Word lookup in dictionaries or Wikipedia, just like in Koreader
- Possibility to hide on screen keyboard when using it with external keyboard
- Font size setting

## Installation and running

To install, copy the contents of the release to the `koreader/plugins` folder.

To run, click on *Interactive fiction* in the *Tools* menu.

Each architecture ships two interpreter binaries, `bocfel` (Z-machine) and `git` (Glulx), under `binaries/<arch>/`. The plugin picks the right one for your device automatically; you only need the folder matching your device:

| Folder | Architecture | Devices |
|--------|--------------|---------|
| `binaries/armhf/` | ARM hard-float | Most e-readers, recent (hard-float) Kindles and Kobos |
| `binaries/armel/` | ARM soft-float | Older Kindles - firmware < 5.16.2 |
| `binaries/aarch64/` | 64-bit ARM (Linux) | Newer aarch64 Linux e-readers |
| `binaries/x86_64/` | X86 (64 bit) | Desktop computers (Linux) / KOReader emulator |

The `aarch64` binaries will **not** run on Android devices (e.g. Boox or other tablets): Android uses a different C library (bionic), and its app storage is typically mounted non-executable, so the plugin's interpreter binaries cannot be launched there.

On some devices you need to make the binaries **executable**. Open the terminal and type:

```
cd Koreader/plugins/frotz.koplugin/binaries/<arch>
chmod +x bocfel
chmod +x git
```

## About interactive fiction games

Interactive fiction was a major game genre at the beginning of the 1980s. It was well adapted for the first PCs, which lacked graphics and processing power. It started with *Colossal Cave Adventure* in 1979 and became mainstream with the *Zork* trilogy, which had a more advanced interpreter with more commands, better puzzles and larger worlds.

By the end of the decade it became replaced by the point and click adventure games, with nicer graphics, more intuitive interfaces and music.

However the genre survived in the shadow, further developed by enthousiasts - it still provides some gameplay mechanics that no other genre offers. *Counterfeit Monkey* takes you to the island of linguistics, where you can manipulate words instead of objects; *Coloratura* presents our world through the eyes of an alien creature, who sees emotions and energies instead of light and so on. What's best: these games are mostly free!

To get IF games, check out one of the dedicated websites: [IFDB](https://ifdb.org/search?browse) or [IFWiki](https://www.ifwiki.org/Special:Drilldown/Games)

---

Please file ideas, suggestions and bug reports as an issue.

> The plugin keeps the *Frotz* name for historical reasons; it drives
> RemGlk-linked virtual machines, not the Frotz interpreter.

## Credits

The interpreters are bundled as separate binaries, each under its own license:

- **[Bocfel](https://github.com/garglk/garglk/tree/master/terps/bocfel)** — Z-machine VM by Chris Spiegel
- **[Git](https://github.com/DavidKinder/Git)** — Glulx VM by Iain Merrick
- **[RemGlk](https://github.com/erkyrath/remglk)** — the JSON Glk I/O layer by Andrew Plotkin

## License

This program is provided under General Public License v3.
