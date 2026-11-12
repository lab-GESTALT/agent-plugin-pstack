# Publication

After the gates pass, a run records the upstream commit, commits both artifacts, tags the version, pushes, and attaches the Agent Plugins 1.0 zip to a release. A downstream user sees a new tag and a downloadable zip whose contents match the version the tag claims.

## Sub-features

- `publish-record` writes the upstream commit, subtree hash, version, and date into `pin.json`.
- `publish-commit` commits `plugins`, `.claude-plugin`, and `pin.json` under a fixed identity, and treats "nothing to commit" as an explicit branch rather than a swallowed failure.
- `publish-tag` derives the tag serial from the tags already on the remote, so a second sync of the same version does not collide.
- `publish-tag-reuse` reuses an existing tag when it already points at the pushed tree, so a self-heal rerun does not create an empty duplicate tag.
- `publish-push` rebases onto `origin/main` before pushing and retries once if the push is rejected; a rebase conflict aborts and turns the step red.
- `publish-release` zips `output/` and attaches it to the tag, skipping create when the release already exists.
- `publish-consistency` is the promise that a green run leaves the remote self-consistent: a release exists, the tag is on the remote, the tag tree equals the remote tree, and tag version, pinned version, and committed manifest version agree.
- `publish-loud-failure` is the promise that a refused commit or a refused release turns the run red instead of advancing the pin silently.

## How to get to it (user POV)

- Read the repository's releases page and download `pstack-<version>-r<N>.zip`.
- Install the Claude Code plugin from the marketplace at the pushed commit.
- Read `pin.json` at `main` to see which upstream commit the published artifacts came from.
- Trigger a run manually with `gh workflow run sync-pstack`.

## Driving it with drive.ps1

Preconditions:

- `doctor.ps1` exits 0.
- `jq`, `zip`, `git`, and `bash` are on PATH; the harness supplies its own `gh` stub.
- The drive uses a local bare remote. It never contacts GitHub.

- **Happy path.** Run `pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature publish -Scenario happy -RunId pub-1`. Expect `VERIFY: PASS`, `remoteAdvanced=True`, a tag named `pstack-<version>-r1`, `tagTree==remoteTree=True`, three equal versions, and `release=True`.
- **Release refused.** Run with `-Scenario release-fails`. The `gh` stub refuses `release create`. Expect `VERIFY: PASS` with `Publish release=1`, `releaseSucceeded=False`, and the assertion `a failed publish step turns the run red`.
- **Commit refused.** Run with `-Scenario commit-fails`. A `pre-commit` hook in the scratch repository exits 1. Expect `Commit=1`, `Tag and push=skipped`, `Publish release=skipped`, `remoteAdvanced=False`, and the remote still holding the previous version.
- **Push rejected mid-run.** Run with `-Scenario push-rejected`. A `pre-push` hook advances the remote at the instant of the first push and refuses it. Expect `VERIFY: PASS`, all steps 0, and the assertion `push rejection exercised the rebase-and-retry path` — the step log must contain `push rejected`.
- **Self-heal rerun.** Run with `-Scenario self-heal`. The pin already matches upstream and a tag already points at that tree, but no release exists. Expect `VERIFY: PASS`, `remoteAdvanced=False`, `remoteTagCount=1`, `releaseSucceeded=True`, and the assertions `self-heal reuses the existing tag` and `self-heal makes no empty commit`.
- **Read the remote, not the working tree.** `verdict.json` records `remotePinVersion`, `remoteManifestVersion`, `tagVersion`, `tagOnRemote`, `tagTreeEqualsRemoteTree`, and `releaseSucceeded`. These come from `git show main:<path>` and `git rev-parse` against the bare remote.
- **Tag serial.** Each drive builds a fresh remote, so every run observes `-r1`. To exercise the serial increment, inspect `git ls-remote --tags` in a `-KeepRoot` scratch and re-run the extracted `Tag and push` block by hand.

## Gotchas

- The harness runs each extracted step with `bash -e -o pipefail`, matching the Actions default shell on Linux. Plain `bash` lets a trailing `rm -f` mask a failed `gh release create`, which made the release-refused path look green. If you drive a step by hand, use the same flags.
- A failed step aborts the remaining steps, as GitHub does without `continue-on-error`. `verdict.json` records them as `skipped`, not `0`. Counting only the executed steps would overstate coverage.
- `Alert on failure` still ends in `|| echo "::warning::..."`. That is deliberate: the job is already red, and a failed alert must not replace the original failure. No other step swallows errors.
- `pin.json` is advanced by `Record upstream`, which runs before `Commit` and before `Publish release`. A red run can therefore leave the local pin ahead of the remote; the remote is the authority, and the next run's self-heal check repairs the missing release.
- The scratch repository starts from the real historical sync state at commit `221395a` (version 0.15.32). Without that rewind there is nothing to advance and the commit step legitimately has nothing to commit, which masks the failure paths. `self-heal` is the exception: it starts from the current `pin.json` because it needs the opposite precondition.
- Advancing the remote during setup does not exercise the push-retry path: the step's opening rebase absorbs it. The race has to be injected at push time, which is what the `pre-push` hook does.
- `output/` is gitignored, so the zip is built from untracked content. A tag can therefore point at a tree that does not contain the zip's own source; the zip's correctness rests on the transform having run in the same invocation.
- The `gh` stub logs every call to `gh-calls.log`. If that file is missing, the step never reached `gh` at all, which is a different failure from a refused release. `releaseSucceeded` is derived from that log plus the step's exit code, never from the scenario name.