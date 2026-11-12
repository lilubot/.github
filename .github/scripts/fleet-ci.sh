#!/usr/bin/env bash
# fleet-ci helper: heavy-lane decisions and tree-SHA verdict reuse
# (fleet CI standard §4.3). heavy.yml embeds a byte-identical copy between
# its BEGIN/END markers (a reusable workflow cannot read this repo's files);
# tests/fleet-ci.test.sh fails when the copies drift.
#
# Usage: fleet-ci.sh <lane|pools|lookup|post|gate>; inputs via env, results
# as key=value lines on stdout (append to $GITHUB_OUTPUT). Needs bash + gh.
set -euo pipefail

# Workflow commands (::error::) are parsed from stderr too; stdout carries
# only key=value results for $GITHUB_OUTPUT.
die() { echo "::error::$*" >&2; exit 1; }

# lane: EVENT BASE_REF HEAD_REF SAME_REPO DRAFT LANE_RE -> lane=run|skip|refuse
# LANE_RE is the caller's regex for this PR's base (empty: every head runs).
fleet_lane() {
  case "${EVENT:-}" in pull_request|pull_request_target) ;; *) echo lane=run; return ;; esac
  if [ "${DRAFT:-false}" = true ]; then echo lane=skip; return; fi
  if [ -z "${LANE_RE:-}" ]; then echo lane=run; return; fi
  if [ "${SAME_REPO:-false}" = true ] && [[ "${HEAD_REF:-}" =~ $LANE_RE ]]; then echo lane=run; return; fi
  echo "::error::${BASE_REF:-?} accepts heavy-lane PRs only from same-repo heads matching ${LANE_RE}; '${HEAD_REF:-}' is refused (fail closed: a skipped heavy run would count as green)" >&2
  echo lane=refuse
}

# pools: REPO POOLS (JSON list of label lists) GH_TOKEN (Administration: read).
# Fails when a self-hosted pool has 0 online runners, so a leg errors in
# seconds instead of queueing for GitHub's 24 h limit. GitHub-hosted pools
# (no "self-hosted" label) are not checked. No token: warn, skip the check.
fleet_pools() {
  if [ -z "${GH_TOKEN:-}" ]; then
    echo "::warning::runner-read-token not set: cannot verify runner pools are online; an offline pool will queue, not fail" >&2
    return 0
  fi
  local rows bad=0 n pool
  rows=$(gh api "repos/$REPO/actions/runners?per_page=100" --paginate --slurp --jq "
    [.[].runners[] | select(.status == \"online\") | [.labels[].name | ascii_downcase]] as \$on
    | ${POOLS} | .[] | map(ascii_downcase) as \$p
    | if (\$p | index(\"self-hosted\")) == null then empty
      else \"\([\$on[] | select(. as \$l | \$p | all(. as \$x | \$l | index(\$x) != null))] | length)\t\(\$p | join(\",\"))\" end") \
    || die "runner pool check failed (token needs Administration: read on $REPO)"
  while IFS=$'\t' read -r n pool; do
    [ -n "$n" ] || continue
    if [ "$n" -eq 0 ]; then echo "::error::runner pool [$pool] has 0 online runners in $REPO: the leg would queue forever; bring a runner online or change the repo's fleet profile" >&2; bad=1
    else echo "runner pool [$pool]: $n online" >&2; fi
  done <<<"$rows"
  return "$bad"
}

tree_of() {
  local t
  t=$(gh api "repos/$REPO/git/commits/$1" --jq .tree.sha) || return 1
  [[ "$t" =~ ^[0-9a-f]{40}$ ]] || return 1
  echo "$t"
}

# lookup: REPO SHA HEAD_SHA RUN_ID SERVER_URL CONTEXT -> tree=T hit=true|false url=U
# A verdict is a CONTEXT commit status by github-actions[bot], state success,
# description "tree=T", whose target_url is a run of this same workflow file
# in this repo that concluded success (or is this run). Candidates: SHA,
# HEAD_SHA and the heads of PRs containing either (a squash on next points
# back at its batch PR). Any API error or doubt is a miss; a miss runs heavy.
fleet_lookup() {
  local tree c url id path concl my_path cands=() seen=" "
  tree=$(tree_of "$SHA") || die "cannot read the tree of $SHA"
  echo "tree=$tree"
  my_path=$(gh api "repos/$REPO/actions/runs/$RUN_ID" --jq .path 2>/dev/null) || { echo hit=false; return 0; }
  for c in "$SHA" "${HEAD_SHA:-}"; do
    [ -n "$c" ] || continue
    cands+=("$c")
    while read -r h; do [ -n "$h" ] && cands+=("$h"); done < <(gh api "repos/$REPO/commits/$c/pulls" --jq '.[].head.sha' 2>/dev/null || true)
  done
  for c in "${cands[@]}"; do
    case "$seen" in *" $c "*) continue ;; esac
    seen="$seen$c "
    while read -r url; do
      [[ "$url" =~ ^"$SERVER_URL/$REPO/actions/runs/"([0-9]+)$ ]] || continue
      id=${BASH_REMATCH[1]}
      read -r path concl < <(gh api "repos/$REPO/actions/runs/$id" --jq '"\(.path) \(.conclusion)"' 2>/dev/null || echo "- -")
      [ "$path" = "$my_path" ] || continue
      if [ "$concl" = success ] || [ "$id" = "$RUN_ID" ]; then
        echo "::notice::heavy verdict reused: tree $tree passed in $url (status on $c)" >&2
        echo hit=true
        echo "url=$url"
        return 0
      fi
    done < <(gh api "repos/$REPO/commits/$c/statuses?per_page=100" --jq ".[] | select(.context == \"$CONTEXT\" and .state == \"success\" and .creator.login == \"github-actions[bot]\" and .description == \"tree=$tree\") | .target_url" 2>/dev/null || true)
  done
  echo hit=false
}

# post: REPO SHA TREE CONTEXT URL. Best effort: a failed post only costs the
# next lane a rerun (fork PRs have a read-only token and always land here).
fleet_post() {
  [[ "$TREE" =~ ^[0-9a-f]{40}$ ]] || die "post: bad tree '$TREE'"
  if gh api -X POST "repos/$REPO/statuses/$SHA" -f state=success -f context="$CONTEXT" \
      -f description="tree=$TREE" -f target_url="$URL" >/dev/null; then
    echo "posted $CONTEXT tree=$TREE on $SHA" >&2
  else
    echo "::warning::could not post $CONTEXT on $SHA; the next lane will rerun heavy" >&2
  fi
}

# gate: VERDICT_RESULT LANE HIT LEGS_RESULT -> exit 0 only when proven.
fleet_gate() {
  [ "${VERDICT_RESULT:-}" = success ] || die "heavy verdict job ${VERDICT_RESULT:-missing}: lane refused, runner pool offline or lookup error (see the verdict job)"
  case "${LANE:-}" in
    skip) echo "::notice::draft PR: heavy not run; it runs on ready_for_review" >&2; return 0 ;;
    run) ;;
    *) die "unknown lane '${LANE:-}'" ;;
  esac
  if [ "${HIT:-}" = true ]; then echo "heavy: verdict reused" >&2; return 0; fi
  [ "${LEGS_RESULT:-}" = success ] || die "heavy legs ${LEGS_RESULT:-missing}"
  echo "heavy: all legs passed" >&2
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    lane) fleet_lane ;; pools) fleet_pools ;; lookup) fleet_lookup ;;
    post) fleet_post ;; gate) fleet_gate ;;
    *) echo "usage: $0 <lane|pools|lookup|post|gate>" >&2; exit 2 ;;
  esac
fi
