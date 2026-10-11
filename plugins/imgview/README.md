# imgview

Preview images without leaving Claude Code, two ways:

- **Hover.** Under any reply of Claude's that names an image file in the working
  directory, the mod draws a chip per file (`▣ login.png`). Rest the pointer on a chip and a card with the
  picture pops up over the rows above it; move away and it is gone. A click on the chip
  opens the picture in the pane.
- **`/img <path>`** opens a picture in a pane of the session: docked beside the
  transcript in the fullscreen layout from 110 columns, inline above the prompt otherwise.

## Install

```
/plugin install imgview --marketplace cmevietnam/claude-skills
```

The mod is a hooks module alone, so it is active in the session that installed it with no
reload, and at user scope in every session started after.

## Use

```
/img shots/login.png            # relative to the session's working directory
/img ~/Desktop/Screenshot.png   # ~ expands
/img /tmp/my\ shot.png          # a path dragged into the terminal works as dropped
/img --cells                    # the picture already shown, drawn the other way
```

Escape at an idle, empty prompt closes the pane (`closeOnEscape` in
`hooks/register.tsx`); so does the pane's own close mark.

Docked, the pane asks for 45 in a hundred of the width it is opened from, between 40
and 100 columns, and keeps asking for that same width for as long as it is up
(`dockColumns`): a docked pane narrows the conversation, so a share taken anew at every
click would give every picture another width. A width you drag the dock to wins.

This plugin is a _mod_: a hooks module the engine loads (`hooks/hooks.json` names
`register.tsx`), not a skill. It puts no skill text and no tool in the model's context.
The slash command is the person's; its one-line answer (`login.png · 1280×720 · cells`)
is recorded in the transcript as any command's output is.

## The hover card

The chip is the hover target, not the path inside Claude's sentence: the reply's own
text is drawn by the engine, and a mod can add rows around it but cannot attach a hover
to a word in it (`ui.render` on `AssistantMessage` wraps what `next(e)` drew).

- A reply gets a chip for each of its first four image files (`MAX_CHIPS`): paths
  written bare, in a code span, in a markdown link or as `file://`, ending in `.png`,
  `.jpg`, `.jpeg`, `.gif`, `.webp`, `.heic`, `.bmp`, `.tif` or `.tiff`. A code span is
  taken as written; in prose the parentheses around a path are the sentence's. A web
  address gets none: nothing here fetches. A path with a space in it is not recognised.
- The card holds at most 80 by 24 cells (`CARD_COLUMNS`, `CARD_ROWS`), fewer columns on
  a terminal narrower than 92. In `cells` mode that is a 160 by 48 pixel thumbnail.
- The terminal applies a hover by itself and runs no hook for it, so the card cannot be
  made on demand: its picture is converted when the reply comes on screen.
- 32 cards are kept, drawn or waiting their turn (`MAX_THUMBS`). A card that a reply on
  screen draws is in use: a drawn one is not dropped for another, so with more than 32
  pictures on screen the extra mentions get no chip until one of the others scrolls
  away. A file no preview could draw is remembered apart and holds no card's place.
- What is on screen is what the engine says is. It draws a reply again when the reply
  comes on screen and when it leaves (`e.props.onScreen`), and not in between, so the
  mod keeps the replies now on screen with the cards each one draws (`onScreen` in
  `hooks/register.tsx`) and reads no clock: a reply that sits still keeps its cards
  however long a conversion takes. A reply stops holding its cards when it is drawn
  again off screen, with no image file named, or outside the fullscreen layout
  (`leave`). When two drawings of one reply overlap, the one begun last asks for the
  cards and decides which the reply holds; the other asks for none (`isHolding`).
- A card is drawn only by a drawing that holds it. A reply drawn off screen shows its
  chips with no card behind them, and gets its cards when it comes back.
- That record has three limits, because the engine names a reply and reports when it
  scrolls away, and nothing else:
  - A reply taken out of the transcript with no last drawing (a rewind, a compaction)
    goes on holding its cards until the session ends (a `/clear` is one), or until 64
    other replies that name image files have been drawn on screen after it
    (`MAX_ON_SCREEN`). While 32 cards are held that way, new mentions get no chip.
  - With more than 64 replies that name image files on screen at once, the one drawn
    longest ago stops holding its cards though it is still there.
  - Two terminals attached to one session are one record: a reply one of them reports
    as gone stops holding its cards while the other may still show it.
- Cards are converted one after another, the one asked for last first. One whose reply
  leaves the screen before its turn is given up, so what is on screen now does not wait
  behind what was (`pruneQueue` and `drain`).
- Where the terminal does not say what is on screen (`onScreen` absent), the chips are
  drawn and no card is made or drawn for them; a click still opens the pane.
- Chips are drawn in the fullscreen layout only (`"tui": "fullscreen"`), on a terminal
  surface. A card that would rise past the top of the viewport is clipped there.

### What a reply can make the mod open

A reply is the model's text, and a chip is drawn with no action of yours, so a hostile
repository or an injected reply can name any path it likes. What that reaches is held
to less than what `/img` takes (`locateMention`, `preview` and `sketch` in
`hooks/register.tsx`):

| A mention gets a chip only when                                 | Enforced by                                                                     |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| it lands inside the session's working directory, links followed | `isInside(found.realPath, host.root)`; `host.root` follows `classic.CwdChanged` |
| the file is at most 20 MiB                                      | `PREVIEW_MAX_BYTES`, on the file before anything runs and again on the copy     |
| `sips` names the copy's real format a bitmap's                  | `isBitmapFormat(size.format)`: no SVG, no PDF, whatever the name says           |
| the picture is at most 40 megapixels                            | `PREVIEW_MAX_PIXELS`, checked before the conversion                             |

How the conversion itself is held:

- `sips` never opens the path the reply named. `preview` copies the file to a name under
  `$TMPDIR` that nobody can guess (`crypto.randomUUID()`). The copy is made by `/bin/sh`
  with noclobber set (`SNAPSHOT`: `set -C; { cat -- "$1" || exit 4; } >"$2" || exit 3`),
  which opens a free name with `O_EXCL` and refuses a file that is there: no copy is
  made over a file, or through a link to a file or to nothing. Exit 3 says the shell did
  not open the name (it is taken, or `$TMPDIR` has no room or is gone), and then the mod
  reads nothing there and removes nothing. After any other exit it looks at what is at
  the name, and takes only a regular file as its copy (`copied?.kind !== "file"`):
  that is written down, checked, and removed when the preview is done. The mod then
  looks at the original again, and measures and converts the copy alone.
- One preview is converted at a time (`drain` takes one job from `queue` and returns at
  once while another call is running): 32 mentions mean 32 conversions in a row, never
  32 decoders at once.
- Each shell and `sips` run for a chip is killed after five seconds
  (`PREVIEW_TIMEOUT_MS`), and ImageMagick is never run for one. So where `sips` is
  missing (Linux) there are no hover cards, only `/img`.
- A preview still unfinished after 30 seconds (`PREVIEW_DEADLINE_MS`) is given up, so
  the cards behind it are drawn. Its commands cannot take that long at five seconds
  each; a file system call that never answers can. The preview given up starts no
  further command when that call does answer, and a command of its that is running
  at the 30 seconds ends, at its own timeout, before the next card is begun
  (`previewInTime`). The files it had written down are removed then; one it comes upon
  later is removed as it is found.
- With eight previews given up and still unanswered (`MAX_ABANDONED`), no new card is
  begun, and a mention that has no card yet gets no chip, until one of them answers: a
  mount that has stopped answering costs eight waiting previews, not one for every
  mention.
- On a terminal that draws pixels the card shows a small PNG the mod converted from the
  copy, never the file the reply named.
- When the working directory changes, every card, lookup and waiting conversion made
  under the old one is dropped and the chips on screen are redrawn without them, before
  anything else happens. Nothing is previewed until the new directory is resolved.

This stops protecting at three edges:

1. `sips` still decodes, with no click, any bitmap in the working directory that passes
   the table. A hostile bitmap inside the repository you opened reaches ImageIO.
2. The engine gives a mod paths, not file handles, so nothing here can hold a file still
   between two steps. A process already running as you can swap the file for a link, a
   pipe or a larger file after the mod has looked at it and before the shell opens it.
   The mod looks again after the copy and gives up if the path then lands elsewhere, is
   no regular file, or has another modification time; a swap undone in time, with the
   same modification time, gets the other file copied, decoded and shown, within the
   size, format and megapixel limits above. A pipe holds the copy for the five seconds
   it is allowed; a huge file is copied for as long before the size check drops it.

   The same process can act on the mod's temporary names too. They are not guessable,
   but they can be read from the process list while the shell and `sips` run:
   - It can replace the copy once it is made, and that file is then what is decoded.
   - Only the copy is created exclusively. `sips` writes its BMP or PNG to a fresh
     random name with no such guarantee, so a link put at that name in time is written
     through. And bash's noclobber opens a pipe or a device that sits at the copy's
     name instead of refusing it: the file's bytes are written into it, for the five
     seconds the shell is allowed at most. The mod then finds no regular file there,
     reads nothing from it, and leaves it: not removed, not written down.
   - The mod removes its files by name (`rm -f`), so whatever that process has put at
     one of those names by then is what is removed.

   A process that can do any of this runs as you, and could write or remove those files
   itself.

3. `/img <path>` has none of these limits: a path you type is opened wherever it is,
   SVG and PDF included, with ImageMagick as the fallback. So is a chip you click: the
   pane then takes the file itself, measured again as it is at the click.

## How it draws

Claude Code owns the terminal while a session runs, and the Bash tool has no terminal at
all (`tty` prints `not a tty` there), so `imgcat`, `chafa` and the like cannot draw from
inside a session. The pane goes through the engine's own two picture elements instead:

| Mode     | When                                                 | What you get                                                                                                                                                                                       |
| -------- | ---------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pixels` | kitty or Ghostty, as the environment names them      | The engine's `Image` element: the terminal reads the PNG itself and draws real pixels (the kitty graphics protocol).                                                                               |
| `cells`  | every other terminal (iTerm2, Terminal.app, VS Code) | The engine's `Raster` element: two by two pixels a cell, drawn as the block character (`▀ ▌ ▞ ▙` and the like) whose quarters split the four pixels best into a foreground and a background color. |

Under tmux and across ssh the mode is `cells` even on kitty: tmux passes no pictures
through, and the terminal reads the PNG from its own machine's disk, not the remote one.
In `pixels` mode only a file `sips` names a PNG is handed to the terminal as it is. `--cells`
and `--pixels` override the choice; a terminal that cannot draw an `Image` shows its
caption and a hint to use `--cells`.

`cells` is a preview, not a viewer: a pane 80 columns wide shows a 160-pixel-wide
picture. It is enough to tell which screenshot this is, whether a chart rendered, or
whether a layout is broken; it is not enough to read small text.

## Requires

One converter on `PATH`. For `/img` the mod tries them in this order; a hover card uses
the first alone:

1. `sips`, which macOS ships. Checked on macOS 14.5: PNG, JPEG, HEIC, GIF, WebP, SVG
   and PDF (first page); `sips --formats` lists the rest.
2. `magick` (ImageMagick 7), for whatever sips cannot read, and on Linux.

Each `/img` runs the converter once to measure the picture and, in `cells` mode, once
per pane size to resize it to exactly the cells on screen: one size at a time, and of
the sizes a resize passes through meanwhile only the last (`paint`). The resized file
goes to `$TMPDIR/claude-imgview-*.bmp` and is removed once read. In `pixels` mode a
file `sips` names a PNG is handed to the terminal by its own path; any other is first
converted to `$TMPDIR/claude-imgview-*.png`, which is removed when another picture
replaces it in the pane. A chip's copy (`*.snap`) is removed as soon as its card is drawn, and a card's PNG
when the card is dropped.

Every temporary file the mod makes is written down by its path until it is removed
(`owned` in `hooks/register.tsx`), and that list is copied into the session's state
(`imgview.temps`) a moment later, from a timer: the engine refuses a state write while a
reply is being drawn, which is when most of these files are made. A name is written down
only once the mod has found a file there, so a name that turned out to be taken never
is. A path is struck off once `rm` has exited 0 for it, not when `rm` is started
(`remove`). When the session ends (`session.end`, in the short time the engine allows
it), and when the module is loaded again in a running session, the files written down
are removed by those exact paths (`sweep`), not by a name pattern. This is what can
still be left behind:

- The PNG the pane is showing, on purpose: a pane that outlives a `/clear` still needs
  it. It goes when another picture replaces it, or when the system clears `$TMPDIR`.
- A file made in the last tenth of a second before the module was reloaded
  (`RECORD_DELAY_MS`), and the output of a conversion the reload cut short.
- A file the mod never found: the copy, or a converter's output, when the look that
  follows its writing never answers. Eight previews at most wait that way at a time.
- A file `rm` could not remove, or one the sweep at `session.end` did not reach in the
  time the engine allows. It stays written down and is removed when the module is next
  loaded in that session; when the session is over by then, it is left.
- Everything, when the process is killed with no `session.end`.

## Limits

- A cell holds four pixels but two colors: where three or four colors meet in one
  cell, two of them are averaged away.
- A `Raster` paints 1024 distinct foreground/background pairs at once. A picture that
  needs more is drawn from a smaller palette, a median cut of its own colors as large
  as still fits (`reducePairs` in `hooks/picture.ts`). A screenshot or a diagram
  usually keeps every color; a photo in a large pane keeps a few hundred.
- A cell is taken as twice as tall as it is wide. A font with other proportions
  stretches the picture slightly.
- EXIF orientation is not applied: a phone photo stored rotated is shown rotated.
- An animated GIF shows its first frame.
- The picture draws in a terminal only. On the desktop app, VS Code and mobile the pane
  says so.

## Develop

```bash
claude --plugin-dir ./plugins/imgview     # load it; edits hot-reload
claude plugin validate ./plugins/imgview  # what the engine will accept
claude plugin test ./plugins/imgview      # tests/*.test.ts, run by the engine's own host
```

The engine writes its type declarations to `.claude-plugin/types/` whenever it loads the
mod from this folder; that directory is ignored by git.

`tests/picture.test.ts` decodes BMP files that the real `sips` and `magick` wrote (kept
as base64 in the test), so a change in either converter's output format shows up there.
`tests/register.test.ts` drives `/img`, the pane and the chips against a faked file
system, a faked shell and a faked `sips`: it asserts the exact command lines, not that a
real picture reached a real screen. The `SNAPSHOT` line itself was run by hand against
the `/bin/sh` of macOS 14.5 (bash 3.2): it copies to a free name and exits 3, writing
nothing, on a file, a link to a file, a dangling link, a directory and a name under a
directory that does not exist. On a device at the name (`/dev/null`) it exits 0, which
is why the mod looks at what is there before calling it a copy.
