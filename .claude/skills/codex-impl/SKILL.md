---
name: codex-impl
description: Implement one bounded feature via Codex in an isolated git worktree, then verify. Use for single-feature Codex implementation or as a worker for parallel fan-out.
argument-hint: "<slug>: <feature description>"
disable-model-invocation: false
allowed-tools: Bash(git *), Bash(.claude/scripts/*), Bash(.claude/skills/codex-impl/scripts/*), Read, Grep, Glob, Edit, Write
---

# Codex single-feature implementer (Pattern A)

You are the Claude orchestrator. **Codex writes the code. You plan, constrain, dispatch, and verify.**

## Hard constraints (repo + user)

- Current main checkout may be on a protected or shared branch. **Do not switch or create branches on the main checkout** unless the user explicitly allows it.
- Feature isolation uses **git worktrees** under `.worktrees/<slug>/` and branches `feat/<slug>`.
- Prefer path-scoped changes. No drive-by refactors.
- Follow `AGENTS.md` and `CLAUDE.md` for this repo (secrets, Ansible conventions, init-system dual support).
- **Never commit secrets**, vault plaintext, `.env`, `auth.json`, or real `vault.yml` contents.
- Prefer cheap verification: `ansible-playbook --syntax-check`, `sh -n`, `python3 -m py_compile`. Do **not** invent full debug builds or heavyweight installers for routine checks.

## Input

$ARGUMENTS

Parse:
1. optional leading `slug:` (kebab-case)
2. remaining text = feature goal
If no slug, derive a short kebab slug from the goal.

## Procedure

### 1) Scope

Write a short plan:
- goal
- in-scope path globs (relative to repo root)
- out-of-scope paths
- acceptance checks (commands)
- files likely touched

For this repo, common roots include:
- `paseo/tasks/**`, `paseo/templates/**`, `paseo/defaults/**`, `paseo/files/**`
- root playbooks: `site.yml`, `dev-*.yml`, `test-*.yml`
- `inventory.yml`, `group_vars/**`, `opencode.jsonc`
- helper scripts: `make-vault.sh`, `vault-pass.sh`, `opencode-*.sh`, `*.py`

If scope is ambiguous, ask once for path hints before calling Codex.

### 2) Worktree (isolated; does not move main checkout)

From repo root:

```bash
.claude/scripts/feature-worktree.sh "<slug>"
```

Capture `WORKTREE` and `BRANCH`.

Default base is `origin/main` / `origin/master` / `origin/main_branch` if present, else current `HEAD`.
To pin base to the current tip:

```bash
.claude/scripts/feature-worktree.sh "<slug>" "$(git rev-parse HEAD)"
```

### 3) Prompt file for Codex

Write `$WORKTREE/.codex-prompt.md`:

```markdown
# Task
<feature goal>

# Repository
- Product: Coral / Paseo Ansible fleet installer (OpenCode + Paseo over NetBird)
- Follow AGENTS.md and CLAUDE.md
- Work ONLY under: <in-scope globs>
- Do NOT modify: <out-of-scope>
- Match existing style; no unrelated refactors
- No new deps unless required (justify if so)
- Secrets stay placeholders / vault-only; never inline real keys

# Verify constraints
- Prefer: ansible-playbook --syntax-check site.yml
- Prefer: sh -n <scripts>; python3 -m py_compile <py>
- Do NOT run full fleet deploys or secret-bearing playbooks unless the user asked

# Acceptance
- <check 1>
- <check 2>

# Deliverable
- Implement the change
- Minimal diff
- End with summary of files changed + how to verify
```

### 4) Run Codex

```bash
.claude/skills/codex-impl/scripts/run-codex.sh "$WORKTREE" "$WORKTREE/.codex-prompt.md"
```

Env overrides:
- `CODEX_APPROVAL` (default `never`; passed as `-c approval_policy=...`)
- `CODEX_SANDBOX` (default `workspace-write`)
- `CODEX_MODEL`
- `CODEX_EXTRA_ARGS`

Logs land in `$WORKTREE/.codex-runs/`.

### 5) Verify (you, not Codex)

In `$WORKTREE`:
1. `.claude/scripts/feature-status.sh "$WORKTREE"`
2. Inspect `git diff` — reject out-of-scope files (restore them)
3. Run acceptance checks scoped to the change
4. One tight Codex fixup pass only if needed

### 6) Return

```markdown
## Feature: <slug>
- Branch: ...
- Worktree: ...
- Status: success | needs-input | failed
- Diff summary: ...
- Verification: ...
- Log: ...
- Next: open PR / revise / blocked
```

Do not merge, force-push, or switch the main checkout branch unless the user asks.
