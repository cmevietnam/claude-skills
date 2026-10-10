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
import type { Measured, Size } from "./picture";

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
// A reply is drawn again for every piece that streams in: a path is looked up
// once in this long, and this many lookups are remembered.
const LOCATE_TTL_MS = 2000;
const MAX_LOCATED = 128;
// This many cards' cells are kept. One drawn in the last while is on screen
// and is never dropped for another: past the limit a new card waits.
const MAX_THUMBS = 32;
const THUMB_ACTIVE_MS = 5000;
// What a reply names is converted with no action of the person's, so it is
// held to less than what `/img` takes: a file this small, a picture of this
// many pixels, `sips` alone, and this long.
const PREVIEW_MAX_BYTES = 20 * 1024 * 1024;
const PREVIEW_MAX_PIXELS = 100_000_000;
const PREVIEW_TIMEOUT_MS = 5000;

const shown = atom({ plugin: "imgview", key: "shown" } as const, null);

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

/** A hover card's picture: `pending` until measured and converted. */
type Thumb =
  | { state: "pending" }
  | { state: "failed" }
  | ({ state: "ready"; cells?: string } & Size & {
        columns: number;
        rows: number;
      });

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
  /** A fresh path under the temporary directory. */
  tempPath: (suffix: "bmp" | "png") => string;
  redraw: () => void;
  home: string | undefined;
  /** Where the session's working directory lands; undefined when unknown. */
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
  const base64 = await host.readBytes(out);
  void host.run(["rm", "-f", out]);
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
 * Whether the terminal can read this picture itself: a PNG by its content,
 * as the converter named it, at an absolute path.
 */
function isReadablePng(path: string, format: string | undefined): boolean {
  return path.startsWith("/") && format === "png";
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
  // The pane's conversions in flight, and the one its last drawing asked for.
  const painting = new Set<string>();
  let wanted: string | undefined;
  const thumbs = new Map<string, { thumb: Thumb; usedAt: number }>();
  const located = new Map<string, { at: number; file: Located | undefined }>();

  /**
   * Converts the picture to `box` cells and asks for the redraw, unless the
   * pane has moved on to another size or picture meanwhile.
   */
  async function paint(
    io: Host,
    picture: Shown,
    box: { columns: number; rows: number },
    id: string,
  ) {
    painting.add(id);
    let painted: Frame = { id, ...box };
    try {
      painted = { id, ...(await rasterize(io, picture.path, box)) };
    } catch (error) {
      painted.error = error instanceof Error ? error.message : String(error);
    }
    painting.delete(id);
    if (wanted !== id) return;
    frame = painted;
    io.redraw();
  }

  /**
   * Makes room for one more card: true while fewer than `MAX_THUMBS` are
   * kept, or once the least recently drawn one has left the screen.
   */
  function admitThumb(now: number): boolean {
    if (thumbs.size < MAX_THUMBS) return true;
    let oldest: string | undefined;
    for (const [id, slot] of thumbs) {
      if (oldest === undefined || slot.usedAt < thumbs.get(oldest)!.usedAt)
        oldest = id;
    }
    if (
      oldest === undefined ||
      now - thumbs.get(oldest)!.usedAt < THUMB_ACTIVE_MS
    )
      return false;
    thumbs.delete(oldest);

    return true;
  }

  /** Measures a mentioned picture and draws its card, then asks for the redraw. */
  async function sketch(
    io: Host,
    file: Located,
    id: string,
    maxColumns: number,
  ) {
    const slot = { thumb: { state: "pending" } as Thumb, usedAt: Date.now() };
    thumbs.set(id, slot);
    let thumb: Thumb = { state: "failed" };
    try {
      const size = await measure(io, file.path, PREVIEW);
      if (
        size !== undefined &&
        isBitmapFormat(size.format) &&
        size.width * size.height <= PREVIEW_MAX_PIXELS
      ) {
        const box = fit(size, maxColumns, CARD_ROWS);
        const { width, height } = size;
        // A pixel terminal reads a PNG itself: the card needs no cells.
        thumb =
          io.isPixelTerminal && isReadablePng(file.path, size.format)
            ? { state: "ready", width, height, ...box }
            : {
                state: "ready",
                width,
                height,
                ...(await rasterize(io, file.path, box, PREVIEW)),
              };
      }
    } catch {
      // not a picture sips converts: the chip is dropped
    }
    slot.thumb = thumb;
    io.redraw();
  }

  on("session.start", async ($, e, next) => {
    const dir = ((await $.env.get("TMPDIR")) ?? "/tmp").replace(/\/+$/, "");
    const stamp = Date.now().toString(36);
    let serial = 0;
    let root: string | undefined;
    try {
      root = (await $.fs.stat(e.cwd, { resolve: true })).realPath;
    } catch {
      // no working directory to hold previews to: none is drawn
    }
    host = {
      run: async (argv, timeoutMs) => {
        try {
          return await $.process.run(
            argv,
            timeoutMs === undefined ? undefined : { timeoutMs },
          );
        } catch {
          return undefined;
        }
      },
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
        `${dir}/${TEMP_PREFIX}${stamp}-${serial++}.${suffix}`,
      redraw: () => $.ui.invalidate("ui.render"),
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
    await $.command.register({
      name: "img",
      description: "Preview an image in a pane",
      argumentHint: "[--cells|--pixels] <path>",
    });

    return next(e);
  });

  on("command.run", { command: "img" }, async ($, e) => {
    if (host === undefined)
      return { text: "img: not ready, the session has not started" };
    const request = parseArgs(e.args);
    const previous = await read($, shown);
    // No path: the picture already shown, opened again or drawn the other way.
    const target = request.path === "" ? previous?.path : request.path;
    if (target === undefined) return { text: USAGE };

    // A path completed with `@` keeps its mention mark: try it without.
    const candidates = target.startsWith("@")
      ? [target, target.slice(1)]
      : [target];
    let found: Awaited<ReturnType<Host["stat"]>>;
    let given = target;
    for (given of candidates) {
      found = await host.stat(expandHome(given, host.home));
      if (found !== undefined) break;
    }
    if (found === undefined) return { text: `img: no such file: ${target}` };
    if (found.kind !== "file") return { text: `img: not a file: ${target}` };

    given = expandHome(given, host.home);
    const path =
      found.realPath ?? (given.startsWith("/") ? given : `./${given}`);
    const size = await measure(host, path);
    if (size === undefined)
      return {
        text: `img: not an image sips or ImageMagick can read: ${target}`,
      };

    const mode = request.mode ?? (host.isPixelTerminal ? "pixels" : "cells");
    const picture: Shown = {
      path,
      name: baseName(path),
      width: size.width,
      height: size.height,
      mtimeMs: found.mtimeMs,
      mode,
    };
    if (mode === "pixels") {
      // The terminal reads a PNG by its absolute path; anything else is converted.
      if (isReadablePng(path, size.format)) {
        picture.png = path;
      } else {
        const out = host.tempPath("png");
        if (!(await convert(host, path, out)))
          return { text: `img: could not convert to PNG: ${target}` };
        picture.png = out;
        picture.isPngTemporary = true;
      }
    }
    // Only a PNG this mod wrote is its to remove, never one it was shown.
    if (
      previous?.png !== undefined &&
      previous.isPngTemporary === true &&
      previous.png !== picture.png
    ) {
      void host.run(["rm", "-f", previous.png]);
    }

    await update($, shown, () => picture);
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
    wanted = id;
    if (host !== undefined && frame?.id !== id && !painting.has(id))
      void paint(host, picture, box, id);
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
    // Only the fullscreen terminal reports the pointer.
    if (
      e.surface !== "terminal" ||
      host === undefined ||
      e.viewport?.isFullscreen !== true
    )
      return row;
    const mentions = findImagePaths(e.props.text, MAX_CHIPS);
    if (mentions.length === 0) return row;

    const { Box, Button, Image, Raster, Text } = $.ui.resolve(e);
    const io = host;
    const columns = e.viewport.columns;
    const maxColumns = Math.max(16, Math.min(CARD_COLUMNS, columns - 12));
    const chips = [];
    let offset = 0;
    for (const mention of mentions) {
      const now = Date.now();
      let entry = located.get(mention);
      if (entry === undefined || now - entry.at > LOCATE_TTL_MS) {
        entry = { at: now, file: await locateMention(io, mention) };
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
      const slot = thumbs.get(id);
      if (slot !== undefined) slot.usedAt = now;
      else if (e.props.onScreen !== null) {
        // No room among the cards on screen: this one waits, with no chip.
        if (!admitThumb(now)) continue;
        void sketch(io, file, id, maxColumns);
      }
      const thumb = slot?.thumb;
      if (thumb?.state === "failed") continue;

      const index = chips.length;
      const name = baseName(file.path);
      const label = `▣ ${name}`;
      const isReady = thumb?.state === "ready";
      const width = isReady ? thumb.columns : 16;
      const caption = (
        isReady ? `${name} · ${thumb.width}×${thumb.height}` : "Rendering…"
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
              if (!isReady) return;
              const picture: Shown = {
                path: file.path,
                name,
                width: thumb.width,
                height: thumb.height,
                mtimeMs: file.mtimeMs,
                mode: thumb.cells === undefined ? "pixels" : "cells",
              };
              if (thumb.cells === undefined) picture.png = file.path;
              await update($, shown, () => picture);
              await $.ui.open(paneRequest(picture, columns));
            }}
          />
          <Box
            position="absolute"
            top={-((isReady ? thumb.rows + 1 : 1) + 2)}
            left={0 - offset}
            display="none"
            hover={{ display: "flex" }}
            flexDirection="column"
            borderStyle="round"
          >
            {isReady && thumb.cells !== undefined && (
              <Raster
                key={`imgview-thumb-${index}`}
                columns={thumb.columns}
                rows={thumb.rows}
                cells={thumb.cells}
              />
            )}
            {isReady && thumb.cells === undefined && (
              <Image
                key={`imgview-thumb-${index}`}
                source={{
                  file: file.path,
                  format: "png",
                  generation: Math.floor(file.mtimeMs),
                }}
                columns={thumb.columns}
                rows={thumb.rows}
                alt={name}
              />
            )}
            <Text dimColor>{caption}</Text>
          </Box>
        </Box>,
      );
      offset += label.length + 2;
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
