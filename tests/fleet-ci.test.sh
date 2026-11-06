#!/usr/bin/env bash
# Tests for .github/scripts/fleet-ci.sh. A fake `gh` serves JSON fixtures and
# applies the real --jq filter with jq, so the filters themselves are tested.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/.github/scripts/fleet-ci.sh"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

# --- drift: heavy.yml and preflight.yml embed the script byte-identically.
# After editing fleet-ci.sh run `tests/fleet-ci.test.sh --sync` to re-embed.
for wf in "$root/.github/workflows/heavy.yml" "$root/.github/workflows/preflight.yml"; do
  if [ "${1:-}" = --sync ]; then
    awk -v src="$script" '/# BEGIN fleet-ci.sh/{print; while ((getline l < src) > 0) print (l == "" ? "" : "          " l); close(src); skip=1; next}
      /# END fleet-ci.sh/{skip=0} !skip' "$wf" >"$work/wf" && cat "$work/wf" >"$wf"
  fi
  embedded=$(awk '/# BEGIN fleet-ci.sh/{f=1;next} /# END fleet-ci.sh/{f=0} f' "$wf" | sed 's/^          //')
  if [ "$embedded" = "$(cat "$script")" ]; then ok "${wf##*/} embeds fleet-ci.sh"; else bad drift "${wf##*/} copy differs: run tests/fleet-ci.test.sh --sync"; fi
done

# --- fake gh
mkdir -p "$work/bin" "$work/fix"
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = api ] || exit 2; shift
method=GET filter=. ep=
while [ $# -gt 0 ]; do
  case "$1" in -X) method=$2; shift 2 ;; --jq) filter=$2; shift 2 ;; -f) shift 2 ;; *) ep=$1; shift ;; esac
done
if [ "$method" = POST ]; then echo "$ep" >>"$FIX/posts.log"; [ -e "$FIX/post-fails" ] && exit 1; echo '{}'; exit 0; fi
f="$FIX/$(echo "${ep%%\?*}" | tr / _).json"
[ -f "$f" ] || exit 1
jq -r "$filter" "$f"
EOF
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" FIX="$work/fix"
run() { bash "$script" "$@" 2>"$work/err"; }

# --- lane
lane() { env EVENT="$1" BASE_REF=next HEAD_REF="$2" SAME_REPO="$3" DRAFT="$4" LANE_RE="$5" bash "$script" lane 2>/dev/null; }
RE='^(lilubot/batch-|hotfix/)'
for row in \
  "push;x;false;false;$RE;run" \
  "pull_request;lilubot/batch-1;true;false;$RE;run" \
  "pull_request;hotfix/a;true;false;$RE;run" \
  "pull_request;hotfix/a;false;false;$RE;refuse" \
  "pull_request;feat/a;true;false;$RE;refuse" \
  "pull_request;feat/a;true;true;$RE;skip" \
  "pull_request;feat/a;false;false;;run"; do
  IFS=';' read -r ev head same draft re want <<<"$row"
  got=$(lane "$ev" "$head" "$same" "$draft" "$re" | sed -n 's/^lane=//p')
  [ "$got" = "$want" ] && ok "lane $ev $head same=$same draft=$draft -> $want" || bad "lane $row" "got $got"
done

# --- pools
cat >"$FIX/repos_o_r_actions_runners.json" <<'EOF'
{"runners":[
 {"status":"online","labels":[{"name":"self-hosted"},{"name":"Linux"},{"name":"nima-fast"}]},
 {"status":"offline","labels":[{"name":"self-hosted"},{"name":"creo-win"}]},
 {"status":"online","labels":[{"name":"self-hosted"},{"name":"nima-linux"},{"name":"ARM64"}]}]}
EOF
export REPO=o/r
if GH_TOKEN=x POOLS='[["self-hosted","nima-fast"],["self-hosted","nima-linux","arm64"],["ubuntu-24.04"]]' run pools; then ok "pools all online (case-insensitive, hosted skipped)"; else bad pools-online "$(cat "$work/err")"; fi
if GH_TOKEN=x POOLS='[["self-hosted","nima-fast"],["self-hosted","creo-win"]]' run pools; then bad pools-offline "passed"
elif grep -q "creo-win\] has 0 online" "$work/err"; then ok "pools: offline creo-win fails with a clear error"; else bad pools-offline "$(cat "$work/err")"; fi
if GH_TOKEN= POOLS='[["self-hosted","creo-win"]]' run pools && grep -q "cannot verify" "$work/err"; then ok "pools: no token warns, does not fail"; else bad pools-notoken "$(cat "$work/err")"; fi

# --- lookup
T=1111111111111111111111111111111111111111
export SHA=aaaa HEAD_SHA=bbbb RUN_ID=9 SERVER_URL=https://github.com CONTEXT=verdict/heavy
echo "{\"tree\":{\"sha\":\"$T\"}}" >"$FIX/repos_o_r_git_commits_aaaa.json"
echo '{"path":".github/workflows/fleet.yml","conclusion":null}' >"$FIX/repos_o_r_actions_runs_9.json"
echo '{"path":".github/workflows/fleet.yml","conclusion":"success"}' >"$FIX/repos_o_r_actions_runs_5.json"
echo '{"path":".github/workflows/other.yml","conclusion":"success"}' >"$FIX/repos_o_r_actions_runs_6.json"
echo '{"path":".github/workflows/fleet.yml","conclusion":"failure"}' >"$FIX/repos_o_r_actions_runs_7.json"
echo '[]' >"$FIX/repos_o_r_commits_aaaa_pulls.json"
echo '[{"head":{"sha":"cccc"}}]' >"$FIX/repos_o_r_commits_bbbb_pulls.json"
st() { echo "{\"context\":\"${4:-verdict/heavy}\",\"state\":\"$2\",\"creator\":{\"login\":\"$3\"},\"description\":\"tree=$1\",\"target_url\":\"https://github.com/o/r/actions/runs/$5\"}"; }
lookup_case() { # name want statuses-json-for-cccc
  rm -f "$FIX"/repos_o_r_commits_*_statuses.json
  echo "$3" >"$FIX/repos_o_r_commits_cccc_statuses.json"
  got=$(run lookup | sed -n 's/^hit=//p')
  [ "$got" = "$2" ] && ok "lookup $1 -> hit=$2" || bad "lookup $1" "got $got; $(cat "$work/err")"
}
lookup_case "valid verdict via PR head's PR" true "[$(st $T success 'github-actions[bot]' verdict/heavy 5)]"
lookup_case "other tree" false "[$(st 2222222222222222222222222222222222222222 success 'github-actions[bot]' verdict/heavy 5)]"
lookup_case "foreign creator" false "[$(st $T success 'mallory' verdict/heavy 5)]"
lookup_case "other workflow file" false "[$(st $T success 'github-actions[bot]' verdict/heavy 6)]"
lookup_case "run concluded failure" false "[$(st $T success 'github-actions[bot]' verdict/heavy 7)]"
lookup_case "this run (in progress)" true "[$(st $T success 'github-actions[bot]' verdict/heavy 9)]"
lookup_case "wrong context" false "[$(st $T success 'github-actions[bot]' verdict/other 5)]"
lookup_case "state failure" false "[$(st $T failure 'github-actions[bot]' verdict/heavy 5)]"
lookup_case "statuses api error" false "not json"
if [ "$(run lookup | sed -n 's/^tree=//p')" = "$T" ]; then ok "lookup reports the tree"; else bad lookup-tree "$(cat "$work/err")"; fi
if SHA=dead run lookup; then bad "lookup no tree" "passed"; else ok "lookup fails when the tree is unreadable"; fi

# --- post
rm -f "$FIX/posts.log"
if TREE=$T URL=u SHA=bbbb run post && grep -qx "repos/o/r/statuses/bbbb" "$FIX/posts.log"; then ok "post writes the status"; else bad post "$(cat "$work/err")"; fi
touch "$FIX/post-fails"
if TREE=$T URL=u SHA=bbbb run post && grep -q "could not post" "$work/err"; then ok "post failure only warns"; else bad post-fail "$(cat "$work/err")"; fi
if TREE=nothex URL=u SHA=bbbb run post; then bad post-badtree passed; else ok "post refuses a bad tree"; fi

# --- gate
gate() { env VERDICT_RESULT="$1" LANE="$2" HIT="$3" LEGS_RESULT="$4" bash "$script" gate 2>/dev/null && echo pass || echo fail; }
for row in "success run true skipped pass" "success run false success pass" "success run false failure fail" \
  "success run false skipped fail" "success run false cancelled fail" "failure run false skipped fail" \
  "success skip false skipped pass" "skipped run false skipped fail" "success refuse false skipped fail"; do
  read -r v l h legs want <<<"$row"
  got=$(gate "$v" "$l" "$h" "$legs")
  [ "$got" = "$want" ] && ok "gate $row" || bad "gate $row" "got $got"
done

exit "$fail"
