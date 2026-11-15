# Project Workflow

## Guiding Principles

1. **The Plan is the Source of Truth:** All work is tracked in `conductor/tracks/<track_id>/plan.md` and `conductor/tracks.md`.
2. **The Tech Stack is Deliberate:** Changes to dependencies or architecture must be documented in `conductor/tech-stack.md` before or alongside implementation.
3. **Test-Driven / ATDD Development:** Write failing unit tests or 4-layer ATDD feature specs (`test/features/` + `test/support/`) before implementing behavior changes.
4. **High Code Coverage & Strict Gates:** Maintain test coverage above the `mix.exs` threshold (`>84%`), targeting `>85%` per module, with zero Credo/Dialyzer/compiler warnings.
5. **Backwards-Compatibility Awareness:** Document every breaking change clearly in `CHANGELOG.md` and migration notes ahead of `v1.0.0`.
6. **Non-Interactive & CI-Aware:** Always run Mix commands matching `.gitlab-ci.yml` (`mix test --cover`, `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`, `mix docs`).

## Task Workflow

All tasks follow a strict lifecycle:

### Standard Task Workflow

1. **Select Task:** Choose the next available task from `plan.md` in sequential order.
2. **Mark In Progress:** Before beginning work, edit `plan.md` and change the task from `[ ]` to `[~]`.
3. **Write Failing Tests (Red Phase):**
   - Add or update unit/regression tests in `test/creatio/` or feature specs in `test/features/`.
   - Run `mix test <test_file>` and confirm the new tests fail as expected before editing `lib/`.
4. **Implement to Pass Tests (Green Phase):**
   - Write the minimum clean Elixir implementation in `lib/` to satisfy the spec.
   - Re-run `mix test` and confirm all tests pass (`Excluding tags: [:live]` by default).
5. **Refactor & Document:**
   - Remove duplication, verify `@doc` / `@spec` coverage, and re-run `mix test`.
6. **Verify Quality Gates:**
   ```bash
   mix format --check-formatted
   mix compile --warnings-as-errors
   mix credo --strict
   mix dialyzer
   mix test --cover
   mix docs
   ```
   Target: All checks pass with 0 errors/warnings and coverage `>84%`.
7. **Document Deviations:** If implementation diverges from `tech-stack.md` or `spec.md`, update the spec/tech-stack with a dated note before committing.
8. **Commit Code Changes:**
   - Stage changes for the task and commit using Conventional Commits (e.g., `feat(odata): ...`, `refactor(client): ...`, `test(live): ...`).
   - Do not push directly to `master` or cut tags unless explicitly requested.
9. **Attach Task Summary with Git Notes (Optional):**
   - Obtain the commit hash via `git log -1 --format="%H"` and attach summary notes with `git notes add -m "<summary>" <commit_hash>`.
10. **Record Task Completion in `plan.md`:**
    - Update `[~]` to `[x]` and append the 7-char commit SHA, then commit the `plan.md` update (`conductor(plan): Mark task '<task>' as complete`).

### Phase Completion Verification and Checkpointing Protocol

**Trigger:** Executed immediately after completing the last task of any Phase in `plan.md`.

1. **Announce Protocol Start:** State that the phase is complete and start verification.
2. **Verify Phase Scope & Coverage:** Inspect changed files via `git diff --name-only <previous_checkpoint_sha> HEAD` and confirm every changed module under `lib/` has matching tests and documentation.
3. **Run Full Automated Gates:**
   - Run `mix format --check-formatted && mix compile --warnings-as-errors && mix credo --strict && mix dialyzer && mix test --cover && mix docs`.
   - For Track 1 (Live Verification), also present the manual live-instance test command (`mix test --only live` with `.env` configured against a sandbox Creatio instance).
4. **Propose Manual Verification Steps:** Present exact commands and expected outcomes for the completed phase and wait for explicit user confirmation.
5. **Create Checkpoint & Update `plan.md`:** Commit checkpoint (`conductor(checkpoint): Checkpoint end of Phase X`), record `[checkpoint: <sha>]` in `plan.md`, and commit the plan update.

## Development Commands

### Setup
```bash
mix deps.get
cp .env.example .env   # Optional: only required for @tag :live tests
```

### Daily Development & Pre-Commit Checks
```bash
mix format
mix compile --warnings-as-errors
mix credo --strict
mix dialyzer
mix test --cover
mix docs
```

### Live Instance Verification (Opt-In)
```bash
CREATIO_LOAD_DOTENV=true mix test --only live
```

## Commit Guidelines

```
<type>(<scope>): <description>
```
Allowed types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`, `perf`, `conductor`.
