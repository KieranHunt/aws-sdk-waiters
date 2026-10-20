#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: scripts/verify-deps.sh <base-ref> [--author <author>]" >&2
  echo "  author also read from PR_AUTHOR; the A/B diff fails only for dependabot[bot]" >&2
  exit 2
}

BASE_REF=""
AUTHOR="${PR_AUTHOR:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --author)
      [ $# -ge 2 ] || usage
      AUTHOR="$2"
      shift 2
      ;;
    -h | --help) usage ;;
    *)
      [ -z "$BASE_REF" ] || usage
      BASE_REF="$1"
      shift
      ;;
  esac
done

[ -n "$BASE_REF" ] || usage
[ -f "find-aws-sdk-waiters.ts" ] || { echo "error: run from the repository root (candidate)" >&2; exit 1; }

SDK_CLONE="${AWS_SDK_CLONE:-$HOME/.cache/aws-sdk-java-v2}"
if [ ! -d "$SDK_CLONE" ]; then
  echo "error: shared SDK clone not found at $SDK_CLONE" >&2
  echo "clone https://github.com/aws/aws-sdk-java-v2 there, or point AWS_SDK_CLONE at an existing clone; CI owns cloning, this script does not" >&2
  exit 1
fi

CANDIDATE_DIR="$(pwd)"
SCRATCH_DIR="$(mktemp -d)"
BASELINE_DIR="$SCRATCH_DIR/baseline"

if ! git worktree add --detach "$BASELINE_DIR" "$BASE_REF" >"$SCRATCH_DIR/worktree.log" 2>&1; then
  cat "$SCRATCH_DIR/worktree.log" >&2
  echo "error: could not create baseline worktree for $BASE_REF" >&2
  rmdir "$SCRATCH_DIR"
  exit 1
fi

cleanup() {
  git worktree remove --force "$BASELINE_DIR" >/dev/null 2>&1 || true
  rm -rf "$SCRATCH_DIR"
}
trap cleanup EXIT

# mise refuses untrusted configs; CI trusts only the checkout, so trust both sides' mise.toml without dropping existing entries
export MISE_TRUSTED_CONFIG_PATHS="${MISE_TRUSTED_CONFIG_PATHS:+$MISE_TRUSTED_CONFIG_PATHS:}$CANDIDATE_DIR/mise.toml:$BASELINE_DIR/mise.toml"

prepare_side() {
  local side="$1" dir="$2" log="$3" bunver="$4"
  (
    # chained with && because errexit is suspended when the caller tests this function
    cd "$dir" &&
      ln -sfn "$SDK_CLONE" aws-sdk-java-v2 &&
      echo "[$side] mise install" &&
      mise install &&
      mise exec -- bun --version | tee "$bunver" &&
      echo "[$side] bun $(cat "$bunver")" &&
      echo "[$side] bun install --frozen-lockfile" &&
      mise exec -- bun install --frozen-lockfile &&
      echo "[$side] strict catalogue run" &&
      mise exec -- bun find-aws-sdk-waiters.ts
  ) >"$log" 2>&1
}

count_field() {
  grep -Eo "$2" "$1" 2>/dev/null | grep -Eo '[0-9]+' | head -n 1 || true
}

write_summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  local verdict="$1"
  local bun_base bun_cand
  bun_base="$(cat "$SCRATCH_DIR/baseline.bun" 2>/dev/null || echo '?')"
  bun_cand="$(cat "$SCRATCH_DIR/candidate.bun" 2>/dev/null || echo '?')"
  {
    echo "## verify-deps A/B"
    echo
    echo "| | baseline ($BASE_REF) | candidate |"
    echo "|---|---|---|"
    echo "| bun | $bun_base | $bun_cand |"
    echo "| waiter files | $(count_field "$SCRATCH_DIR/baseline.log" 'Found [0-9]+ waiters-2\.json files') | $(count_field "$SCRATCH_DIR/candidate.log" 'Found [0-9]+ waiters-2\.json files') |"
    echo "| waiters | $(count_field "$SCRATCH_DIR/baseline.log" 'Generated README\.md with [0-9]+ waiters') | $(count_field "$SCRATCH_DIR/candidate.log" 'Generated README\.md with [0-9]+ waiters') |"
    echo "| services | $(count_field "$SCRATCH_DIR/baseline.log" 'from [0-9]+ services') | $(count_field "$SCRATCH_DIR/candidate.log" 'from [0-9]+ services') |"
    echo
    echo "$verdict"
  } >>"$GITHUB_STEP_SUMMARY"
}

fatal() {
  echo "error: $1" >&2
  write_summary "❌ $2"
  exit 1
}

show_log() {
  grep -E '^\[(baseline|candidate)\]|Found [0-9]+ waiters|Generated README' "$1" || true
}

if ! prepare_side baseline "$BASELINE_DIR" "$SCRATCH_DIR/baseline.log" "$SCRATCH_DIR/baseline.bun"; then
  cat "$SCRATCH_DIR/baseline.log" >&2
  fatal "baseline preparation failed (mise install, frozen install, or strict run)" "Baseline failed to install or run — this is fatal regardless of author."
fi
show_log "$SCRATCH_DIR/baseline.log"

if ! prepare_side candidate "$CANDIDATE_DIR" "$SCRATCH_DIR/candidate.log" "$SCRATCH_DIR/candidate.bun"; then
  cat "$SCRATCH_DIR/candidate.log" >&2
  fatal "candidate preparation failed (mise install or frozen install)" "Candidate failed to install — this is fatal regardless of author."
fi
show_log "$SCRATCH_DIR/candidate.log"

TYPECHECK_LOG="$SCRATCH_DIR/typecheck.log"
if ! (cd "$CANDIDATE_DIR" && mise exec -- bun run typecheck) >"$TYPECHECK_LOG" 2>&1; then
  cat "$TYPECHECK_LOG" >&2
  fatal "candidate typecheck failed" "Candidate failed typecheck — this is fatal regardless of author."
fi

if ! cmp -s "$BASELINE_DIR/README.md" "$CANDIDATE_DIR/README.md"; then
  if [ -z "$AUTHOR" ]; then
    # fail closed: an unknown author in CI means a misconfigured event, so treat the diff as blocking
    write_summary "❌ README.md differs and the author is unknown — failing closed."
    echo "verdict: README.md differs; author unknown, failing closed" >&2
    exit 1
  elif [ "$AUTHOR" = "dependabot[bot]" ]; then
    write_summary "❌ README.md differs — not auto-mergeable for dependabot[bot]."
    echo "verdict: README.md differs; failing for dependabot[bot]" >&2
    exit 1
  else
    write_summary "ℹ️ README.md differs — informational for author \`$AUTHOR\`; review the catalogue change."
    echo "verdict: README.md differs; informational for $AUTHOR, exiting 0"
    exit 0
  fi
fi

write_summary "✅ README.md is byte-identical across baseline and candidate — no observable change."
echo "verdict: README.md is byte-identical"
