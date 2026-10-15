#!/usr/bin/env node
// Behavioural tests for pre-push-gate.sh.
//
//   node .claude/hooks/pre-push-gate.test.mjs
//   HOOK_PATH=/path/to/other-build.sh node .claude/hooks/pre-push-gate.test.mjs   # compare builds
//
// Runs the REAL hook as a child process against generated git repos and an isolated CLAUDE_CONFIG_DIR,
// so no live receipt is read or written.
//
// What it guards: the gate is only useful if it SEES the push. An earlier build read the command with a
// `"[^"]*"` grep, which ends a JSON string at the first escaped quote, so `git commit -m "..." && git push`
// arrived as `git commit -m \` and the hook failed open. Tests 2 and 6 fail against that build.
import { spawnSync, execFileSync } from "child_process";
import fs from "fs";
import os from "os";
import path from "path";
import { fileURLToPath } from "url";

const HOOK = process.env.HOOK_PATH || fileURLToPath(new URL("./pre-push-gate.sh", import.meta.url));
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "pre-push-gate-test-"));
const SANDBOX = path.join(ROOT, "config");
const GATE = path.join(SANDBOX, ".gate");

// package.json is one of the things the hook accepts as a build system.
const git = (cwd, ...a) =>
  execFileSync("git", ["-c", "user.email=t@t", "-c", "user.name=t", ...a], { cwd, encoding: "utf8" });
const repo = (name, withBuild = true) => {
  const dir = path.join(ROOT, name);
  fs.mkdirSync(dir, { recursive: true });
  if (withBuild) fs.writeFileSync(path.join(dir, "package.json"), '{"name":"x","private":true}\n');
  else fs.writeFileSync(path.join(dir, "notes.txt"), "no build system here\n");
  git(dir, "init", "-q", "-b", "main");
  git(dir, "add", "-A");
  git(dir, "commit", "-qm", "init");
  return { dir, sha: git(dir, "rev-parse", "HEAD").trim(), key: name };
};

const GATED = repo("gated-repo");
const PLAIN = repo("plain-repo", false);

const receipt = (r) => path.join(GATE, `${r.key}-${r.sha}.ok`);
const reset = () => { fs.rmSync(SANDBOX, { recursive: true, force: true }); fs.mkdirSync(GATE, { recursive: true }); };
const green = (r) => fs.writeFileSync(receipt(r), `{"repo":"${r.key}","sha":"${r.sha}"}\n`);

// The payload the harness sends: a PreToolUse envelope with the Bash command in it.
const run = (command, r = GATED, cwd = null) => {
  const res = spawnSync("bash", [HOOK], {
    input: JSON.stringify({ cwd: cwd || r.dir, tool_name: "Bash", tool_input: { command } }),
    env: { ...process.env, CLAUDE_CONFIG_DIR: SANDBOX },
    encoding: "utf8",
  });
  return { code: res.status, reason: (res.stderr || "").split("\n")[0] };
};

let pass = 0, fail = 0;
const check = (name, got, want, extra = "") => {
  const okk = got === want;
  okk ? pass++ : fail++;
  console.log(`${okk ? "PASS" : "FAIL"}  ${name}${okk ? "" : `  -> got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}${extra ? `  ${extra}` : ""}`);
};

console.log(`hook: ${HOOK}\nrepo: ${GATED.dir} @ ${GATED.sha.slice(0, 8)}\n`);

// ---- 1. a bare push with no receipt is blocked ----
reset();
check("1  bare push, no receipt", run("git push origin main").code, 2);

// ---- 2. the same push must stay visible when something on the line is quoted ----
reset();
const r2 = run('git commit -m "fix the thing" && git push origin main');
check("2  quoted commit && push, no receipt", r2.code, 2, r2.reason);

// ---- 3+4. a green receipt for THIS commit lets either shape through ----
reset(); green(GATED);
check("3  bare push, receipt present", run("git push origin main").code, 0);
reset(); green(GATED);
check("4  quoted commit && push, receipt present", run('git commit -m "fix" && git push origin main').code, 0);

// ---- 5. a receipt for another commit is not this commit's receipt ----
reset();
fs.writeFileSync(path.join(GATE, `${GATED.key}-${"0".repeat(40)}.ok`), "{}\n");
check("5  receipt for a different sha", run("git push origin main").code, 2);

// ---- 6. the quote may be anywhere on the line. The cd target is a real repo because the gate follows
// ---- it: a quoted path to nowhere would be allowed as "not a git repo" and pass for the wrong reason.
reset();
check("6  quoted path before the push", run(`cd "${GATED.dir}" ; git push --force-with-lease`, GATED, PLAIN.dir).code, 2);

// ---- 7. a command that is not a push is none of this hook's business ----
reset();
check("7a non-push command", run('git commit -m "just committing"').code, 0);
check("7b quoted echo, no push", run('echo "all done"').code, 0);
check("7c git stash push is not a push", run("git stash push -m wip").code, 0);
check("7d a message that mentions push is not a push", run('git commit -m "push the fix later"').code, 0);

// ---- 8. a repo with no build system is not gated, receipt or no receipt ----
reset();
check("8  push from a repo with no build", run("git push origin main", PLAIN).code, 0);

// ---- 9-11. the subject is the repo that RECEIVES the push, not the session's directory ----
reset();
check("9  git -C into the gated repo from elsewhere", run(`git -C ${GATED.dir} push`, GATED, PLAIN.dir).code, 2);
reset();
check("10 cd into a build-less repo from a gated cwd", run(`cd ${PLAIN.dir} && git push`, GATED).code, 0);
// a target the shell expands cannot be resolved: the walk stops and the session's repo stays gated
reset();
check("11 unresolvable cd target keeps the push gated", run("cd $DIR && git push", GATED).code, 2);

// ---- 12. an unpushed commit carrying AI attribution never leaves, even with a green receipt ----
const LEAKY = repo("leaky-repo");
fs.writeFileSync(path.join(LEAKY.dir, "a.txt"), "a\n");
git(LEAKY.dir, "add", "-A");
git(LEAKY.dir, "commit", "-qm", "feat: add a\n\nClaude-Session: https://claude.ai/code/session_x");
LEAKY.sha = git(LEAKY.dir, "rev-parse", "HEAD").trim();
reset(); green(LEAKY);
const r12 = run("git push origin main", LEAKY);
check("12 attribution in an unpushed commit blocks the push", [r12.code, /attribution/.test(r12.reason)].join(), "2,true", r12.reason);

// ---- 13. an unparseable payload fails open ----
const bad = spawnSync("bash", [HOOK], { input: "not json", env: { ...process.env, CLAUDE_CONFIG_DIR: SANDBOX }, encoding: "utf8" });
check("13 unparseable payload -> allow", bad.status, 0);

fs.rmSync(ROOT, { recursive: true, force: true });
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
