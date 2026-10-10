import { describe, expect, test } from "claude-code/testing";

import {
  MAX_PAIRS,
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
  toBase64,
  toCells,
} from "../hooks/picture";
import type { Bitmap } from "../hooks/picture";

// Real converter output for one 4x4 picture: red, green, two clear pixels on
// the first row, blue first on the second, half-clear white last of all.
const SIPS_ALPHA_BMP =
  "Qk3KAAAAAAAAAIoAAAB8AAAABAAAAPz///8BACAAAwAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAD/AAD/AAD/AAAAAAAA/0JHUnMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD//wD/AP8AAAAAAAAAAP8AAP8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA////gA==";
const MAGICK_ALPHA_BMP =
  "Qk3KAAAAAAAAAIoAAAB8AAAABAAAAAQAAAABACAAAwAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAD/AAD/AAD/AAAAAAAA/0JHUnOPwvUoUbgeFR6F6wEzMzMTZmZmJmZmZgaZmZkJPQrXAyhcjzIAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA////gAAAAAAAAAAAAAAAAAAAAAD/AAD/AAAAAAAAAAAAAAAAAAD//wD/AP8AAAAAAAAAAA==";
// A 4x4 red-to-blue gradient from a JPEG: 24 bits, no alpha, top-down.
const SIPS_OPAQUE_BMP =
  "Qk1mAAAAAAAAADYAAAAoAAAABAAAAPz///8BABgAAAAAADAAAAAAAAAAAAAAAAAAAAAAAAAAGgHlGgHlGgHlGgHlWwCjWwCjWwCjWwCjpQBbpQBbpQBbpQBb5gAY5gAY5gAY5gAY";

// Blocks by the quarters they fill.
const SPACE = 0x20;
const TOP_LEFT = 0x2598;
const TOP_HALF = 0x2580;
const BOTTOM_HALF = 0x2584;
const LEFT_HALF = 0x258c;
const ALL_BUT_TOP_LEFT = 0x259f;
const FULL = 0x2588;
const DEFAULT_COLOR = 0x01000000;

function pixel(bitmap: Bitmap, x: number, y: number): number[] {
  return [
    ...bitmap.rgba.subarray(
      (y * bitmap.width + x) * 4,
      (y * bitmap.width + x) * 4 + 4,
    ),
  ];
}

function words(cells: string): number[] {
  const bytes = fromBase64(cells);

  return [
    ...new Uint32Array(bytes.buffer, bytes.byteOffset, bytes.byteLength / 4),
  ];
}

function bitmapOf(
  width: number,
  height: number,
  at: (x: number, y: number) => number[],
): Bitmap {
  const rgba = new Uint8Array(width * height * 4);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) rgba.set(at(x, y), (y * width + x) * 4);
  }

  return { width, height, rgba };
}

/** A BMP header with room for its pixels, all zero, for a test to fill. */
function bmpHeader(spec: {
  width: number;
  height: number;
  bits: number;
  dataOffset: number;
  headerSize?: number;
  masks?: boolean;
}): Uint8Array {
  const pixels = Math.min(spec.width * spec.height, 64) * (spec.bits / 8);
  const bytes = new Uint8Array(Math.max(spec.dataOffset, 54) + pixels + 4);
  const view = new DataView(bytes.buffer);
  bytes.set([0x42, 0x4d]);
  view.setUint32(10, spec.dataOffset, true);
  view.setUint32(14, spec.headerSize ?? 40, true);
  view.setInt32(18, spec.width, true);
  view.setInt32(22, spec.height, true);
  view.setUint16(26, 1, true);
  view.setUint16(28, spec.bits, true);
  if (spec.masks) {
    view.setUint32(30, 3, true);
    view.setUint32(54, 0x00ff0000, true);
    view.setUint32(58, 0x0000ff00, true);
    view.setUint32(62, 0x000000ff, true);
    view.setUint32(66, 0xff000000, true);
  }

  return bytes;
}

describe("parseArgs", () => {
  test("takes a bare path", () => {
    expect(parseArgs("shots/a.png")).toEqual({ path: "shots/a.png" });
  });

  test("reads a mode flag ahead of the path", () => {
    expect(parseArgs("--cells a.png")).toEqual({
      path: "a.png",
      mode: "cells",
    });
    expect(parseArgs("  --pixels   a.png ")).toEqual({
      path: "a.png",
      mode: "pixels",
    });
  });

  test("keeps a flag alone as a mode with no path", () => {
    expect(parseArgs("--cells")).toEqual({ path: "", mode: "cells" });
    expect(parseArgs("")).toEqual({ path: "" });
  });

  test("leaves an unknown flag in the path", () => {
    expect(parseArgs("--cellular a.png")).toEqual({ path: "--cellular a.png" });
  });

  test("keeps the spaces of a quoted or dragged-in path", () => {
    expect(parseArgs("'/tmp/my shot.png'")).toEqual({
      path: "/tmp/my shot.png",
    });
    expect(parseArgs('"/tmp/my shot.png"')).toEqual({
      path: "/tmp/my shot.png",
    });
    expect(parseArgs("/tmp/my\\ shot\\ \\(1\\).png")).toEqual({
      path: "/tmp/my shot (1).png",
    });
  });
});

describe("paths", () => {
  test("expands a leading tilde only", () => {
    expect(expandHome("~/a.png", "/home/me/")).toBe("/home/me/a.png");
    expect(expandHome("~", "/home/me")).toBe("/home/me");
    expect(expandHome("~other/a.png", "/home/me")).toBe("~other/a.png");
    expect(expandHome("a/~/b.png", "/home/me")).toBe("a/~/b.png");
    expect(expandHome("~/a.png", undefined)).toBe("~/a.png");
  });

  test("names a file by its last segment", () => {
    expect(baseName("/a/b/shot.png")).toBe("shot.png");
    expect(baseName("shot.png")).toBe("shot.png");
  });
});

describe("sizes", () => {
  test("reads what sips printed", () => {
    expect(
      parseSipsSize("/a/shot.png\n  pixelWidth: 1280\n  pixelHeight: 720\n"),
    ).toEqual({
      width: 1280,
      height: 720,
    });
  });

  test("reads the decimal sizes sips prints for an SVG or a PDF", () => {
    expect(
      parseSipsSize(
        "/a/logo.svg\n  pixelWidth: 120.000\n  pixelHeight: 60.000\n",
      ),
    ).toEqual({ width: 120, height: 60 });
  });

  test("reads the file's real format beside the size", () => {
    expect(
      parseSipsSize(
        "/a/x.png\n  format: jpeg\n  pixelWidth: 64\n  pixelHeight: 48\n",
      ),
    ).toEqual({ width: 64, height: 48, format: "jpeg" });
    expect(parseIdentifySize("4 4 PNG")).toEqual({
      width: 4,
      height: 4,
      format: "png",
    });
  });

  test("reads nothing from a file sips could not open", () => {
    expect(
      parseSipsSize(
        "/a/notes.txt\n  pixelWidth: <nil>\n  pixelHeight: <nil>\n",
      ),
    ).toBeUndefined();
    expect(parseSipsSize("")).toBeUndefined();
  });

  test("reads what identify printed", () => {
    expect(parseIdentifySize("640 480")).toEqual({ width: 640, height: 480 });
    expect(parseIdentifySize("")).toBeUndefined();
    expect(parseIdentifySize("0 0")).toBeUndefined();
  });
});

describe("fit", () => {
  test("fills the width of a wide picture", () => {
    expect(fit({ width: 1280, height: 720 }, 80, 40)).toEqual({
      columns: 80,
      rows: 23,
    });
  });

  test("fills the height of a tall picture", () => {
    expect(fit({ width: 720, height: 1280 }, 80, 20)).toEqual({
      columns: 23,
      rows: 20,
    });
  });

  test("draws a square picture twice as many columns as rows", () => {
    expect(fit({ width: 500, height: 500 }, 200, 30)).toEqual({
      columns: 60,
      rows: 30,
    });
  });

  test("never leaves the box or drops under one cell", () => {
    expect(fit({ width: 4000, height: 2 }, 80, 20)).toEqual({
      columns: 80,
      rows: 1,
    });
    expect(fit({ width: 2, height: 4000 }, 80, 20)).toEqual({
      columns: 1,
      rows: 20,
    });
    expect(fit({ width: 100, height: 100 }, 80, 0)).toEqual({
      columns: 1,
      rows: 1,
    });
  });
});

describe("decodeBmp", () => {
  test("decodes what sips writes for a picture with alpha", () => {
    const bitmap = decodeBmp(fromBase64(SIPS_ALPHA_BMP));

    expect([bitmap.width, bitmap.height]).toEqual([4, 4]);
    expect(pixel(bitmap, 0, 0)).toEqual([255, 0, 0, 255]);
    expect(pixel(bitmap, 1, 0)).toEqual([0, 255, 0, 255]);
    expect(pixel(bitmap, 2, 0)).toEqual([0, 0, 0, 0]);
    expect(pixel(bitmap, 0, 1)).toEqual([0, 0, 255, 255]);
    expect(pixel(bitmap, 3, 3)).toEqual([255, 255, 255, 128]);
  });

  test("decodes what ImageMagick writes, bottom row first, to the same pixels", () => {
    expect(decodeBmp(fromBase64(MAGICK_ALPHA_BMP))).toEqual(
      decodeBmp(fromBase64(SIPS_ALPHA_BMP)),
    );
  });

  test("decodes a 24-bit picture as opaque", () => {
    const bitmap = decodeBmp(fromBase64(SIPS_OPAQUE_BMP));

    expect([bitmap.width, bitmap.height]).toEqual([4, 4]);
    expect(pixel(bitmap, 0, 0)).toEqual([229, 1, 26, 255]);
    expect(pixel(bitmap, 3, 3)).toEqual([24, 0, 230, 255]);
  });

  test("takes a zero fourth byte as opaque only where no mask gives it a meaning", () => {
    // 1x1, 32 bits, blue 0x33 green 0x22 red 0x11, fourth byte zero.
    const plain = bmpHeader({ width: 1, height: 1, bits: 32, dataOffset: 54 });
    plain.set([0x33, 0x22, 0x11, 0x00], 54);
    expect(pixel(decodeBmp(plain), 0, 0)).toEqual([0x11, 0x22, 0x33, 255]);

    // The same pixel under an alpha mask is transparent (Codex round 1, #5).
    const masked = bmpHeader({
      width: 1,
      height: 1,
      bits: 32,
      dataOffset: 122,
      headerSize: 108,
      masks: true,
    });
    masked.set([0x33, 0x22, 0x11, 0x00], 122);
    expect(pixel(decodeBmp(masked), 0, 0)).toEqual([0x11, 0x22, 0x33, 0]);
  });

  test("refuses a header whose sizes are not a converter's before it allocates", () => {
    // 536870912 wide: the old stride arithmetic wrapped to a negative number.
    const wide = bmpHeader({
      width: 536870912,
      height: 2,
      bits: 32,
      dataOffset: 54,
    });
    expect(() => decodeBmp(wide.subarray(0, 54))).toThrow("a 536870912x2 BMP");
    expect(() =>
      decodeBmp(
        bmpHeader({ width: 1, height: 5000, bits: 24, dataOffset: 54 }),
      ),
    ).toThrow("a 1x5000 BMP");
  });

  test("refuses masks with no room for them and pixels that start inside the header", () => {
    const noRoom = bmpHeader({
      width: 1,
      height: 1,
      bits: 32,
      dataOffset: 66,
      headerSize: 108,
      masks: true,
    });
    expect(() => decodeBmp(noRoom.subarray(0, 68))).toThrow(
      "no room for its channel masks",
    );

    const inside = bmpHeader({ width: 1, height: 1, bits: 24, dataOffset: 20 });
    expect(() => decodeBmp(inside)).toThrow("a truncated BMP");
  });

  test("refuses a file that is not a BMP, a palette BMP and a cut one", () => {
    expect(() => decodeBmp(new Uint8Array(64))).toThrow("not a BMP file");

    const palette = fromBase64(SIPS_OPAQUE_BMP);
    palette[28] = 8;
    expect(() => decodeBmp(palette)).toThrow("a 8-bit BMP");

    expect(() =>
      decodeBmp(fromBase64(SIPS_OPAQUE_BMP).subarray(0, 90)),
    ).toThrow("a truncated BMP");
  });
});

describe("toCells", () => {
  const orange = [255, 136, 0, 255];
  const blue = [0, 0, 255, 255];
  const red = [255, 0, 0, 255];
  const white = [255, 255, 255, 255];
  const clear = [0, 0, 0, 0];

  test("packs two by two pixels a cell, split into the two colors that fit them best", () => {
    const sideBySide = toCells(
      bitmapOf(2, 2, (x) => (x === 0 ? orange : blue)),
    );
    expect([sideBySide.columns, sideBySide.rows]).toEqual([1, 1]);
    expect(words(sideBySide.cells)).toEqual([LEFT_HALF, 0xff8800, 0x0000ff]);

    const stacked = toCells(
      bitmapOf(2, 2, (_x, y) => (y === 0 ? orange : blue)),
    );
    expect(words(stacked.cells)).toEqual([TOP_HALF, 0xff8800, 0x0000ff]);
  });

  test("spells a split one way: the larger color is the foreground", () => {
    // One red quarter on white: white is drawn, red shows through the gap.
    const grid = toCells(
      bitmapOf(2, 2, (x, y) => (x === 0 && y === 0 ? red : white)),
    );

    expect(words(grid.cells)).toEqual([ALL_BUT_TOP_LEFT, 0xffffff, 0xff0000]);
  });

  test("draws a cell of one color as a full block, and averages a near-flat one", () => {
    expect(words(toCells(bitmapOf(2, 2, () => orange)).cells)).toEqual([
      FULL,
      0xff8800,
      0xff8800,
    ]);

    const nearFlat = toCells(
      bitmapOf(2, 2, (x) => [100 + x * 2, 100, 100, 255]),
    );
    expect(words(nearFlat.cells)).toEqual([FULL, 0x656464, 0x656464]);
  });

  test("shows the terminal's background through clear pixels", () => {
    // Three cells: clear over red, red in the top left alone, all clear.
    const grid = toCells(
      bitmapOf(6, 2, (x, y) => {
        if (x < 2) return y === 0 ? clear : red;
        if (x < 4) return x === 2 && y === 0 ? red : clear;

        return clear;
      }),
    );

    expect(words(grid.cells)).toEqual([
      ...[BOTTOM_HALF, 0xff0000, DEFAULT_COLOR],
      ...[TOP_LEFT, 0xff0000, DEFAULT_COLOR],
      ...[SPACE, DEFAULT_COLOR, DEFAULT_COLOR],
    ]);
  });

  test("leaves the missing quarters of an odd edge clear", () => {
    const grid = toCells(bitmapOf(3, 1, () => red));

    expect([grid.columns, grid.rows]).toEqual([2, 1]);
    expect(words(grid.cells)).toEqual([
      ...[TOP_HALF, 0xff0000, DEFAULT_COLOR],
      ...[TOP_LEFT, 0xff0000, DEFAULT_COLOR],
    ]);
  });

  test("keeps every color of a picture that needs few pairs", () => {
    const grid = toCells(
      bitmapOf(32, 2, (x) => [(x >> 1) * 16 + 1, 0, 0, 255]),
    );

    expect(words(grid.cells).slice(0, 6)).toEqual([
      ...[FULL, 0x010000, 0x010000],
      ...[FULL, 0x110000, 0x110000],
    ]);
  });

  test("draws a picture of too many pairs from the largest palette that fits", () => {
    // 64 x 64 cells, every cell its own two colors: 4096 pairs untouched.
    const original = bitmapOf(128, 128, (x, y) => [
      (x >> 1) * 4,
      (y >> 1) * 4,
      x % 2 === 0 ? 0 : 255,
      255,
    ]);
    const packed = words(toCells(original).cells);
    const pairs = new Set<string>();
    let worst = 0;
    for (let cell = 0; cell < 64 * 64; cell++) {
      const [, foreground, background] = packed.slice(cell * 3, cell * 3 + 3);
      pairs.add(`${foreground},${background}`);
      // Blue 255 on the right is the foreground; red and green are the cell's.
      const wanted = (((cell % 64) * 4) << 16) | (((cell >> 6) * 4) << 8) | 255;
      for (const shift of [16, 8, 0]) {
        const off = Math.abs(
          ((foreground! >> shift) & 255) - ((wanted >> shift) & 255),
        );
        worst = Math.max(worst, off);
      }
    }

    expect(packed).toHaveLength(64 * 64 * 3);
    expect(pairs.size).toBeLessThanOrEqual(MAX_PAIRS);
    // The budget is used, not just respected, and no color lands far off.
    expect(pairs.size).toBeGreaterThan(MAX_PAIRS / 2);
    expect(worst).toBeLessThanOrEqual(24);
  });

  test("honours a smaller budget of pairs", () => {
    const grid = toCells(
      bitmapOf(32, 32, (x, y) => [x * 8, y * 8, 0, 255]),
      4,
    );
    const packed = words(grid.cells);
    const pairs = new Set<string>();
    for (let at = 0; at < packed.length; at += 3)
      pairs.add(`${packed[at + 1]},${packed[at + 2]}`);

    expect(pairs.size).toBeLessThanOrEqual(4);
    expect(pairs.size).toBeGreaterThan(1);
  });
});

describe("base64", () => {
  test("round-trips bytes past one chunk", () => {
    const bytes = new Uint8Array(100_000).map((_, i) => (i * 31) % 256);

    expect(fromBase64(toBase64(bytes))).toEqual(bytes);
    expect(toBase64(new Uint8Array([0x00, 0x25, 0x88]))).toBe("ACWI");
  });
});

describe("findImagePaths", () => {
  test("finds a path written bare, in backticks, in a link, bold, or as a file URL", () => {
    const text =
      "Saved shots/a.png and `out/b.JPG`, see [the chart](docs/c.webp), " +
      "**~/d.heic**, ![alt](./e.tiff) and file:///tmp/f.gif.";

    expect(findImagePaths(text, 10)).toEqual([
      "shots/a.png",
      "out/b.JPG",
      "docs/c.webp",
      "~/d.heic",
      "./e.tiff",
      "/tmp/f.gif",
    ]);
  });

  test("keeps a path's own parentheses and drops the sentence's and the link's", () => {
    expect(findImagePaths("![x](shots/a(1).png)", 4)).toEqual([
      "shots/a(1).png",
    ]);
    expect(findImagePaths('[x](b.png "a title")', 4)).toEqual(["b.png"]);
    expect(findImagePaths("(see c.png), (d.png).", 4)).toEqual([
      "c.png",
      "d.png",
    ]);
    expect(findImagePaths("shots/f(1).png and g(2)(3).png", 4)).toEqual([
      "shots/f(1).png",
      "g(2)(3).png",
    ]);
  });

  test("names a file once, and no more files than the limit", () => {
    expect(findImagePaths("a.png b.png a.png c.png d.png", 3)).toEqual([
      "a.png",
      "b.png",
      "c.png",
    ]);
  });

  test("leaves out web addresses, other files, and a suffix with no name", () => {
    expect(
      findImagePaths(
        "https://example.com/logo.png notes.txt main.ts .png dir/.png png",
        10,
      ),
    ).toEqual([]);
  });

  test("leaves out what a renderer would have to run: SVG and PDF", () => {
    expect(findImagePaths("logo.svg report.pdf icon.SVG", 10)).toEqual([]);
  });
});

describe("previews", () => {
  test("tells a path inside a directory from one beside or above it", () => {
    expect(isInside("/work/a.png", "/work")).toBe(true);
    expect(isInside("/work/deep/a.png", "/work/")).toBe(true);
    expect(isInside("/work", "/work")).toBe(true);
    expect(isInside("/workshop/a.png", "/work")).toBe(false);
    expect(isInside("/a.png", "/work")).toBe(false);
    expect(isInside("/work/../etc/a.png", "/work/deep")).toBe(false);
  });

  test("takes a bitmap's format and no renderer's", () => {
    for (const format of ["png", "jpeg", "gif", "tiff", "bmp", "heic", "webp"])
      expect(isBitmapFormat(format)).toBe(true);
    for (const format of ["svg", "pdf", "eps", "", undefined])
      expect(isBitmapFormat(format)).toBe(false);
  });
});
