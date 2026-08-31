# 第七阶段底层运行时快照契约 v1

适用系统：`GameClockService`、`EventScheduler` 与 `PhoneSystem`。本文件只描述本阶段底层快照；整局文件封装、三个槽位与跨系统读取顺序由 `SaveManager` 契约说明。

三个系统统一提供以下公开 API：

```gdscript
func create_snapshot() -> Dictionary
func validate_snapshot(snapshot: Dictionary, context: Dictionary = {}) -> Dictionary
func restore_snapshot(snapshot: Dictionary, context: Dictionary = {}) -> Dictionary
```

- 快照只包含 JSON 对象、数组、字符串、数字、布尔值和 `null`。
- 顶层 `snapshot_version` 必须为数值 `1`，`system_id` 必须与本系统精确匹配。
- 验证器拒绝缺字段、未知字段、错误类型、非有限或带小数的整数语义数值、未知稳定 ID 与非法状态组合。Godot 的 JSON 读取器若将整数读为无小数浮点，仍按整数语义接受并标准化。
- `restore_snapshot` 先完整验证、构建临时值，再一次性提交。失败不改原状态；成功不发送游戏时间推进、事件入队/触发/过期、电话状态转换或记录创建等业务信号。

## GameClockService

`system_id`：`game_clock`

```json
{
  "snapshot_version": 1,
  "system_id": "game_clock",
  "current_game_tick": 1380,
  "pending_tick_progress_units": 0,
  "is_running": true,
  "ending_emitted": false,
  "time_rate": 0
}
```

| 字段 | 约束 |
| --- | --- |
| `current_game_tick` | 整数，`0..3600`。 |
| `pending_tick_progress_units` | 整数，`0..59,999,999`；不足一个游戏 tick 的进度。 |
| `is_running` | 布尔值。正常夜班运行中为 `true`。 |
| `ending_emitted` | 布尔值。仅 `current_game_tick=3600`、时钟停止且 pending 为 0 时可为 `true`。 |
| `time_rate` | `0`（FAST）、`1`（SLOW）或 `2`（PAUSED）。 |

未收束且停止的快照只能是 `01:00` 预备态（tick 和 pending 均为 0）。恢复总会同步单调 wall-clock 基准，因此加载耗时不会补算为游戏时间。默认恢复快照的运行状态；若 `context.defer_running=true`，恢复会保持停止且返回 `resume_required=true`，应用在所有运行时对象绑定完毕后调用 `resume_restored_clock()`。这个启动动作不发出 `shift_started`。

应用销毁当前运行时前可调用 `stop_for_runtime_disposal()`：它只停止真实时间累计，不重置可存档状态且不发业务信号。

## EventScheduler

`system_id`：`event_scheduler`

```json
{
  "snapshot_version": 1,
  "system_id": "event_scheduler",
  "event_status_by_id": {"call_warren": "triggered"},
  "pending_event_ids": [],
  "queued_items": [],
  "condition_eligible_event_ids": [],
  "schedule_sequence": 11,
  "queue_sequence": 2,
  "last_processed_minute": 23,
  "ending_forced": false
}
```

- `event_status_by_id` 的 ID 集合必须与当前已配置内容事件完全相同；允许状态为 `scheduled`、`triggered`、`queued`、`expired`、`suppressed_condition_unmet`、`cleared_for_ending`。
- `pending_event_ids` 仅对应 `scheduled` 状态；`queued_items` 仅对应 `queued` 状态。二者不可重叠、各自不得重复。
- `queued_items` 只保存 `{ "event_id", "queue_sequence" }`，按当前队列顺序排列；恢复从当前已配置的事件定义重新关联，不在存档重复写剧情定义。
- `condition_eligible_event_ids` 只可引用仍待处理且处于自身时间窗内的事件。调度器对无条件事件也使用同一资格集合记录“当前窗口已允许派发”，因此该集合不等同于“事件必须带条件”。
- `ending_forced=true` 时，待处理、队列、条件资格集合均必须为空，且没有 `scheduled` 或 `queued` 事件。

`validate_snapshot` / `restore_snapshot` 可以传入 `{ "event_by_id": <已验证内容映射> }`；省略时使用 Scheduler 已配置事件。无论哪一种，恢复对象都必须已按相同内容完成 `schedule_events`。调用 `get_configured_events_by_id()` 可取得供其他系统核验来显的公开只读副本。

## PhoneSystem

`system_id`：`phone_system`

```json
{
  "snapshot_version": 1,
  "system_id": "phone_system",
  "state": "RINGING",
  "handled_event_ids": ["call_previous"],
  "call_records": [],
  "forced_end": false,
  "snapshot_current_tick": 1380,
  "active_call": {
    "event_id": "call_warren",
    "caller_name": "沃伦",
    "caller_number": "555-0100",
    "ringing_started_tick": 1370,
    "connected_started_tick": -1,
    "ringing_ticks_remaining": 20
  }
}
```

- 可持久化的 `state` 仅为 `IDLE`、`RINGING`、`CONNECTED`、`DIALOGUE_CHOICE`。后两者表达完整状态以便校验，但 `can_save()` 必须返回 `false`；`get_save_block_reason()` 提供中文原因。
- `IDLE` 必须使用 `active_call: null`；非空闲状态必须含活动线路。`forced_end=true` 时也必须空闲，且只允许 `snapshot_current_tick=3600`；02:00 前必须为 `false`。
- 每条记录字段固定为 `event_id`、`time`、`caller_name`、`caller_number`、`outcome`、`duration_ticks`。记录 ID 必须唯一，并与 `handled_event_ids` 一一对应。
- `RINGING` 必须具有 `connected_started_tick=-1` 和严格大于零的 `ringing_ticks_remaining`。恢复用 `context.current_game_tick + ringing_ticks_remaining` 重建 deadline，因此读取不会重新派发同一事件，也不会凭空漏接或补算加载时间。
- `validate_snapshot` / `restore_snapshot` 必须传入：

```gdscript
{
  "current_game_tick": <GameClock 当前 tick>,
  "event_by_id": <EventScheduler.get_configured_events_by_id()>
}
```

其中 `current_game_tick` 必须与 `snapshot_current_tick` 精确相等；所有活动/历史来电的 ID 与来显必须和当前内容事件匹配。未知 ID、来显篡改、负剩余 tick、已处理来电仍活动等情况一律拒绝。
