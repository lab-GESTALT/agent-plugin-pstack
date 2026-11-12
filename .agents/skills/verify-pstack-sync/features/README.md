# pstack-sync verification map

This directory is the maintained source for verifying the user-facing behavior of the pstack sync pipeline. Read the index before driving, then use the matching feature file as the recipe.

## Baseline preconditions

- Run from the repository root. All paths below are repository-relative.
- `pwsh`, `git`, `jq`, `zip`, `bash` on PATH.
- `upstream/` holds a sparse clone of `cursor/plugins` with `pstack` checked out, and its HEAD equals `pin.json.commit`. `pin.pstackTree` may be blank or stale — scenarios that need a synced pin derive it by running the real `Record upstream` step, so a mid-sync pin is a valid starting state.
- Run `pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/doctor.ps1` and require exit 0 before the first drive of a run.
- Never drive against a scratch root left over from an earlier run. Each drive builds its own and removes it.
- `detect`, `publish`, and `alert` drive a local bare remote with a shared `gh` stub. They never contact GitHub and never push to `origin` of this repository.

## Driving conventions

- Start every recipe from the baseline state unless its preconditions say otherwise.
- Treat every command as literal. Keep quoted names and flags unchanged.
- The harness extracts `run:` blocks from `.github/workflows/sync.yml` at drive time. Do not paste workflow logic into a fixture or a helper; a second copy drifts.
- Extracted steps run under `bash -e -o pipefail`, the Actions default shell on Linux, with the working directory set to the scratch root. A step driven under plain `bash` can mask a failure behind its last successful command.
- A failed step aborts the rest of the job, as GitHub does without `continue-on-error`. Later steps are recorded as `skipped`.
- Fixtures are overlays on `fixtures/base/`. A fixture directory contains `plugins/...` or `output/...` directly, with no extra wrapper level.
- Restore nothing by hand: each drive's scratch root is disposable. Do not remove proof artifacts during cleanup.

## Proof and skip reporting

- Capture the command, its stdout+stderr, and its exit code. The harness writes these per step.
- A mutation proof includes a read-only second view of the stored value: `publish` reads `pin.json` and the plugin manifest back out of the bare remote with `git show main:<path>`.
- Record the feature ID and the scenario or fixture name with every artifact. `verdict.json` carries both.
- An exit code of 0 is not proof of publication. Assert on the resulting remote state, and derive success from observed calls and exit codes rather than from the scenario name.
- A scenario name is not coverage. If a path is only reached under a race or a refusal, assert that the branch actually ran — for example that the push-retry warning appears in the step log.
- A precondition the harness invents is not the product's precondition. Where a scenario needs a state the pipeline itself produces, run the step that produces it, and prove the derivation by mutating that step.
- Report an unreachable path with the attempted command and the unmet precondition. Do not report a skipped entry point as verified through a different path.
- These drives observe one run each. Whether a later run recovers from a red one is model-checked by the sibling `formal-verify-pstack-sync` skill; a green drive here does not establish it.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior. It then uses exactly four H2 sections in this order.

1. `Sub-features` lists short IDs with one line for each behavior.
2. `How to get to it (user POV)` lists every user entry point.
3. `Driving it with drive.ps1` starts with `Preconditions:` and uses labeled bullets that pair each user action with an exact command and observable result.
4. `Gotchas` lists traps that can waste or invalidate a verification run.

Keep implementation details out of the map. Name only user paths, stable handles, required state, commands, and observable proof.

## Features

- [Transform upstream into both artifacts](./transform.md) covers the AP 1.0 output, the committed Claude Code plugin, license propagation, and skill parity.
- [Validation gates](./gates.md) covers residual scanning, the frontmatter contract, the AP manifest contract, and the marketplace dry-run, with a red/green fixture corpus.
- [Change detection](./change-detection.md) covers the subtree-hash short circuit, the two pin states that force a resync, and the missing-release self-heal.
- [Publication](./publication.md) covers commit, tag, push, and release, including the two formerly silent-success paths, the push race, and the self-heal rerun.
- [Failure alerting](./alerting.md) covers the issue a failed run opens and whether it carries enough output to locate the failure.