# Transform upstream into both artifacts

A maintainer runs the pipeline and gets two installable products from one upstream tree: an Agent Plugins 1.0 directory that becomes the release zip, and a Claude Code plugin committed under `plugins/pstack/`. Both must carry the upstream MIT text, and both must contain the same set of skills.

## Sub-features

- `transform-ap` produces `output/plugin.json` with the AP 1.0 `$schema` and only contract-allowed keys.
- `transform-cc` produces `plugins/pstack/.claude-plugin/plugin.json` plus `skills/` and `agents/`.
- `transform-extension` preserves the unmodified upstream manifest under `output/com.cursor/plugin.json`.
- `transform-license` copies the upstream `LICENSE` into both products.
- `transform-parity` produces the same skill count in both products.
- `transform-frontmatter` normalizes each skill `name` to its directory name and moves Cursor-only fields into `metadata`.
- `transform-unclassified` refuses to guess when upstream adds a manifest field the rule file does not classify.
- `transform-no-drift` requires the committed Claude Code tree to equal what the current rules recompute, so a hand edit or a stale artifact cannot survive.

## How to get to it (user POV)

- Run the transform script directly during local development.
- Let the `Transform` step of the `sync-pstack` workflow run it after a detected upstream change.
- Install the committed Claude Code plugin from this repository's marketplace.
- Download the release zip and install it as an Agent Plugins 1.0 plugin.

## Driving it with drive.ps1

Preconditions:

- `doctor.ps1` exits 0.
- `upstream/pstack` exists and its HEAD equals `pin.json.commit`.

- **Full transform.** Run `pwsh -NoProfile -File .agents/skills/verify-pstack-sync/helpers/drive.ps1 -Feature transform -RunId transform-1`. `verdict.json` shows `transform exit=0`, `gates exit=0 on real upstream`, `CC LICENSE present`, `AP LICENSE present`, `skill parity` with equal counts, and `committed CC artifact equals recomputed output`. The captured `transform.txt` ends with `OK: <scratch>/output / <scratch> (<n> skills)`.
- **No drift in the committed tree.** The `committed CC artifact equals recomputed output` assertion compares every file under the repo's `plugins/pstack/` against the freshly produced one, normalizing CRLF. A non-empty detail list names the drifted paths. This is the enforcer for the convention that generated content is never hand-edited.
- **Skill parity value.** Read `skills` from `verdict.json`. It must equal the number of directories under `upstream/pstack/skills` plus any injected asset skill.
- **License text is upstream's.** Compare the produced `plugins/pstack/LICENSE` against `upstream/pstack/LICENSE`. They must be byte-identical; the pipeline copies, never rewrites, the upstream copyright.
- **Extension manifest is unmodified.** Compare `output/com.cursor/plugin.json` against `upstream/pstack/.cursor-plugin/plugin.json`. They must be byte-identical.
- **Unclassified field fails closed.** Add a new top-level key to a scratch copy of the upstream manifest and re-run the transform script against it. Expect a non-zero exit and an error naming the field and `map.json`. This entry point is driven by hand against a scratch copy, not by `-Feature transform`, which uses the real clone.

## Gotchas

- The gate's AP checks are skipped when `output/` is absent, and the skip is reported as a note, not an error. A green gate run on a checkout without `output/` proves nothing about the AP contract or the AP residual scan. `-Feature transform` always generates `output/` first.
- `plugins/pstack/` is wiped and recopied on every transform. Hand edits there are lost; change `transform/map.json` or the scripts instead.
- `.claude-plugin/marketplace.json` is written only when missing, so a transform run will not repair a hand-broken marketplace.
- Body-token replacement applies only to the prose extensions declared in `map.json` `gate.proseExtensions`. A Cursor-specific string inside a `.ts`, `.sh`, or `.json` file survives the transform unchanged; see [gates](./gates.md) for how that is handled.
- A stale local `output/` from an older upstream version produces a skill-parity failure that looks like a regression but is not. Delete `output/` and re-transform before judging.