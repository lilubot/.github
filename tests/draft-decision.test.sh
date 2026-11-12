#!/usr/bin/env bash
# Branch coverage for .github/scripts/draft-decision.sh + drift check against
# the copy embedded in pr-hygiene.yml. Exits non-zero on any failure.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/.github/scripts/draft-decision.sh"
wf="$root/.github/workflows/pr-hygiene.yml"
fail=0

# decide DRAFT HEAD_REF SAME_REPO LABELS ACTOR READY_HEADS EXEMPT TRIAGE -> stdout
decide() {
  DRAFT=$1 HEAD_REF=$2 SAME_REPO=$3 LABELS=$4 ACTOR=$5 READY_HEADS=$6 EXEMPT_LABEL=$7 TRIAGE_USERS=$8 \
    bash "$script" 2>/dev/null
}
check() { # name want got
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want $2 got $3"; fail=1; fi
}

H='^(train/[0-9]{4}-[0-9]{2}-[0-9]{2}(-[1-9][0-9]*)?|hotfix/.+)$'
check "already draft"            keep   "$(decide true  feat/x          true  ""             dev "$H" draft-exempt "")"
check "dated train"              keep   "$(decide false train/2026-11-06 true  ""             dev "$H" draft-exempt "")"
check "dated train -N"           keep   "$(decide false train/2026-11-06-2 true ""            dev "$H" draft-exempt "")"
check "train suffix -0 rejected" demote "$(decide false train/2026-11-06-0 true ""            dev "$H" draft-exempt "")"
check "hotfix lane"              keep   "$(decide false hotfix/fix-it    true  ""             dev "$H" draft-exempt "")"
check "hotfix fork head"         demote "$(decide false hotfix/fix-it    false ""             dev "$H" draft-exempt "")"
check "train fork head"          demote "$(decide false train/2026-11-06 false ""             dev "$H" draft-exempt "")"
check "exempt label"             keep   "$(decide false feat/x           true  "bug,draft-exempt,x" dev "$H" draft-exempt "")"
check "exempt label on fork"     keep   "$(decide false feat/x           false "draft-exempt" dev "$H" draft-exempt "")"
check "label is whole-name"      demote "$(decide false feat/x           true  "draft-exempt-2" dev "$H" draft-exempt "")"
check "exempt lane off"          demote "$(decide false feat/x           true  "draft-exempt" dev "$H" "" "")"
check "triage user"              keep   "$(decide false feat/x           true  ""             dev "$H" draft-exempt "a, dev ,b")"
check "triage case-insensitive"  keep   "$(decide false feat/x           true  ""             Dev "$H" draft-exempt "dev")"
check "triage bot login"         keep   "$(decide false feat/x           true  ""             'intake[bot]' "$H" draft-exempt "dev,intake[bot]")"
check "triage substring no"      demote "$(decide false feat/x           true  ""             de  "$H" draft-exempt "dev")"
check "empty triage, empty actor" demote "$(decide false feat/x          true  ""             ""  "$H" draft-exempt "")"
check "ready-heads lane off"     demote "$(decide false hotfix/x         true  ""             dev ""   draft-exempt "")"
check "plain demote"             demote "$(decide false feat/x           true  ""             dev "$H" draft-exempt "other")"

# Drift: embedded copy in the workflow must equal the script's function block.
blk() { sed -n '/# BEGIN draft-decision/,/# END draft-decision/p' "$1" | sed 's/^ *//'; }
if [[ -n "$(blk "$script")" && "$(blk "$script")" == "$(blk "$wf")" ]]; then
  echo "ok   workflow copy matches script"
else
  echo "FAIL workflow copy of draft_decision differs from $script"; fail=1
fi
exit "$fail"
