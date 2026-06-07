#!/bin/sh
# preflight-archive.sh — refuse to ARCHIVE from commits that aren't on a remote.
#
# Why this exists: TestFlight builds were once archived from local-only commits
# that were never pushed, leaving GitHub `main` ~9 builds behind reality. This
# guard fails the Archive if the commit being shipped isn't pushed, or if the
# working tree has uncommitted changes (e.g. a build bump or new icon left behind).
#
# It runs ONLY during Xcode Archive (ACTION=install). Normal Debug/Release
# builds and `xcodebuild build` pass straight through. Read-only git (no fetch),
# so it is safe under user-script sandboxing.
set -u

# Only guard the Archive action; let every other build through untouched.
[ "${ACTION:-build}" = "install" ] || exit 0

REPO="${SRCROOT:-$(pwd)}"
cd "$REPO" 2>/dev/null || exit 0

fail() {
  echo "error: ARCHIVE BLOCKED — $1" >&2
  echo "error: Commit + push your build bump and assets, then archive from a pushed branch (normally main)." >&2
  echo "error: (If the commit really is pushed, run 'git fetch' so remote-tracking refs are current, then retry.)" >&2
  exit 1
}

# Decide whether this checkout is expected to be a git repo.
# If there is a .git on disk but `git` cannot run (e.g. blocked by the build
# sandbox), FAIL LOUD rather than silently skipping the guard. Only a genuine
# non-git checkout (no .git) is allowed to pass through.
if [ -e "$REPO/.git" ] || git rev-parse --git-dir >/dev/null 2>&1; then
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    fail "expected a git checkout at SRCROOT but 'git' could not run (build sandbox?). Set ENABLE_USER_SCRIPT_SANDBOXING=NO for this target, or push manually before archiving."
  fi
else
  exit 0
fi

# 1) No uncommitted changes to tracked files.
if ! git diff --quiet || ! git diff --cached --quiet; then
  fail "working tree has uncommitted changes."
fi

# 2) HEAD must exist on some remote branch (i.e. it was actually pushed).
HEAD_SHA=$(git rev-parse HEAD 2>/dev/null)
if [ -z "$(git branch -r --contains "$HEAD_SHA" 2>/dev/null)" ]; then
  fail "HEAD ($(git rev-parse --short HEAD 2>/dev/null)) is not on any remote branch — it was never pushed."
fi

echo "preflight-archive: OK — HEAD $(git rev-parse --short HEAD) is pushed and the tree is clean."
exit 0
