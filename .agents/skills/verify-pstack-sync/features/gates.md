# Validation gates

Before anything is committed or published, three gates decide whether the derived artifacts are free of Cursor-specific residue and structurally loadable. A maintainer sees either `GATES GREEN: <n> skills, <n> patterns, gates 1/2/3 passed` or a numbered failure list with file and line locations.

## Sub-features

- `gate1-residual` scans every text file in the committed plugin for Cursor-specific patterns.
- `gate1-allowlist` exempts registered code residuals and reports them as notes rather than errors.
- `gate2-frontmatter` requires each skill `name` to equal its directory name and rejects Cursor-only frontmatter fields.
- `gate2-license` requires the upstream MIT text in both products.
- `gate2-ap-contract` validates the AP manifest against the allowed-key set, required keys, schema id, name pattern, and author shape.
- `gate3-marketplace` resolves every declared marketplace path and confirms it is non-empty.
- `gate-corpus` distinguishes real residue, which must stay blocked, from legitimate content, which must not be blocked.

## How to get to it (user POV)

- Run the validation script directly during local development.
- Let the `Validate gates` step of the `sync-pstack` workflow run it after a transform.
- Read the gate output quoted in a `sync failed:` issue.

## Driving it with drive.ps1

Preconditions:

- `doctor.ps1` exits 0.
- `fixtures/index.json` parses and every listed fixture has a `plugins/` overlay.

- **Whole corpus.** Run `pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature corpus -RunId corpus-1`. `verdict.json` lists one row per fixture with `kind`, `class`, `expectedExit`, `actualExit`, and `pass`. Every `must-block` fixture must exit 1 and every `must-pass` fixture must exit 0.
- **One fixture.** Run `pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature gates -Fixture fp-ts-subagent-type -RunId one-1`. The captured `validate-fp-ts-subagent-type.txt` holds the full gate output.
- **Real residue stays blocked.** Run `-Fixture tp-models-bare`. Expect exit 1 and an error naming `pstack-models`. This is the reconstructed signature of the five consecutive failures recorded in issues #1 through #5.
- **Frontmatter contract.** Run `-Fixture tp-frontmatter-icon` and `-Fixture tp-name-mismatch`. Both must exit 1.
- **Gates on real upstream.** Run `-Feature transform`. Its `gates exit=0 on real upstream` assertion is the only proof that the current rule set matches the current upstream tree; the corpus alone cannot show that.

## Gotchas

- A fixture is an overlay on `fixtures/base/`. Its directory must contain `plugins/...` directly. An extra wrapper level makes the overlay land in the wrong place and the fixture silently passes for the wrong reason.
- The corpus measures the gates in isolation, without a transform run. A `must-block` prose fixture therefore stays blocked even though the real pipeline would have rewritten that text first. That is intended: it proves the gate can still fail.
- `gate1` scans all text files under `plugins/pstack/`, while the transform rewrites only `*.md`. Fixtures in class B exercise exactly that boundary.
- `gate2`'s AP checks are skipped with a note when `output/` is absent. Fixture roots intentionally have no `output/`, so corpus runs never exercise the AP contract; `-Feature transform` does.
- Adding a fixture means adding both the overlay directory and an `index.json` entry with a real `origin`. A fixture without a recorded origin is a guess, not evidence.