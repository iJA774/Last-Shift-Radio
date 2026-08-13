# 第六阶段测试夜班剧情契约 v1

适用文件：`data/story/test_night_story.json`。该文件是 UTF-8 标准 JSON；任一来电、短信、发布任务、信息项、条件或对话引用损坏时，`ContentValidator.validate_test_night_story()` 必须拒绝整份文件。

## 顶层

```json
{
  "content_format_version": 1,
  "content_kind": "test_night_story",
  "conditions": [],
  "events": [],
  "checklist_entries": [],
  "news_entries": [],
  "messages": [],
  "broadcast_tasks": [],
  "dialogue_nodes": [],
  "statements": [],
  "facts": []
}
```

- `conditions`：对象数组，每项只有稳定英文 `snake_case` 的 `id`。
- `events`：精确 11 项，且同时符合 [incoming_call_events_v1.md](./incoming_call_events_v1.md)。每项额外要求 `dialogue_start_id`；来电事件本身不直接解锁玩家发布任务。
- `checklist_entries`：值班清单来源，字段为 `id`、`title`、`body`、0～59 的整数 `unlock_minute`、`statement_ids` 与 `fact_ids`。
- `news_entries`：地方新闻来源，字段为 `id`、`title`、`source`、`body`、0～59 的整数 `unlock_minute`、非空 `topic_ids`、`statement_ids` 与 `fact_ids`。至少 5 条，其中至少 2 条不含固定 topic ID `north_bridge`；由显式 `topic_ids` 而非正文搜索判定。
- `messages`：短信对象，字段为 `id`、`sender`、`body`、0～59 的整数 `unlock_minute`、`statement_ids` 与 `fact_ids`。短信可以提供任务信息项所需陈述，但不计入“完成必要对话”的门槛。
- `broadcast_tasks`：精确 2 项；字段为 `id`、`name`、`channel`、`source`、`related_dialogue_event_ids`、`required_dialogue_event_ids`、`sets_condition_id` 与 `information_items`。`channel` 当前必须为 `microphone`；`sets_condition_id` 可为空字符串。
- 每个 `information_items` 项字段为 `id`、`source_label`、`body`、`statement_ids`、`fact_ids`。信息项 ID 在整份内容中全局唯一；`statement_ids` 至少一项，且必须全部真实揭示后该信息项才可供玩家选择。
- `dialogue_nodes`：预制对话树节点，字段为 `id`、`event_id`、`speaker`、`text`、`is_terminal`、`reveals_statement_ids`、`options`。选项字段为 `id`、`text`、`next_node_id`、`reveals_statement_ids`。两个 `reveals_statement_ids` 都必须显式存在（可为空数组），并且只能引用以该节点 `event_id` 为 `source_id` 的陈述。
- `statements`：来源陈述，字段为 `id`、`source_id`、`body`。`source_id` 必须是一个电脑来源条目或来电事件 ID；解锁来源不等于揭示陈述，电脑来源必须由玩家阅读，电话来源必须经过明确的对话节点/选项。
- `facts`：轻量事实规则，字段为 `id`、`initially_confirmed`、`required_statement_ids`。除结尾专属的 `fact_unauthorized_broadcast` 与 `fact_anomaly_cause_unknown` 外，未初始确认的事实至少需要一条必要陈述，且只有全部必要陈述都已揭示后才会确认。

### 既定事实 ID

测试夜班必须完整使用且只使用以下 8 个稳定事实 ID：`fact_bridge_accident_before_shift`、`fact_bridge_closed`、`fact_accounts_conflict`、`fact_same_wagon_recurs`、`fact_wagon_positions_conflict`、`fact_bridge_traffic_after_closure`、`fact_unauthorized_broadcast`、`fact_anomaly_cause_unknown`。其中最后两个由 02:00 的权威结尾事件确认；艾米的陈述只能作为来源记录，不能提前确认它们。

`fact_accounts_conflict` 专指不同来源对北桥事故诱因的互不兼容描述：测试夜班需要沃伦的非权威“油罐车起火/翻倒”陈述与官方“结构受损封闭”陈述，不能用“封桥后仍有通行主张”代替。后者只用于 `fact_bridge_traffic_after_closure`。

## 发布任务与信息收集

- `related_dialogue_event_ids` 声明与任务有关、可能继续提供信息的对话；每个 ID 必须存在且有预制对话。
- `required_dialogue_event_ids` 声明允许发布前必须完成的最低对话集合；必须非空并且是 `related_dialogue_event_ids` 的子集。
- **发布门槛与信息收集是两个独立维度。** 门槛只由 `required_dialogue_event_ids` 是否已经真实完成决定；可选信息只由对应 `information_items[*].statement_ids` 是否已经真实揭示决定。
- 因此玩家达到最低必要对话门槛后，可以立即发送当前已经收集到的信息；也可以关闭面板继续值守，等待后续相关来电或电脑来源揭示更多可选信息，再一次性发送。
- 米勒警方短信是北桥任务的官方补充信息来源，但不是必要电话；阅读它可以增加 `info_bridge_official_closure`，不能替代沃伦与东侧卡车司机的最低对话门槛。
- 北桥任务的必要对话固定为 `call_01_warren` + `call_06_trucker`；`call_09_southbound` 是可等待的相关对话，可额外提供 `info_bridge_southbound_crossing`。
- `sets_condition_id` 非空时必须指向 `conditions` 中的 ID。条件事件只在窗口内实际满足过条件后才会成为来电；从未满足条件的事件安静失效，不生成漏接记录。
- 每个发布任务本局只允许成功发送一次。一次发送必须至少选择一个当前可用信息项，并以一个原子操作记账；任务发送后不得追加、拆分或再次发送。
- 玩家发布记录由 `BroadcastSystem` 创建，包含 `task_id`、`information_item_ids`、`source`、`sent_at_tick`、由所选信息正文组合得到的 `body`、`is_unauthorized=false`。02:00 的异常记录由 `StoryEngine` 单独创建，固定使用 `broadcast_id=broadcast_unauthorized_north_bridge_open`、`fact_id=fact_unauthorized_broadcast` 与 `is_unauthorized=true`；它不属于玩家发布任务。

## 对话可达性

- 每个事件的 `dialogue_start_id` 必须存在且属于该事件；所有选项跳转也不得跨事件或悬空。
- 入口可达的图不能有循环，所有节点必须从某个事件入口到达，并且每条路径都必须结束于显式 `is_terminal=true` 节点。
- `call_11_final_amy` 是用户确认的唯一回应，所有路径必须恰为 1 轮玩家选择。其他 10 通电话每条路径必须为 2～4 轮玩家选择。

## 状态归属

- `ComputerSystem` 是 `source_unlocked`、`source_read` 和未读计数的唯一权威；`StoryEngine` 只通过其公开接口展示这些状态。
- `StoryEngine` 是 `statement_revealed`、`fact_confirmed`、`completed_dialogue_event_ids`、发布任务门槛/信息可用性和 02:00 收束的唯一权威。漏接只会生成 `PhoneSystem` 的真实来电记录，绝不揭示电话陈述。
- `BroadcastSystem` 不判断来源是否读过、电话是否完成或任务是否可发布；它只校验最终选中的任务/信息项并负责一次性发送记录、去重和快照。
