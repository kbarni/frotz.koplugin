# How to play interactive fiction — a beginner's guide

Interactive fiction (IF) is a story you take part in. There are two kinds, and this
plugin plays both:

- **Parser games** (Z-machine, Glulx, TADS): the game describes a place, you type
  what you want to do — `open the mailbox`, `go north`, `ask the guard about the key` —
  and it tells you what happens.
- **Choice games** (Twine): the story shows a passage of text with links in it, and
  you tap the one you want to follow. No typing, no guessing.

If you have never played either, start with a choice game to get the feel of it, then
try a parser game from the list at the end — parser games are where the genre's best
puzzles and worlds are.

---

## 1. Your first five minutes with a parser game

A game begins by describing where you are:

```
West of House
You are standing in an open field west of a white house, with a boarded
front door. There is a small mailbox here.

> examine the mailbox
The small mailbox is closed.

> open mailbox
Opening the small mailbox reveals a leaflet.

> read leaflet
"WELCOME TO ZORK! ZORK is a game of adventure, danger, and low cunning..."

> north
North of House
You are facing the north side of a white house...
```

That is the whole loop: **read, look at things, try something, read what happened.**
The game only understands short imperative sentences — think "verb + noun", not
full English. `take the brass lantern from the trophy case` works; `I wonder if I
should take that lantern` does not.

Two habits make everything easier:

1. **Examine everything the text mentions.** Nouns in the description are usually
   real objects, and the important ones reward a closer look.
2. **Type `look` whenever you lose track** of where you are. It reprints the room.

---

## 2. The commands you actually need

### Moving around

| Command | Meaning |
|---|---|
| `north`, `south`, `east`, `west` | Move. Abbreviated `n`, `s`, `e`, `w` |
| `ne`, `nw`, `se`, `sw` | Diagonals |
| `up`, `down` (`u`, `d`) | Stairs, ladders, holes |
| `in`, `out`, `enter house`, `exit` | Go into or out of something |
| `go to kitchen` | Only in some modern games, but worth trying |

### Looking at the world

| Command | Short form | Meaning |
|---|---|---|
| `look` | `l` | Describe the room again |
| `examine lamp` | `x lamp` | Look closely at one thing — **your most used command** |
| `search desk` | | Look *through* something (often finds hidden items) |
| `look under bed`, `look behind painting` | | Classic hiding places |
| `read note` | | Not always the same as `examine` |
| `inventory` | `i` | What you are carrying |

### Handling things

| Command | Meaning |
|---|---|
| `take lamp` / `drop lamp` | Pick up, put down |
| `take all` | Take everything loose in the room |
| `open door`, `close door`, `lock door with key`, `unlock chest with key` | |
| `put coin in slot`, `put book on shelf` | |
| `push button`, `pull lever`, `turn dial`, `move rug` | |
| `wear coat`, `remove coat` | |
| `turn on lamp`, `turn off lamp` | |
| `give flower to woman`, `show badge to guard` | |
| `tie rope to hook`, `fill bottle with water`, `light candle` | |
| `eat`, `drink`, `smell`, `listen`, `touch`, `taste` | The other senses are sometimes the puzzle |

### Talking to people

Conversation differs from game to game. Try these, in this order:

| Command | Meaning |
|---|---|
| `talk to sailor` | Modern games often handle the whole conversation for you |
| `topics` | In many TADS games: lists what you could bring up now |
| `ask sailor about ship` / `tell sailor about storm` | The classic system |
| `sailor, open the door` | Ordering a character around |
| `yes` / `no` | Answering a question the game asked you |

If `ask X about Y` gets a blank reply, you are usually on the wrong subject rather
than using the wrong command.

### Commands to the game itself

| Command | What it does |
|---|---|
| `save` / `restore` | Store and reload your progress (see §3 — the plugin gives you slots) |
| `undo` | Take back the last move. Use it freely — most games allow several in a row |
| `again` (`g`) | Repeat the last command |
| `oops lantern` | Fix the word you just mistyped |
| `wait` (`z`) | Let a turn pass — sometimes that *is* the solution |
| `score` / `full score` | How you are doing, and what earned points |
| `verbose` | Always print the full room description (recommended) |
| `about`, `credits` | Author's notes — often lists that game's special commands |
| `help`, `hint` | Built-in help, sometimes a full adaptive hint system |
| `think`, `remember`, `goals`, `exits`, `xyzzy` | Extras some games add; `about` will say |

---

## 4. Tips that make you better at this

- **Take everything that is not nailed down.** If you can carry it, you will need it.
- **Examine, then search, then look under.** Three different commands, three
  different results.
- **Re-read the descriptions after something changes.** A room you know can have a new
  sentence in it after you flip a switch.
- **Solve one puzzle at a time, but explore widely first.** Mapping the whole
  accessible area before working on any single obstacle usually hands you the tool
  you were missing.
- **The parser is not the puzzle.** If you are sure *what* should happen but cannot
  phrase it, try two or three wordings and then assume you are wrong about the idea,
  not the words. Good games accept the obvious phrasing.
- **`undo` is not cheating.** Try the dangerous thing, read what happens, undo.
- **Save before anything irreversible** — going through a one-way door, giving away
  an object, provoking anyone armed.
- **Watch the turn counter.** If a game counts moves, something is on a timer: a
  lamp running out, a tide coming in, a guard on patrol.
- **Read `about` first.** It takes ten seconds and often tells you the game's own
  conveniences (`topics`, `go to`, `think about`, a built-in hint menu).
- **Check the cruelty rating on IFDB** before committing to a game. On the "Zarfian"
  scale, *Merciful* games cannot be lost, while *Cruel* ones let you wander for hours
  in a state you can no longer win from. Beginners want Merciful or Polite.

### When you are stuck

Work down this list before looking anything up:

1. `inventory` — what do you have that you have not used?
2. Re-examine your objects. Many have a second detail you missed.
3. Re-visit rooms you passed through early, especially their scenery.
4. Ask yourself what the *character* wants, not what the puzzle wants.
5. Try the senses: `listen`, `smell`, `touch`.
6. Look for a locked thing and a not-yet-used thing, and pair them.
7. `think`, `hint`, `help` — use the game's own hints; they are graded for a reason.
8. Still stuck? Walkthroughs exist for nearly every game on IFDB, and transcripts of
   the "Club Floyd" group playthroughs show how other people got there.

---

## 4. Choice (Twine) games are different

There is nothing to guess: every link is a real choice, and the story moves when you
tap one. What to know:

- Links are **underlined**; tap one, or type its text or number and Send.
- **Undo** in the menu steps back one passage; save slots hold your current position.
- Some passages change **in place** — a link reveals a sentence instead of moving you
  on. That is normal; keep reading the same page.
- Some Twine stories have timed text that appears on its own. Wait a moment before
  deciding nothing happened.
- Twine games were written for a web browser. The plugin plays the text
  but drops styling, animation and sound, and some games do not work at all — check
  the [Twine compatibility list](twinegames.md) before downloading.

---

## 5. Good first games

All of these are free, and *Find games on IFDB…* in the plugin can download most of
them. The plugin chooses the right interpreter from the file itself, so you do not
need to care which format a game uses.

### Parser games, gentle

| Game | Author | Why start here |
|---|---|---|
| **The Dreamhold** | Andrew Plotkin | Written as a game *and* a tutorial: an optional voice explains what to type while you explore a wizard's fortress |
| **Lost Pig** | Admiral Jota | You are an orc who lost a pig. Short, very funny, forgiving, and it understands almost anything you try |
| **9:05** | Adam Cadre | Five minutes long, with a twist that makes you replay it immediately. A perfect first taste |
| **Photopia** | Adam Cadre | Emotional story with almost no puzzles — read it if you came for the writing rather than the locks |
| **Violet** | Jeremy Freese | One room, one goal: write your dissertation. Constant gentle hints, and impossible to get truly stuck |
| **Bronze** | Emily Short | Beauty and the Beast, afterwards. Has a tutorial mode, an `exits` listing and `go to` travel — the friendliest big map in IF |
| **Taco Fiction** | Ryan Veeder | A robbery that goes sideways. Relaxed, generous, and never punishes you |

### Parser games, once you have the hang of it

| Game | Author | Notes |
|---|---|---|
| **Counterfeit Monkey** | Emily Short | An island where you change objects by changing their letters. The flagship modern IF; big, brilliant |
| **Anchorhead** | Michael Gentry | Lovecraftian horror over three days. Large, atmospheric, unforgiving of a missed clue |
| **Coloratura** | Lynnea Glazer | Explore the world from the point of view of an alien creature, who sees and manipulates energies and emotions instead of objects |
| **Spider and Web** | Andrew Plotkin | An interrogation, told backwards. Contains the single most admired puzzle in the genre |
<!--| **Return to Ditch Day** | Michael J. Roberts | A Caltech campus full of fair, well-clued machinery |
| **The Elysium Enigma** | Eric Eve | Worth playing for its conversation system alone — try `topics` |-->
| **Zork I**, **Colossal Cave Adventure** | Infocom / Crowther & Woods | The historical roots. Wonderful to have played, but cruel: mazes, sudden deaths and a lamp that runs out. Map on paper and save often |

### Twine stories

Taken from the "Gold" entries of the [compatibility list](twinegames.md), so they
play properly in the plugin:

| Game | Author | Notes |
|---|---|---|
| **Birdland** | Brendan Patrick Hennessy | Summer camp, strange dreams, very likeable. The best entry point to Twine |
| **Bell Park, Youth Detective** | Brendan Patrick Hennessy | Short, comic, same warmth |
| **Tangaroa Deep** | Astrid Dalmady | A deep-sea dive; quiet and tense |
| **Arcane Intern (Unpaid)** | Astrid Dalmady | Office comedy with wizards |
| **Eikas** | Lauren O'Donoghue | Gentle village fantasy |
| **Depression Quest** | Quinn, Lindsey & Schankler | A serious, deliberately constrained portrait of depression |
| **howling dogs** | Porpentine | Difficult, intense, and one of the most important IF works of the last fifteen years |

---

## 6. Playing on your e-reader

Inside a game the plugin gives you:

- **The command bar** at the bottom: type, then tap **Send** (or press Enter on a
  keyboard).
- **`[Tap to continue…]`** when the story text is longer than a screen: tap anywhere
  in the text to read on.
- **"Press any key" prompts** (menus, the end of a chapter): tap the story area to
  send a space, or type a single letter in the command bar and hit **Send** when the
  game asks for a specific key.
- **Hold a word** in the story to look it up in your dictionaries or Wikipedia, as
  anywhere else in KOReader.
- **The menu** (☰, top left):
  - *Scroll to bottom* — back to the newest text
  - *Show / Hide on-screen keyboard* — hide it when you use an external keyboard
  - *Undo* — same as typing `undo`
  - *Save game* / *Restore game* — five slots plus an autosave, per game
  - *Illustrations* — the pictures shown so far, and whether to show all, only the
    notable ones, or none
  - *Font size*
  - *Close game*
- **Autosave**: closing the game saves it, and opening it again offers *Resume*.
  Save and restore only work when the game is at its normal command prompt — not in
  the middle of a menu or a "press any key" pause.

A paper map is still the best accessory for a big parser game. Draw rooms as boxes
and exits as lines; you will be glad of it by the second evening.

---

## 7. Where to look next

- **[IFDB](https://ifdb.org)** — the database: ratings, reviews, cruelty ratings,
  download links, and themed lists. Reachable from the plugin's *Find games on IFDB…*
- **[IF Archive](https://ifarchive.org)** — where the files themselves live
- **[IFComp](https://ifcomp.org)** and **Spring Thing** — yearly competitions; every
  entry is free and most are short
- **[intfiction.org](https://intfiction.org)** — the community forum, including help
  threads for specific games
- **[IFWiki](https://www.ifwiki.org)** — history, authors, formats

Have fun, and remember: `x me` is always a good first command.
