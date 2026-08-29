#!/usr/bin/env bash
# TANDEM_WEB_SEARCH closes the native web_search channel on every Codex seat
# without changing the default read-only policy. The pin's position, the
# explicit `on` no-op, the swarm banner and fail-closed validation are all part
# of the public contract.
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "review {{TARGET}}"
printf 'fully rendered seat prompt\n' >"$SANDBOX/seat.txt"
export CODEX_STUB_SCENARIO=ok
export CODEX_STUB_THREAD_ID=thr_web_search

# --- off: start, resume and all swarm tiers carry the pin -------------------
export TANDEM_WEB_SEARCH=off

run bash "$SCRIPTS/codex-start.sh" review web-start "$SANDBOX/p.tpl"
assert_rc 0 "read-only start with web search off"
START_KEY="$(tkey web-start)"
REVIEW_SD="$(state_dir review)"
assert_argv 1 "exec${US}--json${US}--skip-git-repo-check${US}--color${US}never${US}--model${US}gpt-5.6-sol${US}--sandbox${US}read-only${US}-c${US}model_reasoning_effort=xhigh${US}--ignore-user-config${US}--ignore-rules${US}-c${US}sandbox_mode=read-only${US}-c${US}sandbox_workspace_write.network_access=false${US}-c${US}sandbox_workspace_write.writable_roots=[]${US}-c${US}approval_policy=never${US}-c${US}approvals_reviewer=user${US}-c${US}web_search=disabled${US}--output-last-message${US}$REVIEW_SD/$START_KEY.t1.reply.txt${US}-"
assert_file_contains "$ERR" "web_search pinned off on every seat (TANDEM_WEB_SEARCH=off)"

seed_thread review web-resume thr_web_search 4
RESUME_KEY="$(tkey web-resume)"
run bash "$SCRIPTS/codex-resume.sh" review web-resume "$SANDBOX/p.tpl"
assert_rc 0 "read-only resume with web search off"
assert_argv 2 "exec${US}--json${US}--skip-git-repo-check${US}--color${US}never${US}--model${US}gpt-5.6-sol${US}--sandbox${US}read-only${US}-c${US}model_reasoning_effort=xhigh${US}--ignore-user-config${US}--ignore-rules${US}-c${US}sandbox_mode=read-only${US}-c${US}sandbox_workspace_write.network_access=false${US}-c${US}sandbox_workspace_write.writable_roots=[]${US}-c${US}approval_policy=never${US}-c${US}approvals_reviewer=user${US}-c${US}web_search=disabled${US}--output-last-message${US}$REVIEW_SD/$RESUME_KEY.t5.reply.txt${US}resume${US}thr_web_search${US}-"
assert_file_contains "$ERR" "web_search pinned off on every seat (TANDEM_WEB_SEARCH=off)"

run bash "$SCRIPTS/codex-swarm.sh" judge web-run judge-off "$SANDBOX/seat.txt"
assert_rc 0 "judge with web search off"
RUN_KEY="$(tkey web-run)"
JUDGE_KEY="$(tkey judge-off)"
ULTRA_SD="$CLAUDE_PROJECT_DIR/.tandem/state/ultra/$RUN_KEY"
assert_argv 3 "exec${US}--json${US}--skip-git-repo-check${US}--color${US}never${US}--model${US}gpt-5.6-sol${US}--sandbox${US}read-only${US}-c${US}model_reasoning_effort=xhigh${US}--ignore-user-config${US}--ignore-rules${US}-c${US}sandbox_mode=read-only${US}-c${US}sandbox_workspace_write.network_access=false${US}-c${US}sandbox_workspace_write.writable_roots=[]${US}-c${US}approval_policy=never${US}-c${US}approvals_reviewer=user${US}-c${US}web_search=disabled${US}--output-last-message${US}$ULTRA_SD/$JUDGE_KEY.reply.txt${US}-"
assert_file_contains "$ERR" "web_search=off"

run bash "$SCRIPTS/codex-swarm.sh" worker web-run worker-off "$SANDBOX/seat.txt"
assert_rc 0 "worker with web search off"
run bash "$SCRIPTS/codex-swarm.sh" scout web-run scout-off "$SANDBOX/seat.txt"
assert_rc 0 "scout with web search off"

i=3
while [ "$i" -le 5 ]; do
  assert_file_contains "$CODEX_STUB_LOG.argv.$i" "web_search=disabled"
  i=$((i + 1))
done

# A write seat already closes web search. The switch must not append a second
# copy when both branches of the policy are true.
run bash "$SCRIPTS/codex-start.sh" implement web-implement-off "$SANDBOX/p.tpl"
assert_rc 0 "write seat with web search off"
assert_eq "1" "$(tr "$US" '\n' <"$CODEX_STUB_LOG.argv.6" | grep -c '^web_search=disabled$')" \
  "web_search pin occurrences on a write seat"

# --- on: an explicit default for read-only, never an opener for write seats -
export TANDEM_WEB_SEARCH=on
run bash "$SCRIPTS/codex-start.sh" review web-review-on "$SANDBOX/p.tpl"
assert_rc 0 "read-only start with web search on"
assert_not_contains "$CODEX_STUB_LOG.argv.7" "web_search"

run bash "$SCRIPTS/codex-start.sh" implement web-implement-on "$SANDBOX/p.tpl"
assert_rc 0 "write start with web search on"
assert_file_contains "$CODEX_STUB_LOG.argv.8" "web_search=disabled"

# With the variable absent, swarm keeps the established read-only policy and
# exposes that effective state as the final banner field.
unset TANDEM_WEB_SEARCH
run bash "$SCRIPTS/codex-swarm.sh" worker web-run worker-default "$SANDBOX/seat.txt"
assert_rc 0 "default swarm banner"
assert_file_contains "$ERR" "concurrency=4 web_search=on"
assert_not_contains "$CODEX_STUB_LOG.argv.9" "web_search"

# --- empty/unknown: usage error before dependencies, codex or state ----------
seed_thread review web-refused thr_web_search 7
REFUSED_TURN="$REVIEW_SD/$(tkey web-refused).turn"
MINBIN="$(make_minbin)"

refused() {
  # refused <script> <value> <label>
  local script="$1" value="$2" label="$3"
  rm -f "$CODEX_STUB_LOG".*
  case "$script" in
    codex-start.sh | codex-resume.sh)
      run env PATH="$MINBIN" TANDEM_WEB_SEARCH="$value" \
        bash "$SCRIPTS/$script" review web-refused "$SANDBOX/p.tpl"
      ;;
    codex-swarm.sh)
      run env PATH="$MINBIN" TANDEM_WEB_SEARCH="$value" \
        bash "$SCRIPTS/$script" worker refused-run refused-seat "$SANDBOX/seat.txt"
      ;;
  esac
  assert_rc 64 "$label"
  assert_file_contains "$ERR" "TANDEM_WEB_SEARCH is not a valid value"
  assert_not_contains "$ERR" "codex CLI not found"
  assert_no_file "$CODEX_STUB_LOG.n"
  assert_no_file "$CODEX_STUB_LOG.argv.1"
  assert_eq "7" "$(cat "$REFUSED_TURN")" "turn counter after $label"
}

for SCRIPT in codex-start.sh codex-resume.sh codex-swarm.sh; do
  refused "$SCRIPT" "" "$SCRIPT empty TANDEM_WEB_SEARCH"
  refused "$SCRIPT" bogus "$SCRIPT unknown TANDEM_WEB_SEARCH"
done

