---
name: formal-verify-pstack-sync
description: "Model-check the publication ordering of .github/workflows/sync.yml: that a green run always leaves a release matching the pinned version, and that a stalled publication always recovers. Use when changing Detect change, Record upstream, Commit, Tag and push, or Publish release, or when a sync run is green but no release appeared."
---

# Formal verification of pstack-sync publication

## What is verified, in plain words

**Property 1 — GreenConsistent (safety).** Every green run ends with a release whose version equals both `pin.json`'s version and the version actually committed on `main`.
*Harm if broken:* a downstream user downloads `pstack-<version>-r<N>.zip` by tag name and gets a different version than the tag claims.

**Property 2 — EventuallyPublished (liveness).** Once upstream stops moving and failures stop recurring, the current upstream version eventually gets a release.
*Harm if broken:* `pin.json` claims the repository is synced while the generic artifact is never published, and every later cron short-circuits — the schedule becomes meaningless.

These are the two promises a single-run test cannot reach: the second one is about what happens *after* a failed run, across an unbounded sequence of runs.

## Why TLA+

The question is whether events can happen in a bad order — pin advancing before publication, a failure being swallowed, a later run deciding nothing changed. That is a model-checking question over a small design model, and TLA+ is the default tool for it in any language. The model checker is TLC, pinned to `tla2tools.jar` v1.7.4 (SHA256 `936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88`), bootstrapped on first run into the gitignored `artifacts/tool/`. Nothing is vendored. Requires a JDK (>= 11) on PATH.

## Run it

One command, from the repository root:

```sh
pwsh -NoProfile -File .agents/skills/formal-verify-pstack-sync/helpers/run.ps1 -RunId formal-1
```

It reads `.github/workflows/sync.yml`, **derives** the model's switches from how the steps are actually written, writes a `.cfg` per variant, runs TLC, and asserts:

- `current` — the derived configuration satisfies both properties.
- `no-self-heal`, `swallow-release`, `swallow-commit`, `stale-version` — each removes or breaks exactly one rule and **must** violate the named property.

Exit 0 means all five assertions held. `-SkipVariants` runs only `current` (faster, but proves nothing about the checks being able to fail). Evidence lands in `artifacts/<RunId>/`: `verdict.json`, one `.cfg` and one full TLC log per variant, and a copy of the model as it was run.

**Read `current` first.** The broken variants inherit the derived base flags, so if `current` is already failing, TLC stops at the first violation and a variant may report `GreenConsistent` instead of its own named property. That is one finding, not several.

Read every TLC result with the pstack `/statechart` skill. It turns an invariant violation into its shortest path in plain words, and draws the state graph when the check passes.

## How the model stays true to the code

`helpers/run.ps1` derives four switches from the live workflow text, using the same `workflow.psm1` step reader that `verify-pstack-sync` uses — there is no second hand-maintained copy of the pipeline:

| Switch | Derived from | True when |
| --- | --- | --- |
| `SelfHeal` | `Detect change` | the step counts releases matching `^pstack-${PIN_VERSION}` **and** the `if [ "$MATCH" = 0 ]` branch assigns `CHANGED=yes` |
| `SwallowCommit` | `Commit` | `git commit ... \|\|` swallows the failure |
| `SwallowRelease` | `Publish release` | `gh release create ... \|\|` swallows the failure |
| `StaleVersion` | `Record upstream` | `VERSION` is read from `pin.json` instead of the freshly transformed manifest |

If an anchor disappears (`gh release list`, `git commit`, `gh release create`, `VERSION=`), the runner **throws** rather than guessing. A refactor that invalidates the derivation must be re-derived, not silently scored as clean.

The derivation was tested against real breaks, not only against synthetic switches. Two scratch edits to `sync.yml` were each caught and then reverted: deleting the `MATCH` decision while keeping the release listing, and keeping the `self-heal` log line while deleting `CHANGED=yes`. The second is why `SelfHeal` keys on the assignment: `CHANGED=yes` also appears unconditionally at the top of the step, so matching that string alone is vacuous. Both breaks produced the same counterexample — run 1 pushes `main` and `pin.json` forward and then fails before publishing; run 2 clones the same subtree, `Detect change` short-circuits to green, and no release ever appears.

Each model action names the workflow step it stands for: `Detect` → Detect change, `Transform` → Transform, `Record` → Record upstream, `Commit` → Commit, `Push` and `Tag` → Tag and push, `Release` → Publish release. `StartRun` stands for `Fetch upstream`, which clones once per run; `clonedV` is that fixed clone, and every read inside the run uses it. `StartRun` also models the fetch itself failing — a rate limit or a network error turns the run red before `Detect change`, and the pin does not move.

## Bounds and assumptions

- `MaxV = 2` upstream versions, `MaxUp = 1` upstream advance, `MaxFails = 2` failures. 585 distinct states for `current`.
- A failure budget makes "failures eventually stop" a bounded assumption rather than a fairness promise. Once it is exhausted, steps must succeed.
- `WF_vars(Next)` gives weak fairness: a continuously enabled step eventually fires.
- One version number stands for one `pstack` subtree and its artifact. Release identity is the version, not the tag serial.
- Upstream may advance at any instant, including mid-run; the run still publishes what it cloned.

A pass covers this model at these bounds. It is not a proof about the real repository at arbitrary size.

## What is NOT covered

- The git-level push race and rebase retry, tag-tree vs remote-tree byte comparison, and zip contents — `verify-pstack-sync -Feature publish -Scenario push-rejected` and `-Feature transform` drive those with real git.
- Transform rules and the three validation gates — `verify-pstack-sync -Feature corpus / rules / transform`.
- Whether GitHub actually fires the cron. There is no enforcer for that anywhere in the repository; see the known-gaps list in `AGENTS.md`.
- Tag serial increment (`r2` when `r1` exists at a different tree). The model collapses serials; `verify-pstack-sync -Feature publish -Scenario tag-serial` drives that branch with real git.

## Telling a real finding from a modeling error

A violation is a **finding** when the counterexample's steps are things the workflow can actually do. Read the trace in the code's words before believing it.

Worked example of a **modeling error** caught during construction: an earlier revision set `pinT` from the *live* upstream at push time. TLC reported a liveness violation where upstream advanced mid-run, `pinT` jumped to the new version while `pinV` stayed old, and every later run short-circuited. That is not reachable in the real workflow: `Record upstream` reads `git -C upstream rev-parse HEAD:pstack` from the **local clone**, fixed at `Fetch upstream`, so `pinT` and `pinV` always come from the same clone. The fix was to introduce `clonedV` and read it everywhere inside a run — a faithfulness fix, not a weakening of the property. If you ever "fix" a violation by relaxing `GreenConsistent` or `EventuallyPublished`, you have destroyed the check.

When the current code genuinely breaks a property, report it with the counterexample and leave the property alone. Do not edit `sync.yml` to make the model pass unless the user asks.

## Coverage record

| Check | Covers | Last confirmed at commit | `sync.yml` SHA256 |
| --- | --- | --- | --- |
| `GreenConsistent`, `EventuallyPublished` | `.github/workflows/sync.yml`: Detect change, Transform, Record upstream, Commit, Tag and push, Publish release | `6a5b7b9` | `8ac97c1f316e7fdfa79f83eff6e83ab14c2378391a1c2fdc4632b31a354428e8` |

The hash is the binding: it identifies the exact text the model was derived from even when the working tree is dirty and the commit column names an older revision. Advance the commit column after re-running on a clean tree.

Move the sync commit forward **only after** you have confirmed the model still describes the code at the new commit — re-read the changed steps against the action table above, re-derive the switches, and re-run. If a step was renamed, reordered, split, or given a new guard, the model needs updating first. `verdict.json` records the commit each run actually saw, plus `syncSha256` and `syncDirty`: a dirty working tree means the commit alone does not identify the text that was checked, so the hash is the binding.

For bringing the verification back in line after changes that did not recheck it, use `/maintain-formal-verification-skill`.

## Known findings

None at the sync commit above. All four broken variants violate their named property, so both checks have been seen to fail.