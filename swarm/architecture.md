# AI Swarm Architecture: Router + Worker Pool

## Overview

```
                         User
                          │
                    ┌─────▼─────┐
                    │  Router    │  Task classification + dispatch
                    └─────┬─────┘
                          │
              ┌───────────┼───────────┐
              │           │           │
        ┌─────▼─────┐┌───▼───┐┌─────▼─────┐
        │ Code Pool ││ Docs  ││ Research  │
        │  (1-N)    ││ Pool  ││ Pool      │
        └───────────┘└───────┘└───────────┘
              │           │           │
              └───────────┼───────────┘
                          │
                    ┌─────▼─────┐
                    │ Task Board │  Shared state (YAML)
                    └───────────┘
```

## Design Principles

### vs multi-agent-shogun

| Aspect | Shogun (Current) | Swarm (Proposed) |
|--------|-----------------|------------------|
| Hierarchy | 3-tier fixed (将軍→家老→足軽) | 2-tier dynamic (Router→Workers) |
| Task assignment | Karo manually designs execution plan | Router classifies, workers self-select |
| Worker identity | Fixed roles (ashigaru1-8) | Typed pools (code, docs, research) |
| Scaling | Always 8 workers | 1-N per pool, on demand |
| Communication | YAML + send-keys | Task Board + send-keys |
| Cost model | Sonnet/Opus split by worker number | Model selected per task complexity |
| Recovery | Manual compaction/clear protocols | Stateless workers, Task Board is truth |

### Core Ideas

1. **Workers are stateless** - Any worker in a pool can pick up any task. No "ashigaru3's file".
2. **Task Board is the single source of truth** - Not conversation context, not dashboard.
3. **Router decides WHAT, not HOW** - Workers are experts in their domain.
4. **Pools scale independently** - 5 code workers + 1 docs worker, or 2 code + 4 research.

## Components

### Router Agent

**Role**: Classify incoming tasks and dispatch to the right pool.

**Does**:
- Analyze user request
- Break into sub-tasks if needed
- Classify each sub-task (code / docs / research / test)
- Estimate complexity → select model (haiku/sonnet/opus)
- Write tasks to Task Board
- Wake appropriate pool workers
- Monitor Task Board for completions
- Report results to user

**Does NOT**:
- Execute tasks itself
- Decide implementation details (that's the worker's job)
- Manage worker lifecycle (psmux handles that)

### Worker Pools

Each pool is a set of identical workers specialized in one domain.

| Pool | Specialty | Default Model | Persona |
|------|-----------|---------------|---------|
| **code** | Implementation, refactoring, debugging | Sonnet | Senior Software Engineer |
| **docs** | Documentation, writing, translation | Sonnet | Technical Writer |
| **research** | Investigation, comparison, analysis | Sonnet | Research Analyst |
| **test** | Testing, validation, QA | Sonnet | QA Engineer |
| **design** | Architecture, system design | Opus | Solutions Architect |

Workers in the same pool are interchangeable. Any code worker can pick up any code task.

### Task Board

Central YAML file that all agents read/write.

```yaml
# swarm/board.yaml
tasks:
  - id: task_001
    type: code            # Pool type
    status: pending       # pending → assigned → done → verified
    model: sonnet         # Recommended model
    priority: high
    assigned_to: null     # Worker pane ID when picked up
    description: |
      Implement the login API endpoint.
      - POST /api/login
      - JWT token response
      - Input validation
    context:
      project: my_app
      files:
        - src/api/auth.ts
        - src/middleware/jwt.ts
    result: null
    created_at: "2026-03-29T10:00:00"
    completed_at: null

  - id: task_002
    type: research
    status: pending
    model: sonnet
    priority: medium
    assigned_to: null
    description: |
      Compare top 3 JWT libraries for Node.js.
      Output: comparison table with pros/cons.
    context: {}
    result: null
    created_at: "2026-03-29T10:00:00"
    completed_at: null
```

### Result Store

Workers write results to individual files (avoids RACE condition):

```
swarm/results/
  task_001_result.yaml
  task_002_result.yaml
```

## Communication Flow

```
1. User → Router: "Build a login system"

2. Router:
   - Breaks into sub-tasks
   - Writes to Task Board (board.yaml)
   - Wakes workers via psmux send-keys

3. Workers:
   - Read Task Board
   - Pick up tasks matching their pool type
   - Update status: pending → assigned
   - Execute task
   - Write result to swarm/results/
   - Update status: assigned → done
   - Notify Router via send-keys

4. Router:
   - Scans results
   - Aggregates if needed
   - Reports to user
```

### send-keys Protocol (inherited from shogun)

Same 2-call rule applies:

```bash
# Call 1: message
psmux send-keys -t swarm:0.1 'New task on board. Check swarm/board.yaml.'
# Call 2: enter
psmux send-keys -t swarm:0.1 Enter
```

## Model Selection

Router decides model per task, not per worker slot.

| Complexity | Criteria | Model |
|-----------|----------|-------|
| Low | Single file, straightforward change | Haiku |
| Medium | Multi-file, requires domain knowledge | Sonnet |
| High | Architecture decisions, complex debugging | Opus |

Workers accept any model assignment. The same code worker might run Sonnet for one task and Opus for the next (via `/model` command).

## Scaling

### Static (default)

```
Router: 1 (Opus, thinking disabled)
Code:   2 workers (Sonnet)
Docs:   1 worker (Sonnet)
Research: 1 worker (Sonnet)
```

### Battle Mode

```
Router: 1 (Opus, thinking enabled)
Code:   4 workers (Opus)
Docs:   2 workers (Opus)
Research: 2 workers (Opus)
```

### Custom

`swarm/config.yaml` で任意の構成を定義可能。

## Cost Control

1. **No polling** - Event-driven via send-keys (same as shogun)
2. **Stateless workers** - `/clear` after each task (no context bloat)
3. **Model-per-task** - Haiku for simple tasks, Opus only when needed
4. **Pool scaling** - Don't spawn workers you don't need

## Error Handling

| Scenario | Action |
|----------|--------|
| Worker crashes | Task stays `assigned` on board. Router re-assigns after timeout. |
| Task fails | Worker writes `status: failed` + error. Router decides retry or escalate. |
| Router crashes | Workers continue current tasks. User restarts Router. Board state survives. |
| Task stuck | Router checks `assigned_at` timestamp. Re-assigns if stale (>10min). |

## Migration from Shogun

| Shogun Component | Swarm Equivalent |
|-----------------|------------------|
| 将軍 (Shogun) | User (direct interaction with Router) |
| 家老 (Karo) | Router |
| 足軽 (Ashigaru) | Pool Workers |
| queue/shogun_to_karo.yaml | User → Router (direct) |
| queue/tasks/ashigaru{N}.yaml | swarm/board.yaml (shared) |
| queue/reports/ | swarm/results/ |
| dashboard.md | swarm/status.md (Router updates) |
| instructions/shogun.md | Not needed (no Shogun layer) |
| instructions/karo.md | swarm/router.md |
| instructions/ashigaru.md | swarm/worker.md |
| Memory MCP | Same (shared across all agents) |
| CLAUDE.md | Same (shared project context) |
