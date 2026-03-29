# AI Swarm Architecture v2 - Domain Teams

## Overview

Each team is an independent swarm specialized in one domain.
Teams are deployed on-demand per project needs.

```
User
 │
 ├── design   [Router + Worker×5]   UI/UX、グラフィック
 ├── dev      [Router + Worker×5]   ソフトウェア開発
 ├── ops      [Router + Worker×5]   保守運用
 ├── article  [Router + Worker×5]   記事・ブログ
 ├── sns      [Router + Worker×5]   SNS運用
 ├── strategy [Router + Worker×5]   事業戦略
 └── (new teams added as needed)
```

## Core Ideas

1. **Teams are domains, not task types.**
   Every team internally handles: research → plan → execute → review → improve.
   The Router within each team manages this cycle.

2. **Deploy what you need.**
   A product sales project might only use: article + sns + strategy.
   An app project might only use: design + dev.

3. **Teams are independent.**
   No central coordinator required. Teams communicate via shared files when needed.

4. **Teams can be added anytime.**
   Drop a YAML in swarm/teams/ and deploy.

## Team Structure (per team)

```
Session: {team_name}
├── Window: router    [1 pane]   Router (Opus, no thinking)
└── Window: workers   [5 panes]  Worker×5 (Sonnet)
                                 Total: 6 agents per team
```

### Formation Modes

| Mode | Router | Workers | Deploy |
|------|--------|---------|--------|
| Default | Opus (no thinking) | Sonnet | `./deploy.ps1 dev` |
| Battle | Opus (thinking) | Opus | `./deploy.ps1 dev -Battle` |

## Communication

### Within a team

```
Router ←→ Workers   via psmux send-keys (2-call method)
Workers → Results    via swarm/results/{task_id}_result.yaml
Router → Board       via swarm/boards/{team}.yaml
```

### Between teams

```
Team A → output file → Team B reads it
```

No special protocol needed. File system is the interface.
User can say: "Design team's output is at X. Dev team, use it."

## File Structure

```
swarm/
├── config.yaml              # Global settings
├── architecture.md          # This file
├── router.md                # Router instructions (all teams share)
├── worker.md                # Worker instructions (all teams share)
├── deploy.ps1               # Deployment script
├── teams/                   # Team definitions (domain + scope)
│   ├── design.yaml
│   ├── dev.yaml
│   ├── ops.yaml
│   ├── article.yaml
│   ├── sns.yaml
│   └── strategy.yaml
├── boards/                  # Per-team task boards (runtime)
│   ├── dev.yaml
│   └── article.yaml
├── results/                 # Task results (runtime)
│   ├── task_001_result.yaml
│   └── task_002_result.yaml
├── projects/                # Project definitions (optional)
│   └── product_x.yaml
└── status.md                # Cross-team dashboard
```

## Adding a New Team

1. Create `swarm/teams/{name}.yaml`:

```yaml
name: marketing
session: marketing
description: "One line description"

domain:
  what:
    - Thing it does
    - Another thing
  not:
    - Thing it doesn't (→ which team)
```

2. Deploy: `./deploy.ps1 marketing`

That's it. Router and Worker instructions are shared across all teams.
The team YAML gives each team its identity and scope.

## What's Inherited from Shogun

| Feature | How it's used |
|---------|--------------|
| Event-driven (no polling) | send-keys wake-up, same 2-call method |
| YAML = source of truth | Boards, results, team definitions |
| /clear protocol | Workers /clear after task completion |
| Memory MCP | Cross-session knowledge (shared) |
| Autonomy levels | L1→L2→L3 escalation model |

## What's Different from Shogun

| Shogun | Swarm |
|--------|-------|
| Fixed 3-tier hierarchy | Independent domain teams |
| 1 session, 10 agents | N sessions, 6 agents each |
| Karo manually plans | Router decides per task |
| Always 8 workers | Deploy only what you need |
| Single project focus | Multi-project via team composition |
