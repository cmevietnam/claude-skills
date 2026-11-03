// Stub of @deepseek-ai/dsh lib/bin.js for test-deepseek-review.sh.
//
// The harness copies this file to <dsh-dir>/node_modules/@deepseek-ai/dsh/lib/bin.js and writes
// a scenario.json beside it. The wrapper scrubs the environment, so the scenario cannot come
// from env: it is read from the file next to this script (the dsh dir is readable inside the
// fence).
//
// What it does:
//   --patch FILE       (any mode) read FILE first, as real dsh does; an unreadable one prints
//                      `Error: dsh: failed to read overlay FILE: Error: <code>: ...` and exits 1
//                      with no stream and no record; results land in the record's patch_reads
//   --version         spawn a scenario.version_marker grandchild (if set), record, print
//                      scenario.version (default 0.2.1-rc.5), exit 0; with scenario.version_hang,
//                      record and hang instead of printing
//   otherwise          read stdin, take the nonce from the LAST /VERDICT-([0-9a-f]{16}):/,
//                      run the requested fence probes, optionally spawn a grandchild carrying a
//                      unique marker in its argv, record everything to $HOME/stub-record-<pid>.json,
//                      emit scenario.lines with {NONCE} and {CWD} substituted, write
//                      scenario.stderr, then exit / self-signal / hang as the scenario says.
//
// Output goes through fs.writeSync on fds 1 and 2 (never process.stdout), so it is complete
// before a self-inflicted SIGKILL or process.exit.
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
let scenario;
try {
  scenario = JSON.parse(
    fs.readFileSync(path.join(here, "scenario.json"), "utf8"),
  );
} catch (e) {
  scenario = { scenario_error: String(e), lines: [] };
}

// Like real dsh (0.2.1-rc.5 loadOverlayPatches), read every `--patch <file>` before anything
// else; an unreadable overlay is fatal: one stderr line, exit 1, no stream, no record.
const patchReads = {};
{
  const av = process.argv.slice(2);
  for (let i = 0; i < av.length; i++) {
    if (av[i] !== "--patch" || i + 1 >= av.length) continue;
    const f = av[++i];
    try {
      fs.readFileSync(f);
      patchReads[f] = "OK";
    } catch (e) {
      patchReads[f] = e.code || String(e);
      fs.writeSync(
        2,
        `Error: dsh: failed to read overlay ${f}: Error: ${e.message || e}\n`,
      );
      process.exit(1);
    }
  }
}

function sleepMs(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function writeAll(fd, text) {
  const buf = Buffer.from(text, "utf8");
  let off = 0;
  while (off < buf.length) {
    try {
      off += fs.writeSync(fd, buf, off, buf.length - off);
    } catch (e) {
      if (e.code === "EAGAIN") {
        sleepMs(5);
        continue;
      }
      throw e;
    }
  }
}

function readStdin() {
  const chunks = [];
  const b = Buffer.alloc(65536);
  for (;;) {
    let n;
    try {
      n = fs.readSync(0, b, 0, b.length, null);
    } catch (e) {
      if (e.code === "EAGAIN") {
        sleepMs(5);
        continue;
      }
      if (e.code === "EOF") break;
      return {
        text: Buffer.concat(chunks).toString("utf8"),
        error: e.code || String(e),
      };
    }
    if (n === 0) break;
    chunks.push(Buffer.from(b.subarray(0, n)));
  }
  return { text: Buffer.concat(chunks).toString("utf8"), error: null };
}

function probe(kind, p) {
  try {
    if (kind === "read") fs.readFileSync(p);
    else fs.writeFileSync(p, "stub-probe-write\n");
    return "OK";
  } catch (e) {
    return e.code || String(e);
  }
}

function runProbes() {
  const out = { read: {}, write: {} };
  const pr = scenario.probes || {};
  for (const p of pr.read || []) out.read[p] = probe("read", p);
  for (const p of pr.write || []) out.write[p] = probe("write", p);
  return out;
}

function envRecord() {
  const env = {};
  for (const [k, v] of Object.entries(process.env)) {
    env[k] = k === "DEEPSEEK_API_KEY" ? { present: true, length: v.length } : v;
  }
  return env;
}

function record(kind, extra) {
  const rec = {
    kind,
    pid: process.pid,
    argv: process.argv,
    execPath: process.execPath,
    cwd: process.cwd(),
    env: envRecord(),
    probes: runProbes(),
    patch_reads: patchReads,
    scenario_error: scenario.scenario_error || null,
    ...extra,
  };
  const home = process.env.HOME;
  if (!home) {
    writeAll(2, "stub-dsh: HOME unset, cannot record\n");
    return;
  }
  try {
    fs.writeFileSync(
      path.join(home, `stub-${kind}-${process.pid}.json`),
      JSON.stringify(rec, null, 1),
    );
  } catch (e) {
    writeAll(2, `stub-dsh: cannot record: ${e.code || e}\n`);
  }
}

const args = process.argv.slice(2);
if (args.includes("--version")) {
  // version_marker: spawn a grandchild carrying it (it outlives this process). version_hang:
  // record, then never answer (the wrapper's version check must time out or be cancelled and kill
  // the whole group); without it, answer and exit, leaving the grandchild in the group.
  let vgc = null;
  if (scenario.version_marker) {
    const c = spawn(
      process.execPath,
      ["-e", "setInterval(()=>{},1000)", scenario.version_marker],
      { stdio: "ignore" },
    );
    vgc = c.pid ?? null;
  }
  record("version", { grandchild_pid: vgc });
  if (scenario.version_hang) {
    // Block synchronously: a setInterval would let the script fall through into the main path.
    for (;;) sleepMs(1000);
  } else {
    writeAll(1, (scenario.version ?? "0.2.1-rc.5") + "\n");
    process.exit(0);
  }
}

// no_stdin: never touch fd 0 (a child that ignores its stdin; the wrapper's feeder must not
// block the timeout on the full pipe).
const stdin = scenario.no_stdin
  ? { text: "", error: "not read (no_stdin)" }
  : readStdin();
let nonce = "NONCE-NOT-FOUND";
for (const m of stdin.text.matchAll(/VERDICT-([0-9a-f]{16}):/g)) nonce = m[1];
const cwd = process.cwd();
const jsonEsc = (s) => JSON.stringify(s).slice(1, -1);
// {KEY}: the DEEPSEEK_API_KEY the stub got (a scenario that echoes it proves the wrapper
// scrubs what it prints).
const KEY = process.env.DEEPSEEK_API_KEY || "";

function render(lines) {
  return (lines || [])
    .map((l) => {
      const raw = typeof l === "string";
      const s = raw ? l : JSON.stringify(l);
      return (
        s
          .replaceAll("{NONCE}", nonce)
          .replaceAll("{KEY}", raw ? KEY : jsonEsc(KEY))
          .replaceAll("{CWD}", raw ? cwd : jsonEsc(cwd)) + "\n"
      );
    })
    .join("");
}
const sub = (s) =>
  (s || "")
    .replaceAll("{NONCE}", nonce)
    .replaceAll("{KEY}", KEY)
    .replaceAll("{CWD}", cwd);

// key_scan: at startup, before anything is planted, list the files under DSH_HOME (never
// through a symlink) holding the key as written or JSON-escaped. A --continue must find none:
// the wrapper scrubs what earlier attempts left before it starts dsh.
function keyScan(root) {
  const forms = [...new Set([KEY, jsonEsc(KEY)])]
    .filter((f) => f.length > 0)
    .map((f) => Buffer.from(f, "utf8"));
  const res = { root, seen: [], hits: [], errors: [] };
  const walk = (d) => {
    let ents;
    try {
      ents = fs.readdirSync(d, { withFileTypes: true });
    } catch (e) {
      res.errors.push(`${d}: ${e.code || e}`);
      return;
    }
    for (const e of ents) {
      const p = path.join(d, e.name);
      if (e.isSymbolicLink()) continue;
      if (e.isDirectory()) walk(p);
      else if (e.isFile()) {
        res.seen.push(p);
        try {
          const b = fs.readFileSync(p);
          if (forms.some((f) => b.includes(f))) res.hits.push(p);
        } catch (err) {
          res.errors.push(`${p}: ${err.code || err}`);
        }
      }
    }
  };
  if (root) walk(root);
  return res;
}
const keyScanResult = scenario.key_scan
  ? keyScan(process.env.DSH_HOME || process.env.HOME || "")
  : null;

// plant: [[PATH, LINE]] files written like dsh's session store and startup log (PATH may hold
// {HOME} = DSH_HOME and {TMPDIR}; LINE is rendered like scenario.lines, so {KEY} is the key as
// written in a string line and JSON-escaped in an object line). links: [[PATH, TARGET]] symlinks.
const planted = { files: {}, links: {} };
const expandPath = (s) =>
  s
    .replaceAll("{HOME}", process.env.DSH_HOME || process.env.HOME || "")
    .replaceAll("{TMPDIR}", process.env.TMPDIR || "");
for (const [p, line] of scenario.plant || []) {
  const f = expandPath(p);
  try {
    fs.mkdirSync(path.dirname(f), { recursive: true });
    fs.writeFileSync(f, render([line]));
    planted.files[f] = "OK";
  } catch (e) {
    planted.files[f] = e.code || String(e);
  }
}
// lock: [PATH] planted files then made mode 0000 (a file dsh left unreadable to its owner).
planted.locked = {};
for (const p of scenario.lock || []) {
  const f = expandPath(p);
  try {
    fs.chmodSync(f, 0);
    planted.locked[f] = "OK";
  } catch (e) {
    planted.locked[f] = e.code || String(e);
  }
}
for (const [l, target] of scenario.links || []) {
  const f = expandPath(l);
  try {
    fs.mkdirSync(path.dirname(f), { recursive: true });
    fs.symlinkSync(target, f);
    planted.links[f] = "OK";
  } catch (e) {
    planted.links[f] = e.code || String(e);
  }
}

const emitted = render(scenario.lines);
const emittedStderr = sub(scenario.stderr);
const onTerm = scenario.on_sigterm || null;
const emittedSigterm = onTerm ? render(onTerm.lines) : null;

if (onTerm) {
  process.on("SIGTERM", () => {
    writeAll(1, emittedSigterm);
    writeAll(2, sub(onTerm.stderr));
    process.exit(onTerm.exit ?? 0);
  });
} else if (scenario.ignore_sigterm) {
  process.on("SIGTERM", () => {});
}

let grandchildPid = null;
if (scenario.grandchild_marker) {
  // An ignoring grandchild records the SIGTERM it got in $HOME/grandchild-sigterm.txt (and
  // keeps running), so a case can tell a group signal from one sent to dsh alone.
  const code = scenario.grandchild_ignore_sigterm
    ? "process.on('SIGTERM',()=>{try{require('fs').writeFileSync(process.env.HOME+" +
      "'/grandchild-sigterm.txt','SIGTERM\\n')}catch(e){}});setInterval(()=>{},1000)"
    : "setInterval(()=>{},1000)";
  const c = spawn(process.execPath, ["-e", code, scenario.grandchild_marker], {
    stdio: "ignore",
  });
  grandchildPid = c.pid ?? null;
}

record("record", {
  stdin: stdin.text,
  stdin_error: stdin.error,
  nonce,
  emitted,
  emitted_stderr: emittedStderr,
  emitted_sigterm: emittedSigterm,
  grandchild_pid: grandchildPid,
  key_scan: keyScanResult,
  planted,
});

writeAll(1, emitted);
writeAll(2, emittedStderr);

if (scenario.hang || onTerm || scenario.ignore_sigterm) {
  setInterval(() => {}, 1000);
} else if (scenario.self_signal) {
  process.kill(process.pid, scenario.self_signal);
  setInterval(() => {}, 1000);
} else {
  process.exit(scenario.exit ?? 0);
}
