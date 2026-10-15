#!/usr/bin/env node
// attribution-gate.mjs - PreToolUse hook (matcher "^(Bash|mcp__.*)$"). Denies (exit 2 + permissionDecision):
//   1. a `git commit` or `git push` that switches the git hooks off: --no-verify, -n on commit,
//      or core.hooksPath set on the command line;
//   2. a Bash command that commits, tags or writes a PR / issue / release (git commit, git tag,
//      gh pr|issue|release create|edit|comment|review) and carries AI attribution anywhere in its text:
//      -m values, heredocs, --body, --trailer;
//   3. an MCP write (create / update / comment / transition / append / post / send / *_write ...) whose
//      input carries AI attribution: tracker comments, PR descriptions, chat posts.
// Attribution = a claude.ai link, a Claude-Session trailer, Co-Authored-By: Claude, "Generated with Claude".
// .githooks/commit-msg is the backstop for what this cannot see: a -F message file, a commit made outside
// Claude Code. Fail posture: OPEN on an unparseable payload; a crash inside the gate DENIES, because this
// is the hard stop for the attribution ban and a bug in it must be loud, not silent.
import fs from "fs";

const AI_ATTRIBUTION = /claude\.ai\/|Claude-Session:|Co-Authored-By:\s*Claude|Generated with \[?Claude/i;

const deny = (why) => {
  const reason = `GATE FAILED - ${why}`;
  process.stdout.write(JSON.stringify({ hookSpecificOutput: {
    hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason } }) + "\n");
  process.stderr.write(reason + "\n");
  process.exit(2);
};
process.on("uncaughtException", (e) => deny(`attribution-gate crashed (${e && e.message}) - the gate fails closed; fix .claude/hooks/attribution-gate.mjs.`));

let payload;
try { payload = JSON.parse(fs.readFileSync(0, "utf8").replace(/^\uFEFF/, "").trim()); } catch { process.exit(0); }
const tool = String(payload.tool_name || "");
const input = payload.tool_input || {};

// Command segments split on UNQUOTED ; & | and newlines, after joining backslash line continuations, so a
// flag on the next line of `git commit \` still belongs to its commit and a quoted "a; b" stays whole.
function segments(cmd) {
  const s = cmd.replace(/\\\r?\n/g, " ");
  const out = []; let cur = ""; let q = null;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) { cur += c; if (c === q && s[i - 1] !== "\\") q = null; continue; }
    if (c === '"' || c === "'") { q = c; cur += c; continue; }
    if (c === ";" || c === "&" || c === "|" || c === "\n") { out.push(cur); cur = ""; continue; }
    cur += c;
  }
  out.push(cur);
  return out.map((x) => x.trim()).filter(Boolean);
}
// git [global options] <commit|push> <rest>; global options may carry a value (-C <dir>, -c <k=v>).
const GIT = /^\(?\s*(?:(?:sudo|command|env|time)\s+)*(?:\S*[\/\\])?git(?:\.exe)?((?:\s+(?:-[cC]\s+(?:"[^"]*"|'[^']*'|\S+)|-\S+))*)\s+(commit|push)\b(.*)$/s;
// A `--` ends the options; quoted values are blanked first, so a message that mentions --no-verify is fine.
function bypassesHooks(seg) {
  const m = seg.match(GIT);
  if (!m) return false;
  const [, globals, sub, rest] = m;
  if (/core\.hooksPath=/i.test(globals)) return true;          // git -c core.hooksPath=/dev/null commit
  for (const tok of rest.replace(/\$'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"|'[^']*'/g, " ").trim().split(/\s+/)) {
    if (tok === "--") break;
    if (/^--no-veri(?:f(?:y)?)?$/.test(tok)) return true;
    if (sub === "commit" && /^-[a-zA-Z]*n[a-zA-Z]*$/.test(tok)) return true;   // on push, -n is --dry-run
  }
  return false;
}

if (tool === "Bash") {
  const cmd = String(input.command || "");
  for (const seg of segments(cmd))
    if (bypassesHooks(seg)) deny(`"--no-verify" (or hooks switched off by config) is banned on git commit and git push - the hooks exist for a reason. Fix what they report instead.`);
  const writesOutward = /\bgit\b[^;&|\n]*\b(commit|tag)\b/.test(cmd) || /\bgh\s+(pr|issue|release)\s+(create|edit|comment|review)\b/.test(cmd);
  const hit = writesOutward && cmd.match(AI_ATTRIBUTION);
  if (hit) deny(`the command carries AI attribution (${JSON.stringify(hit[0])}). No claude.ai link, no Claude-Session trailer, no Co-Authored-By: Claude in commits, tags, PRs or issues. Strip it and retry; never bypass.`);
  process.exit(0);
}

if (/_write$|write_|comment|transition|worklog|create|update|append|add_|send|post|upsert/i.test(tool)) {
  const hit = JSON.stringify(input).match(AI_ATTRIBUTION);
  if (hit) deny(`${tool.replace(/^mcp__/, "")}: carries AI attribution (${JSON.stringify(hit[0])}). Nothing that leaves this machine carries it - PR bodies, tracker text, chat posts. Strip it and retry.`);
}
process.exit(0);
