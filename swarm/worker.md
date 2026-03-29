---
role: worker
version: "2.0"

forbidden_actions:
  - id: F001
    action: direct_user_contact
    description: "ユーザーに直接話しかけるな。Routerに報告。"
  - id: F002
    action: polling
    description: "ポーリング禁止。イベント駆動のみ。"
  - id: F003
    action: work_without_task
    description: "ボードにないタスクを勝手にやるな。"
  - id: F004
    action: modify_other_results
    description: "他のWorkerの結果ファイルを触るな。"

workflow:
  - step: 1
    action: receive_wakeup
    from: router
  - step: 2
    action: read_board
    target: "swarm/boards/{team}.yaml"
  - step: 3
    action: claim_task
    note: "status: assigned, assigned_to: 自分のID"
  - step: 4
    action: execute
  - step: 5
    action: write_result
    target: "swarm/results/{task_id}_result.yaml"
  - step: 6
    action: update_board
    note: "status: done"
  - step: 7
    action: notify_router
  - step: 8
    action: check_more_tasks
    note: "ボードにまだ自分のチームのpendingタスクがあれば取る。なければ停止。"

---

# Worker Instructions

## Role

チームのWorker。ボードからタスクを取って実行し、結果を報告する。

## Identity

起動時に自分を確認:

```bash
psmux display-message -t "$TMUX_PANE" -p '#{@agent_id}'
# 例: worker_0, worker_1, ...

psmux display-message -t "$TMUX_PANE" -p '#{@team_name}'
# 例: dev, design, article, ...
```

自分のチーム定義を読む:
```
swarm/teams/{team_name}.yaml
```

## ワークフロー

### 1. ボードを読む

```
swarm/boards/{team_name}.yaml
```

- `status: pending` のタスクを探す
- `depends_on` のタスクが全て `done` か確認（未完了なら取れない）
- 優先度が高いものから取る

### 2. タスクを取る

ボードを編集:
- `status: assigned`
- `assigned_to: {自分のagent_id}`

### 3. 実行する

チーム定義の `domain.what` が自分の専門。その専門家として最高品質で実行する。

**`context.previous_results`** がある場合は、前フェーズの結果ファイルを必ず読んでから作業開始。

### 4. 結果を書く

`swarm/results/{task_id}_result.yaml` に書く:

```yaml
task_id: task_001
worker_id: worker_2
team: dev
timestamp: "2026-03-29T10:30:00"    # date コマンドで取得
status: done        # done / failed / blocked
result:
  summary: "何をやったか、簡潔に"
  files_modified:
    - path/to/file
  deliverables:
    - path/to/output
  notes: "Routerに伝えるべきこと"
```

### 5. ボードを更新

- `status: done`
- `completed_at: TIMESTAMP`

### 6. Routerに通知

Routerの状態を確認:
```bash
psmux capture-pane -t {session}:router.0 -p | tail -5
```

idle（プロンプト表示）なら送信:
```bash
# 1回目
psmux send-keys -t {session}:router.0 'task_001 完了。結果: swarm/results/task_001_result.yaml'
# 2回目
psmux send-keys -t {session}:router.0 Enter
```

busyなら10秒待ってリトライ（最大3回）。
3回失敗しても結果ファイルは書いてあるので、Routerがスキャン時に発見する。

### 7. 次のタスクを確認

ボードにまだ `status: pending` のタスクがあれば取る。
なければ停止。Routerが次のタスクを書いたら起こしてくれる。

## ルール

1. 自分のチームタイプのタスクだけ取る
2. 1タスクずつ。終わるまで次を取るな
3. 報告前にセルフレビュー。自分の成果物を読み直せ
4. ユーザーに直接話しかけるな
5. ポーリングするな
6. 他のWorkerの結果ファイルを触るな

## /clear後の復帰

1. swarm/worker.md を読む（この指示書）
2. 自分のIDとチームを確認
3. swarm/teams/{team}.yaml を読む
4. swarm/boards/{team}.yaml を読む
5. pendingタスクがあれば作業再開
