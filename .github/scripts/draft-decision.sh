#!/usr/bin/env bash
# draft-guard decision: prints `keep` (PR stays ready) or `demote` (return to
# draft) on stdout, the reason on stderr. Pure function of its env, no network.
#
#   DRAFT        true|false  PR is already a draft
#   HEAD_REF     head branch name
#   SAME_REPO    true|false  head repo == base repo (forks never match ready heads)
#   LABELS       comma-separated PR label names
#   ACTOR        login that triggered the event
#   READY_HEADS  ERE; same-repo heads matching it stay ready ("" = lane off)
#   EXEMPT_LABEL label that keeps a PR ready ("" = lane off)
#   TRIAGE_USERS comma-separated logins that may mark ready ("" = lane off)
#
# pr-hygiene.yml embeds the function between the BEGIN/END markers verbatim
# (a reusable workflow cannot read its own repo files without a checkout);
# tests/draft-decision.test.sh fails if the two copies drift.

# BEGIN draft-decision
draft_decision() {
  local list=",${TRIAGE_USERS// /},"
  if [[ "$DRAFT" == true ]]; then
    echo "already draft" >&2; echo keep; return
  fi
  if [[ "$SAME_REPO" == true && -n "$READY_HEADS" && "$HEAD_REF" =~ $READY_HEADS ]]; then
    echo "ready head $HEAD_REF" >&2; echo keep; return
  fi
  if [[ -n "$EXEMPT_LABEL" && ",$LABELS," == *",$EXEMPT_LABEL,"* ]]; then
    echo "carries $EXEMPT_LABEL" >&2; echo keep; return
  fi
  if [[ -n "$TRIAGE_USERS" && -n "$ACTOR" && "${list,,}" == *",${ACTOR,,},"* ]]; then
    echo "$ACTOR is triage" >&2; echo keep; return
  fi
  echo "no lane matched" >&2; echo demote
}
# END draft-decision

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  draft_decision
fi
