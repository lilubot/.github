# lilubot/.github

Fleet CI standard v1 (spec: fleet `reviews/workflow-audit-2026-11-06.md` §4–5). Public and secret-free: callers pass secrets explicitly and every job runs on the caller's own runners.

| reusable | checks it reports (`<caller job> / …`) | caller grants |
|---|---|---|
| `fast.yml` | `lint`, `typecheck`, `fast` | `contents: read` |
| `security.yml` | `zizmor`, `gitleaks`, `osv` (+`trivy`) | `contents: read` |
| `semgrep.yml` | `semgrep` | `contents: read` |
| `heavy.yml` | `gate` (require this one only), plus one check per leg | `contents: read, statuses: write, pull-requests: read, actions: read` |
| `ocr.yml` | `review` | `contents: read, pull-requests: write, actions: write` |
| `pr-hygiene.yml` | `draft-guard`, `merge-receipt`, `merge-conflict` | see its header |
| `preflight.yml` | `runners` | none |
| `.github/actions/tree-verdict` | composite: `mode: lookup\|post` | lookup: read, post: `statuses: write` |

## Runner-agnostic profiles

No workflow here hard-codes a runner label. A repo's **profile is its thin caller** (`.github/workflows/fleet.yml`): each lane's `runner` (JSON label list), toolchain (`setup`, `setup-version`, `setup-cmd`) and commands are `with:` inputs. Heavy takes any number of legs, each on its own pool and shell:

```yaml
name: fleet
on:
  pull_request: {types: [opened, synchronize, reopened, ready_for_review, labeled]}
  push: {branches: [main, next]}
permissions: {}
concurrency:
  group: fleet-${{ github.event_name == 'pull_request' && format('pr-{0}', github.event.pull_request.number) || format('push-{0}', github.ref) }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
jobs:
  fast:
    uses: lilubot/.github/.github/workflows/fast.yml@<sha> # v1
    permissions: {contents: read}
    with: {runner: '["self-hosted","fleet-fast"]', setup: dotnet, setup-version: "8.0.x", lint-cmd: dotnet format --verify-no-changes, test-cmd: dotnet test -c Release --filter Category!=Slow, shell: powershell}
  heavy:
    needs: fast
    uses: lilubot/.github/.github/workflows/heavy.yml@<sha> # v1
    permissions: {contents: read, statuses: write, pull-requests: read, actions: read}
    secrets: {runner-read-token: "${{ secrets.FLEET_RUNNER_READ_TOKEN }}"}
    with:
      control-runner: '["self-hosted","fleet-fast"]'
      lanes: '{"next":"^(lilubot/batch-|hotfix/)","main":"^train/[0-9]{4}-[0-9]{2}-[0-9]{2}(-[1-9][0-9]*)?$"}'
      legs: >-
        [{"name":"native","runner":["self-hosted","creo-win"],"shell":"powershell","cmd":"./ci/native.ps1","timeout":60},
         {"name":"linux","runner":["self-hosted","fleet-heavy"],"setup":"python","cmd":"scripts/ci/linux.sh","timeout":60,"artifacts":"junit*.xml"}]
```

`setup` covers `python` (uv), `node`, `dotnet`; anything else (Rust, Godot, Unity, Luau) is `setup-cmd` on a runner that has the toolchain. Pools with 0 online runners fail in seconds with the pool named (heavy's `verdict` job; `preflight.yml` for the other lanes) when `runner-read-token` (Administration: read) is passed; otherwise a warning says the check was skipped.

Runner discovery paginates repository-scoped runners only. Organization runner groups require separate organization permissions and access-policy validation; do not rely on this preflight for organization-only pools.

PowerShell profiles (`pwsh` and Windows PowerShell 5.1) must explicitly check `$LASTEXITCODE` immediately after native commands that can fail (for example, `dotnet test; if ($LASTEXITCODE) { exit $LASTEXITCODE }`). A later native command can overwrite that exit code; the workflow's final check alone cannot detect earlier failures. Handle expected nonzero exits explicitly in the profile.

## Tree-verdict reuse (heavy)

On a miss heavy runs its legs, then posts commit status `verdict/heavy` = `tree=<T>` on the PR head (push: the pushed SHA). The next run whose commit has tree `T` (the squash on next, the train PR, the main push) finds it through `GET /commits/{sha}/pulls`, checks the creator is `github-actions[bot]` and the linked run is this repo's same workflow file with conclusion `success`, skips the legs, and re-stamps. Equal trees include equal workflow files, so the battery is identical. Any doubt is a miss. Limit: a write-access author could post a forged status from a modified workflow; that workflow is part of the tree it covers, so it lands only through review.

`lanes` maps a base branch to the heads allowed to run heavy into it; any other PR into a mapped base **fails closed** (`gate` red), because a skipped required check counts as green.

## Labels and rulesets (templates, not applied)

`labels.json` and `rulesets/{next,main}.json` are templates. Owner applies (O1):

```sh
jq -c '.[]' labels.json | while read -r l; do gh label create "$(jq -r .name <<<"$l")" -R lilubot/REPO --force --color "$(jq -r .color <<<"$l")" --description "$(jq -r .description <<<"$l")"; done
gh api -X PUT repos/lilubot/REPO/rulesets/RULESET_ID --input rulesets/next.json   # or -X POST repos/lilubot/REPO/rulesets
```

## Releasing

Callers pin a full SHA. Bump: merge here, then update `@<sha>` in each caller (one PR per repo). Edit `.github/scripts/fleet-ci.sh`, then `tests/fleet-ci.test.sh --sync` to re-embed it into `heavy.yml`/`preflight.yml` (reusable workflows cannot read this repo's files at run time). `ci.yml` lints everything, runs `tests/*.test.sh`, and calls every reusable workflow on GitHub-hosted runners, including a heavy→heavy reuse proof.
