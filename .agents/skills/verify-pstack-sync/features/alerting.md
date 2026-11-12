# Failure alerting

When a run fails, the pipeline opens or updates a `sync failed:` issue so a maintainer learns about it without watching Actions. The issue must carry enough of the gate output to locate the failure without opening the run log.

## Sub-features

- `alert-create` opens a new issue when no open `sync failed:` issue exists.
- `alert-merge` comments on the existing open issue instead of opening another.
- `alert-gate-output` quotes the tail of the failing gate report inside a fenced block.
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

## Gotchas

- The step merges only into an **open** issue whose title starts with `sync failed:`. Once such an issue is closed, the next failure opens a new one. Closing an issue is not a way to silence the alert.
- The fence is built with a single-quoted `FENCE` variable and a one-line `printf`. A literal block scalar in YAML cannot contain a column-0 line, so do not "simplify" this into a multi-line heredoc.
- `gate-report.txt` is written by the `Validate gates` step. If the run failed before that step, the file is absent and the body carries only the run link. That is expected, not a broken alert.
- The alert step itself ends in `|| echo "::warning::alert ... failed"`. A failed alert does not fail the run, so a red run can still leave no issue. Check `gh-calls.log` when an expected issue is missing.
- `GITHUB_SERVER_URL`, `GITHUB_REPOSITORY`, and `GITHUB_RUN_ID` are supplied by the harness as placeholders. The run link in local evidence is therefore not resolvable; judge the body's structure, not the link.