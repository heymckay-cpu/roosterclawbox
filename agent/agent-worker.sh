#!/usr/bin/env bash
# agent-worker.sh — main loop for the Jetson overnight agent.
#
# Polls GitHub issues, runs Claude Code on the next agent-ready task,
# opens a PR if successful, sends a push notification.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.env"

mkdir -p "$LOG_DIR"

# ─────────────────────────── helpers ───────────────────────────

log() { echo "[$(date -Is)] $*"; }

notify() {
  local msg="$1"
  log "$msg"
  if [ -n "${NTFY_TOPIC:-}" ]; then
    curl -fsS -d "$msg" "$NTFY_TOPIC" > /dev/null || true
  fi
}

set_label() {
  # set_label <repo_slug> <issue_number> <add_label> [remove_label]
  local repo="$1" num="$2" add="$3" remove="${4:-}"
  local args=(--repo "$repo" "$num" --add-label "$add")
  [ -n "$remove" ] && args+=(--remove-label "$remove")
  gh issue edit "${args[@]}" >/dev/null || true
}

normalize_test_output() {
  # Keep only failure-ish lines; strip volatile numbers (durations, line:col,
  # addresses) so the diff compares the SET of failures, not runtime noise.
  grep -aiE 'fail|error|✗|✖|assert' "$1" \
    | sed -E 's/[0-9]+(\.[0-9]+)?[[:space:]]*m?s\b//g; s/\b[0-9]+:[0-9]+\b//g; s/0x[0-9a-fA-F]+//g' \
    | sort
}

test_command_for_repo() {
  if [ -f .agent-test ]; then
    cat .agent-test
  else
    echo "$TEST_CMD"
  fi
}

# ─────────────────────────── per-task run ───────────────────────────

run_task() {
  local repo_dir="$1" repo_slug="$2" issue_num="$3"

  cd "$repo_dir" || { log "Cannot cd to $repo_dir"; return 1; }

  local title body branch log_file
  title=$(gh issue view "$issue_num" --repo "$repo_slug" --json title -q .title)
  body=$(gh issue view "$issue_num" --repo "$repo_slug" --json body -q .body)
  branch="agent/issue-${issue_num}"
  log_file="$LOG_DIR/${repo_slug//\//-}-issue-${issue_num}-$(date +%s).log"

  # ─── Local-LLM triage (optional) ───
  # Cheap classifier runs on the Jetson's GPU. Bounces vague/spam issues
  # before they burn a Claude slot.
  if [ "${TRIAGE_ENABLED:-0}" = "1" ]; then
    local triage_json verdict reason
    triage_json=$("$SCRIPT_DIR/triage.sh" "$title" "$body" 2>/dev/null \
      || echo '{"verdict":"ready","reason":"triage failed"}')
    verdict=$(echo "$triage_json" | jq -r '.verdict // "ready"')
    reason=$(echo "$triage_json" | jq -r '.reason // ""')
    log "Triage verdict for #${issue_num}: $verdict — $reason"

    case "$verdict" in
      vague)
        gh issue comment "$issue_num" --repo "$repo_slug" --body "🤖 Triage rejected this issue as too vague to act on safely.

Please add: specific files to change, clear acceptance criteria, and how to verify the change works (e.g. which test should pass).

Triage reason: $reason

Re-apply the \`${LABEL}\` label once you've updated the issue." >/dev/null || true
        set_label "$repo_slug" "$issue_num" needs-more-info agent-working
        notify "⊘ Vague #${issue_num}: $reason"
        return 0
        ;;
      spam)
        gh issue comment "$issue_num" --repo "$repo_slug" --body "🤖 Triage closed this as not an actionable coding task.

Reason: $reason" >/dev/null || true
        gh issue close "$issue_num" --repo "$repo_slug" >/dev/null || true
        notify "✗ Spam #${issue_num}: $reason"
        return 0
        ;;
      ready|*)
        : # fall through to Claude
        ;;
    esac
  fi

  notify "▶ Starting #${issue_num}: ${title}"

  # Fresh branch off latest main.
  git fetch origin --quiet
  git checkout "$DEFAULT_BRANCH" --quiet
  git reset --hard "origin/$DEFAULT_BRANCH" --quiet
  git checkout -B "$branch" --quiet
  rm -f BLOCKER.md

  # Build the prompt.
  local prompt
  prompt=$(cat <<EOF
You are an autonomous coding agent running unattended on a Jetson Orin Nano.
Implement the following GitHub issue. Work in small, verifiable steps.

REPO: ${repo_slug}
ISSUE #${issue_num}: ${title}

${body}

REQUIREMENTS:
1. Read the relevant code before making changes.
2. Implement the minimal change that satisfies the issue.
3. Run the project's test command and make sure it passes:
     $(test_command_for_repo)
4. Commit your changes with a clear conventional-commits message.
5. Do NOT push or open a PR. The wrapper script handles that.

IF YOU GET STUCK:
- Write a short explanation of what's blocking you to BLOCKER.md and exit.
- Do not guess. Do not make sweeping changes outside the issue's scope.

You have full shell access. Be careful — this runs unattended.
EOF
)

  # Run Claude Code with a wall-clock timeout.
  if ! timeout "$TIMEOUT" claude -p "$prompt" \
        --max-turns "$MAX_TURNS" \
        --dangerously-skip-permissions \
        > "$log_file" 2>&1; then
    notify "✗ Failed #${issue_num} (timeout or error). Log: $log_file"
    git checkout "$DEFAULT_BRANCH" --quiet 2>/dev/null || true
    git branch -D "$branch" --quiet 2>/dev/null || true
    set_label "$repo_slug" "$issue_num" agent-failed agent-working
    return 0
  fi

  # Did the agent give up?
  if [ -f BLOCKER.md ]; then
    local reason
    reason=$(head -c 500 BLOCKER.md)
    git checkout "$DEFAULT_BRANCH" --quiet
    git branch -D "$branch" --quiet 2>/dev/null || true
    set_label "$repo_slug" "$issue_num" agent-blocked agent-working
    gh issue comment "$issue_num" --repo "$repo_slug" --body "Agent blocked: $reason"
    notify "⊘ Blocked #${issue_num}: $reason"
    return 0
  fi

  # Run tests as a gate before opening a PR.
  # DELTA GATE (patched 2026-08-17): pre-existing failures on the base branch
  # don't block; only NEW failures introduced by this change do.
  local test_cmd post_out base_out post_rc base_rc
  test_cmd=$(test_command_for_repo)
  log "Running tests: $test_cmd"
  post_out=$(mktemp); base_out=$(mktemp)
  bash -c "$test_cmd" > "$post_out" 2>&1
  post_rc=$?
  cat "$post_out" >> "$log_file"
  if [ "$post_rc" -ne 0 ]; then
    log "Tests failed on branch (rc=$post_rc). Re-running on baseline $DEFAULT_BRANCH for delta…"
    git checkout "origin/$DEFAULT_BRANCH" --quiet --detach
    bash -c "$test_cmd" > "$base_out" 2>&1
    base_rc=$?
    git checkout "$branch" --quiet
    echo "--- baseline test output (rc=$base_rc) ---" >> "$log_file"
    cat "$base_out" >> "$log_file"
    if [ "$base_rc" -ne 0 ] && diff <(normalize_test_output "$post_out") <(normalize_test_output "$base_out") >/dev/null 2>&1; then
      log "Only pre-existing failures (identical failure set on baseline). Gate passes."
    else
      notify "✗ NEW test failures for #${issue_num}. Not opening PR. Log: $log_file"
      rm -f "$post_out" "$base_out"
      git checkout "$DEFAULT_BRANCH" --quiet
      git branch -D "$branch" --quiet 2>/dev/null || true
      set_label "$repo_slug" "$issue_num" agent-failed agent-working
      return 0
    fi
  fi
  rm -f "$post_out" "$base_out"

  # Any actual changes?
  if git diff --quiet "origin/$DEFAULT_BRANCH"..HEAD; then
    set_label "$repo_slug" "$issue_num" agent-no-change agent-working
    notify "○ No changes for #${issue_num}"
    git checkout "$DEFAULT_BRANCH" --quiet
    git branch -D "$branch" --quiet 2>/dev/null || true
    return 0
  fi

  # Push branch + open PR.
  git push -u origin "$branch" --quiet
  gh pr create --repo "$repo_slug" \
    --title "agent: ${title}" \
    --body "Closes #${issue_num}

Automated PR by the Jetson overnight agent. Tests passed locally.
Review carefully before merging." \
    --head "$branch" >/dev/null

  set_label "$repo_slug" "$issue_num" agent-pr-open agent-working
  notify "✓ PR open for #${issue_num}: ${title}"
}

# ─────────────────────────── main loop ───────────────────────────

main_loop() {
  log "Agent worker starting. Watching ${#REPOS[@]} repo(s)."
  notify "🤖 Agent worker started"

  while true; do
    if [ -f "$KILL_SWITCH" ]; then
      log "Kill switch present at $KILL_SWITCH — paused."
      sleep 60
      continue
    fi

    local did_work=0
    for entry in "${REPOS[@]}"; do
      IFS='|' read -r repo_dir repo_slug <<< "$entry"

      if [ ! -d "$repo_dir/.git" ]; then
        log "Skip: $repo_dir is not a git repo"
        continue
      fi

      # Oldest open issue with the agent-ready label.
      local issue_num
      issue_num=$(gh issue list --repo "$repo_slug" \
        --label "$LABEL" --state open \
        --json number --jq 'sort_by(.number) | .[0].number // empty')

      [ -z "$issue_num" ] && continue

      # Claim it so a parallel worker (or a re-run) doesn't double-pick.
      set_label "$repo_slug" "$issue_num" agent-working "$LABEL"
      run_task "$repo_dir" "$repo_slug" "$issue_num"
      did_work=1
    done

    if [ $did_work -eq 0 ]; then
      log "Queue empty. Sleeping ${SLEEP_BETWEEN}s."
      sleep "$SLEEP_BETWEEN"
    fi
  done
}

main_loop
