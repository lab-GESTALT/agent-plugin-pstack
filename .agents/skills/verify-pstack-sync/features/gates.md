# Validation gates

Before anything is committed or published, three gates decide whether the derived artifacts are free of Cursor-specific residue and structurally loadable. A maintainer sees either `GATES GREEN: <n> skills, <n> patterns, gates 1/2/3 passed` or a numbered failure list with file and line locations.

## Sub-features

- `gate1-residual` scans every text file in both products for Cursor-specific patterns. Prose files get the full rule set; code files get only the hard residual markers.
- `gate1-scope` decides prose versus code from `map.json` `gate.proseExtensions`, the same field the transform reads.
- `gate1-allowlist` exempts registered classes of code residual (`glob` + `scope` + `patterns`) and reports them as notes rather than errors.
- `gate1-actionable` names the fix for every unexpected hit: a missing rewrite rule, a stale artifact, or a code file the transform deliberately leaves alone.
- `gate2-frontmatter` requires each skill `name` to equal its directory name and rejects Cursor-only fields in the frontmatter region, using a field set derived from `map.json`.
- `gate2-license` requires the upstream MIT text in both products.
- `gate2-ap-contract` validates the AP manifest against the allowed-key set, required keys, schema id, name pattern, and author shape.
- `gate3-marketplace` resolves every declared marketplace path and confirms it is non-empty.
- `gate-corpus` distinguishes real residue, which must stay blocked, from legitimate content, which must not be blocked.
- `rules-derivation` proves the frontmatter field set is derived rather than copied, by declaring a new key and watching the gate enforce it.

## How to get to it (user POV)

- Run the validation script directly during local development.
- Let the `Validate gates` step of the `sync-pstack` workflow run it after a transform.
- Read the gate output quoted in a `sync failed:` issue.

## Driving it with drive.ps1

Preconditions:

- `doctor.ps1` exits 0.
- `fixtures/index.json` parses and every listed fixture overlays `plugins/` or `output/`.

- **Whole corpus.** Run `pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature corpus -RunId corpus-1`. `verdict.json` lists one row per fixture with `kind`, `class`, `expectedExit`, `actualExit`, and `pass`. Every `must-block` fixture must exit 1 and every `must-pass` fixture must exit 0.
- **One fixture.** Run `pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature gates -Fixture fp-ts-subagent-type -RunId one-1`. The captured `validate-fp-ts-subagent-type.txt` holds the full gate output.
- **Real residue stays blocked.** Run `-Fixture tp-models-bare`. Expect exit 1 and an error naming `pstack-models`. This is the reconstructed signature of the five consecutive failures recorded in issues #1 through #5.
- **Frontmatter contract.** Run `-Fixture tp-frontmatter-icon`, `-Fixture tp-frontmatter-reminder`, `-Fixture tp-frontmatter-is-background`, and `-Fixture tp-name-mismatch`. All must exit 1. The first three cover both halves of the derived field set: `drop` and `moveToMetadata`.
- **The AP tree is scanned.** Run `-Fixture tp-ap-only-residual`. Residue sits only in `output/`, the CC side is clean, and the gate must still exit 1 naming `output/skills/demo/SKILL.md`. `-Fixture fp-ap-clean` is its green counterpart.
- **The field set is derived, not copied.** Run `pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature rules -RunId rules-1`. It writes a SKILL.md carrying a synthetic frontmatter key, confirms the gate ignores it while undeclared, then declares it in a scratch copy of `map.json` and confirms the gate blocks it. A hardcoded field list passes the second half and fails the assertion.
- **Gates on real upstream.** Run `-Feature transform`. Its `gates exit=0 on real upstream` assertion is the only proof that the current rule set matches the current upstream tree; the corpus alone cannot show that.

## Gotchas

- A fixture is an overlay on `fixtures/base/`. Its directory must contain `plugins/...` or `output/...` directly. An extra wrapper level makes the overlay land in the wrong place and the fixture silently passes for the wrong reason.
- The corpus measures the gates in isolation, without a transform run. A `must-block` prose fixture therefore stays blocked even though the real pipeline would have rewritten that text first. That is intended: it proves the gate can still fail.
- Prose and code are scanned differently, and the boundary lives in `map.json` `gate.proseExtensions`. Class B fixtures exercise it: a `subagent_type` string literal in a `.ts` file is legitimate, the same string in a SKILL.md is residue.
- The allowlist is class-level. `skills/**` with `scope: code` exempts scripts under any skill, so a new script inherits the exemption; the same glob does not exempt prose. `api2.cursor.sh` and `pstack-models.mdc` are in no exemption and stay blocked everywhere.
- `gate2`'s Cursor-field check reads only the frontmatter region. A fenced `css`/`yaml` block in the body may legitimately start a line with `color:` or `mode:`.
- When `output/` is absent, both `gate1` and `gate2`'s AP part print a skip note. Fixture roots without an `output/` overlay therefore never exercise the AP contract; `-Feature transform` and the two class E fixtures do.
- Adding a fixture means adding both the overlay directory and an `index.json` entry with a real `origin`. A fixture without a recorded origin is a guess, not evidence.
- A fixture overlay named `output/` is vulnerable to the repo's ignore rules. An unanchored `output/` pattern hides it locally while a fresh clone loses it entirely, and the corpus then reports PASS with fewer rows. `doctor.ps1` checks that every fixture would ship; `-Feature doctor` proves that check can fail.