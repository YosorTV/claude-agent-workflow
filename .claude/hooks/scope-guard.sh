#!/usr/bin/env sh
# Rejects edits outside the story's declared scope.
#
# The story declares its surface in .claude/scope (one glob per line, # for comments).
# Without that file the guard fails closed: an undeclared scope is not an unlimited one.
set -eu

SCOPE_FILE=".claude/scope"

[ -f "$SCOPE_FILE" ] || {
  printf '\033[31mSCOPE GUARD:\033[0m no %s — declare the story surface before editing\n' "$SCOPE_FILE" >&2
  exit 1
}

changed=$(git diff --cached --name-only)
[ -n "$changed" ] || exit 0

violations=""
for file in $changed; do
  allowed=0
  while IFS= read -r pattern; do
    case "$pattern" in ''|\#*) continue ;; esac
    # shellcheck disable=SC2254
    case "$file" in $pattern) allowed=1; break ;; esac
  done < "$SCOPE_FILE"
  [ "$allowed" -eq 1 ] || violations="$violations  $file\n"
done

if [ -n "$violations" ]; then
  printf '\033[31mSCOPE GUARD FAILED:\033[0m files outside the declared surface:\n' >&2
  printf "$violations" >&2
  printf 'Widen the scope in the story and have it re-reviewed, or leave these files alone.\n' >&2
  exit 1
fi

printf '\033[32mSCOPE GUARD PASSED\033[0m\n'
