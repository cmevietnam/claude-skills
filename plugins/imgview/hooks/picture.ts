// Pure helpers of the image pane: argument parsing, fitting a picture to a box
// of cells, decoding the BMP a converter wrote, and packing it as Raster cells.

export type Mode = "cells" | "pixels";

export type Request = { path: string; mode?: Mode };

export type Size = { width: number; height: number };

export type Bitmap = Size & {
  /** `width * height` pixels, row-major from the top, 4 bytes each: R, G, B, A. */
  rgba: Uint8Array;
};

/** A Raster paints this many distinct foreground/background pairs at once. */
export const MAX_PAIRS = 1024;

const DEFAULT_COLOR = 0x01000000;
// The block a cell draws, by which of its quarters are foreground: 1 the top
// left, 2 the top right, 4 the bottom left, 8 the bottom right.
const QUARTER_BLOCKS = [
  0x20, 0x2598, 0x259d, 0x2580, 0x2596, 0x258c, 0x259e, 0x259b, 0x2597, 0x259a,
  0x2590, 0x259c, 0x2584, 0x2599, 0x259f, 0x2588,
];
// A cell whose quarters differ by less than this (summed squares over the
// channels) is drawn in one color.
const FLAT_SPREAD = 48;
// The most colors a reduced palette is searched up to.
const MAX_PALETTE = 2048;

/** The bytes a base64 text holds. */
export function fromBase64(text: string): Uint8Array {
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);

  return bytes;
}

/** Standard padded base64 of the bytes. */
export function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }

  return btoa(binary);
}

/**
 * `/img` arguments: an optional `--cells` or `--pixels`, then one path as it
 * was typed, quoted, or dragged into the terminal (spaces backslash-escaped).
 */
export function parseArgs(args: string): Request {
  let rest = args.trim();
  let mode: Mode | undefined;
  const flag = /^--(cells|pixels)(?:\s+|$)/.exec(rest);
  if (flag) {
    mode = flag[1] as Mode;
    rest = rest.slice(flag[0].length).trim();
  }
  const quoted = /^(['"])(.*)\1$/.exec(rest);
  const path = quoted ? quoted[2]! : rest.replace(/\\(.)/g, "$1");

  return mode ? { path, mode } : { path };
}

/** `~` and `~/x` under `home`; any other path as given. */
export function expandHome(path: string, home: string | undefined): string {
  if (home === undefined || (path !== "~" && !path.startsWith("~/")))
    return path;

  return home.replace(/\/+$/, "") + path.slice(1);
}

/** The last path segment. */
export function baseName(path: string): string {
  return path.replace(/\/+$/, "").split("/").pop() || path;
}

// What a reply's mention is taken for a picture by: a bitmap's suffix. An SVG
// or a PDF runs a renderer, which nothing here does unasked.
const IMAGE_SUFFIX = /[^/]\.(?:png|jpe?g|gif|webp|heic|bmp|tiff?)$/i;
const BITMAP_FORMATS = ["png", "jpeg", "gif", "tiff", "bmp", "heic", "webp"];

/**
 * The image files a text mentions, in order, each once, `limit` at most: every
 * run of path characters that ends in a bitmap's suffix, as markdown writes it
 * (bare, in backticks, in a link) or as `file://`.
 *
 * A web address is left out: nothing here fetches. Whether a mention is a
 * file at all is the caller's to check.
 */
export function findImagePaths(text: string, limit: number): string[] {
  const found: string[] = [];
  for (const run of text.split(/[\s`'"<>[\]{}|*]+/)) {
    if (found.length >= limit) break;
    let path = unwrap(run.replace(/[.,;:!?]+$/, "")).replace(/[.,;:!?]+$/, "");
    if (path.startsWith("file://")) path = path.slice("file://".length);
    if (path.includes("://") || !IMAGE_SUFFIX.test(path)) continue;
    if (!found.includes(path)) found.push(path);
  }

  return found;
}

/**
 * A run without the parentheses that are the sentence's or the link's, not
 * the path's own: `(a.png)` and `a.png)` are `a.png`, `a(1).png` stays.
 */
function unwrap(run: string): string {
  let path = run;
  for (;;) {
    const opens = path.split("(").length - 1;
    const closes = path.split(")").length - 1;
    if (path.startsWith("(") && closeOf(path) === path.length - 1) {
      path = path.slice(1, -1);
    } else if (path.startsWith("(") && opens > closes) {
      path = path.slice(1);
    } else if (path.endsWith(")") && closes > opens) {
      path = path.slice(0, -1);
    } else {
      return path;
    }
  }
}

/** Where the parenthesis a run opens with is closed; -1 when it never is. */
function closeOf(run: string): number {
  let depth = 0;
  for (let i = 0; i < run.length; i++) {
    if (run[i] === "(") depth++;
    if (run[i] === ")" && --depth === 0) return i;
  }

  return -1;
}

/** Whether `path` is `root` or lies beneath it; both absolute and resolved. */
export function isInside(path: string, root: string): boolean {
  const base = root.replace(/\/+$/, "");

  return path === base || path.startsWith(`${base}/`);
}

/** A picture's size and, where the converter said, the file's real format. */
export type Measured = Size & {
  /** As `sips` names it, lower case: `png`, `jpeg`, `pdf`, ... */
  format?: string;
};

/** Whether a converter's format name is a bitmap's: no SVG, no PDF. */
export function isBitmapFormat(format: string | undefined): boolean {
  return format !== undefined && BITMAP_FORMATS.includes(format);
}

/**
 * What `sips -g format -g pixelWidth -g pixelHeight` printed, if it printed a
 * size. The format is the file's own, whatever its suffix says.
 */
export function parseSipsSize(stdout: string): Measured | undefined {
  const width = /pixelWidth:\s*(\d+)/.exec(stdout);
  const height = /pixelHeight:\s*(\d+)/.exec(stdout);
  const format = /format:\s*(\w+)/.exec(stdout);
  const size =
    width && height ? toSize(Number(width[1]), Number(height[1])) : undefined;

  return size && format ? { ...size, format: format[1]!.toLowerCase() } : size;
}

/** What `magick identify -format '%w %h %m'` printed, if it printed a size. */
export function parseIdentifySize(stdout: string): Measured | undefined {
  const found = /^\s*(\d+) (\d+)(?: (\w+))?/.exec(stdout);
  const size = found ? toSize(Number(found[1]), Number(found[2])) : undefined;

  return size && found?.[3]
    ? { ...size, format: found[3].toLowerCase() }
    : size;
}

function toSize(width: number, height: number): Size | undefined {
  return width > 0 && height > 0 ? { width, height } : undefined;
}

/**
 * The largest box of cells, at most `maxColumns` by `maxRows`, that keeps the
 * picture's shape: a cell is taken as twice as tall as it is wide.
 */
export function fit(
  size: Size,
  maxColumns: number,
  maxRows: number,
): { columns: number; rows: number } {
  const columns = clamp(
    Math.round((maxRows * 2 * size.width) / size.height),
    1,
    maxColumns,
  );
  const rows = clamp(
    Math.ceil((columns * size.height) / size.width / 2),
    1,
    maxRows,
  );

  return { columns, rows };
}

function clamp(value: number, low: number, high: number): number {
  return Math.max(low, Math.min(Math.max(low, high), value));
}

// No conversion asks for more than 510 pixels a side: a header that claims
// far more is not a converter's.
const MAX_BMP_SIDE = 4096;

/**
 * Decodes an uncompressed 24- or 32-bit BMP, the two forms `sips` and
 * ImageMagick write. Throws on any other file, naming what it found.
 */
export function decodeBmp(bytes: Uint8Array): Bitmap {
  if (bytes.length < 54 || bytes[0] !== 0x42 || bytes[1] !== 0x4d)
    throw new Error("not a BMP file");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const dataOffset = view.getUint32(10, true);
  const headerSize = view.getUint32(14, true);
  const width = view.getInt32(18, true);
  const signedHeight = view.getInt32(22, true);
  const height = Math.abs(signedHeight);
  const bitsPerPixel = view.getUint16(28, true);
  const compression = view.getUint32(30, true);
  if (bitsPerPixel !== 24 && bitsPerPixel !== 32)
    throw new Error(`a ${bitsPerPixel}-bit BMP`);
  if (compression !== 0 && compression !== 3)
    throw new Error(`BMP compression ${compression}`);
  if (
    width <= 0 ||
    height === 0 ||
    width > MAX_BMP_SIDE ||
    height > MAX_BMP_SIDE
  )
    throw new Error(`a ${width}x${signedHeight} BMP`);

  // Which byte of a pixel holds each channel: B, G, R(, A) unless masks say otherwise.
  let red = 2;
  let green = 1;
  let blue = 0;
  let alpha = bitsPerPixel === 32 ? 3 : -1;
  const hasMasks = compression === 3;
  if (hasMasks) {
    // Three masks follow the 40 header bytes, a fourth in the longer headers.
    const hasAlphaMask = headerSize >= 56;
    if (bitsPerPixel !== 32 || bytes.length < (hasAlphaMask ? 70 : 66))
      throw new Error("a BMP with no room for its channel masks");
    red = maskByte(view.getUint32(54, true));
    green = maskByte(view.getUint32(58, true));
    blue = maskByte(view.getUint32(62, true));
    alpha = hasAlphaMask ? maskByte(view.getUint32(66, true), true) : -1;
  }

  // The sides are small, so none of this leaves the safe integers.
  const step = bitsPerPixel / 8;
  const stride = Math.ceil((width * step) / 4) * 4;
  if (
    dataOffset < (hasMasks ? 66 : 54) ||
    dataOffset + stride * (height - 1) + width * step > bytes.length
  )
    throw new Error("a truncated BMP");
  const rgba = new Uint8Array(width * height * 4);
  let isAlphaUsed = false;
  for (let y = 0; y < height; y++) {
    const row = dataOffset + stride * (signedHeight < 0 ? y : height - 1 - y);
    for (let x = 0; x < width; x++) {
      const from = row + x * step;
      const to = (y * width + x) * 4;
      rgba[to] = bytes[from + red]!;
      rgba[to + 1] = bytes[from + green]!;
      rgba[to + 2] = bytes[from + blue]!;
      rgba[to + 3] = alpha < 0 ? 255 : bytes[from + alpha]!;
      if (rgba[to + 3] !== 0) isAlphaUsed = true;
    }
  }
  // Without masks a 32-bit pixel's fourth byte means nothing: zero throughout
  // is an opaque picture. Under an alpha mask, zero is transparent.
  if (!hasMasks && !isAlphaUsed)
    for (let i = 3; i < rgba.length; i += 4) rgba[i] = 255;

  return { width, height, rgba };
}

function maskByte(mask: number, isOptional = false): number {
  const index = [0xff, 0xff00, 0xff0000, 0xff000000].indexOf(mask >>> 0);
  if (index < 0 && !(isOptional && mask === 0))
    throw new Error(`BMP channel mask ${mask.toString(16)}`);

  return index;
}

/**
 * Packs a bitmap as Raster cells, one cell per two by two pixels: the block
 * whose quarters split the four pixels best into two colors, a foreground and
 * a background.
 *
 * A transparent pixel shows the terminal's own background. A picture that
 * needs more than `maxPairs` distinct color pairs is drawn from the largest
 * palette that fits (`reducePairs`).
 *
 * @returns the grid's size and its cells as `RasterProps` packs them
 */
export function toCells(
  bitmap: Bitmap,
  maxPairs = MAX_PAIRS,
): { columns: number; rows: number; cells: string } {
  const columns = Math.ceil(bitmap.width / 2);
  const rows = Math.ceil(bitmap.height / 2);
  const words = new Uint32Array(columns * rows * 3);
  const foreground = new Int32Array(columns * rows);
  const background = new Int32Array(columns * rows);
  // The four pixels of the cell in hand: red, green, blue each.
  const quarters = new Float64Array(12);
  for (let row = 0; row < rows; row++) {
    for (let column = 0; column < columns; column++) {
      let opaque = 0;
      for (let quarter = 0; quarter < 4; quarter++) {
        const x = column * 2 + (quarter & 1);
        const y = row * 2 + (quarter >> 1);
        const at = (y * bitmap.width + x) * 4;
        if (x >= bitmap.width || y >= bitmap.height) continue;
        if (bitmap.rgba[at + 3]! < 128) continue;
        opaque |= 1 << quarter;
        quarters.set(bitmap.rgba.subarray(at, at + 3), quarter * 3);
      }
      const cell = row * columns + column;
      if (opaque !== 15) {
        // Clear quarters are the background; the rest share one color.
        words[cell * 3] = QUARTER_BLOCKS[opaque]!;
        foreground[cell] =
          opaque === 0 ? DEFAULT_COLOR : meanColor(quarters, opaque);
        background[cell] = DEFAULT_COLOR;
        continue;
      }
      let split = 15;
      let least = spread(quarters, 15);
      if (least > FLAT_SPREAD) {
        // Every way to part four quarters in two: 1 to 7 and their complements.
        for (let mask = 1; mask <= 7; mask++) {
          const error = spread(quarters, mask) + spread(quarters, 15 ^ mask);
          if (error < least) {
            split = mask;
            least = error;
          }
        }
      }
      const a = meanColor(quarters, split);
      const b = split === 15 ? a : meanColor(quarters, 15 ^ split);
      // One picture, one spelling: the larger color is the foreground.
      if (a >= b) {
        words[cell * 3] = QUARTER_BLOCKS[split]!;
        foreground[cell] = a;
        background[cell] = b;
      } else {
        words[cell * 3] = QUARTER_BLOCKS[15 ^ split]!;
        foreground[cell] = b;
        background[cell] = a;
      }
    }
  }
  reducePairs(foreground, background, maxPairs);
  for (let cell = 0; cell < foreground.length; cell++) {
    words[cell * 3 + 1] = foreground[cell]!;
    words[cell * 3 + 2] = background[cell]!;
  }

  return { columns, rows, cells: toBase64(new Uint8Array(words.buffer)) };
}

/** The mean color of the quarters `mask` names. */
function meanColor(quarters: Float64Array, mask: number): number {
  const sum = [0, 0, 0];
  let count = 0;
  for (let quarter = 0; quarter < 4; quarter++) {
    if ((mask & (1 << quarter)) === 0) continue;
    for (let channel = 0; channel < 3; channel++) {
      sum[channel]! += quarters[quarter * 3 + channel]!;
    }
    count++;
  }

  return (
    (Math.round(sum[0]! / count) << 16) |
    (Math.round(sum[1]! / count) << 8) |
    Math.round(sum[2]! / count)
  );
}

/** How far the quarters `mask` names lie from their mean: summed squares. */
function spread(quarters: Float64Array, mask: number): number {
  let total = 0;
  for (let channel = 0; channel < 3; channel++) {
    let sum = 0;
    let squares = 0;
    let count = 0;
    for (let quarter = 0; quarter < 4; quarter++) {
      if ((mask & (1 << quarter)) === 0) continue;
      const value = quarters[quarter * 3 + channel]!;
      sum += value;
      squares += value * value;
      count++;
    }
    total += squares - (sum * sum) / count;
  }

  return total;
}

/** A box of the median cut: its colors, and the two it was cut into. */
type PaletteBox = {
  colors: number[];
  /** The channel its colors range widest over, and by how much. */
  channel: number;
  range: number;
  /** The weighted mean of its colors: what they are all drawn as. */
  center: number;
  /** How many boxes there were once this one was made. */
  born: number;
  halves?: [PaletteBox, PaletteBox];
};

/**
 * Redraws the cells from a smaller palette when they need more than
 * `maxPairs` distinct foreground/background pairs: a median cut of the colors
 * in use, as large as still fits. In place; the default color is kept.
 */
function reducePairs(
  foreground: Int32Array,
  background: Int32Array,
  maxPairs: number,
): void {
  if (countPairs(foreground, background) <= maxPairs) return;
  const weights = new Map<number, number>();
  for (const colors of [foreground, background]) {
    for (const color of colors) {
      if (color !== DEFAULT_COLOR)
        weights.set(color, (weights.get(color) ?? 0) + 1);
    }
  }
  const root = cutPalette(weights, Math.min(weights.size, MAX_PALETTE));
  // More colors never need fewer pairs: search for the most that fit.
  let palette = paletteOf(root, 1);
  let low = 2;
  let high = Math.min(weights.size, MAX_PALETTE);
  while (low <= high) {
    const size = (low + high) >> 1;
    const candidate = paletteOf(root, size);
    if (countPairs(foreground, background, candidate) <= maxPairs) {
      palette = candidate;
      low = size + 1;
    } else {
      high = size - 1;
    }
  }
  for (let cell = 0; cell < foreground.length; cell++) {
    foreground[cell] = palette.get(foreground[cell]!) ?? foreground[cell]!;
    background[cell] = palette.get(background[cell]!) ?? background[cell]!;
  }
}

function countPairs(
  foreground: Int32Array,
  background: Int32Array,
  palette?: Map<number, number>,
): number {
  const pairs = new Set<number>();
  for (let cell = 0; cell < foreground.length; cell++) {
    const a = palette?.get(foreground[cell]!) ?? foreground[cell]!;
    const b = palette?.get(background[cell]!) ?? background[cell]!;
    // A color is at most 25 bits: the two fit one exact number.
    pairs.add(a * 0x2000000 + b);
  }

  return pairs.size;
}

/**
 * Cuts the colors into `size` boxes, each time the box that ranges widest,
 * at the weighted median of its widest channel, and keeps the order of the
 * cuts: the first `n` boxes are the palette of `n` colors.
 */
function cutPalette(weights: Map<number, number>, size: number): PaletteBox {
  const root = paletteBox([...weights.keys()], weights, 1);
  const leaves = [root];
  while (leaves.length < size) {
    let widest = -1;
    for (let i = 0; i < leaves.length; i++) {
      if (leaves[i]!.range === 0) continue;
      if (widest < 0 || leaves[i]!.range > leaves[widest]!.range) widest = i;
    }
    if (widest < 0) break;
    const box = leaves[widest]!;
    const shift = 16 - box.channel * 8;
    box.colors.sort((a, b) => ((a >> shift) & 255) - ((b >> shift) & 255));
    let total = 0;
    for (const color of box.colors) total += weights.get(color)!;
    let cut = 1;
    let seen = weights.get(box.colors[0]!)!;
    while (cut < box.colors.length - 1 && seen < total / 2) {
      seen += weights.get(box.colors[cut++]!)!;
    }
    const born = leaves.length + 1;
    box.halves = [
      paletteBox(box.colors.slice(0, cut), weights, born),
      paletteBox(box.colors.slice(cut), weights, born),
    ];
    leaves[widest] = box.halves[0];
    leaves.push(box.halves[1]);
  }

  return root;
}

function paletteBox(
  colors: number[],
  weights: Map<number, number>,
  born: number,
): PaletteBox {
  let channel = 0;
  let range = -1;
  const sum = [0, 0, 0];
  let total = 0;
  for (let c = 0; c < 3; c++) {
    const shift = 16 - c * 8;
    let low = 255;
    let high = 0;
    for (const color of colors) {
      const value = (color >> shift) & 255;
      if (value < low) low = value;
      if (value > high) high = value;
      sum[c]! += value * weights.get(color)!;
    }
    if (high - low > range) {
      range = high - low;
      channel = c;
    }
  }
  for (const color of colors) total += weights.get(color)!;
  const center =
    (Math.round(sum[0]! / total) << 16) |
    (Math.round(sum[1]! / total) << 8) |
    Math.round(sum[2]! / total);

  return { colors, channel, range, center, born };
}

/** Each color's stand-in under the palette of the first `size` boxes. */
function paletteOf(root: PaletteBox, size: number): Map<number, number> {
  const palette = new Map<number, number>();
  const walk = (box: PaletteBox) => {
    if (box.halves !== undefined && box.halves[0].born <= size) {
      walk(box.halves[0]);
      walk(box.halves[1]);
    } else {
      for (const color of box.colors) palette.set(color, box.center);
    }
  };
  walk(root);

  return palette;
}
