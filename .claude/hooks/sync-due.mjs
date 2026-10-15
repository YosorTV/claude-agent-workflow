#!/usr/bin/env node
// sync-due.mjs - PostToolUse hook (matcher "Bash|Agent|Task|mcp__tracker__transition"). Turns "work shipped" into
// a HARD obligation to run the session-sync agent before the session may end; run-guard.mjs (Stop) reads
// the markers this hook writes and holds the session while one is outstanding.
//
// Why a hook and not prompt text: "log the session at the end of every task" was an instruction for months
// and the log still went missing on runs that ended right after the work landed. An instruction the model
// may forget is not a guarantee; a marker the Stop hook reads is.
//
//   1. A commit landed (HEAD of the command's repo committed in the last 2 minutes) -> .locks/syncdue-session.json
//   2. A ticket moved into a review state through the tracker MCP (mcp/tracker-mcp `transition`)
//      -> .locks/syncdue-<ticket>.json
//   3. A session-sync agent dispatch -> clears the markers it covers.
//
// Fail posture: OPEN. It only writes and removes marker files; anything unparseable exits 0, so a bug here
// never eats the tool call it observed. Escape hatch: touch ~/.claude/.locks/sync-due-off.
import fs from "fs"; import os from "os"; import path from "path"; import { spawnSync } from "child_process";

// The review states of the bundled tracker-mcp WORKFLOW. Edit for your tracker.
const REVIEW_STATES = ["in_review", "ready_to_merge"];
const SYNC_AGENT = /^session-?sync$/i;

const CLAUDE_DIR = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), ".claude");
const LOCKS = path.join(CLAUDE_DIR, ".locks");
const LOG = path.join(LOCKS, "sync-due.log");

let p = {}; try { p = JSON.parse(fs.readFileSync(0, "utf8").replace(/^\uFEFF/, "").trim()); } catch { process.exit(0); }
if (fs.existsSync(path.join(LOCKS, "sync-due-off"))) process.exit(0);

const log = (verdict, detail) => {
  try { fs.mkdirSync(LOCKS, { recursive: true }); fs.appendFileSync(LOG, `${new Date().toISOString()} ${verdict} ${detail}\n`); } catch {}
};
const tool = String(p.tool_name || "");
const input = p.tool_input || {};
const resp = JSON.stringify(p.tool_response ?? p.tool_result ?? "");
const failed = /\\?"isError\\?"\s*:\s*true/i.test(resp) || /\\?"ok\\?"\s*:\s*false/i.test(resp);

const arm = (key, detail, extra) => {
  try {
    fs.mkdirSync(LOCKS, { recursive: true });
    fs.writeFileSync(path.join(LOCKS, `syncdue-${key}.json`),
      JSON.stringify({ id: key, tool, sessionId: p.session_id || null, at: Date.now(), ...extra }));
    log("due", detail);
  } catch {}
};

// ---------- 1. session-sync ran -> release the obligation ----------
// It logs the whole session, so it always clears the session marker. Ticket markers: the ones its prompt
// names, or every one when it names none.
if (/^(Agent|Task)$/i.test(tool) && SYNC_AGENT.test(String(input.subagent_type || ""))) {
  const prompt = String(input.prompt || "");
  let files = [];
  try { files = fs.readdirSync(LOCKS).filter((f) => /^syncdue-.+\.json$/.test(f)); } catch {}
  const ids = files.map((f) => f.slice(8, -5)).filter((id) => id !== "session");
  const named = ids.filter((id) => prompt.includes(id));
  let cleared = 0;
  for (const f of files) {
    const id = f.slice(8, -5);
    if (id !== "session" && named.length && !named.includes(id)) continue;
    try { fs.unlinkSync(path.join(LOCKS, f)); cleared++; } catch {}
  }
  if (cleared) log("cleared", `${cleared} marker(s)${named.length ? ` for ${named.join(",")}` : " (all)"}`);
  process.exit(0);
}

// ---------- 2. a ticket reached a review state ----------
if (/^mcp__tracker__transition$/.test(tool)) {
  const id = String(input.ticket_id || "").replace(/[^A-Za-z0-9._-]/g, "");
  const to = String(input.to_state || "");
  if (id && REVIEW_STATES.includes(to)) {
    if (failed) log("skip", `${id} -> ${to} was refused`);
    else arm(id, `${id} -> ${to} (session-sync owed)`, { state: to, kind: "ticket" });
  }
  process.exit(0);
}

// ---------- 3. no ticket, but a commit landed: a commit is a completed task ----------
// True when HEAD was committed within `seconds` in any directory the command names with `cd`, or the
// session cwd. The command text is a hint, never the verdict: prose that merely mentions `git commit`
// (a heredoc, a note) must not arm, and `git commit -q` prints nothing to match on - HEAD's own commit
// date settles both. Any failure answers false (fail open: the worst case is a missed obligation).
const freshHead = (dir, seconds) => {
  if (!dir) return false;
  const r = spawnSync("git", ["-C", dir, "log", "-1", "--format=%ct"], { encoding: "utf8", timeout: 5000 });
  const at = Number((r.stdout || "").trim());
  return Number.isFinite(at) && at > 0 && (Date.now() / 1000 - at) <= seconds;
};
// Git for Windows cannot resolve an MSYS path (/c/work/repo), which is the form a Bash tool hands over.
const winPath = (d) =>
  process.platform === "win32" ? d.replace(/^\/(?:cygdrive\/)?([A-Za-z])(?=\/|$)/, (_, drive) => `${drive.toUpperCase()}:/`) : d;
const committedWithin = (cmd, cwd, seconds) => {
  const home = os.homedir();
  const dirs = [...cmd.matchAll(/\bcd\s+(?:"([^"]+)"|'([^']+)'|([^\s;&|]+))/g)]
    .map((m) => m[1] || m[2] || m[3])
    .map((d) => d.replace(/^~(?=\/|$)/, home).replace(/^\$HOME\b|^\$\{HOME\}/, home))
    .filter((d) => !/\$/.test(d));            // an unresolved variable cannot be probed
  dirs.push(cwd);
  return dirs.some((d) => freshHead(winPath(String(d || "")), seconds));
};

if (/^Bash$/i.test(tool) && !failed) {
  const cmd = String(input.command || "");
  // An invocation STARTS a command segment; prose does not. The `-[A-Za-z]\s+\S+` arm lets an option carry
  // a value (`git -C /repo commit`); a non-option token stops the match (`git log --grep commit`).
  const INVOKE = /^(?:(?:sudo|time|command|env)\s+)*git\s+(?:--\S+\s+|-[A-Za-z]\s+\S+\s+|-\S+\s+)*commit\b/;
  const looksLikeCommit = cmd.split(/[;&|\n]+/).some((seg) => INVOKE.test(seg.trim())) && !/--dry-run\b/.test(cmd);
  if (looksLikeCommit && SYNC_AGENT.test(String(p.agent_type || ""))) {
    log("skip", "commit by the session-sync agent (it satisfies the obligation, never owes one)");
  } else if (looksLikeCommit && committedWithin(cmd, p.cwd, 120)) {
    arm("session", "a commit landed (session-sync owed for this session)", { kind: "commit" });
  }
}
process.exit(0);
