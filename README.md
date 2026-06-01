# *Frotz* interactive fiction plugin for Koreader

This plugin allows to play interactive fiction games in Koreader.

![Screenshot](screenshot_frotz.png)

It uses the Frotz interpreter to parse *Z-machine* file format (this is by far the most used format for interactive fiction): .z3, .z4, .z5, .z6, .z8, .zblorb, .zlb

To install, copy the contents of the release to the `koreader/plugins` folder.

To run, click on *Interactive fiction* in the *Tools* menu.

**Important**: This plugin needs the `dfrotz` binary compatible with your system. The provided binary will run on most recent `arm` (`hf`) systems.

You might need to change it with one of the binaries below:

| File | Architecture | Devices |
|------|--------------|---------|
| [Download]() | ARM-HF | Most e-readers |
| [Download]() | ARM-EL | Older Kindles - firmware < 5.16.2 |
| [Download]() | X86 (64 bit) | Desktop computers (Linux) |


**This is a work in progress.** Please file your ideas, suggestions bug reports as an issue.