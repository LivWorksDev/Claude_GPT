#!/usr/bin/env bash
# The `council` role and the turn receipt.
#
# A1 — `council` is a role of its OWN (Astra, max, read-only, watchdog 3600):
# its pins are re-applied by resolve_role on every resume, so a continuation can
# never fall back to ask's xhigh or to the 540 s foreground watchdog. Its
# variables are its own, it keeps web search like every read-only seat unless
# TANDEM_WEB_SEARCH=off, and it is exec-only: under TANDEM_TRANSPORT=mcp the
# closed role case answers 64 before the stub or any state moves.
#
# A1b — every successful start and resume, of EVERY role, leaves the receipt
# <key>.t<N>.ok = {turn, thread_id, reply_sha256}; no failure path of the
# suite writes it. It is the only durable proof that a turn passed the
# wrapper's validation (scripts/council.sh refuses to publish without it).
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

make_repo "$CLAUDE_PROJECT_DIR"
tpl "$SANDBOX/p.tpl" "council turn for {{TARGET}}"
export CODEX_STUB_SCENARIO=ok
SD="$(state_dir council)"

pins_ro() {
  # The read-only policy block, joined like the stub records it.
  printf '%s' "--ignore-user-config${US}--ignore-rules${US}-c${US}sandbox_mode=read-only${US}-c${US}sandbox_workspace_write.network_access=false${US}-c${US}sandbox_workspace_write.writable_roots=[]${US}-c${US}approval_policy=never${US}-c${US}approvals_reviewer=user"
}

stub_n() { if [ -f "$CODEX_STUB_LOG.n" ]; then cat "$CODEX_STUB_LOG.n"; else printf '0'; fi; }

sha_of() { shasum -a 256 <"$1" | cut -d' ' -f1; }

# =============================================================================
# A1 — the argv of a council turn, start and resume, byte for byte
# =============================================================================
run bash "$SCRIPTS/codex-start.sh" council c-start "$SANDBOX/p.tpl"
assert_rc 0 "council start"
KEY="$(tkey c-start)"
assert_argv 1 "exec${US}--json${US}--skip-git-repo-check${US}--color${US}never${US}--model${US}gpt-6-astra${US}--sandbox${US}read-only${US}-c${US}model_reasoning_effort=max${US}$(pins_ro)${US}--output-last-message${US}$SD/$KEY.t1.reply.txt${US}-"
assert_not_contains "$CODEX_STUB_LOG.argv.1" "web_search"
assert_file_contains "$ERR" "role=council model=gpt-6-astra effort=max sandbox=read-only target=c-start"
assert_json "$SD/$KEY.t1.meta.json" '. == {role:"council", model:"gpt-6-astra", effort:"max", sandbox:"read-only"}'

run bash "$SCRIPTS/codex-resume.sh" council c-start "$SANDBOX/p.tpl"
assert_rc 0 "council resume"
assert_argv 2 "exec${US}--json${US}--skip-git-repo-check${US}--color${US}never${US}--model${US}gpt-6-astra${US}--sandbox${US}read-only${US}-c${US}model_reasoning_effort=max${US}$(pins_ro)${US}--output-last-message${US}$SD/$KEY.t2.reply.txt${US}resume${US}thr_stub_1${US}-"
assert_not_contains "$CODEX_STUB_LOG.argv.2" "web_search"

# TANDEM_WEB_SEARCH=off closes the read-only seat's search, in its pin
# position — and, in the SAME turns, the review role's variables are exported:
# the exact argv proves that neither TANDEM_REVIEW_MODEL nor _EFFORT reaches
# the council (one comparison, two contracts, two turns fewer).
run env TANDEM_WEB_SEARCH=off TANDEM_REVIEW_MODEL=review-only TANDEM_REVIEW_EFFORT=low \
  bash "$SCRIPTS/codex-start.sh" council c-web-off "$SANDBOX/p.tpl"
assert_rc 0 "council start, web search off, TANDEM_REVIEW_* exported"
assert_argv 3 "exec${US}--json${US}--skip-git-repo-check${US}--color${US}never${US}--model${US}gpt-6-astra${US}--sandbox${US}read-only${US}-c${US}model_reasoning_effort=max${US}$(pins_ro)${US}-c${US}web_search=disabled${US}--output-last-message${US}$SD/$(tkey c-web-off).t1.reply.txt${US}-"
run env TANDEM_WEB_SEARCH=off TANDEM_REVIEW_MODEL=review-only TANDEM_REVIEW_EFFORT=low \
  bash "$SCRIPTS/codex-resume.sh" council c-web-off "$SANDBOX/p.tpl"
assert_rc 0 "council resume, web search off, TANDEM_REVIEW_* exported"
assert_argv 4 "exec${US}--json${US}--skip-git-repo-check${US}--color${US}never${US}--model${US}gpt-6-astra${US}--sandbox${US}read-only${US}-c${US}model_reasoning_effort=max${US}$(pins_ro)${US}-c${US}web_search=disabled${US}--output-last-message${US}$SD/$(tkey c-web-off).t2.reply.txt${US}resume${US}thr_stub_1${US}-"

# Its own variables win, on start AND resume.
run env TANDEM_COUNCIL_MODEL=custom-council TANDEM_COUNCIL_EFFORT=ultra \
  bash "$SCRIPTS/codex-start.sh" council c-ovr "$SANDBOX/p.tpl"
assert_rc 0 "council start with overrides"
assert_argv 5 "exec${US}--json${US}--skip-git-repo-check${US}--color${US}never${US}--model${US}custom-council${US}--sandbox${US}read-only${US}-c${US}model_reasoning_effort=ultra${US}$(pins_ro)${US}--output-last-message${US}$SD/$(tkey c-ovr).t1.reply.txt${US}-"
run env TANDEM_COUNCIL_MODEL=custom-council TANDEM_COUNCIL_EFFORT=ultra \
  bash "$SCRIPTS/codex-resume.sh" council c-ovr "$SANDBOX/p.tpl"
assert_rc 0 "council resume with overrides"
assert_argv 6 "exec${US}--json${US}--skip-git-repo-check${US}--color${US}never${US}--model${US}custom-council${US}--sandbox${US}read-only${US}-c${US}model_reasoning_effort=ultra${US}$(pins_ro)${US}--output-last-message${US}$SD/$(tkey c-ovr).t2.reply.txt${US}resume${US}thr_stub_1${US}-"

# --- exec-only: mcp answers 64 before the stub and before any state ----------
BEFORE_N="$(stub_n)"
run env TANDEM_TRANSPORT=mcp bash "$SCRIPTS/codex-start.sh" council c-mcp "$SANDBOX/p.tpl"
assert_rc 64 "council start under mcp"
assert_file_contains "$ERR" "TANDEM_TRANSPORT=mcp supports roles ask, review, implement and image (got: 'council')"
assert_eq "$BEFORE_N" "$(stub_n)" "exec invocations after the mcp start"
assert_no_file "$CODEX_STUB_LOG.mcp.in"
assert_no_file "$SD/$(tkey c-mcp).turn"
assert_no_file "$SD/$(tkey c-mcp).t1.prompt.txt"

TURN_BEFORE="$(cat "$SD/$KEY.turn")"
run env TANDEM_TRANSPORT=mcp bash "$SCRIPTS/codex-resume.sh" council c-start "$SANDBOX/p.tpl"
assert_rc 64 "council resume under mcp"
assert_eq "$BEFORE_N" "$(stub_n)" "exec invocations after the mcp resume"
assert_no_file "$CODEX_STUB_LOG.mcp.in"
assert_eq "$TURN_BEFORE" "$(cat "$SD/$KEY.turn")" "turn counter after the mcp resume"

# A fresh project: no council state may have been created by a refused start.
FRESH="$SANDBOX/fresh-project"
make_repo "$FRESH"
run env CLAUDE_PROJECT_DIR="$FRESH" TANDEM_TRANSPORT=mcp \
  bash "$SCRIPTS/codex-start.sh" council c-mcp-fresh "$SANDBOX/p.tpl"
assert_rc 64 "council start under mcp, fresh project"
assert_no_file "$FRESH/.tandem"

# --- the watchdog literal and its resolution ----------------------------------
assert_file_contains "$SCRIPTS/_common.sh" "TANDEM_EXEC_TIMEOUT_DEFAULT_COUNCIL=3600"
watchdog_of() (
  # shellcheck source=../scripts/_common.sh
  . "$SCRIPTS/_common.sh"
  exec_timeout_validate council
  printf '%s' "$EXEC_TIMEOUT"
)
assert_eq "3600" "$(env -u TANDEM_EXEC_TIMEOUT_SECONDS bash -c "$(declare -f watchdog_of); SCRIPTS='$SCRIPTS'; watchdog_of")" \
  "exec_timeout_validate council"
assert_eq "77" "$(env TANDEM_EXEC_TIMEOUT_SECONDS=77 bash -c "$(declare -f watchdog_of); SCRIPTS='$SCRIPTS'; watchdog_of")" \
  "TANDEM_EXEC_TIMEOUT_SECONDS wins over the council default"

# =============================================================================
# A1b — the receipt of every successful turn, in every role
# =============================================================================
# The FAILURE paths of the suite are asserted where those scenarios already
# live — start-codex-fails-exit1-not-rc (fail), start-empty-reply-exit1,
# start-no-thread-event-exit1, resume-fallback-guard-full (the wrong thread
# whose reply stays on disk on purpose) and exec-watchdog (start and resume):
# each of them now pins that no t<N>.ok is left behind.
assert_receipt() {
  # assert_receipt <role> <target> <turn> <thread> [null] — the exact object.
  local role="$1" target="$2" n="$3" thr="$4" dir key sha
  dir="$(state_dir "$role")"
  key="$(tkey "$target")"
  assert_file "$dir/$key.t$n.ok"
  if [ "${5:-}" = "null" ]; then
    sha=null
  else
    sha="\"$(sha_of "$dir/$key.t$n.reply.txt")\""
  fi
  assert_json "$dir/$key.t$n.ok" ". == {turn: $n, thread_id: \"$thr\", reply_sha256: $sha}"
}

# council: the start and the resume of A1 above.
assert_receipt council c-start 1 thr_stub_1
assert_receipt council c-start 2 thr_stub_1

# Every other role, start and resume. The image start runs WITHOUT any sha256
# tool on PATH: the receipt still lands, with a null digest.
NOSHA="$(make_minbin)"
ln -sf "$(command -v jq)" "$NOSHA/jq"
ln -sf "$SANDBOX/bin/codex" "$NOSHA/codex"
for role in review ask implement image; do
  if [ "$role" = "image" ]; then
    run env PATH="$NOSHA" CODEX_STUB_LOG="$CODEX_STUB_LOG" CODEX_STUB_THREAD_ID="thr_rcpt_$role" \
      bash "$SCRIPTS/codex-start.sh" "$role" "rcpt-$role" "$SANDBOX/p.tpl"
    assert_rc 0 "$role start without a sha256 tool"
    assert_receipt "$role" "rcpt-$role" 1 "thr_rcpt_$role" null
  else
    run env CODEX_STUB_THREAD_ID="thr_rcpt_$role" bash "$SCRIPTS/codex-start.sh" "$role" "rcpt-$role" "$SANDBOX/p.tpl"
    assert_rc 0 "$role start"
    assert_receipt "$role" "rcpt-$role" 1 "thr_rcpt_$role"
  fi
  run env CODEX_STUB_THREAD_ID="thr_rcpt_$role" bash "$SCRIPTS/codex-resume.sh" "$role" "rcpt-$role" "$SANDBOX/p.tpl"
  assert_rc 0 "$role resume"
  assert_receipt "$role" "rcpt-$role" 2 "thr_rcpt_$role"
done

# The mcp start shares the success tail of every transport: same receipt.
mkdir -p "$HOME/.codex"
printf '{"tokens":{"access":"fake-for-tests"}}\n' >"$HOME/.codex/auth.json"
run env TANDEM_TRANSPORT=mcp TANDEM_MCP_TIMEOUT_SECONDS=20 CODEX_STUB_MCP_ROLLOUT=1 \
  CODEX_STUB_MCP_THREAD_ID=thr_rcpt_mcp CODEX_STUB_THREAD_ID=thr_rcpt_mcp \
  bash "$SCRIPTS/codex-start.sh" ask rcpt-mcp "$SANDBOX/p.tpl"
assert_rc 0 "mcp ask start"
assert_receipt ask rcpt-mcp 1 thr_rcpt_mcp

# codex-reset.sh deletes the receipts with the rest of the target's state.
run bash "$SCRIPTS/codex-reset.sh" review rcpt-review
assert_rc 0 "reset of a target with receipts"
assert_no_file "$(state_dir review)/$(tkey rcpt-review).t1.ok"
assert_no_file "$(state_dir review)/$(tkey rcpt-review).t2.ok"

note "council role pinned (Astra/max/read-only/3600, exec-only); receipts written on every successful start/resume, in every role"
