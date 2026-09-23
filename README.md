# *Frotz* interactive fiction plugin for KOReader

This plugin lets you play interactive fiction games in KOReader.

![Screenshot](screenshot_frotz.png)

It uses RemGlk-linked interpreters that speak a structured JSON protocol, so the plugin renders a native KOReader UI (real status bar, styled text, single-key and line input). Four interpreters are driven by the same engine, selected by file extension:

- **Bocfel** — [Z-machine](https://www.ifwiki.org/Z-machine) games: `.z1`–`.z8`, `.zblorb`, `.zlb`, `.dat` (the most common interactive fiction format)
- **Git** — Glulx games (modern Inform 7): `.ulx`, `.gblorb`, `.glb`, `.blb`, `.blorb`
- **GlkTADS** — [TADS](https://www.tads.org) 2 and 3 games: `.gam`, `.t3` (one binary plays both)
- **Twine** — [Twine](https://twinery.org) stories, published as a single `.html`/`.htm` file, run by the plugin's own Twine player on the [QuickJS](https://bellard.org/quickjs/) JavaScript engine.

The plugin is text-focused. Illustrations *are* available: the story shows a link (e.g. `[Illustration 3]`), and tapping it (or the menu's **Illustrations** entry) opens the picture in KOReader's image viewer. Decorative and repeated images (borders in Glulx games, graphical page elements in Twine games) are left out. For full graphics support, use the **[Gargoyle application](https://github.com/kbarni/garglk)** for Kindle instead.

**Interactive Fiction games are unlike modern games. If you never played interactive fiction before, read the [beginner's tutorial](TUTORIAL.md) and the small introduction to interactive fiction below.S**

## Features

- Should work on most platforms where KOReader is available
- Z-machine, Glulx (Inform 7), TADS 2/3 and Twine games
- Native KOReader rendering: status bar, styled text, single-key and line input
- Simple save and restore (per game and with slots), including autosave on closing
- Recent games list, so you can pick up a game you played before without browsing for it again
- Built-in game finder: browse and search [IFDB](https://ifdb.org), read a game's description and rating, download it and play
- Illustrations from the game's blorb or a Twine story's pictures, opened full screen from the story or the menu
- Word lookup in dictionaries or Wikipedia, just like in KOReader
- Option to hide the on-screen keyboard when using an external keyboard
- Font size setting
- A [beginner's tutorial](TUTORIAL.md) for players new to interactive fiction

## Installation and running

To install, copy the contents of the release to the `koreader/plugins` folder.

To run, tap *Interactive fiction* in the *Tools* menu.

If the Simple UI or ZenUI plugins are installed, Frotz can be added to the main screen:

- as a **quick action** called *Interactive Fiction*, which can be put on the bottom bar or in a Quick Actions row like any built-in action; it opens the *Recent games* list, or the game browser when you haven't played anything yet
- a **homescreen widget** of the games you played last, switched on in Simple UI's *Arrange* list: tap a game to resume it (*saved* marks one with an autosave), and choose how many are listed in the module's *Games shown* setting

### Interpreter binaries

Each architecture ships the interpreter binaries `bocfel` (Z-machine), `git` (Glulx), `tadsr` (TADS 2/3) and `qjs` (QuickJS, for Twine) under `binaries/<arch>/`. The plugin picks the right one for your device automatically; you only need the folder matching your device:

| Folder | Architecture | Devices |
|--------|--------------|---------|
| `binaries/armhf/` | ARM hard-float | Most e-readers, recent (hard-float) Kindles and Kobos |
| `binaries/armel/` | ARM soft-float | Older Kindles (firmware < 5.16.2) |
| `binaries/aarch64/` | 64-bit ARM (Linux) | Newer aarch64 Linux e-readers |
| `binaries/x86_64/` | x86 (64-bit) | Desktop computers (Linux) / KOReader emulator |

The `aarch64` binaries will **not** run on Android devices (e.g. Boox or other tablets): Android uses a different C library (bionic), and its app storage is usually mounted non-executable, so the plugin's interpreter binaries cannot be launched there.

On some devices you need to make the binaries **executable**. Open a terminal and type:

```
cd koreader/plugins/frotz.koplugin/binaries/<arch>
chmod +x bocfel
chmod +x git
chmod +x tadsr
chmod +x qjs
```

### When a game won't start

If the interpreter fails to start or stops before the game appears, the plugin offers to **diagnose** the problem. You can also run the diagnosis at any time from **Interactive Fiction → Diagnose interpreter…**, which tests the last game you played. It checks the binaries, the device's `/tmp` and process start-up, then launches the game. You get a short report in plain words, and the details are written to `frotz_diag.log` in the KOReader folder (e.g. `/mnt/us/koreader/frotz_diag.log` on a Kindle). Please attach that file when you report a problem.

### Finding games

*Find games on IFDB…* opens a browser for the [Interactive Fiction Database](https://ifdb.org) (needs an internet connection):

- Lists: *Top rated*, *Most rated*, *Newest releases*, *Short games*, *Surprise me*
- Filtering by supported game format: all, Z-machine + Glulx, Z-machine, Glulx, TADS or Twine (tap *Formats* to choose)
- Twine games can be downloaded only when the files are available: an `.html` file or a zip (usually on the IF Archive); games published only online (itch.io, philome.la) cannot
- *Search…* by title or author, or with IFDB filters such as `tag:horror`, `author:"Emily Short"`, `rating:4-`, `playtime:-1h`
- Tap a game to see its description, rating, play time, tags and cover, and to **Download** it. Zip files are unpacked automatically; the game is saved to the download folder (default `koreader/ifgames/<game title>/`) and can be started right away


## About interactive fiction games

Interactive fiction was a major game genre at the beginning of the 1980s. It was well suited to the first PCs, which lacked graphics and processing power. It started with *Colossal Cave Adventure* in the late '70s and became mainstream with the *Zork* trilogy, which had a more advanced interpreter with more commands, better puzzles and larger worlds.

Playing is a conversation with the story. The game describes where you are and what you see, and you answer by typing short commands in plain English: `look`, `go north`, `take the lamp`, `open the mailbox`, `ask the guard about the key`. The game replies with what happens next. There is no fixed list of choices: you explore, examine things, pick up objects and combine them to solve puzzles, and part of the pleasure is discovering what the world lets you do. Stuck? `help`, `hint` or `about` often work, and `save`, `restore` and `undo` let you try a risky move without losing your progress.

By the end of the '80s, interactive fiction was replaced by point-and-click adventure games, with nicer graphics and animation, more intuitive interfaces, and sound and music.

However, the genre survived as a subculture, kept alive by enthusiasts. The parsers became more sophisticated, allowing more natural interaction, and the genre still offers gameplay mechanics that no other genre does. *Counterfeit Monkey* takes you to an island shaped by linguistics, where you manipulate words instead of objects; *Coloratura* shows our world through the eyes of an alien creature that perceives emotions and energies instead of light and objects. Best of all: these games are mostly free!

New to the genre? The [beginner's tutorial](TUTORIAL.md) walks you through a first game: the commands worth knowing, how to get unstuck, how the plugin's controls work on an e-reader, and a list of games to start with.

To get IF games, use the plugin's *Find games on IFDB…* entry, or check one of the dedicated websites: [IFDB](https://ifdb.org/search?browse) or [IFWiki](https://www.ifwiki.org/Special:Drilldown/Games).

## About Twine games

[Twine](https://twinery.org) made interactive fiction much easier to write: instead of a parser and typed commands, a story is a web of passages joined by links, and the reader simply chooses. It opened the genre to many new authors, and some of the most talked-about IF of the last fifteen years was made with it — Porpentine's *howling dogs* and *With Those We Love Alive*, Brendan Patrick Hennessy's *Birdland*, *Depression Quest*. Being easier to write, these games became an excellent medium for personal and emotional journeys and for themes that were rarely explored before: personal experience and mental health, identity, gender and social issues, literary and philosophical exploration. They are also simpler to play: you follow links instead of typing commands and guessing the right wording.

Twine stories are published as HTML pages and are normally played in a web browser. As KOReader has no built-in browser, *Frotz* uses its own interpreter running on the *QuickJS* JavaScript engine. The story works, but using pure text mode, Twine games will be very stripped down: no styling or decorative elements, no music or sound - which can be important elements for the full experience. If possible, play these games in browser, as originally intended.

*Twine support* is still experimental: around three quarters of the most-rated Twine games on IFDB play well. Stories with their own JavaScript code, complex styling or animations may show errors or get stuck.

Please check the [Twine compatibility guide](twinegames.md) to see whether a game is supported.

To get Twine games, choose *Twine* in *Find games on IFDB…*, or look for `.html` files and zips in the [IF Archive](https://ifarchive.org/indexes/if-archive/games/twine/). Games that only exist as a web page (on itch.io, for example) cannot be downloaded. *However you can download them manually using a browser: open the game, then select `Save page as...` from the menu; then copy them to the Kindle.*

## Why play interactive fiction today?

*Interactive fiction* is as relevant today as it was in the '80s, thanks to the small but enthusiastic community that keeps it alive. The genre will appeal to avid readers, offering high-quality storytelling, original approaches to gaming, personal and philosophical themes, interaction and puzzle solving. Its slow pace and text-heavy interface make it a great match for e-readers, and *Frotz*'s interface was designed specifically for these devices.

Today's IF games are for everyone: casual players and beginners, experienced players, storytelling and puzzle enthusiasts — you'll find your favorite journey!


---

Please file ideas, suggestions and bug reports as an issue.

> The plugin keeps the *Frotz* name for historical reasons; it drives
> RemGlk-linked virtual machines, not the Frotz interpreter.

## Credits

The interpreters are bundled as separate binaries, each under its own license:

- **[Bocfel](https://github.com/garglk/garglk/tree/master/terps/bocfel)** — Z-machine VM by Chris Spiegel
- **[Git](https://github.com/DavidKinder/Git)** — Glulx VM by Iain Merrick
- **[GlkTADS](https://github.com/tads-intfic/tads-runner)** — TADS 2/3 VM by Michael J. Roberts, Glk port extracted from Gargoyle (GPL-2.0)
- **[RemGlk](https://github.com/erkyrath/remglk)** — the JSON Glk I/O layer by Andrew Plotkin
- **[QuickJS](https://bellard.org/quickjs/)** — JavaScript engine by Fabrice Bellard and Charlie Gordon (MIT), which runs the Twine player

## License

This program is provided under the GNU General Public License v3.
