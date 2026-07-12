---
name: features-parallel
description: Develop multiple unrelated features in parallel using git worktrees and Codex implementers. Use when the user lists several independent features to build concurrently.
argument-hint: "slug-a: goal a; slug-b: goal b"
disable-model-invocation: true
allowed-tools: Bash(git *), Bash(.claude/scripts/*), Bash(.claude/skills/codex-impl/scripts/*), Read, Grep, Glob, Edit, Write, Agent, Skill, TaskCreate, TaskUpdate, TaskList
---

# Parallel multi-feature development

Claude orchestrates. **Each feature gets its own worktree + Codex implementer.**

## Input

$ARGUMENTS

Split features on `;` or newlines. Each item may be `slug: description` or just a description.

## Hard constraints

- Do **not** switch the main checkout branch.
- Do **not** create branches on the main checkout except via the worktree helper (`feat/<slug>` in `.worktrees/`).
- If the user has forbidden branch/worktree creation, stop and confirm before any `feature-worktree.sh` call.
- Cap concurrency at 3–4 features unless the user asks for more.
- Keep features path-disjoint; if two items collide on core files, ask to split or serialize.
- Codex implements; Claude verifies.
- Never commit secrets/vault plaintext.

## Coral path cheat-sheet

Use these when inferring globs (verify before locking):
- role tasks/templates: `paseo/tasks/**`, `paseo/templates/**`, `paseo/defaults/**`
- role helpers: `paseo/files/**`
- playbooks: `site.yml`, `dev-*.yml`, `test-*.yml`
- inventory/vars: `inventory.yml`, `group_vars/**` (never real vault secrets)
- OpenCode config: `opencode.jsonc` (placeholders only)
- controller scripts: `make-vault.sh`, `vault-pass.sh`, `*.py`

## Execution

### 1) Normalize

Produce a list:
```json
[
  {
    "slug": "openrc-env-path",
    "goal": "...",
    "paths": ["paseo/templates/**"],
    "checks": ["ansible-playbook --syntax-check site.yml", "sh -n paseo/files/some.sh"]
  }
]
```

### 2) Preflight

- `command -v codex`
- `git rev-parse --show-toplevel` (must be coral repo root)
- confirm still on the user-approved main checkout branch (do not change it)
- create `.worktrees/` only via the helper

### 3) Fan-out

For each feature, run an isolated worker that follows `/codex-impl` semantics:

1. `.claude/scripts/feature-worktree.sh "<slug>"`  
   Prefer basing on current HEAD when pinned to an integration branch:
   ```bash
   .claude/scripts/feature-worktree.sh "<slug>" "$(git rev-parse HEAD)"
   ```
2. Write scoped `.codex-prompt.md` in that worktree
3. `.claude/skills/codex-impl/scripts/run-codex.sh "$WORKTREE" "$WORKTREE/.codex-prompt.md"`
4. Verify with `.claude/scripts/feature-status.sh` + targeted checks
5. Return a compact status block only

Run workers in parallel when features are independent.

### 4) Scoreboard

| slug | branch | worktree | status | key files | verify | next |
|------|--------|----------|--------|-----------|--------|------|
| ...  | ...    | ...      | ...    | ...       | ...    | ...  |

### 5) Optional PR

Only if asked: from each worktree, `gh pr create` independently.

## Failure handling

- Codex crash → `failed`, keep worktree, include `.codex-runs/` log path
- Scope bleed → restore out-of-scope files, one fixup Codex pass
- Flaky checks → one retry, then `needs-input`
- Never repair by switching the main checkout branch
