# Failure alerting

When a run fails, the pipeline opens or updates a `sync failed:` issue so a maintainer learns about it without watching Actions. The issue must carry enough output to locate the failure without opening the run log — whichever step failed, not just the gates.

## Sub-features

- `alert-create` opens a new issue when no open `sync failed:` issue exists.
- `alert-merge` comments on the existing open issue instead of opening another.
- `alert-gate-output` quotes the tail of the failing gate report inside a fenced block.
- `alert-failed-step` names the failing step, read from the jobs API so it is available mid-run.
- `alert-early-failure` still locates the failure when it happened before the gates and no gate report exists.
- `alert-log-unavailable` says so explicitly when neither a gate report nor a retrievable log exists, instead of silently going bare.
- `alert-upstream` names the upstream commit the run attempted.
- `alert-run-link` links the run.

## How to get to it (user POV)

- Read the repository's issues for a `sync failed:` title.
- Receive the notification GitHub sends for a new issue or comment.
- Open the linked run from the issue body.

## Driving it with drive.ps1

Preconditions:

- `doctor.ps1` exits 0.
- The `Alert on failure` step still exists in `sync.yml`; doctor checks this.
- The drive uses the shared `gh` stub, whose behaviour is set entirely by environment variables. It never opens a real issue.

- **No open issue.** Run `pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature alert -Scenario no-open-issue -RunId alert-1`. Expect `alert uses issue create`, `alert body carries gate output`, and `alert body names the failing pattern` to pass. `gh-body.log` holds the exact body.
- **Existing open issue.** Run with `-Scenario open-issue`. The stub returns `6` from `issue list`; expect `alert uses issue comment 6`.
- **Real gate output.** The harness feeds the step a genuinely failing gate report produced by the `tp-models-bare` fixture, not a hand-written string. The body must contain `Gate output:` and the failing pattern name.
- **Another fixture.** Run with `-Fixture tp-frontmatter-icon`. The body must then name that failure instead, proving the report is read from disk rather than hardcoded.
- **Failure before the gates.** Run with `-Scenario no-gate-report`. The harness supplies no `gate-report.txt` and no `upstream/` clone, which is the state a failed `Fetch upstream` leaves behind. Expect `alert body names the failed step`, `alert body carries the failed-step log`, and `alert issue title falls back to unknown upstream`. The stubbed log is the real production text: an anonymous clone rejected with HTTP 429.
- **Discriminating proof, same command.** `-Scenario no-gate-report` then runs a frozen copy of the historical bare-link step and asserts `bare-link alert is caught by the locatability assertion`. That copy is the version that actually shipped and produced a link-only issue; the assertion must reject it. `gh-body-bare.log` holds its body next to the current one.
- **Log not retrievable yet.** Run with `-Scenario no-log-available`. The stub refuses `run view --log-failed`, as GitHub does before the log is archived. Expect `alert says the log is unavailable instead of going bare`.

## Gotchas

- The step merges only into an **open** issue whose title starts with `sync failed:`. Once such an issue is closed, the next failure opens a new one. Closing an issue is not a way to silence the alert.
- The fence is built with a single-quoted `FENCE` variable and a one-line `printf`. A literal block scalar in YAML cannot contain a column-0 line, so do not "simplify" this into a multi-line heredoc.
- `gate-report.txt` is written by the `Validate gates` step. When the run failed earlier — fetching or transforming — the file is absent, and the body must fall back to the failing step's log. A body carrying only the run link is a broken alert, not an expected one; `-Scenario no-gate-report` is the check that keeps it that way.
- The failed-step name comes from the jobs API, which answers mid-run. `gh run view --log-failed` needs an archived log and can legitimately fail while the run is still finishing; that is why the name and the log are fetched separately and the log has an explicit unavailable branch.
- `upstream` is absent when the clone itself failed, so the title reads `sync failed: upstream unknown`. That is the correct title for that failure, not a bug — the body carries the locating information instead.
- The alert step itself ends in `|| echo "::warning::alert ... failed"`. A failed alert does not fail the run, so a red run can still leave no issue. Check `gh-calls.log` when an expected issue is missing.
- `GITHUB_SERVER_URL`, `GITHUB_REPOSITORY`, and `GITHUB_RUN_ID` are supplied by the harness as placeholders. The run link in local evidence is therefore not resolvable; judge the body's structure, not the link.