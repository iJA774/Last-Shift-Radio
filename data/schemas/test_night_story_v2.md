# Agent Dialogue 测试夜班剧情契约 v2

适用目标：`data/story/test_night_story.json` 从预制 dialogue tree 迁移到 Agent Dialogue 后的正式内容合同。

**当前状态（2026-08-29）**：`scripts/core/test_night_story_v2_validator.gd` 已实现该合同，并由 `ContentValidator.validate_test_night_story()` 在 `content_format_version=2` 时委托校验；但正式 `data/story/test_night_story.json` 当前仍为 v1，因此本文档描述的是**已经有代码支持、尚未完成数据迁移的 v2 目标格式**。不要在完成内容迁移前声称正式夜班已经启用 v2。

## 1. 顶层

```json
{
  "content_format_version": 2,
  "content_kind": "test_night_story",
  "conditions": [],
  "events": [],
  "checklist_entries": [],
  "news_entries": [],
  "messages": [],
  "broadcast_tasks": [],
  "actors": [],
  "statements": [],
  "facts": []
}
```

要求：

- `content_format_version` 必须精确为整数 `2`。
- `content_kind` 必须精确为 `test_night_story`。
- 上述 9 个内容集合必须为数组。
- 正式 v2 **禁止 `dialogue_nodes`**。
- v2 来电事件 **禁止 `dialogue_start_id`**。
- v1 `incoming_call_events` fixture 合同仍保持 v1，不应为了 v2 偷改其字段语义。

## 2. Actor 定义

`actors` 必须精确包含 **10 个 caller Actor**。每项：

```json
{
  "id": "ronnie",
  "display_name": "罗尼",
  "voice_profile_id": "voice_low_male_02",
  "profile": {
    "role": "夜间货运司机",
    "personality": "谨慎、疲惫，对自己的记忆越来越不确定",
    "speech_style": "短句、口语化、偶尔停顿"
  },
  "initial_state": {
    "knowledge": [],
    "beliefs": [],
    "episodic_memory": [],
    "current_goal": "verify_memory",
    "available_goal_ids": ["verify_memory", "seek_external_confirmation"],
    "trust": 0.5,
    "stress": 0.3,
    "heard_signal_ids": [],
    "private_information": [],
    "forbidden_knowledge": []
  }
}
```

### 2.1 Actor 字段

- `id`：稳定英文 `snake_case`。
- `display_name`：非空展示名。
- `voice_profile_id`：非空稳定音色配置引用；当前只是内容合同，正式动态 ActorTurn 语音路由仍待接入。
- `profile`：至少包含非空 `role`、`personality`、`speech_style`。
- `initial_state`：必须包含本文列出的全部状态维度。

### 2.2 Actor canonical state

- `knowledge`、`beliefs`、`episodic_memory`、`private_information`、`forbidden_knowledge`：非空字符串组成的数组，可为空数组。
- `available_goal_ids`、`heard_signal_ids`：稳定 ID 数组，不得重复。
- `current_goal`：可为空；非空时必须是稳定 ID，并来自 `available_goal_ids`。
- `trust`、`stress`：`0..1` 数值。

Actor state 由 `AgentRuntime / ActorAgent` 持有 canonical runtime copy；LLM 不能自由创造新状态字段。

## 3. 11 通来电事件

`events` 必须精确包含 **11 通 incoming_call**。保留 v1 的调度字段：

- `id`
- `kind=incoming_call`
- `priority=main|normal`
- `window_start_minute`
- `window_end_minute`
- `when_busy=queue|expire`
- `on_expire=mark_missed`
- `condition_ids`
- `caller_display_name`
- `caller_number`

并新增 Agent Dialogue 字段：

```json
{
  "actor_id": "warren",
  "available_statement_ids": ["statement_warren_tanker_fire"],
  "line_profile_id": "landline_noisy",
  "call_reason": "向电台报告北桥方向的异常情况",
  "opening_intent": "先确认电台是否有人值守，再说明自己看到的情况",
  "fallback_utterance": "线路里只剩下一阵杂音，对方很快挂断了。"
}
```

要求：

- `actor_id` 必须引用 `actors` 中真实 Actor。
- 11 通电话必须覆盖全部 10 个 Actor。
- `ronnie` 必须恰好出现 **2 次**；其它 9 个 Actor 各恰好 1 次。
- `available_statement_ids` 只能引用存在的 Statement，并且每个 Statement 的 `source_id` 必须等于当前 event ID。
- `line_profile_id`、`call_reason`、`opening_intent`、`fallback_utterance` 必须为非空字符串。
- `fallback_utterance` 是作者可控的 deterministic dialogue fallback；fallback 不应凭空声明 claim。

### 3.1 可选 session_state_patch

事件可以提供作者声明的会话前 Actor 状态补丁，例如 Ronnie 第二通电话的记忆断片：

```json
{
  "session_state_patch": {
    "episodic_memory": ["我记得自己今晚已经给电台打过电话，但细节对不上。"],
    "beliefs": ["也许上一通电话并不是我记得的那样。"],
    "current_goal": "verify_memory",
    "stress": 0.72
  }
}
```

只允许修改：

- `knowledge`
- `beliefs`
- `episodic_memory`
- `current_goal`
- `trust`
- `stress`

该 patch 是**作者确定性规则**，由 StoryEngine 在建立 interaction 时返回，再由 AgentRuntime 更新 Actor state；不是模型生成的世界写入。

## 4. Statement 与语义守卫

Statement 基本字段保持：

```json
{
  "id": "statement_dog_walker_wagon_color",
  "source_id": "call_04_dog_walker",
  "body": "遛狗者看到一辆深色旧旅行车，右后灯忽明忽暗。"
}
```

`source_id` 必须引用现有来电、checklist、news 或 message 来源。

电话 Statement 不再由 `dialogue_nodes[*].reveals_statement_ids` 揭示，而由合法 committed `ActorTurn.asserted_claim_ids` 揭示：

```text
ActorTurn.asserted_claim_ids
→ ActorTurn 结构 / claim 白名单校验
→ TurnSemanticGuard
→ StoryEngine source authority validation
→ StoryEngine.commit_agent_turn()
→ Statement reveal
→ Fact evaluation
→ Broadcast Task refresh
```

### 4.1 可选 semantic_guard

关键 claim 可以附加作者语义守卫：

```json
{
  "semantic_guard": {
    "required_term_groups": [
      ["深色", "暗色", "暗绿"],
      ["旅行车"],
      ["右后灯", "尾灯"]
    ],
    "forbidden_terms": ["鲜红", "红色旅行车"]
  }
}
```

- `required_term_groups`：每组至少一个非空字符串；声明该 claim 时，utterance 必须命中每组中的至少一个概念词。
- `forbidden_terms`：非空字符串数组；命中时拒绝该 ActorTurn。
- 该守卫用于关键作者事实的一致性，不应演化成通用自然语言真理判断器。

## 5. Fact

Fact ID 与 v1 保持稳定，测试夜班必须完整使用且只使用以下 8 个：

- `fact_bridge_accident_before_shift`
- `fact_bridge_closed`
- `fact_accounts_conflict`
- `fact_same_wagon_recurs`
- `fact_wagon_positions_conflict`
- `fact_bridge_traffic_after_closure`
- `fact_unauthorized_broadcast`
- `fact_anomaly_cause_unknown`

字段仍为：

- `id`
- `initially_confirmed`
- `required_statement_ids`

除两个 02:00 ending-only Fact 外，未初始确认的 Fact 至少需要一个必要 Statement。Fact 仍由 StoryEngine 根据已揭示 Statement 确定性派生，LLM 不直接确认 Fact。

## 6. 电脑来源与短信

`checklist_entries`、`news_entries`、`messages` 保留 v1 的来源 / 阅读边界：

- 来源解锁不等于 Statement 揭示；
- checklist / news / message 只有玩家实际阅读后，ComputerSystem 才发出 source-read；
- StoryEngine 才能据此揭示对应 Statement；
- 来电记录仍必须来自 PhoneSystem 的真实 call record，不能由 Agent transcript 补造漏接内容。

新闻仍至少 5 条，并至少 2 条不含 `north_bridge` topic。

## 7. Broadcast Task v2

v2 正式任务不再使用：

- `related_dialogue_event_ids`
- `required_dialogue_event_ids`

改为：

```json
{
  "id": "task_broadcast_bridge_closure",
  "name": "北桥封锁信息",
  "selection_mode": "multiple",
  "channel": "microphone",
  "source": "Studio A",
  "related_event_ids": ["call_01_warren", "call_06_trucker", "call_09_southbound"],
  "requirements": [
    {"type": "statement_revealed", "id": "statement_warren_tanker_fire"},
    {"type": "statement_revealed", "id": "statement_trucker_east_queue"}
  ],
  "sets_condition_id": "",
  "information_items": []
}
```

### 7.1 支持的 requirement type

当前 validator / StoryEngine v2 分支支持：

- `statement_revealed`
- `fact_confirmed`
- `condition_true`
- `interaction_answered`
- `interaction_completed`
- `broadcast_sent`
- `message_read`

每个 requirement 必须且只能包含 `type` 与 `id`，不得重复。

`broadcast_sent` 当前只允许引用**在内容数组中此前已经声明**、且不是自身的任务，以避免直接形成循环依赖。

### 7.2 Information item

`information_items` 保持：

- `id`
- `source_label`
- `body`
- `statement_ids`
- `fact_ids`

信息项只有当其全部 `statement_ids` 已真实揭示后才可供玩家选择。任务 requirement 是否满足与“当前收集到哪些 information item”仍是两个独立维度。

## 8. Interaction answered / completed 语义

StoryEngine v2 区分：

- `interaction_answered`：当前 event 至少有一个 ActorTurn 被合法 committed；
- `interaction_completed`：该 ConversationSession 被确定性结束并归档。

因此自由盘问不再需要“走到 terminal dialogue node”才能推进世界语义。玩家问到关键 Statement 后主动挂断，也可以保留已经 committed 的 Statement；是否满足某个 Task 由其显式 requirement 决定。

## 9. Phone / Conversation 权限

- PhoneSystem 继续拥有响铃、接听、线路唯一性、挂断、漏接与 02:00 强制结束。
- ConversationSession 只保存 committed 展示 transcript 与 request serial，不拥有世界事实。
- InteractionCoordinator 负责 PlayerTurn、ActorTurn 请求、stale guard 与 commit 顺序。
- 网络响应必须在提交前复核 session/event/request/runtime serial、当前电话状态和 02:00；过期响应不得进入 transcript 或 StoryEngine。
- Actor `session_intent=end` 只是结束请求，最终线路状态仍必须由 PhoneSystem 提交。

## 10. 正式迁移要求

把 `data/story/test_night_story.json` 从 v1 升到 v2 时必须一次完成以下事项，不长期维持双轨：

1. `content_format_version` 升为 `2`；
2. 新增精确 10 个 Actor；
3. 11 通 event 绑定 Actor，Ronnie 两通共用同一个 Actor；
4. 删除正式 `dialogue_nodes` 与所有 event `dialogue_start_id`；
5. 为电话 event 填入 `available_statement_ids / line_profile_id / call_reason / opening_intent / fallback_utterance`；
6. 保留既有稳定 Statement / Fact IDs，不把模型措辞升级成新事实；
7. Broadcast Task 改用 `related_event_ids + requirements`；
8. 更新依赖旧 dialogue tree 的 smoke tests；
9. 在可执行 Godot 4.7.1 环境中通过内容校验、电话路由与 Agent interaction smoke 后，才把 v2 视为正式启用。

## 11. 当前未包含在本 schema 的后续系统

以下仍是运行时后续工作，不属于 `test_night_story` v2 内容文件本身：

- SaveManager 顶层 Agent / interaction committed-state 升级；
- SignalSystem；
- DeliverySystem；
- Director Opportunity Builder / trigger policy；
- committed ActorTurn → CharacterVoicePlayer 的动态语音路由。
