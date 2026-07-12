# Claude Code → Codex Parallel Feature Orchestration (Coral)

How to develop **multiple unrelated features at once** by letting **Claude Code orchestrate** and **OpenAI Codex implement** inside isolated git worktrees.

This is **Pattern A**: Claude is the boss; Codex is a scoped worker process.

Exported from the LunarWing orchestration kit and adapted for the Coral / Paseo Ansible repo.

| Role | Tool | Responsibility |
|------|------|----------------|
| Orchestrator | Claude Code | Scope, path bounds, worktrees, dispatch, verify, scoreboard |
| Implementer | Codex CLI (`codex exec`) | Write code inside one feature worktree |
| Isolation | `git worktree` + `feat/<slug>` | Parallel features without fighting one checkout |

## In-repo layout

| Path | Purpose |
|------|---------|
| `.claude/skills/codex-impl/` | `/codex-impl` — single feature |
| `.claude/skills/features-parallel/` | `/features-parallel` — many features |
| `.claude/scripts/feature-worktree.sh` | Create/reuse `.worktrees/<slug>` |
| `.claude/scripts/feature-status.sh` | Status / changed-file summary |
| `.claude/skills/codex-impl/scripts/run-codex.sh` | Non-interactive Codex wrapper |
| `.claude/README-codex-orchestration.md` | Short pointer / defaults |

Also respect [`AGENTS.md`](../../AGENTS.md) and [`CLAUDE.md`](../../CLAUDE.md).

## When to use

**Use when:** 2+ path-disjoint features; shared dirty checkout is painful; Claude plans/verifies and Codex implements.

**Do not use when:** one-line fix; features share the same core files; you need interactive Codex TUI.

## Mental model

```text
You
 └── Claude Code (session on main_branch or integration branch)
      ├── Feature A  →  .worktrees/a  (branch feat/a)  →  codex exec
      ├── Feature B  →  .worktrees/b  (branch feat/b)  →  codex exec
      └── Feature C  →  .worktrees/c  (branch feat/c)  →  codex exec
```

Rules:

1. **Main checkout stays put.**
2. **Each feature owns a worktree** under `.worktrees/<slug>/` and branch `feat/<slug>`.
3. **Codex only writes inside its worktree**, under path globs in the prompt.
4. **Claude verifies** after Codex exits.
5. **Secrets never land in commits** (vault / `.env` / `auth.json`).

`.worktrees/`, `**/.codex-runs/`, and `**/.codex-prompt.md` are gitignored.

## Prerequisites

```bash
command -v codex && codex --version
codex login status
git rev-parse --show-toplevel   # must be coral root
ls .claude/skills/codex-impl .claude/scripts
```

## Quick start

```bash
cd /path/to/coral
.claude/scripts/feature-worktree.sh "example-slug" "$(git rev-parse HEAD)"
# write .worktrees/example-slug/.codex-prompt.md
.claude/skills/codex-impl/scripts/run-codex.sh \
  .worktrees/example-slug \
  .worktrees/example-slug/.codex-prompt.md
.claude/scripts/feature-status.sh .worktrees/example-slug
```

Or in Claude Code: `/codex-impl` or `/features-parallel` with a feature list.

## Verification defaults for Coral

Prefer:

```bash
ansible-playbook --syntax-check site.yml
sh -n make-vault.sh vault-pass.sh
python3 -m py_compile redact-json.py opencode-effective-config.py
```

Avoid routine full fleet deploys and secret-bearing runs unless explicitly requested.

## Origin

Portable scripts and skill shape were exported from LunarWing_v2 Pattern A orchestration and retargeted to this Ansible/Paseo layout.
