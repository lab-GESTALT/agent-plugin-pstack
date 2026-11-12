---
name: verify-pstack-sync
description: "Drive the pstack sync pipeline for real: transform upstream into both artifacts, run the three validation gates against a red/green fixture corpus, and execute the actual sync.yml steps (change detection, commit, tag, push, release, alert) against a local bare remote. Use when changing transform/map.json, transform/scripts/*.ps1, or .github/workflows/sync.yml, or when a sync run is red or suspiciously green."
---

# Verify pstack-sync

The app under verification is a build pipeline, not a server. Its user-facing surface is the pair of artifacts it publishes (the committed Claude Code plugin under `plugins/pstack/`, and the Agent Plugins 1.0 zip attached to each release) plus the issue a failed run opens. Every drive runs the repo's real scripts and the real `run:` blocks extracted from `.github/workflows/sync.yml` — the harness never keeps a second copy of the pipeline logic.

## Launch

There is no long-lived process. Launch means: have `pwsh`, `git`, `jq`, `zip`, `bash` on PATH, and have the upstream sparse clone present. Each drive then builds its own isolated scratch root under the system temp directory and tears it down at the end.

```sh
git clone --depth 1 --filter=blob:none --sparse https://github.com/cursor/plugins.git upstream
git -C upstream sparse-checkout set pstack
```

`upstream/` is gitignored. Ready means the clone resolves `HEAD:pstack` to a tree hash, not merely that the directory exists.

## Doctor

Run this first whenever anything looks off, and again after any failed drive:

```sh
pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/doctor.ps1
```

It is read-only. It checks the toolchain, that the clone's HEAD equals `pin.json.commit`, that `map.json` and the fixture index parse, that every fixture overlays an artifact tree (`plugins/` or `output/`), that every fixture would actually ship rather than being swallowed by an ignore rule, that the upstream fetch is authenticated, and that every step the harness drives still exists in `sync.yml`. Exit 0 means the instance is worth driving. A stale clone is the most common cause of a misleading result: refresh it with `git -C upstream fetch --depth 1 origin main && git -C upstream reset --hard FETCH_HEAD` only when you intend to verify against newer upstream.

The shippable-fixture check has a reproducible mutation proof: `-Feature doctor` runs doctor once against the real repo, then again with a temporary `core.excludesFile` containing an unanchored `output/`. The second run must exit 1 naming the AP fixtures. Without that check, an ignore rule can hide a fixture locally while a fresh clone silently loses it and the corpus still reports PASS. The check asks git about the ignore rules themselves (`check-ignore --no-index`), not about the index: once a fixture is committed, an index-based check is permanently true and would stop catching the next swallowed fixture.

`-Feature doctor` carries two more mutation proofs against copies of `sync.yml`, run with `-WorkflowPath`: stripping the credential from the upstream clone URL must exit 1 naming the authenticated-fetch check, and removing `actions: read` must exit 1 naming the jobs API check. No drive ever executes `Fetch upstream` — the harness links the local clone — and a missing permission leaves the alert exiting 0 with the step name silently gone, so these static checks are the only enforcers for either failure.

## Drive

One command per feature. `-RunId` names the evidence directory; omit it and a timestamped id is generated.

```sh
# the whole red/green corpus against the current gates
pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature corpus -RunId corpus-1

# one fixture
pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature gates -Fixture fp-ts-subagent-type

# is the frontmatter field set derived from map.json, or a second hardcoded list?
pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature rules -RunId rules-1

# doctor healthy, plus the mutation proof that ignore-swallowed fixtures are caught
pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature doctor -RunId doctor-1

# real upstream -> both artifacts -> all three gates
pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature transform

# the real Detect change block: two pin states, the subtree short circuit, and the self-heal
pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature detect -Scenario unchanged
pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature detect -Scenario changed
pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature detect -Scenario missing-field
pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature detect -Scenario release-missing
pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature detect -Scenario gh-fails

# the real Record/Commit/Tag-and-push/Publish blocks against a local bare remote
pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature publish -Scenario happy
pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature publish -Scenario release-fails
pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature publish -Scenario commit-fails
pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature publish -Scenario push-rejected
pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature publish -Scenario self-heal
pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature publish -Scenario tag-serial

# the real Alert on failure block, fed a genuinely failing gate report
pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature alert -Scenario no-open-issue
pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature alert -Scenario open-issue

# failure before the gates: no gate report, no clone. Also proves the historical
# bare-link version of the step is rejected by the locatability assertion.
pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature alert -Scenario no-gate-report
pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature alert -Scenario no-log-available
```

Extracted steps run under `bash -e -o pipefail` — the Actions default shell on Linux — with the working directory set to the scratch root, and a failed step aborts the rest of the job. Both details are load-bearing: under plain `bash` a trailing `rm -f` masks a refused `gh release create`, and reading `pin.json` from the repository root instead of the scratch root proves nothing about the scenario.

`detect`, `publish`, and `alert` replace GitHub with a local bare remote and one shared `gh` stub whose behaviour is set entirely by environment variables. The stand-in setup, which the real target does not need, is recorded in each `verdict.json` under `standInSetup`: the pin and plugin version are rewound to the real historical sync state at commit `221395a` (version 0.15.32) so that a genuine advance exists to publish, and transform runs twice — once to build the baseline commit, once to simulate upstream moving forward. `self-heal` inverts the precondition and starts from the current pin, because it needs "artifacts identical, release missing". `push-rejected` injects the race with a `pre-push` hook, since advancing the remote during setup is absorbed by the step's opening rebase and never reaches the retry branch. Everything else is the repo's own code: real `git commit`, real `git tag`, real `git push`, real `zip`.

Add `-KeepRoot` to leave the scratch root in place for inspection. It is the only mode that leaves residue; clean it yourself afterwards.

## Evidence

Every drive writes to `.agents/skills/verify-pstack-sync/artifacts/<RunId>/`:

- `verdict.json` — feature, scenario, each assertion with pass/fail, and the observed state (remote head, tag name, tag tree vs remote tree, tag/pin/manifest versions, whether a release was created).
- `commands.txt` — every command with its exit code.
- `<step>.txt` — full stdout+stderr of each driven command, named after the fixture or workflow step.
- `gh-calls.log`, `gh-body.log` — for `publish` and `alert`, the exact `gh` invocations and issue bodies. `gh-body-bare.log` holds the historical bare-link body next to the current one.

Proof standard: a drive proves behavior only when it asserts on the **remote** state a downstream consumer would see, not on the scratch working tree. `publish` reads `pin.json` and the plugin manifest back out of the bare remote with `git show main:<path>`. Capture the action and the resulting state together; a green exit code alone is not evidence. Only `Alert on failure` still swallows its own error, deliberately, because the job is already red. Success is derived from observed `gh` calls and step exit codes, never from the scenario name, and a scenario that depends on a race asserts that the branch actually ran.

`artifacts/` is gitignored. Evidence survives cleanup — the harness asserts this on every run.

## Cleanup

Automatic, in a `finally` block, on success and on failure alike. Junctions and symlinks are unlinked before the recursive delete so the real `upstream/` clone is never followed into. Three assertions run after teardown: scratch removed, upstream clone still present, evidence still present. Cleanup never removes evidence.

## Helpers

- `helpers/doctor.ps1` — read-only health check, exit 0 healthy.
- `helpers/drive.ps1` — the driver. `-Feature gates|corpus|rules|doctor|transform|detect|publish|alert`, `-Fixture <name>`, `-Scenario <name>`, `-RunId <id>`, `-WorkflowPath <file>`, `-KeepRoot`.

`-WorkflowPath` points every step read at a different workflow file, so a mutated copy can be driven without editing `sync.yml`. The built-in mutation proofs use the same mechanism.

Scenarios that need an "already synced" pin derive it by running the real `Record upstream` step against the local clone. They do not read the repository's `pin.json`, so a deliberately mid-sync pin — a blank `pstackTree` used to force a full resync — neither breaks the drives nor makes doctor unhealthy.

Both are invoked exactly as shown above; neither needs a build step.

## Feature map

Read [`features/README.md`](features/README.md) before driving, then the matching feature file. The map is the maintained source for what this pipeline promises.

## Maintenance

After changing `transform/`, `map.json`, or `sync.yml`, re-run `corpus` plus the feature you touched. Changing the publication steps also requires re-running the sibling `formal-verify-pstack-sync` skill, which derives its model from the same `sync.yml` text. Use `/maintain-verification-skill` for a full periodic pass over the map.