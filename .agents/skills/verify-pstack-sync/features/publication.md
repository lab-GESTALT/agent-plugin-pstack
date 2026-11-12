# Publication

After the gates pass, a run records the upstream commit, commits both artifacts, tags the version, pushes, and attaches the Agent Plugins 1.0 zip to a release. A downstream user sees a new tag and a downloadable zip whose contents match the version the tag claims.

## Sub-features

- `publish-record` writes the upstream commit, subtree hash, version, and date into `pin.json`.
- `publish-commit` commits `plugins`, `.claude-plugin`, and `pin.json` under a fixed identity.
- `publish-tag` derives the tag serial from the tags already on the remote, so a second sync of the same version does not collide.
- `publish-push` pushes the commit and the tag to `main`.
- `publish-release` zips `output/` and attaches it to the tag.
- `publish-consistency` is the promise that a green run leaves the remote self-consistent: tag version, pinned version, and committed manifest version agree, the tag tree equals the remote tree, and a release exists.

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
- **Release refused.** Run with `-Scenario release-fails`. The `gh` stub refuses `release create`. Observe whether the run is still green and whether a release exists.
- **Commit refused.** Run with `-Scenario commit-fails`. A `pre-commit` hook in the scratch repository exits 1. Observe the tag's version against the versions actually stored on the remote.
- **Read the remote, not the working tree.** `verdict.json` records `remotePinVersion`, `remoteManifestVersion`, `tagVersion`, `tagTreeEqualsRemoteTree`, and `releaseSucceeded`. These come from `git show main:<path>` against the bare remote.
- **Tag serial.** Run `-Scenario happy` twice against the same scratch remote is not supported; each drive builds a fresh remote, so every run observes `-r1`. To exercise the serial increment, inspect `git ls-remote --tags` in a `-KeepRoot` scratch and re-run the extracted `Tag and push` block by hand.

## Gotchas

- Two steps end in `|| echo "::warning::..."`. A zero exit code from every step therefore does not imply a published artifact. Always assert on `releaseSucceeded` and the remote versions.
- `pin.json` is advanced by `Record upstream`, which runs before `Commit` and before `Publish release`. If a later step fails silently, the pin can claim a version the remote never received.
- The scratch repository starts from the real historical sync state at commit `221395a` (version 0.15.32). Without that rewind there is nothing to advance and the commit step legitimately has nothing to commit, which masks the failure paths.
- `output/` is gitignored, so the zip is built from untracked content. A tag can therefore point at a tree that does not contain the zip's own source; the zip's correctness rests on the transform having run in the same invocation.
- The `gh` stub logs every call to `gh-calls.log`. If that file is missing, the step never reached `gh` at all, which is a different failure from a refused release.