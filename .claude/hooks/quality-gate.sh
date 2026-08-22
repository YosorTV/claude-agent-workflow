#!/usr/bin/env sh
# Runs after an implementer finishes, before anything reaches review.
# Fails closed: any non-zero exit stops the pipeline. There is deliberately no bypass flag.
set -eu

fail() { printf '\033[31mQUALITY GATE FAILED:\033[0m %s\n' "$1" >&2; exit 1; }
step() { printf '\033[36m→\033[0m %s\n' "$1"; }

step "formatting"
if [ -f package.json ]; then
  npm run --silent format:check || fail "formatting check failed"
fi

step "lint"
if [ -f package.json ]; then
  npm run --silent lint || fail "lint failed"
fi

step "types"
if [ -f tsconfig.json ]; then
  npx --no-install tsc --noEmit || fail "type check failed"
fi

step "tests"
if [ -f package.json ]; then
  npm test --silent || fail "test suite failed"
fi

step "debug leftovers"
if git diff --cached -U0 | grep -nE '^\+.*(console\.(log|debug)|debugger;|Console\.WriteLine|TODO(?!\(#))' >/dev/null 2>&1; then
  fail "debug output or untracked TODO in the staged diff"
fi

printf '\033[32mQUALITY GATE PASSED\033[0m\n'
