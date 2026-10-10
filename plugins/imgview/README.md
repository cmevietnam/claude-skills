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

This plugin is a _mod_: a hooks module the engine loads (`hooks/hooks.json` names
`register.tsx`), not a skill. It puts no skill text and no tool in the model's context.
The slash command is the person's; its one-line answer (`login.png · 1280×720 · cells`)
is recorded in the transcript as any command's output is.

## The hover card

The chip is the hover target, not the path inside Claude's sentence: the reply's own
text is drawn by the engine, and a mod can add rows around it but cannot attach a hover
to a word in it (`ui.render` on `AssistantMessage` wraps what `next(e)` drew).

- A reply gets a chip for each of its first four image files (`MAX_CHIPS`): paths
  written bare, in backticks, in a markdown link or as `file://`, ending in `.png`,
  `.jpg`, `.jpeg`, `.gif`, `.webp`, `.heic`, `.bmp`, `.tif` or `.tiff`. A web address
  gets none: nothing here fetches. A path with a space in it is not recognised.
- The card holds at most 80 by 24 cells (`CARD_COLUMNS`, `CARD_ROWS`), fewer columns on
  a terminal narrower than 92. In `cells` mode that is a 160 by 48 pixel thumbnail.
- The terminal applies a hover by itself and runs no hook for it, so the card cannot be
  made on demand: its picture is converted when the reply comes on screen.
- The cells of 32 cards are kept (`MAX_THUMBS`). A card drawn in the last five seconds
  is on screen and is not dropped for another, so with more than 32 pictures on screen
  the extra mentions get no chip until one of the others scrolls away.
- Chips are drawn in the fullscreen layout only (`"tui": "fullscreen"`), on a terminal
  surface. A card that would rise past the top of the viewport is clipped there.

### What a reply can make the mod open

A reply is the model's text, and a chip is drawn with no action of yours, so a hostile
repository or an injected reply can name any path it likes. What that reaches is held
to less than what `/img` takes (`locateMention` and `sketch` in `hooks/register.tsx`):

| A mention gets a chip only when                                   | Enforced by                                                    |
| ----------------------------------------------------------------- | -------------------------------------------------------------- |
| it lands inside the session's working directory, links followed   | `isInside(found.realPath, host.root)`, both resolved by `stat` |
| the file is at most 20 MiB                                        | `PREVIEW_MAX_BYTES`, checked before any converter runs         |
| `sips` names its real format a bitmap's, whatever the suffix says | `isBitmapFormat(size.format)`: no SVG, no PDF                  |
| the picture is at most 100 megapixels                             | `PREVIEW_MAX_PIXELS`, checked before the conversion            |

Each `sips` run for a chip is killed after five seconds (`PREVIEW_TIMEOUT_MS`), and
ImageMagick is never run for one. So where `sips` is missing (Linux) there are no hover
cards, only `/img`.

This stops protecting at two edges. `sips` still parses the header of any file in the
working directory with a bitmap's suffix to learn its format, and decodes those that
pass: a hostile bitmap inside the repository you opened is decoded by ImageIO without a
click. And `/img <path>` has none of these limits: a path you type is opened wherever it
is, SVG and PDF included, with ImageMagick as the fallback.

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

Each `/img`, and each chip, runs the converter once to measure the picture and, in
`cells` mode, once per size to resize it to exactly the cells on screen. The resized file goes to
`$TMPDIR/claude-imgview-*.bmp` and is removed once read. In `pixels` mode a PNG is handed
to the terminal by its own path; any other format is first converted to
`$TMPDIR/claude-imgview-*.png`, which is removed when the next `/img` replaces it; the
last one of a session stays until the system clears `$TMPDIR`.

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
`tests/register.test.ts` drives `/img` and the pane against a faked file system and a
faked `sips`: it asserts the exact command lines, not that a real picture reached a real
screen.
