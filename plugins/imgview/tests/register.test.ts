import { expect, mock, test } from "claude-code/testing";
import type { On, RenderElement } from "claude-code";
import type { Engine } from "claude-code/testing";

import { toBase64 } from "../hooks/picture";

/**
 * What a path leads to in the fake file system. An `image` is 200 by 100 in
 * the format its suffix names; the others are what a preview has to refuse.
 */
type Kind =
  | "image"
  | "text"
  | "dir"
  // A PDF whatever its suffix: sips names a file's real format.
  | "pdf"
  // A picture of 40000 by 40000 pixels.
  | "huge"
  // A picture file of 100 MiB.
  | "heavy"
  // A picture whose path lands outside the working directory.
  | "link-out"
  // A JPEG whatever its suffix.
  | "jpeg"
  // A picture the converter writes at another size than it was asked.
  | "misconverted"
  // A picture of 8000 by 6250 pixels: 50 megapixels.
  | "large"
  // A small picture that is 100 MiB by the time it is copied.
  | "grows"
  // A picture replaced by another once it has been looked up.
  | "moved"
  // A picture `cp` fails on, though a file is left where the copy was to go.
  | "uncopyable"
  // A picture replaced by a pipe once it has been looked up.
  | "piped";

const FORMATS: Record<string, string> = {
  png: "png",
  jpg: "jpeg",
  jpeg: "jpeg",
  gif: "gif",
  webp: "webp",
  heic: "heic",
  svg: "svg",
};

/** A solid orange 24-bit BMP, bottom row first, as a converter would write. */
function bmp(width: number, height: number): string {
  const stride = (width * 3 + 3) & ~3;
  const bytes = new Uint8Array(54 + stride * height);
  const view = new DataView(bytes.buffer);
  bytes.set([0x42, 0x4d]);
  view.setUint32(10, 54, true);
  view.setUint32(14, 40, true);
  view.setInt32(18, width, true);
  view.setInt32(22, height, true);
  view.setUint16(26, 1, true);
  view.setUint16(28, 24, true);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++)
      bytes.set([0x00, 0x88, 0xff], 54 + y * stride + x * 3);
  }

  return toBase64(bytes);
}

/**
 * The host beneath the mod: the working directory `/work`, a file system of
 * `files`, a `cp`, a `sips` that measures and converts the pictures among
 * them, and no ImageMagick. With `isWriting` false no converter's output ever
 * appears.
 */
function world(
  on: On,
  files: Record<string, Kind>,
  env: Record<string, string> = {},
  isWriting = true,
  // A barrier every conversion waits at before it writes its file.
  barrier?: Promise<void>,
  extra: {
    // Every name the mod picks for a copy is already taken by someone else.
    isSquatted?: boolean;
    // Looking at this path waits at this gate.
    statGate?: { path: string; gate: Promise<void> };
  } = {},
) {
  // The engine's clock, moved by the test alone.
  const clock = mock.clock(on, { now: 1_700_000_000_000 });
  const runs: string[][] = [];
  // The timeout each run was given, beside `runs`.
  const timeouts: (number | undefined)[] = [];
  const opened: {
    id: string;
    title?: string;
    rows?: number;
    columns?: number;
  }[] = [];
  const written = new Map<string, string>();
  // Copies `cp` made: where each one is, and which file it is a copy of.
  const copies = new Map<string, string>();
  // Every copy ever made, kept after its removal for a test to trace.
  const everCopied = new Map<string, string>();
  // How many `sips` are running, and the most that ever ran at once.
  let running = 0;
  let peak = 0;
  const realOf = (name: string) =>
    files[name] === "link-out"
      ? `/elsewhere/${name.split("/").pop()}`
      : name.startsWith("/")
        ? name
        : `/work/${name}`;
  /** The file a path is, itself or as a copy; undefined for any other path. */
  const nameAt = (path: string) =>
    copies.get(path) ??
    Object.keys(files).find((name) => realOf(name) === path);
  const sizeOf = (name: string) =>
    files[name] === "heavy" ? 100 * 1024 * 1024 : 10;
  // How often each file was looked at: a `moved` one changes after the first.
  const looks = new Map<string, number>();

  mock.env(on, {
    HOME: "/home/me",
    TMPDIR: "/tmp/t/",
    TERM: "xterm-256color",
    ...env,
  });
  on("fs.stat", async (_$, e) => {
    if (extra.statGate?.path === e.path) await extra.statGate.gate;
    const directory = {
      kind: "dir" as const,
      size: 0,
      mtimeMs: 7,
      isLink: false,
    };
    if (e.path === "/work" || e.path === "/other")
      return { value: { ...directory, realPath: e.path } };
    const copied = copies.get(e.path);
    if (copied !== undefined) {
      return {
        value: {
          kind: "file" as const,
          size: files[copied] === "grows" ? 100 * 1024 * 1024 : sizeOf(copied),
          mtimeMs: 9,
          isLink: false,
          realPath: e.path,
        },
      };
    }
    // The engine resolves a relative path under its working directory first.
    const name = Object.keys(files).find(
      (key) =>
        e.path === key ||
        e.path === realOf(key) ||
        (!key.startsWith("/") && e.path.endsWith(`/${key}`)),
    );
    if (name === undefined) return { deny: "no such file" };
    const kind = files[name];
    if (kind === "dir")
      return { value: { ...directory, realPath: realOf(name) } };
    const seen = looks.get(name) ?? 0;
    looks.set(name, seen + 1);

    return {
      value: {
        kind:
          kind === "piped" && seen > 0 ? ("other" as const) : ("file" as const),
        size: sizeOf(name),
        mtimeMs: kind === "moved" && seen > 0 ? 8 : 7,
        isLink: kind === "link-out",
        realPath: realOf(name),
      },
    };
  });
  on("process.run", async (_$, e) => {
    runs.push([...e.argv]);
    timeouts.push(e.init?.timeoutMs);
    const tool = e.argv[0];
    if (tool !== "sips" && tool !== "rm" && tool !== "cp")
      return { deny: "not installed" };
    const done = (stdout = "", exitCode = 0) => ({
      value: {
        exitCode,
        stdout,
        stderr: "",
        isStdoutTruncated: false,
        isStderrTruncated: false,
      },
    });
    if (tool === "cp") {
      const name = nameAt(e.argv[1]!);
      if (name !== undefined) {
        copies.set(e.argv[2]!, name);
        everCopied.set(e.argv[2]!, name);
      }

      return done(
        "",
        name !== undefined && files[name] === "uncopyable" ? 1 : 0,
      );
    }
    if (tool === "rm") {
      for (const path of e.argv.slice(1)) copies.delete(path);

      return done();
    }

    running++;
    peak = Math.max(peak, running);
    try {
      const source = e.argv.map(nameAt).find((name) => name !== undefined);
      const kind = source === undefined ? undefined : files[source];
      const isPicture = kind !== undefined && kind !== "text" && kind !== "dir";
      if (e.argv[1] === "-g") {
        const suffix = source?.split(".").pop() ?? "";
        const format =
          kind === "pdf" || kind === "jpeg"
            ? kind
            : (FORMATS[suffix] ?? suffix);
        const side =
          kind === "huge"
            ? [40000, 40000]
            : kind === "large"
              ? [8000, 6250]
              : [200, 100];

        return done(
          `${source}\n  format: ${format}\n` +
            `  pixelWidth: ${isPicture ? side[0] : "<nil>"}\n` +
            `  pixelHeight: ${isPicture ? side[1] : "<nil>"}\n`,
        );
      }
      if (e.argv[1] === "-s") await barrier;
      if (e.argv[1] === "-s" && isPicture) {
        const z = e.argv.indexOf("-z");
        const out = e.argv[e.argv.indexOf("--out") + 1]!;
        written.set(
          out,
          e.argv[3] === "png"
            ? "png"
            : bmp(
                Number(e.argv[z + 2]) + (kind === "misconverted" ? 2 : 0),
                Number(e.argv[z + 1]),
              ),
        );
      }

      return done();
    } finally {
      running--;
    }
  });
  on("fs.exists", (_$, e) => ({
    value:
      (extra.isSquatted === true && e.path.endsWith(".snap")) ||
      (isWriting && written.has(e.path)),
  }));
  on("session.start", (_$, e) => ({ cwd: e.cwd }));
  on("command.register", (_$, e) => ({ value: { command: e.name } }));
  on("fs.read", (_$, e) => ({ value: { base64: written.get(e.path) ?? "" } }));
  // The engine's own drawing of a reply, which the mod wraps.
  on("ui.render", { component: "AssistantMessage" }, ($, e) => {
    const { Text } = $.ui.resolve(e);

    return h(Text, {}, "ENGINE ROW") as RenderElement;
  });
  on("ui.open", (_$, e) => {
    opened.push(e);

    return { value: { isPlaced: true as const } };
  });

  return {
    clock,
    runs,
    timeouts,
    opened,
    /** The most `sips` that ran at once. */
    peak: () => peak,
    /** The file a run's path names, a copy traced back to what it copies. */
    origin: (path: string | undefined) => {
      const name =
        path === undefined ? undefined : (everCopied.get(path) ?? nameAt(path));

      return name === undefined ? path : realOf(name);
    },
  };
}

async function start($: Engine) {
  await $.session.start({
    cwd: "/work",
    surface: "terminal",
    isInteractive: true,
  });
}

function img($: Engine, args: string) {
  return $.command.run({
    command: "img",
    args,
    origin: { kind: "composer" },
    presentation: { isFullscreen: true, columns: 160 },
  });
}

function pane($: Engine, bodyColumns: number, bodyRows: number) {
  return $.ui.mount({
    plugin: "imgview",
    surface: "terminal",
    component: "Pane",
    requestId: "imgview",
    props: {
      title: "imgview",
      isFocused: false,
      bodyColumns,
      placement: "dock",
      scroll: { offset: 0, bodyRows },
      view: {},
    },
    viewport: { columns: 160, rows: 50, isFullscreen: true },
  });
}

test("says how to use it when given no path and nothing is shown", async ($, on) => {
  const { opened, runs } = world(on, {});
  await start($);

  expect((await img($, "")).text).toBe(
    "Usage: /img [--cells|--pixels] <image path>",
  );
  expect(opened).toHaveLength(0);
  expect(runs).toHaveLength(0);
});

test("draws a picture as half-block cells on a terminal without graphics", async ($, on) => {
  const { opened, runs } = world(
    on,
    { "shot.png": "image" },
    { TERM_PROGRAM: "iTerm.app" },
  );
  await start($);

  expect((await img($, "shot.png")).text).toBe("shot.png · 200×100 · cells");
  expect(opened).toHaveLength(1);
  expect(opened[0]).toMatchObject({ id: "imgview", title: "shot.png" });

  const ui = await pane($, 40, 21);
  const raster = await ui.find({ type: "Raster" });
  // 200x100 in 40 columns: 40 cells by 10, each two pixels wide and tall.
  expect(raster?.props).toMatchObject({ columns: 40, rows: 10 });
  expect(String(raster?.props.cells)).toHaveLength(40 * 10 * 12 * (4 / 3));
  expect(
    await ui.find({ type: "Text", text: "shot.png · 200×100" }),
  ).toBeDefined();
  expect(await ui.find({ type: "Image" })).toBeUndefined();

  const convert = runs.find((argv) => argv[1] === "-s");
  expect(convert?.slice(0, 8)).toEqual([
    "sips",
    "-s",
    "format",
    "bmp",
    "-z",
    "20",
    "80",
    "/work/shot.png",
  ]);
  expect(convert?.[9]).toMatch(/^\/tmp\/t\/claude-imgview-[0-9a-f-]{36}\.bmp$/);
  // The converted file is read once and removed.
  expect(runs).toContainEqual(["rm", "-f", convert![9]!]);
});

test("converts once for a size and again when the pane's size changes", async ($, on) => {
  const { runs } = world(on, { "shot.png": "image" });
  await start($);
  await img($, "shot.png");
  const conversions = () => runs.filter((argv) => argv[1] === "-s").length;

  await (await pane($, 40, 21)).unmount();
  await (await pane($, 40, 21)).unmount();
  expect(conversions()).toBe(1);

  const ui = await pane($, 80, 11);
  expect((await ui.find({ type: "Raster" }))?.props).toMatchObject({
    columns: 40,
    rows: 10,
  });
  expect(conversions()).toBe(1);
  await ui.unmount();

  const narrow = await pane($, 20, 11);
  expect((await narrow.find({ type: "Raster" }))?.props).toMatchObject({
    columns: 20,
    rows: 5,
  });
  expect(conversions()).toBe(2);
});

test("hands a PNG to a terminal that draws pixels, by its absolute path", async ($, on) => {
  const { runs } = world(on, { "shot.png": "image" }, { TERM: "xterm-kitty" });
  await start($);

  expect((await img($, "shot.png")).text).toBe("shot.png · 200×100 · pixels");
  const ui = await pane($, 40, 21);
  const image = await ui.find({ type: "Image" });
  expect(image?.props).toMatchObject({
    columns: 40,
    rows: 10,
    source: { file: "/work/shot.png", format: "png", generation: 7 },
  });
  expect(await ui.find({ type: "Raster" })).toBeUndefined();
  expect(runs.filter((argv) => argv[1] === "-s")).toHaveLength(0);
});

test("converts a picture that is not a PNG before a pixel terminal reads it", async ($, on) => {
  const { runs } = world(
    on,
    { "/photos/cat.jpg": "image" },
    { TERM_PROGRAM: "ghostty" },
  );
  await start($);
  await img($, "/photos/cat.jpg");

  const ui = await pane($, 40, 21);
  const source = (await ui.find({ type: "Image" }))?.props.source as {
    file: string;
  };
  expect(source.file).toMatch(/^\/tmp\/t\/claude-imgview-[0-9a-f-]{36}\.png$/);
  expect(runs).toContainEqual([
    "sips",
    "-s",
    "format",
    "png",
    "/photos/cat.jpg",
    "--out",
    source.file,
  ]);
});

test("draws cells under tmux, which passes no pixels through", async ($, on) => {
  world(
    on,
    { "shot.png": "image" },
    { TERM: "xterm-kitty", TMUX: "/tmp/tmux-501/default,1,0" },
  );
  await start($);

  expect((await img($, "shot.png")).text).toBe("shot.png · 200×100 · cells");
});

test("takes the mode a flag names over the terminal's, and re-draws the shown picture with it", async ($, on) => {
  world(on, { "shot.png": "image" }, { TERM: "xterm-kitty" });
  await start($);

  expect((await img($, "--cells shot.png")).text).toBe(
    "shot.png · 200×100 · cells",
  );
  const ui = await pane($, 40, 21);
  expect(await ui.find({ type: "Raster" })).toBeDefined();

  // The open pane follows: the same drawing now holds the Image.
  expect((await img($, "--pixels")).text).toBe("shot.png · 200×100 · pixels");
  expect(await ui.find({ type: "Image" })).toBeDefined();
  expect(await ui.find({ type: "Raster" })).toBeUndefined();
});

test("finds a path under the home directory, with a mention mark, or with spaces", async ($, on) => {
  world(on, {
    "/home/me/a.png": "image",
    "docs/b.png": "image",
    "/tmp/my shot.png": "image",
  });
  await start($);

  expect((await img($, "~/a.png")).text).toBe("a.png · 200×100 · cells");
  expect((await img($, "@docs/b.png")).text).toBe("b.png · 200×100 · cells");
  expect((await img($, "/tmp/my\\ shot.png")).text).toBe(
    "my shot.png · 200×100 · cells",
  );
});

test("names what it could not show, and opens nothing", async ($, on) => {
  const { opened } = world(on, { "notes.txt": "text", shots: "dir" });
  await start($);

  expect((await img($, "gone.png")).text).toBe("img: no such file: gone.png");
  expect((await img($, "shots")).text).toBe("img: not a file: shots");
  expect((await img($, "notes.txt")).text).toBe(
    "img: not an image sips or ImageMagick can read: notes.txt",
  );
  expect(opened).toHaveLength(0);
});

test("says why in the pane when no converter can paint the picture", async ($, on) => {
  const { runs } = world(on, { "shot.png": "image" }, {}, false);
  await start($);
  await img($, "shot.png");

  const ui = await pane($, 40, 21);
  expect(await ui.find({ type: "Raster" })).toBeUndefined();
  expect(
    await ui.find({
      type: "Text",
      text: /neither sips nor ImageMagick could convert it/,
    }),
  ).toBeDefined();
  expect(
    runs.some((argv) => argv[0] === "magick" && argv.includes("80x20!")),
  ).toBe(true);
});

test("tells a surface that is not a terminal that it draws there only", async ($, on) => {
  world(on, { "shot.png": "image" });
  await start($);
  await img($, "shot.png");

  const ui = await $.ui.mount({
    plugin: "imgview",
    surface: "desktop",
    component: "Pane",
    requestId: "imgview",
    props: {
      title: "imgview",
      isFocused: false,
      bodyColumns: 40,
      placement: "dock",
      scroll: { offset: 0, bodyRows: 21 },
      view: {},
    },
  });
  expect(await ui.find({ type: "Text", text: /terminal only/ })).toBeDefined();
});

function reply(
  $: Engine,
  text: string,
  where: {
    columns?: number;
    isFullscreen?: boolean;
    isOffScreen?: boolean;
    id?: string;
  } = {},
) {
  return $.ui.mount({
    plugin: "imgview",
    surface: "terminal",
    component: "AssistantMessage",
    requestId: where.id ?? "reply-1",
    props: {
      text,
      isFirstOfReply: true,
      ...(where.isOffScreen ? { onScreen: null } : {}),
    },
    viewport: {
      columns: where.columns ?? 120,
      rows: 50,
      isFullscreen: where.isFullscreen ?? true,
    },
  });
}

type Node = {
  type?: string;
  props?: Record<string, unknown>;
  hover?: unknown;
  children?: unknown;
};

/**
 * The hidden boxes of a drawing, the cards a hover reveals: each one's props
 * with the `hover` the tree carries beside them.
 */
async function cards(ui: Awaited<ReturnType<typeof reply>>) {
  const found: Record<string, unknown>[] = [];
  const walk = (node: unknown) => {
    if (Array.isArray(node)) return node.forEach(walk);
    if (typeof node !== "object" || node === null) return;
    const { props, hover, children } = node as Node;
    if (props?.display === "none") found.push({ ...props, hover });
    walk(children);
  };
  walk(await ui.drawn());

  return found;
}

test("draws a chip under a reply that names an image file, with its picture in a hidden card", async ($, on) => {
  const { runs, origin } = world(on, {
    "shot.png": "image",
    "notes.txt": "text",
  });
  await start($);

  const ui = await reply(
    $,
    "Saved the chart to `shot.png`; notes in notes.txt.",
  );
  expect(await ui.find({ type: "Text", text: "ENGINE ROW" })).toBeDefined();
  const chips = await ui.findAll({ type: "Button" });
  expect(chips.map((chip) => chip.props.label)).toEqual(["▣ shot.png"]);

  // 200x100 in a card of at most 80 by 24 cells: 80 by 20.
  expect((await ui.find({ type: "Raster" }))?.props).toMatchObject({
    columns: 80,
    rows: 20,
  });
  const convert = runs.find((argv) => argv[1] === "-s");
  expect(convert?.slice(4, 7)).toEqual(["-z", "40", "160"]);
  expect(origin(convert?.[7])).toBe("/work/shot.png");

  // The card sits over the rows above the chip, shown by the hover alone.
  const [card, ...others] = await cards(ui);
  expect(others).toHaveLength(0);
  expect(card).toMatchObject({
    position: "absolute",
    top: -23,
    left: 0,
    hover: { display: "flex" },
  });
  expect(
    await ui.find({ type: "Text", text: /^shot\.png · 200×100 +$/ }),
  ).toBeDefined();
});

test("leaves a reply as the engine drew it when it names no image that exists", async ($, on) => {
  const { runs } = world(on, { "fake.png": "text" });
  await start($);

  const plain = await reply($, "Nothing to see in main.ts or gone.png.");
  expect(await plain.drawn()).toMatchObject({ type: "Text" });
  expect(runs).toHaveLength(0);
  await plain.unmount();

  // A file named like a picture that no converter reads loses its chip.
  const fake = await reply($, "See fake.png.");
  expect(await fake.findAll({ type: "Button" })).toHaveLength(0);
  expect(await fake.find({ type: "Text", text: "ENGINE ROW" })).toBeDefined();
  // sips could not read it, and nothing else is asked.
  expect(runs.filter((argv) => argv[0] === "magick")).toEqual([]);
});

test("draws no chip on the main screen, which reports no pointer", async ($, on) => {
  const { runs } = world(on, { "shot.png": "image" });
  await start($);

  const ui = await reply($, "Saved shot.png.", { isFullscreen: false });
  expect(await ui.drawn()).toMatchObject({ type: "Text" });
  expect(runs).toHaveLength(0);
});

test("converts nothing for a reply that is off screen", async ($, on) => {
  const { runs } = world(on, { "shot.png": "image" });
  await start($);

  const ui = await reply($, "Saved shot.png.", { isOffScreen: true });
  expect(await ui.findAll({ type: "Button" })).toHaveLength(1);
  expect(await ui.find({ type: "Raster" })).toBeUndefined();
  expect(await ui.find({ type: "Text", text: /^Rendering…/ })).toBeDefined();
  expect(runs).toHaveLength(0);
});

test("opens the pane on the picture when its chip is clicked", async ($, on) => {
  const { opened } = world(on, { "shot.png": "image" });
  await start($);

  const ui = await reply($, "Saved shot.png.");
  await ui.press({ key: "imgview-open-0" });
  expect(opened).toHaveLength(1);
  expect(opened[0]).toMatchObject({ id: "imgview", title: "shot.png" });

  const shownPane = await pane($, 40, 21);
  expect((await shownPane.find({ type: "Raster" }))?.props).toMatchObject({
    columns: 40,
    rows: 10,
  });
});

test("hands a pixel terminal a small PNG of its own making in the card, never the file the reply named", async ($, on) => {
  const { runs, origin } = world(
    on,
    { "shot.png": "image", "cat.jpg": "image" },
    { TERM: "xterm-kitty" },
  );
  await start($);

  const ui = await reply($, "Compare shot.png with cat.jpg.");
  const images = await ui.findAll({ type: "Image" });
  expect(images).toHaveLength(2);
  expect(await ui.findAll({ type: "Raster" })).toHaveLength(0);
  for (const image of images) {
    expect(image.props).toMatchObject({ columns: 80, rows: 20 });
    const source = image.props.source as { file: string; format: string };
    expect(source.format).toBe("png");
    expect(source.file).toMatch(
      /^\/tmp\/t\/claude-imgview-[0-9a-f-]{36}\.png$/,
    );
  }

  // 80 by 20 cells at 10 by 20 pixels a cell, converted from the copy.
  const conversions = runs.filter((argv) => argv[1] === "-s");
  expect(conversions.map((argv) => argv.slice(2, 7))).toEqual([
    ["format", "png", "-z", "400", "800"],
    ["format", "png", "-z", "400", "800"],
  ]);
  expect(conversions.map((argv) => origin(argv[7]))).toEqual([
    "/work/shot.png",
    "/work/cat.jpg",
  ]);
});

test("draws four chips at most, and keeps every card at the row's left edge", async ($, on) => {
  world(on, {
    "a.png": "image",
    "b.png": "image",
    "c.png": "image",
    "d.png": "image",
    "e.png": "image",
  });
  await start($);

  const ui = await reply($, "a.png b.png c.png d.png e.png");
  const chips = await ui.findAll({ type: "Button" });
  expect(chips.map((chip) => chip.props.label)).toEqual([
    "▣ a.png",
    "▣ b.png",
    "▣ c.png",
    "▣ d.png",
  ]);
  // Each chip is seven cells and a gap of two past the one before it.
  expect((await cards(ui)).map((card) => card.left)).toEqual([0, -9, -18, -27]);
});

test("fits the card to a narrow terminal", async ($, on) => {
  world(on, { "shot.png": "image" });
  await start($);

  const ui = await reply($, "Saved shot.png.", { columns: 40 });
  expect((await ui.find({ type: "Raster" }))?.props).toMatchObject({
    columns: 28,
    rows: 7,
  });
});

// Codex review, round 1, finding 1.
test("removes the PNG it converted when another picture replaces it, and never a picture of the person's", async ($, on) => {
  const { runs } = world(
    on,
    {
      "/home/me/claude-imgview-family.png": "image",
      "/photos/cat.jpg": "image",
      "shot.png": "image",
    },
    { TERM: "xterm-kitty" },
  );
  await start($);
  const removed = () =>
    runs.filter((argv) => argv[0] === "rm").map((argv) => argv[2]);

  // Shown as it is: the terminal reads the person's own file.
  await img($, "/home/me/claude-imgview-family.png");
  // A JPEG is converted to a temporary PNG first.
  await img($, "/photos/cat.jpg");
  expect(removed()).toEqual([]);

  await img($, "shot.png");
  expect(removed()).toHaveLength(1);
  expect(removed()[0]).toMatch(/^\/tmp\/t\/claude-imgview-[0-9a-f-]{36}\.png$/);
});

// Codex review, round 1, finding 2: what a reply names is looked at with no
// action of the person's, so only a bitmap inside the working directory is.
test("previews no file outside the working directory, by its path or through a link", async ($, on) => {
  const { runs } = world(on, {
    "/etc/outside.png": "image",
    "/home/me/mine.png": "image",
    "escape.png": "link-out",
  });
  await start($);

  const ui = await reply($, "See /etc/outside.png, ~/mine.png and escape.png.");
  expect(await ui.findAll({ type: "Button" })).toHaveLength(0);
  expect(await ui.drawn()).toMatchObject({ type: "Text" });
  expect(runs).toHaveLength(0);
});

test("previews bitmaps only: no SVG by its suffix, no PDF by its content", async ($, on) => {
  const { runs } = world(on, { "logo.svg": "image", "scan.png": "pdf" });
  await start($);

  const ui = await reply($, "See logo.svg and scan.png.");
  expect(await ui.findAll({ type: "Button" })).toHaveLength(0);
  // The SVG is never opened; the PDF is asked its format and no more.
  expect(runs.filter((argv) => argv.includes("/work/logo.svg"))).toEqual([]);
  expect(runs.filter((argv) => argv[1] === "-s")).toEqual([]);
});

test("previews no file too heavy and no picture too large", async ($, on) => {
  const { runs } = world(on, { "heavy.png": "heavy", "huge.png": "huge" });
  await start($);

  const ui = await reply($, "See heavy.png and huge.png.");
  expect(await ui.findAll({ type: "Button" })).toHaveLength(0);
  expect(runs.filter((argv) => argv.includes("/work/heavy.png"))).toEqual([]);
  expect(runs.filter((argv) => argv[1] === "-s")).toEqual([]);
});

test("gives a mentioned file to sips alone, under a short timeout", async ($, on) => {
  // No converter's output appears: /img would go on to ImageMagick here.
  const { runs, timeouts } = world(on, { "shot.png": "image" }, {}, false);
  await start($);

  const ui = await reply($, "Saved shot.png.");
  expect(await ui.findAll({ type: "Button" })).toHaveLength(0);
  expect(runs.length).toBeGreaterThan(0);
  expect(runs.filter((argv) => argv[0] === "magick")).toEqual([]);
  for (const [index, argv] of runs.entries()) {
    if (argv[0] === "sips") expect(timeouts[index]).toBeLessThanOrEqual(5000);
  }
});

// Codex review, round 1, finding 3.
test(
  "settles with more cards on screen than it keeps: none is converted twice",
  { timeoutMs: 20000 },
  async ($, on) => {
    const files: Record<string, Kind> = {};
    const replies: string[] = [];
    for (let n = 0; n < 9; n++) {
      const names = [0, 1, 2, 3].map((k) => `p${n}-${k}.png`);
      for (const name of names) files[name] = "image";
      replies.push(names.join(" "));
    }
    const { runs, origin } = world(on, files);
    await start($);

    // 36 pictures on screen at once, four more than are kept.
    const drawings = [];
    for (const [n, text] of replies.entries()) {
      drawings.push(await reply($, text, { id: `reply-${n}` }));
    }
    const conversions = runs
      .filter((argv) => argv[1] === "-s")
      .map((argv) => origin(argv[7]));
    expect(new Set(conversions).size).toBe(conversions.length);
    expect(conversions.length).toBeLessThanOrEqual(32);

    let chips = 0;
    for (const ui of drawings)
      chips += (await ui.findAll({ type: "Raster" })).length;
    expect(chips).toBe(32);
  },
);

// Codex review, round 1, findings 6, 7 and 10.
test("hands the terminal a PNG by its content, not its suffix", async ($, on) => {
  const { runs } = world(
    on,
    { "renamed.png": "jpeg" },
    { TERM: "xterm-kitty" },
  );
  await start($);

  // /img: converted first, as any JPEG is.
  await img($, "renamed.png");
  const shownPane = await pane($, 40, 21);
  const source = (await shownPane.find({ type: "Image" }))?.props.source as {
    file: string;
  };
  expect(source.file).toMatch(/^\/tmp\/t\/claude-imgview-[0-9a-f-]{36}\.png$/);
  expect(runs).toContainEqual([
    "sips",
    "-s",
    "format",
    "png",
    "/work/renamed.png",
    "--out",
    source.file,
  ]);

  // The hover card: a PNG the mod converted, never the file itself.
  const ui = await reply($, "Saved renamed.png.");
  const card = (await ui.find({ type: "Image" }))?.props.source as {
    file: string;
  };
  expect(card.file).toMatch(/^\/tmp\/t\/claude-imgview-[0-9a-f-]{36}\.png$/);
  expect(card.file).not.toBe(source.file);
});

for (const variable of ["SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY"]) {
  test(`draws cells across ssh (${variable}), where the terminal cannot read this machine's files`, async ($, on) => {
    world(
      on,
      { "shot.png": "image" },
      { TERM: "xterm-kitty", [variable]: "10.0.0.2 51022 10.0.0.9 22" },
    );
    await start($);

    expect((await img($, "shot.png")).text).toBe("shot.png · 200×100 · cells");
    const ui = await reply($, "Saved shot.png.");
    expect(await ui.find({ type: "Image" })).toBeUndefined();
    expect(await ui.findAll({ type: "Raster" })).toHaveLength(1);
  });
}

test("refuses a conversion that came back another size than asked", async ($, on) => {
  world(on, { "odd.png": "misconverted" });
  await start($);
  await img($, "odd.png");

  const ui = await pane($, 40, 21);
  expect(await ui.find({ type: "Raster" })).toBeUndefined();
  expect(
    await ui.find({
      type: "Text",
      text: /the converter wrote 82x20, not 80x20/,
    }),
  ).toBeDefined();
});

// Codex review, round 1, finding 4.
test("converts a pane size once however the pane is resized meanwhile, and keeps the size last asked", async ($, on) => {
  let release = () => {};
  const barrier = new Promise<void>((resolve) => {
    release = resolve;
  });
  const { runs } = world(on, { "shot.png": "image" }, {}, true, barrier);
  await start($);
  await img($, "shot.png");
  const sizes = () =>
    runs.filter((argv) => argv[1] === "-s").map((argv) => argv[6]);

  // 40 columns, then 20, then 40 again, each before any conversion ends.
  for (const columns of [40, 20, 40]) {
    const ui = await pane($, columns, 21);
    expect(await ui.find({ type: "Text", text: "Rendering…" })).toBeDefined();
    await ui.unmount();
  }
  expect(sizes()).toEqual(["80", "40"]);

  release();
  const ui = await pane($, 40, 21);
  expect((await ui.find({ type: "Raster" }))?.props).toMatchObject({
    columns: 40,
    rows: 10,
  });
  expect(sizes()).toEqual(["80", "40"]);
});

// Codex review, round 2, finding 1.
test("converts one mentioned picture at a time", async ($, on) => {
  let release = () => {};
  const barrier = new Promise<void>((resolve) => {
    release = resolve;
  });
  const { peak } = world(
    on,
    { "a.png": "image", "b.png": "image", "c.png": "image" },
    {},
    true,
    barrier,
  );
  await start($);

  // Three cards wanted at once, the first conversion held at the barrier.
  const ui = await reply($, "a.png b.png c.png");
  expect(await ui.findAll({ type: "Button" })).toHaveLength(3);
  expect(peak()).toBe(1);

  release();
  await ui.unmount();
  const after = await reply($, "a.png b.png c.png");
  expect(await after.findAll({ type: "Raster" })).toHaveLength(3);
  expect(peak()).toBe(1);
});

test("previews no picture over 40 megapixels", async ($, on) => {
  const { runs } = world(on, { "large.png": "large" });
  await start($);

  const ui = await reply($, "See large.png.");
  expect(await ui.findAll({ type: "Button" })).toHaveLength(0);
  expect(runs.filter((argv) => argv[1] === "-s")).toEqual([]);
});

// Codex review, round 2, finding 2.
test("decodes a copy of a mentioned file, checked again, never the path the reply named", async ($, on) => {
  const { runs, timeouts } = world(on, { "shot.png": "image" });
  await start($);

  const ui = await reply($, "Saved shot.png.");
  expect(await ui.findAll({ type: "Raster" })).toHaveLength(1);

  const copy = runs.find((argv) => argv[0] === "cp");
  expect(copy?.slice(0, 2)).toEqual(["cp", "/work/shot.png"]);
  expect(copy?.[2]).toMatch(/^\/tmp\/t\/claude-imgview-[0-9a-f-]{36}\.snap$/);
  expect(timeouts[runs.indexOf(copy!)]).toBe(5000);
  // sips is only ever given the copy, and the copy is removed afterwards.
  const sips = runs.filter((argv) => argv[0] === "sips");
  expect(sips.length).toBeGreaterThan(1);
  for (const argv of sips) {
    expect(argv).toContain(copy![2]);
    expect(argv).not.toContain("/work/shot.png");
  }
  expect(runs).toContainEqual(["rm", "-f", copy![2]!]);
});

test("previews no file that grew or was swapped between the look and the copy", async ($, on) => {
  const { runs } = world(on, { "grows.png": "grows", "moved.png": "moved" });
  await start($);

  const ui = await reply($, "See grows.png and moved.png.");
  expect(await ui.findAll({ type: "Button" })).toHaveLength(0);
  expect(runs.filter((argv) => argv[0] === "cp")).toHaveLength(2);
  expect(runs.filter((argv) => argv[0] === "sips")).toEqual([]);
});

// Codex review, round 2, finding 3.
test("moves the previews' boundary with the working directory", async ($, on) => {
  world(on, { "a.png": "image", "/other/b.png": "image" });
  on("classic.CwdChanged", () => ({}));
  await start($);
  const labels = async (ui: Awaited<ReturnType<typeof reply>>) =>
    (await ui.findAll({ type: "Button" })).map((chip) => chip.props.label);

  const before = await reply($, "/work/a.png and /other/b.png");
  expect(await labels(before)).toEqual(["▣ a.png"]);
  await before.unmount();

  await $.classic.CwdChanged({ old_cwd: "/work", new_cwd: "/other" });
  const after = await reply($, "/work/a.png and /other/b.png");
  expect(await labels(after)).toEqual(["▣ b.png"]);
  expect(await after.findAll({ type: "Raster" })).toHaveLength(1);
});

// Codex review, round 2, finding 4.
test(
  "gives a picture its card though 32 files that are no pictures are on screen",
  { timeoutMs: 20000 },
  async ($, on) => {
    const files: Record<string, Kind> = { "real.png": "image" };
    const replies: string[] = [];
    for (let n = 0; n < 8; n++) {
      const names = [0, 1, 2, 3].map((k) => `junk${n}-${k}.png`);
      for (const name of names) files[name] = "text";
      replies.push(names.join(" "));
    }
    world(on, files);
    await start($);

    for (const [n, text] of replies.entries()) {
      const ui = await reply($, text, { id: `reply-${n}` });
      expect(await ui.findAll({ type: "Button" })).toHaveLength(0);
    }
    const ui = await reply($, "real.png", { id: "reply-real" });
    expect(await ui.findAll({ type: "Raster" })).toHaveLength(1);
  },
);

// Codex review, round 2, finding 5.
test("removes the PNG it converted when a chip's picture replaces it in the pane", async ($, on) => {
  const { runs, opened } = world(
    on,
    { "/photos/cat.jpg": "image", "shot.png": "image" },
    { TERM: "xterm-kitty" },
  );
  await start($);
  await img($, "/photos/cat.jpg");
  const converted = runs.find((argv) => argv[1] === "-s")!.at(-1)!;
  expect(converted).toMatch(/\.png$/);

  const ui = await reply($, "Saved shot.png.");
  await ui.press({ key: "imgview-open-0" });
  expect(opened).toHaveLength(2);
  expect(runs).toContainEqual(["rm", "-f", converted]);
  // The pane now shows the PNG the reply named, as the person's click asked.
  const shownPane = await pane($, 40, 21);
  expect((await shownPane.find({ type: "Image" }))?.props.source).toMatchObject(
    {
      file: "/work/shot.png",
    },
  );
});

test("drops the cards of the directory it left, and the PNGs it made for them", async ($, on) => {
  const { runs } = world(on, { "a.png": "image" }, { TERM: "xterm-kitty" });
  on("classic.CwdChanged", () => ({}));
  await start($);

  const ui = await reply($, "a.png");
  const card = (await ui.find({ type: "Image" }))?.props.source as {
    file: string;
  };
  expect(runs).not.toContainEqual(["rm", "-f", card.file]);

  await $.classic.CwdChanged({ old_cwd: "/work", new_cwd: "/other" });
  expect(runs).toContainEqual(["rm", "-f", card.file]);
});

// Codex review, round 3, finding 1.
test(
  "gives up the cards that scrolled away while they waited, and draws the one on screen next",
  { timeoutMs: 20000 },
  async ($, on) => {
    let release = () => {};
    const barrier = new Promise<void>((resolve) => {
      release = resolve;
    });
    const files: Record<string, Kind> = { "new.png": "image" };
    const olds: string[] = [];
    for (let n = 0; n < 2; n++) {
      const names = [0, 1, 2, 3].map((k) => `old${n}-${k}.png`);
      for (const name of names) files[name] = "image";
      olds.push(names.join(" "));
    }
    const { runs, clock } = world(on, files, {}, true, barrier);
    await start($);

    // Eight cards asked for: the first is at the barrier, seven wait behind it.
    const drawings = [];
    for (const [n, text] of olds.entries())
      drawings.push(await reply($, text, { id: `old-${n}` }));
    // They scroll away, and nothing asks for them for six seconds.
    for (const ui of drawings) await ui.unmount();
    await clock.advance(6000);
    // Drawn again off screen, they are still not in use.
    for (const [n, text] of olds.entries()) {
      const hidden = await reply($, text, {
        id: `old-${n}`,
        isOffScreen: true,
      });
      await hidden.unmount();
    }
    const ui = await reply($, "new.png", { id: "new" });
    expect(await ui.find({ type: "Text", text: /^Rendering…/ })).toBeDefined();

    release();
    await clock.settle();
    await ui.unmount();
    const after = await reply($, "new.png", { id: "new" });
    expect(await after.findAll({ type: "Raster" })).toHaveLength(1);
    // The one already under way, then the one on screen: none of the seven.
    expect(
      runs.filter((argv) => argv[0] === "cp").map((argv) => argv[1]),
    ).toEqual(["/work/old0-0.png", "/work/new.png"]);
  },
);

test(
  "drops the card drawn longest ago once it is off screen, and none a reply on screen is using",
  { timeoutMs: 20000 },
  async ($, on) => {
    const files: Record<string, Kind> = { "extra.png": "image" };
    const replies: string[] = [];
    for (let n = 0; n < 8; n++) {
      const names = [0, 1, 2, 3].map((k) => `p${n}-${k}.png`);
      for (const name of names) files[name] = "image";
      replies.push(names.join(" "));
    }
    const { clock } = world(on, files);
    await start($);
    const rasters = async (text: string, id: string) => {
      const ui = await reply($, text, { id });
      const count = (await ui.findAll({ type: "Raster" })).length;
      await ui.unmount();

      return count;
    };

    // 32 cards drawn; the first reply's are the oldest.
    for (const [n, text] of replies.entries()) {
      expect(await rasters(text, `reply-${n}`)).toBe(4);
      await clock.advance(10);
    }
    // In use a moment ago: nothing gives way to a 33rd.
    expect(await rasters("extra.png", "extra")).toBe(0);

    // Six seconds on, replies 1 to 7 are on screen again; reply 0 is not.
    await clock.advance(6000);
    for (let n = 1; n < 8; n++)
      expect(await rasters(replies[n]!, `reply-${n}`)).toBe(4);
    // One of reply 0's cards gives way, and only one.
    await rasters("extra.png", "extra");
    expect(await rasters("extra.png", "extra")).toBe(1);
    expect(await rasters(replies[0]!, "reply-0")).toBe(3);
  },
);

// Codex review, round 3, finding 2.
test("starts nothing for a reply drawn while a new working directory is being resolved", async ($, on) => {
  let open = () => {};
  const gate = new Promise<void>((resolve) => {
    open = resolve;
  });
  const { clock } = world(
    on,
    { sub: "dir", "sub/a.png": "image" },
    {},
    true,
    undefined,
    { statGate: { path: "/work/sub", gate } },
  );
  on("classic.CwdChanged", () => ({}));
  await start($);

  const before = await reply($, "/work/sub/a.png");
  expect(await before.findAll({ type: "Raster" })).toHaveLength(1);
  await before.unmount();

  const changing = $.classic.CwdChanged({
    old_cwd: "/work",
    new_cwd: "/work/sub",
  });
  await clock.settle();
  // Drawn again before the new directory is known: no chip, nothing begun.
  const during = await reply($, "/work/sub/a.png");
  expect(await during.findAll({ type: "Button" })).toHaveLength(0);
  await during.unmount();

  open();
  await changing;
  const after = await reply($, "/work/sub/a.png");
  expect(await after.findAll({ type: "Raster" })).toHaveLength(1);
});

test("keeps the working directory changed to last, whichever is resolved last", async ($, on) => {
  let open = () => {};
  const gate = new Promise<void>((resolve) => {
    open = resolve;
  });
  const { clock } = world(
    on,
    { sub: "dir", "sub/a.png": "image", "/other/b.png": "image" },
    {},
    true,
    undefined,
    { statGate: { path: "/work/sub", gate } },
  );
  on("classic.CwdChanged", () => ({}));
  await start($);

  const first = $.classic.CwdChanged({
    old_cwd: "/work",
    new_cwd: "/work/sub",
  });
  await clock.settle();
  await $.classic.CwdChanged({ old_cwd: "/work/sub", new_cwd: "/other" });
  // The first change's directory is resolved only now, after the second's.
  open();
  await first;

  const ui = await reply($, "/work/sub/a.png and /other/b.png");
  expect(
    (await ui.findAll({ type: "Button" })).map((chip) => chip.props.label),
  ).toEqual(["▣ b.png"]);
});

// Codex review, round 3, finding 3.
test("opens a clicked chip's file as it is now, not as it was when the card was drawn", async ($, on) => {
  const files: Record<string, Kind> = { "shot.png": "image" };
  const { runs } = world(on, files, { TERM: "xterm-kitty" });
  await start($);
  const ui = await reply($, "Saved shot.png.");
  expect(await ui.findAll({ type: "Image" })).toHaveLength(1);

  // Rebuilt as a JPEG under the same name before the click.
  files["shot.png"] = "jpeg";
  await ui.press({ key: "imgview-open-0" });

  const shownPane = await pane($, 40, 21);
  const source = (await shownPane.find({ type: "Image" }))?.props.source as {
    file: string;
  };
  expect(source.file).toMatch(/^\/tmp\/t\/claude-imgview-[0-9a-f-]{36}\.png$/);
  expect(runs).toContainEqual([
    "sips",
    "-s",
    "format",
    "png",
    "/work/shot.png",
    "--out",
    source.file,
  ]);
});

// Codex review, round 3, finding 4.
test("removes every PNG it converted but the one shown, when two chips are clicked at once", async ($, on) => {
  let release = () => {};
  const barrier = new Promise<void>((resolve) => {
    release = resolve;
  });
  const { runs, clock } = world(
    on,
    { "a.jpg": "image", "b.jpg": "image" },
    { TERM: "xterm-kitty" },
    true,
    barrier,
  );
  await start($);
  const ui = await reply($, "a.jpg b.jpg");

  // Both clicks land before either conversion ends.
  const presses = Promise.all([
    ui.press({ key: "imgview-open-0" }),
    ui.press({ key: "imgview-open-1" }),
  ]);
  await clock.settle();
  release();
  await presses;

  // The pane's own conversions are the ones with no size: a card's has one.
  const made = runs
    .filter((argv) => argv[3] === "png" && !argv.includes("-z"))
    .map((argv) => argv.at(-1)!);
  expect(made).toHaveLength(2);
  const shownPane = await pane($, 40, 21);
  const source = (await shownPane.find({ type: "Image" }))?.props.source as {
    file: string;
  };
  expect(made).toContain(source.file);
  const removed = runs
    .filter((argv) => argv[0] === "rm")
    .map((argv) => argv[2]);
  for (const png of made) {
    if (png !== source.file) expect(removed).toContain(png);
  }
  expect(removed).not.toContain(source.file);
});

// Codex review, round 3, finding 5.
test("decodes no copy that cp did not make: a failed copy, a name already taken, a file turned pipe", async ($, on) => {
  const { runs } = world(on, { "odd.png": "uncopyable", "pipe.png": "piped" });
  await start($);

  const ui = await reply($, "odd.png and pipe.png");
  expect(await ui.findAll({ type: "Button" })).toHaveLength(0);
  expect(runs.filter((argv) => argv[0] === "cp")).toHaveLength(2);
  expect(runs.filter((argv) => argv[0] === "sips")).toEqual([]);
});

test("copies nothing over a name that is already taken", async ($, on) => {
  const { runs } = world(on, { "shot.png": "image" }, {}, true, undefined, {
    isSquatted: true,
  });
  await start($);

  const ui = await reply($, "Saved shot.png.");
  expect(await ui.findAll({ type: "Button" })).toHaveLength(0);
  expect(runs.filter((argv) => argv[0] === "cp" || argv[0] === "sips")).toEqual(
    [],
  );
});

test("names its temporary files so that no two can be guessed or collide", async ($, on) => {
  const { runs } = world(on, { "a.png": "image", "b.png": "image" });
  await start($);
  await reply($, "a.png b.png");

  const copies = runs
    .filter((argv) => argv[0] === "cp")
    .map((argv) => argv[2]!);
  expect(copies).toHaveLength(2);
  expect(new Set(copies).size).toBe(2);
  for (const copy of copies)
    expect(copy).toMatch(
      /^\/tmp\/t\/claude-imgview-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.snap$/,
    );
});

test("converts the waiting card asked for last first", async ($, on) => {
  let release = () => {};
  const barrier = new Promise<void>((resolve) => {
    release = resolve;
  });
  const { runs, clock } = world(
    on,
    { "x.png": "image", "y.png": "image", "z.png": "image" },
    {},
    true,
    barrier,
  );
  await start($);

  // x is at the barrier; y waits, then z a moment after it.
  await reply($, "x.png", { id: "x" });
  await clock.advance(10);
  await reply($, "y.png", { id: "y" });
  await clock.advance(10);
  await reply($, "z.png", { id: "z" });

  release();
  await clock.settle();
  expect(
    runs.filter((argv) => argv[0] === "cp").map((argv) => argv[1]),
  ).toEqual(["/work/x.png", "/work/z.png", "/work/y.png"]);
});

test("converts none of the cards still waiting when the working directory changes", async ($, on) => {
  let release = () => {};
  const barrier = new Promise<void>((resolve) => {
    release = resolve;
  });
  const { runs, clock } = world(
    on,
    { "a.png": "image", "b.png": "image" },
    {},
    true,
    barrier,
  );
  on("classic.CwdChanged", () => ({}));
  await start($);

  // a is at the barrier, b waits behind it.
  await reply($, "a.png b.png");
  await $.classic.CwdChanged({ old_cwd: "/work", new_cwd: "/other" });
  release();
  await clock.settle();
  expect(
    runs.filter((argv) => argv[0] === "cp").map((argv) => argv[1]),
  ).toEqual(["/work/a.png"]);
});
