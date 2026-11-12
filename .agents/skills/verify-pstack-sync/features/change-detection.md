# Change detection

A scheduled run decides whether upstream's `pstack` subtree actually moved. If it did not, the run stops after the comparison and publishes nothing; if it did, the whole pipeline runs. A maintainer sees this as the difference between a sixteen-second green run and a multi-minute run that produces a commit, a tag, and a release.

## Sub-features

- `detect-unchanged` reports `changed=no` when the pinned subtree hash equals upstream's current `pstack` tree.
- `detect-changed` reports `changed=yes` when the hashes differ.
- `detect-missing-field` reports `changed=yes` when `pin.json` has no `pstackTree`, so an old pin forces one resync that writes the field back.
- `detect-scope` ignores upstream commits that touch directories other than `pstack`.

## How to get to it (user POV)

- Wait for the `0 0 */3 * *` schedule and read the run's step list.
- Trigger the workflow manually with `gh workflow run sync-pstack`.
- Read `pin.json` to see which upstream commit and subtree the repository is currently aligned to.

## Driving it with drive.ps1

Preconditions:

- `doctor.ps1` exits 0.
- `upstream/` resolves `HEAD:pstack` to a tree hash.

- **Unchanged.** Run `pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature detect -Scenario unchanged -RunId detect-1`. `verdict.json` shows `changed: "no"` and the assertion `detect scenario=unchanged changed=no want=no` passes.
- **Changed.** Run the same command with `-Scenario changed`. The harness empties `pstackTree` in a scratch copy of `pin.json`; expect `changed: "yes"`.
- **Missing field.** Run with `-Scenario missing-field`. The harness removes `pstackTree` entirely; expect `changed: "yes"`.
- **Scope.** Compare `git -C upstream rev-parse HEAD` with `git -C upstream rev-parse HEAD:pstack`. The first changes on any upstream commit; only the second drives a resync. `detect.txt` records both values as `new=` and the computed tree.
- **Live alignment.** Run `jq -r '.pstackTree' pin.json` and `gh api repos/cursor/plugins/git/trees/main --jq '.tree[] | select(.path=="pstack") | .sha'`. Equal values mean the next scheduled run will short-circuit.

## Gotchas

- A green run with `changed=no` exercises only the clone and the hash comparison. It is not evidence that the transform, the gates, or publication work. Do not cite a short-circuited cron as proof of a fix.
- The three scenarios mutate a scratch copy of `pin.json`, never the repository's. If `pin.json` in the working tree changes after a detect drive, something is wrong with the harness.
- `--depth 1 --filter=blob:none --sparse` still resolves `HEAD:pstack`, because a tree hash needs no blob content. Do not "fix" this by fetching full history.
- Upstream's default branch is whatever `git clone` selects. A renamed default branch changes what `HEAD` means without changing this repository.