import { atom, read, update } from "claude-code";
import type { Register } from "claude-code";

import type { Shown } from "../types";
import {
  baseName,
  decodeBmp,
  expandHome,
  findImagePaths,
  fit,
  fromBase64,
  isBitmapFormat,
  isInside,
  parseArgs,
  parseIdentifySize,
  parseSipsSize,
  toCells,
} from "./picture";
import type { Measured, Mode, Size } from "./picture";

const PANE = "imgview";
const KEY = "picture";
// An Image is at most 255 cells a side; a Raster is held to the same here.
const MAX_CELLS = 255;
const USAGE = "Usage: /img [--cells|--pixels] <image path>";
const TEMP_PREFIX = "claude-imgview-";
// A reply draws a chip for its first few image files; each chip's hover card
// holds a picture of at most this many cells.
const MAX_CHIPS = 4;
const CARD_COLUMNS = 80;
const CARD_ROWS = 24;
// The pixels a card's PNG is given a cell, where the terminal draws pixels.
const CARD_CELL_PIXELS = { width: 10, height: 20 };
// A reply is drawn again for every piece that streams in: a path is looked up
// once in this long, and this many lookups are remembered.
const LOCATE_TTL_MS = 2000;
const MAX_LOCATED = 128;
// This many cards are kept, drawn or waiting to be. One a reply on screen
// draws is in use: a drawn one is not dropped for another, and a waiting one
// keeps its turn. Past the limit a new card waits with no chip. A picture
// that could not be drawn is remembered apart.
const MAX_THUMBS = 32;
const MAX_FAILED = 128;
// The replies remembered as on screen. The engine says when one scrolls off
// it, and nothing of one taken out of the transcript: such a reply holds its
// cards until this many others have been drawn after it.
const MAX_ON_SCREEN = 64;
// What a reply names is converted with no action of the person's, so it is
// held to less than what `/img` takes: a file this small, a picture of this
// many pixels, `sips` alone, this long, and one conversion at a time.
const PREVIEW_MAX_BYTES = 20 * 1024 * 1024;
const PREVIEW_MAX_PIXELS = 40_000_000;
const PREVIEW_TIMEOUT_MS = 5000;
// More than a preview's commands take at their timeouts, one after another:
// only a file system call that never answers lasts this long, and then the
// card is given up so that the ones behind it are drawn.
const PREVIEW_DEADLINE_MS = 30_000;
// A preview given up may never answer at all. With this many unanswered no
// new card is begun, so they and what they left behind cannot pile up.
const MAX_ABANDONED = 8;
// Copies $1 to $2 under the shell's noclobber, which refuses a file that is
// there and opens with O_EXCL where none is: no copy is made over a file, or
// through a link to one or to nothing. Exit 3 says the shell did not open the
// name (it is taken, or there is no room or no directory for it), and then
// nothing was written. A pipe or a device that sits at the name is opened as
// it is, so what is there afterwards is looked at before it is called a copy.
const SNAPSHOT = 'set -C; { cat -- "$1" || exit 4; } >"$2" || exit 3';
const SNAPSHOT_NOT_OPENED = 3;

const shown = atom({ plugin: "imgview", key: "shown" } as const, null);
// Every temporary file the mod has made and not yet removed, by its path:
// kept with the session, so a module loaded again knows what the last left.
const temps = atom({ plugin: "imgview", key: "temps" } as const, []);
// How far behind the files that record is written: a drawing may write no
// state, so the record is never written from where a file is made.
const RECORD_DELAY_MS = 100;

type Cells = { columns: number; rows: number; cells: string };

/** The cells last painted for one picture at one size, or why they were not. */
type Frame = {
  id: string;
  columns: number;
  rows: number;
  cells?: string;
  error?: string;
};

/** A file a path leads to: where it landed and when it last changed. */
type Located = { path: string; mtimeMs: number };

/**
 * A hover card's picture, measured and converted: cells, or on a terminal
 * that draws pixels a small PNG of the mod's own for it to read.
 */
type Card = Measured & {
  columns: number;
  rows: number;
  cells?: string;
  png?: string;
};

/**
 * A card's place among those kept: no `card` yet while it waits its turn.
 * `askedAt` orders the cards by when a reply on screen last asked for each:
 * a count, not a time, so no two are equal.
 */
type Slot = { card?: Card; askedAt: number };

/**
 * A reply on screen: the cards its last finished drawing asked for, and the
 * ones the drawing of it begun last, if still at work, has asked for so far.
 */
type Reply = { cards: Set<string>; drawing?: Set<string> };

/** What the pane's drawing asks to be converted: a picture at a size. */
type Wanted = {
  id: string;
  picture: Shown;
  box: { columns: number; rows: number };
};

/** A card waiting to be converted, under the working directory it was asked in. */
type Job = {
  id: string;
  file: Located;
  maxColumns: number;
  slot: Slot;
  boundary: number;
};

/** How a conversion is held back: `/img` passes none of these. */
type Limits = {
  /** No ImageMagick where `sips` cannot. */
  isSipsOnly?: boolean;
  timeoutMs?: number;
};

const PREVIEW: Limits = { isSipsOnly: true, timeoutMs: PREVIEW_TIMEOUT_MS };

/**
 * What the converters need of the engine, bound once at `session.start`: a
 * conversion outlives the drawing that asked for it.
 */
type Host = {
  /** Runs a host command; undefined when it is not installed or timed out. */
  run: (
    argv: readonly string[],
    timeoutMs?: number,
  ) => Promise<{ exitCode: number; stdout: string } | undefined>;
  exists: (path: string) => Promise<boolean>;
  /** What a path leads to, with where it lands; undefined when missing. */
  stat: (path: string) => Promise<
    | {
        kind: string;
        size: number;
        mtimeMs: number;
        realPath?: string;
      }
    | undefined
  >;
  /** A file's bytes, base64. */
  readBytes: (path: string) => Promise<string>;
  /** A fresh path under the temporary directory, its name not guessable. */
  tempPath: (suffix: "bmp" | "png" | "snap") => string;
  /** Writes a path down as a file the mod made, its own to remove. */
  keep: (path: string) => void;
  /** Removes a file the mod made, and strikes its path off. */
  remove: (path: string) => void;
  /**
   * Removes every file written down but the PNG the pane shows: what a
   * module loaded before, or a session that ended, left behind.
   */
  sweep: () => Promise<void>;
  redraw: () => void;
  /** Calls `fn` once after `ms` milliseconds on the engine's clock. */
  after: (ms: number, fn: () => void) => { cancel: () => void };
  home: string | undefined;
  /**
   * Where the session's working directory lands, kept up as it changes;
   * undefined when unknown, and then no reply's mention is previewed.
   */
  root: string | undefined;
  /**
   * kitty and Ghostty draw an Image as pixels, from a file they read
   * themselves: not through tmux, and not across ssh.
   */
  isPixelTerminal: boolean;
};

async function measure(
  host: Host,
  path: string,
  limits: Limits = {},
): Promise<Measured | undefined> {
  const sips = await host.run(
    ["sips", "-g", "format", "-g", "pixelWidth", "-g", "pixelHeight", path],
    limits.timeoutMs,
  );
  const size = sips ? parseSipsSize(sips.stdout) : undefined;
  if (size !== undefined || limits.isSipsOnly) return size;
  const magick = await host.run(
    ["magick", "identify", "-format", "%w %h %m", `${path}[0]`],
    limits.timeoutMs,
  );

  return magick?.exitCode === 0 ? parseIdentifySize(magick.stdout) : undefined;
}

/**
 * Writes the picture to `out` as its suffix says (BMP or PNG), stretched to
 * `size` when given: `sips` first, ImageMagick where sips cannot.
 */
async function convert(
  host: Host,
  path: string,
  out: string,
  size?: Size,
  limits: Limits = {},
): Promise<boolean> {
  const format = out.endsWith(".png") ? "png" : "bmp";
  const resample = size ? ["-z", String(size.height), String(size.width)] : [];
  // sips exits 0 on a file it cannot read: the written file is the proof.
  await host.run(
    ["sips", "-s", "format", format, ...resample, path, "--out", out],
    limits.timeoutMs,
  );
  const isWritten = await host.exists(out);
  if (isWritten || limits.isSipsOnly) return isWritten;
  const resize = size ? ["-resize", `${size.width}x${size.height}!`] : [];
  await host.run(["magick", `${path}[0]`, ...resize, out], limits.timeoutMs);

  return host.exists(out);
}

/**
 * The picture as `box` cells of quarter blocks, two pixels a cell each way;
 * throws when nothing converts it.
 */
async function rasterize(
  host: Host,
  path: string,
  box: { columns: number; rows: number },
  limits: Limits = {},
): Promise<Cells> {
  const out = host.tempPath("bmp");
  const size = { width: box.columns * 2, height: box.rows * 2 };
  if (!(await convert(host, path, out, size, limits))) {
    throw new Error(
      limits.isSipsOnly
        ? "sips could not convert it"
        : "neither sips nor ImageMagick could convert it",
    );
  }
  host.keep(out);
  let base64: string;
  try {
    base64 = await host.readBytes(out);
  } finally {
    host.remove(out);
  }
  const bitmap = decodeBmp(fromBase64(base64));
  if (bitmap.width !== size.width || bitmap.height !== size.height) {
    throw new Error(
      `the converter wrote ${bitmap.width}x${bitmap.height}, not ${size.width}x${size.height}`,
    );
  }

  return toCells(bitmap);
}

/**
 * The file a reply's mention leads to, a `~` expanded: a regular file that
 * lands inside the session's working directory, every link followed, and is
 * no larger than a preview takes. Undefined for anything else.
 */
async function locateMention(
  host: Host,
  given: string,
): Promise<Located | undefined> {
  if (host.root === undefined) return undefined;
  const found = await host.stat(expandHome(given, host.home));
  if (found?.kind !== "file" || found.realPath === undefined) return undefined;
  if (!isInside(found.realPath, host.root)) return undefined;
  if (found.size > PREVIEW_MAX_BYTES) return undefined;

  return { path: found.realPath, mtimeMs: found.mtimeMs };
}

/**
 * The card of a file a reply named, or undefined when it is not a picture a
 * preview takes. Everything is decoded from a copy of the file made first:
 * the copy is the mod's own, so what was checked is what `sips` reads.
 */
async function preview(
  host: Host,
  file: Located,
  maxColumns: number,
): Promise<Card | undefined> {
  const copy = host.tempPath("snap");
  let isCopyMine = false;
  try {
    const copying = await host.run(
      ["/bin/sh", "-c", SNAPSHOT, "sh", file.path, copy],
      PREVIEW_TIMEOUT_MS,
    );
    // The name was not opened: what is there is not the mod's to read or
    // remove.
    if (copying?.exitCode === SNAPSHOT_NOT_OPENED) return undefined;
    // A regular file there is the one the shell made: whole, in part, or cut
    // short at the timeout. Anything else sat there before, and is left.
    const copied = await host.stat(copy);
    if (copied?.kind !== "file") return undefined;
    isCopyMine = true;
    host.keep(copy);
    if (copying?.exitCode !== 0 || copied.size > PREVIEW_MAX_BYTES)
      return undefined;
    // Swapped for another file, a link or a pipe while it was copied: not
    // this one.
    const still = await host.stat(file.path);
    if (
      still?.kind !== "file" ||
      still.realPath !== file.path ||
      still.mtimeMs !== file.mtimeMs
    )
      return undefined;

    const size = await measure(host, copy, PREVIEW);
    if (
      size === undefined ||
      !isBitmapFormat(size.format) ||
      size.width * size.height > PREVIEW_MAX_PIXELS
    )
      return undefined;
    const box = fit(size, maxColumns, CARD_ROWS);
    if (host.isPixelTerminal) {
      // A small PNG of the mod's own for the terminal to read, whatever the
      // file's format: never the file the reply named.
      const png = host.tempPath("png");
      const pixels = {
        width: box.columns * CARD_CELL_PIXELS.width,
        height: box.rows * CARD_CELL_PIXELS.height,
      };
      if (await convert(host, copy, png, pixels, PREVIEW)) {
        host.keep(png);

        return { ...size, ...box, png };
      }
    }

    return { ...size, ...(await rasterize(host, copy, box, PREVIEW)) };
  } finally {
    if (isCopyMine) host.remove(copy);
  }
}

/**
 * Whether the terminal can read this picture itself: a PNG by its content,
 * as the converter named it, at an absolute path.
 */
function isReadablePng(path: string, format: string | undefined): boolean {
  return path.startsWith("/") && format === "png";
}

/**
 * The picture the pane will show in place of `previous`, or undefined when
 * `pixels` mode needs a PNG and nothing converts the file to one. The PNG the
 * mod converted for `previous` goes: it is the mod's to remove, where a PNG
 * the pane was shown as it is never is.
 */
async function present(
  host: Host,
  previous: Shown | null,
  file: Located,
  size: Measured,
  mode: Mode,
): Promise<Shown | undefined> {
  const picture: Shown = {
    path: file.path,
    name: baseName(file.path),
    width: size.width,
    height: size.height,
    mtimeMs: file.mtimeMs,
    mode,
  };
  if (mode === "pixels") {
    // The terminal reads a PNG by its absolute path; anything else is converted.
    if (isReadablePng(file.path, size.format)) {
      picture.png = file.path;
    } else {
      const out = host.tempPath("png");
      if (!(await convert(host, file.path, out))) return undefined;
      host.keep(out);
      picture.png = out;
      picture.isPngTemporary = true;
    }
  }
  if (
    previous?.png !== undefined &&
    previous.isPngTemporary === true &&
    previous.png !== picture.png
  ) {
    host.remove(previous.png);
  }

  return picture;
}

/**
 * What the pane asks of the layout for a picture: inline, the rows the picture
 * fills under the full width; docked, a share of the columns.
 */
function paneRequest(picture: Shown, columns: number) {
  const inline = fit(
    picture,
    Math.min(Math.max(1, columns - 4), MAX_CELLS),
    24,
  );

  return {
    id: PANE,
    title: picture.name,
    closeOnEscape: true as const,
    rows: inline.rows + 1,
    columns: Math.max(40, Math.min(100, Math.round(columns * 0.45))),
  };
}

export const register: Register = (on) => {
  let host: Host | undefined;
  let frame: Frame | undefined;
  // Whether the pane has a conversion in flight, and what its last drawing
  // asked for.
  let isPainting = false;
  let wanted: Wanted | undefined;
  // The temporary files the mod has made and not removed: what the session's
  // record is written from.
  const owned = new Set<string>();
  const thumbs = new Map<string, Slot>();
  // Counts up each time a reply on screen asks for a card.
  let asked = 0;
  // The replies on screen by the engine's id for each, the one drawn longest
  // ago first. The engine draws a reply again as it comes on screen and as it
  // leaves, and not in between: a reply is on screen until it is said to go.
  const onScreen = new Map<string, Reply>();
  // The previews given up that have not answered since.
  let abandoned = 0;
  // Pictures no preview could draw, oldest first: they hold no card's place.
  const failed = new Set<string>();
  const located = new Map<string, { at: number; file: Located | undefined }>();
  // Cards waiting to be converted: one at a time, never side by side.
  const queue: Job[] = [];
  let isPreviewing = false;
  // Moves on when the working directory does: what was started before is void.
  let boundary = 0;
  // The pane's picture is replaced by one caller at a time, so each one sees
  // the picture it really replaces.
  let replacing: Promise<unknown> = Promise.resolve();

  function oneAtATime<T>(work: () => Promise<T>): Promise<T> {
    const done = replacing.then(work, work);
    replacing = done.catch(() => undefined);

    return done;
  }

  /**
   * Converts what the pane wants to cells and asks for the redraw: one
   * conversion at a time. Where the pane has moved on to another size or
   * picture meanwhile, the one it wants by then is next, and none between.
   */
  async function paint(io: Host) {
    if (isPainting) return;
    isPainting = true;
    try {
      for (;;) {
        const job = wanted;
        if (job === undefined || frame?.id === job.id) return;
        let painted: Frame = { id: job.id, ...job.box };
        try {
          painted = {
            id: job.id,
            ...(await rasterize(io, job.picture.path, job.box)),
          };
        } catch (error) {
          painted.error =
            error instanceof Error ? error.message : String(error);
        }
        if (wanted?.id !== job.id) continue;
        frame = painted;
        io.redraw();

        return;
      }
    } finally {
      isPainting = false;
    }
  }

  /** Forgets a card, and removes the PNG the mod made for it. */
  function dropThumb(io: Host, id: string) {
    const png = thumbs.get(id)?.card?.png;
    thumbs.delete(id);
    if (png !== undefined) io.remove(png);
  }

  /** Forgets every card and every reply, with no file removed. */
  function forgetCards() {
    thumbs.clear();
    queue.length = 0;
    onScreen.clear();
  }

  /** Notes a reply as on screen, the one drawn last of them. */
  function enter(requestId: string): Reply {
    const reply = onScreen.get(requestId) ?? { cards: new Set() };
    onScreen.delete(requestId);
    onScreen.set(requestId, reply);
    for (const stale of onScreen.keys()) {
      if (onScreen.size <= MAX_ON_SCREEN) break;
      onScreen.delete(stale);
    }

    return reply;
  }

  /** Notes a reply as on screen no longer: its cards are in use no more. */
  function leave(requestId: string) {
    if (onScreen.delete(requestId)) pruneQueue();
  }

  /** Whether a reply on screen draws this card, or is being drawn with it. */
  function isInUse(id: string): boolean {
    for (const reply of onScreen.values()) {
      if (reply.cards.has(id) || reply.drawing?.has(id) === true) return true;
    }

    return false;
  }

  /**
   * Gives up the waiting cards no reply on screen draws: they scrolled away
   * before their turn came.
   */
  function pruneQueue() {
    for (let i = queue.length - 1; i >= 0; i--) {
      const job = queue[i]!;
      if (isInUse(job.id)) continue;
      queue.splice(i, 1);
      if (thumbs.get(job.id) === job.slot) thumbs.delete(job.id);
    }
  }

  /**
   * Makes room for one more card: true while fewer than `MAX_THUMBS` are
   * kept, or once one that is drawn is on screen no longer, and then the one
   * asked for longest ago goes. The card being converted is never the one.
   * None is made while too many previews given up are unanswered.
   */
  function admitThumb(io: Host): boolean {
    if (abandoned >= MAX_ABANDONED) return false;
    pruneQueue();
    if (thumbs.size < MAX_THUMBS) return true;
    let oldest: string | undefined;
    for (const [id, slot] of thumbs) {
      if (slot.card === undefined || isInUse(id)) continue;
      if (oldest === undefined || slot.askedAt < thumbs.get(oldest)!.askedAt)
        oldest = id;
    }
    if (oldest === undefined) return false;
    dropThumb(io, oldest);

    return true;
  }

  /**
   * A job's card, or undefined when it has none or was not drawn in time: a
   * call that never answers must not hold up the cards behind it.
   */
  function previewInTime(io: Host, job: Job): Promise<Card | undefined> {
    return new Promise((resolve) => {
      let isLate = false;
      // The command the preview began last, and the files it holds.
      let running: Promise<unknown> = Promise.resolve();
      const held = new Set<string>();
      const bound: Host = {
        ...io,
        // Once given up, the preview starts no command.
        run: (argv, timeoutMs) => {
          if (isLate) return Promise.resolve(undefined);
          const result = io.run(argv, timeoutMs);
          running = result;

          return result;
        },
        keep: (path) => {
          io.keep(path);
          // Too late to be of use: a file found only now goes at once.
          if (isLate) io.remove(path);
          else held.add(path);
        },
        remove: (path) => {
          if (held.delete(path)) io.remove(path);
        },
      };
      const giveUp = () => {
        for (const path of held) io.remove(path);
        held.clear();
        resolve(undefined);
      };
      const deadline = io.after(PREVIEW_DEADLINE_MS, () => {
        isLate = true;
        abandoned++;
        // A command begun before now ends at its own timeout, and the next
        // card waits for that: no two conversions run side by side. Then the
        // files this preview holds go, whether or not it ever answers.
        void running.then(giveUp, giveUp);
      });
      const settle = (card: Card | undefined) => {
        deadline.cancel();
        if (isLate) abandoned--;
        // Too late to be a card: its PNG went as it was kept.
        resolve(isLate ? undefined : card);
      };
      // Rejected: not a picture sips converts, and the chip is dropped.
      preview(bound, job.file, job.maxColumns).then(settle, () =>
        settle(undefined),
      );
    });
  }

  /**
   * Converts the waiting cards one after another, the one asked for last
   * first, and asks for the redraw as each is drawn or given up.
   */
  async function drain(io: Host) {
    if (isPreviewing) return;
    isPreviewing = true;
    try {
      for (;;) {
        pruneQueue();
        // Too many previews given up are unanswered: no other is begun, and
        // the cards that waited their turn are given up with them.
        if (abandoned >= MAX_ABANDONED) {
          for (const job of queue.splice(0)) {
            if (thumbs.get(job.id) === job.slot) thumbs.delete(job.id);
          }

          return;
        }
        let next = -1;
        for (let i = 0; i < queue.length; i++) {
          if (next < 0 || queue[i]!.slot.askedAt > queue[next]!.slot.askedAt)
            next = i;
        }
        if (next < 0) return;
        const job = queue.splice(next, 1)[0]!;
        const card = await previewInTime(io, job);
        // The working directory moved on meanwhile, and took the place with it.
        if (job.boundary !== boundary || thumbs.get(job.id) !== job.slot) {
          if (card?.png !== undefined) io.remove(card.png);
        } else if (card === undefined) {
          thumbs.delete(job.id);
          failed.add(job.id);
          for (const stale of failed) {
            if (failed.size <= MAX_FAILED) break;
            failed.delete(stale);
          }
        } else {
          job.slot.card = card;
        }
        io.redraw();
      }
    } finally {
      isPreviewing = false;
    }
  }

  /** Takes a card's place at once and puts its conversion in the queue. */
  function sketch(io: Host, file: Located, id: string, maxColumns: number) {
    const slot: Slot = { askedAt: ++asked };
    thumbs.set(id, slot);
    queue.push({ id, file, maxColumns, slot, boundary });
    void drain(io);
  }

  on("session.start", async ($, e, next) => {
    const dir = ((await $.env.get("TMPDIR")) ?? "/tmp").replace(/\/+$/, "");
    let root: string | undefined;
    try {
      root = (await $.fs.stat(e.cwd, { resolve: true })).realPath;
    } catch {
      // no working directory to hold previews to: none is drawn
    }
    const run: Host["run"] = async (argv, timeoutMs) => {
      try {
        return await $.process.run(
          argv,
          timeoutMs === undefined ? undefined : { timeoutMs },
        );
      } catch {
        return undefined;
      }
    };
    // The record follows `owned` a moment behind, from a timer of its own.
    let isRecordDue = false;
    const writeRecord = async () => {
      isRecordDue = false;
      try {
        await update($, temps, () => [...owned]);
      } catch {
        // Refused while a reply was being drawn: once more, a moment later.
        record();
      }
    };
    const record = () => {
      if (isRecordDue) return;
      isRecordDue = true;
      $.clock.after(RECORD_DELAY_MS, () => void writeRecord());
    };
    host = {
      run,
      exists: (path) => $.fs.exists(path),
      stat: async (path) => {
        try {
          return await $.fs.stat(path, { resolve: true });
        } catch {
          return undefined;
        }
      },
      readBytes: async (path) =>
        (await $.fs.read(path, { as: "bytes" })).base64,
      tempPath: (suffix) =>
        `${dir}/${TEMP_PREFIX}${crypto.randomUUID()}.${suffix}`,
      keep: (path) => {
        owned.add(path);
        record();
      },
      // A path is struck off once `rm` has said it is gone, and not before:
      // one that could not be removed stays written down for the next sweep.
      remove: (path) => {
        void run(["rm", "-f", path]).then((done) => {
          if (done?.exitCode !== 0) return;
          owned.delete(path);
          record();
        });
      },
      sweep: async () => {
        const pane = await read($, shown);
        const kept = pane?.isPngTemporary === true ? pane.png : undefined;
        const left = [...owned].filter((path) => path !== kept);
        if (left.length > 0) {
          const done = await run(["rm", "-f", ...left]);
          if (done?.exitCode === 0) for (const path of left) owned.delete(path);
        }
        await writeRecord();
      },
      redraw: () => $.ui.invalidate("ui.render"),
      after: (ms, fn) => $.clock.after(ms, fn),
      home: await $.env.get("HOME"),
      root,
      isPixelTerminal:
        (await $.env.get("TMUX")) === undefined &&
        (await $.env.get("SSH_CONNECTION")) === undefined &&
        (await $.env.get("SSH_CLIENT")) === undefined &&
        (await $.env.get("SSH_TTY")) === undefined &&
        ((await $.env.get("TERM")) === "xterm-kitty" ||
          (await $.env.get("TERM")) === "xterm-ghostty" ||
          (await $.env.get("TERM_PROGRAM"))?.toLowerCase() === "ghostty" ||
          (await $.env.get("KITTY_WINDOW_ID")) !== undefined),
    };
    // A module loaded again starts with no card: the files the last one made
    // for its own go, each by the path it was written down under.
    owned.clear();
    for (const path of await read($, temps)) owned.add(path);
    forgetCards();
    await host.sweep();
    await $.command.register({
      name: "img",
      description: "Preview an image in a pane",
      argumentHint: "[--cells|--pixels] <path>",
    });

    return next(e);
  });

  // The previews' boundary is the working directory as it is now. When it
  // changes, everything made under the old one is dropped before anything is
  // awaited, and no preview is made until the new one is resolved.
  on("classic.CwdChanged", async (_$, e, next) => {
    if (host !== undefined) {
      const io = host;
      const mine = ++boundary;
      io.root = undefined;
      for (const id of [...thumbs.keys()]) dropThumb(io, id);
      queue.length = 0;
      onScreen.clear();
      failed.clear();
      located.clear();
      // The cards on screen are the old directory's: they go now, not when
      // the new one is known.
      io.redraw();
      const root = (await io.stat(e.new_cwd))?.realPath;
      // A later change owns the root now: this one's answer is stale.
      if (mine === boundary) {
        io.root = root;
        io.redraw();
      }
    }

    return next(e);
  });

  // The session's replies go with it, and their cards with them. The PNG the
  // pane shows stays: after a `/clear` the pane is still there to show it.
  on("session.end", async (_$, e, next) => {
    if (host !== undefined) {
      forgetCards();
      await host.sweep();
    }

    return next(e);
  });

  on("command.run", { command: "img" }, async ($, e) => {
    if (host === undefined)
      return { text: "img: not ready, the session has not started" };
    const io = host;
    const request = parseArgs(e.args);
    // No path: the picture already shown, opened again or drawn the other way.
    const target =
      request.path === "" ? (await read($, shown))?.path : request.path;
    if (target === undefined) return { text: USAGE };

    // A path completed with `@` keeps its mention mark: try it without.
    const candidates = target.startsWith("@")
      ? [target, target.slice(1)]
      : [target];
    let found: Awaited<ReturnType<Host["stat"]>>;
    let given = target;
    for (given of candidates) {
      found = await io.stat(expandHome(given, io.home));
      if (found !== undefined) break;
    }
    if (found === undefined) return { text: `img: no such file: ${target}` };
    if (found.kind !== "file") return { text: `img: not a file: ${target}` };

    given = expandHome(given, io.home);
    const file = {
      path: found.realPath ?? (given.startsWith("/") ? given : `./${given}`),
      mtimeMs: found.mtimeMs,
    };
    const size = await measure(io, file.path);
    if (size === undefined)
      return {
        text: `img: not an image sips or ImageMagick can read: ${target}`,
      };

    const mode = request.mode ?? (io.isPixelTerminal ? "pixels" : "cells");
    const picture = await oneAtATime(async () => {
      const replacement = await present(
        io,
        await read($, shown),
        file,
        size,
        mode,
      );
      if (replacement !== undefined) await update($, shown, () => replacement);

      return replacement;
    });
    if (picture === undefined)
      return { text: `img: could not convert to PNG: ${target}` };
    await $.ui.open(paneRequest(picture, e.presentation.columns));

    return {
      text: `${picture.name} · ${picture.width}×${picture.height} · ${mode}`,
    };
  });

  on("ui.render", { component: "Pane", requestId: PANE }, async ($, e) => {
    if (e.surface !== "terminal") {
      const { Text } = $.ui.resolve(e);

      return <Text dimColor>imgview draws pictures in the terminal only.</Text>;
    }
    const { Box, Image, Raster, Text } = $.ui.resolve(e);
    const picture = await read($, shown);
    if (picture === null) return <Text dimColor>{USAGE}</Text>;

    const caption = `${picture.name} · ${picture.width}×${picture.height}`;
    const box = fit(
      picture,
      Math.min(e.props.bodyColumns, MAX_CELLS),
      Math.min(e.props.scroll.bodyRows - 1, MAX_CELLS),
    );
    if (picture.mode === "pixels" && picture.png !== undefined) {
      return (
        <Box flexDirection="column">
          <Image
            key={KEY}
            source={{
              file: picture.png,
              format: "png",
              generation: Math.floor(picture.mtimeMs),
            }}
            columns={box.columns}
            rows={box.rows}
            alt={`${caption}: no pixels on this terminal, try /img --cells`}
          />
          <Text dimColor>{caption}</Text>
        </Box>
      );
    }

    const id = `${picture.path}|${picture.mtimeMs}|${box.columns}x${box.rows}`;
    wanted = { id, picture, box };
    if (host !== undefined && frame?.id !== id) void paint(host);
    if (frame?.id === id && frame.error !== undefined) {
      return <Text dimColor>{`${caption}: ${frame.error}`}</Text>;
    }

    // While another size is converted, the last frame of this picture stays up.
    const isSamePicture =
      frame?.id.startsWith(`${picture.path}|${picture.mtimeMs}|`) === true;
    return (
      <Box flexDirection="column">
        {frame?.cells !== undefined && isSamePicture ? (
          <Raster
            key={KEY}
            columns={frame.columns}
            rows={frame.rows}
            cells={frame.cells}
          />
        ) : (
          <Text dimColor>Rendering…</Text>
        )}
        <Text dimColor>{caption}</Text>
      </Box>
    );
  });

  // Under a reply that names image files: one chip a file. The pointer on a
  // chip reveals a card with the picture over the rows above; a click opens
  // the pane. The surface applies the hover itself, so the card is drawn
  // ahead of it, hidden, while the reply is on screen.
  on("ui.render", { component: "AssistantMessage" }, async ($, e, next) => {
    const row = await next(e);
    if (e.surface !== "terminal" || host === undefined) return row;
    // Only the fullscreen terminal reports the pointer. A reply that draws
    // no chip, there or for want of a file named, holds no card either.
    if (e.viewport?.isFullscreen !== true) {
      leave(e.requestId);

      return row;
    }
    const mentions = findImagePaths(e.props.text, MAX_CHIPS);
    if (mentions.length === 0) {
      leave(e.requestId);

      return row;
    }

    const { Box, Button, Image, Raster, Text } = $.ui.resolve(e);
    const io = host;
    // Where the terminal does not say what is on screen, nothing is taken to
    // be: the chips are drawn, and no card is made or drawn for them.
    const visibility = e.props.onScreen;
    const reply =
      visibility === undefined || visibility === null
        ? undefined
        : enter(e.requestId);
    if (reply === undefined) leave(e.requestId);
    // The cards this drawing asks for. They are the reply's own once the
    // drawing is done, and no other drawing's set is touched meanwhile.
    const cards = new Set<string>();
    if (reply !== undefined) reply.drawing = cards;
    const columns = e.viewport.columns;
    const maxColumns = Math.max(16, Math.min(CARD_COLUMNS, columns - 12));
    const chips = [];
    let offset = 0;
    for (const mention of mentions) {
      // Between two working directories nothing is looked up, or remembered.
      if (io.root === undefined) break;
      const now = await $.clock.now();
      let entry = located.get(mention);
      if (entry === undefined || now - entry.at > LOCATE_TTL_MS) {
        const asked = boundary;
        entry = { at: now, file: await locateMention(io, mention) };
        // Looked up under a working directory that has since changed.
        if (asked !== boundary) continue;
        located.delete(mention);
        if (located.size >= MAX_LOCATED) {
          for (const [key, old] of located) {
            if (now - old.at > LOCATE_TTL_MS) located.delete(key);
          }
        }
        // Still full of fresh lookups: the oldest of them goes.
        for (const key of located.keys()) {
          if (located.size < MAX_LOCATED) break;
          located.delete(key);
        }
        located.set(mention, entry);
      }
      const file = entry.file;
      if (file === undefined) continue;

      const id = `${file.path}|${file.mtimeMs}|${maxColumns}`;
      if (failed.has(id)) continue;
      const slot = thumbs.get(id);
      // Only the drawing begun last of a reply still on screen asks for a
      // card, holds one in use, or draws one.
      const isHolding =
        reply !== undefined &&
        reply.drawing === cards &&
        onScreen.get(e.requestId) === reply;
      if (isHolding) {
        // No room among the cards on screen: this one waits, with no chip.
        if (slot === undefined && !admitThumb(io)) continue;
        cards.add(id);
        if (slot !== undefined) slot.askedAt = ++asked;
        else sketch(io, file, id, maxColumns);
      }
      const card = slot?.card;

      const index = chips.length;
      const name = baseName(file.path);
      const label = `▣ ${name}`;
      const width = card === undefined ? 16 : card.columns;
      const caption = (
        card === undefined
          ? "Rendering…"
          : `${name} · ${card.width}×${card.height}`
      )
        .slice(0, width)
        .padEnd(width);
      chips.push(
        <Box key={`imgview-chip-${index}`}>
          <Button
            key={`imgview-open-${index}`}
            plain
            dimColor
            label={label}
            onPress={async () => {
              // A click is the person's: the pane takes the file itself, as
              // it is now and not as it was when the card was drawn.
              const found = await io.stat(file.path);
              if (found?.kind !== "file") return;
              const fresh = {
                path: found.realPath ?? file.path,
                mtimeMs: found.mtimeMs,
              };
              const size = await measure(io, fresh.path);
              if (size === undefined) return;
              const mode = io.isPixelTerminal ? "pixels" : "cells";
              const picture = await oneAtATime(async () => {
                const replacement = await present(
                  io,
                  await read($, shown),
                  fresh,
                  size,
                  mode,
                );
                if (replacement !== undefined)
                  await update($, shown, () => replacement);

                return replacement;
              });
              if (picture === undefined) return;
              await $.ui.open(paneRequest(picture, columns));
            }}
          />
          {isHolding && (
            <Box
              position="absolute"
              top={-((card === undefined ? 1 : card.rows + 1) + 2)}
              left={0 - offset}
              display="none"
              hover={{ display: "flex" }}
              flexDirection="column"
              borderStyle="round"
            >
              {card?.cells !== undefined && (
                <Raster
                  key={`imgview-thumb-${index}`}
                  columns={card.columns}
                  rows={card.rows}
                  cells={card.cells}
                />
              )}
              {card?.png !== undefined && (
                <Image
                  key={`imgview-thumb-${index}`}
                  source={{ file: card.png, format: "png" }}
                  columns={card.columns}
                  rows={card.rows}
                  alt={name}
                />
              )}
              <Text dimColor>{caption}</Text>
            </Box>
          )}
        </Box>,
      );
      offset += label.length + 2;
    }
    // The drawing of a reply begun last says which cards the reply draws now.
    if (reply !== undefined && reply.drawing === cards) {
      reply.drawing = undefined;
      reply.cards = cards;
    }
    if (chips.length === 0) return row;

    return (
      <Box flexDirection="column">
        {row}
        <Box flexDirection="row" columnGap={2} marginLeft={2}>
          {chips}
        </Box>
      </Box>
    );
  });
};
