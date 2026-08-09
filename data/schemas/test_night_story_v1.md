# 第五阶段测试夜班剧情契约 v1

适用文件：`data/story/test_night_story.json`。该文件是 UTF-8 标准 JSON；任一来电、短信、广播、条件或对话引用损坏时，`ContentValidator.validate_test_night_story()` 必须拒绝整份文件。

## 顶层

```json
{
  "content_format_version": 1,
  "content_kind": "test_night_story",
  "conditions": [],
  "events": [],
  "messages": [],
  "broadcasts": [],
  "dialogue_nodes": []
}
```

- `conditions`：对象数组，每项只有稳定英文 `snake_case` 的 `id`。
- `events`：精确 11 项，且同时符合 [incoming_call_events_v1.md](./incoming_call_events_v1.md)。每项额外要求 `dialogue_start_id` 与 `unlocks_broadcast_ids`。
- `messages`：短信对象，字段为 `id`、`sender`、`body`、0～59 的整数 `unlock_minute` 与 `unlocks_broadcast_ids`。
- `broadcasts`：精确 3 项；字段为 `id`、`source`、`body`、`unlock_message_ids`、`unlock_event_ids`、`sets_condition_id` 与 `exclusive_group_id`。后两个字段可为空字符串；非空值必须是已声明的稳定 ID。
- `dialogue_nodes`：预制对话树节点，字段为 `id`、`event_id`、`speaker`、`text`、`is_terminal`、`options`。选项字段为 `id`、`text`、`next_node_id`。

## 解锁与广播

- 来电和短信的 `unlocks_broadcast_ids` 必须指向存在的稿件；稿件的 `unlock_event_ids`、`unlock_message_ids` 必须反向引用同一来源，缺一侧即拒绝。
- `sets_condition_id` 非空时必须指向 `conditions` 中的 ID。条件事件只在窗口内实际满足过条件后才会成为来电；从未满足条件的事件安静失效，不生成漏接记录。
- `exclusive_group_id` 相同且非空的稿件互斥：玩家播出其中一条后，同组其余稿件保持可见但不可发送，并提供中文原因。
- 玩家播出记录由 `BroadcastSystem` 创建，包含 `broadcast_id`、`source`、`sent_at_tick`、`body`、`is_unauthorized=false`。02:00 的异常记录由 `StoryEngine` 单独创建，固定带 `fact_id=fact_unauthorized_broadcast` 与 `is_unauthorized=true`。

## 对话可达性

- 每个事件的 `dialogue_start_id` 必须存在且属于该事件；所有选项跳转也不得跨事件或悬空。
- 入口可达的图不能有循环，所有节点必须从某个事件入口到达，并且每条路径都必须结束于显式 `is_terminal=true` 节点。
- `call_11_final_amy` 是用户确认的唯一回应，所有路径必须恰为 1 轮玩家选择。其他 10 通电话每条路径必须为 2～4 轮玩家选择。
