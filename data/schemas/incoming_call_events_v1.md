# 来电事件内容契约 v1

适用文件：`data/story/foundation_events.json`。文件必须是 UTF-8 编码的标准 JSON；不允许注释或尾随逗号。

## 顶层对象

```json
{
  "content_format_version": 1,
  "content_kind": "incoming_call_events",
  "events": []
}
```

- `content_format_version`：数值必须精确等于 `1`。
- `content_kind`：字符串，必须精确为 `incoming_call_events`。
- `events`：事件对象数组；一项无效即拒绝整个文件。

## 事件对象

| 字段 | 类型与约束 |
| --- | --- |
| `id` | 英文 `snake_case` 稳定 ID，文件内唯一。 |
| `kind` | 必须为 `incoming_call`。 |
| `priority` | `main` 或 `normal`。 |
| `window_start_minute` | 相对 01:00 的整数分钟。 |
| `window_end_minute` | 相对 01:00 的整数分钟，且 `start <= end < 60`。 |
| `when_busy` | `queue` 或 `expire`；`main` 必须为 `queue`。 |
| `on_expire` | 必须为 `mark_missed`。 |
| `condition_ids` | 英文 `snake_case` 字符串 ID 数组；当前阶段只检查 ID 形状。 |
| `caller_display_name` | 非空字符串。 |
| `caller_number` | 非空字符串。 |

标准 JSON 数字在 Godot 运行时可能表现为 `int` 或 `float`。校验器只接受数学上没有小数部分的数字，并在成功输出中统一为 `int`；如 `1.5` 必须拒绝。

校验失败的结果固定包含：`source_path`、`event_id`（顶层错误为空字符串）、`field`、`error_code` 和简体中文 `message`。
