# 人物配音信息表 v1

文件：`data/characters/character_voice_manifest.json`，UTF-8 JSON。

该表是电话人物身份、个人简介和试听素材绑定的唯一来源；电话剧情只通过稳定的 `event_id` 查表，绝不按界面显示名或对白中的 `speaker` 文本猜测音色。

顶层字段固定为 `format_version`（整数 `1`）、`kind`（`character_voice_manifest`）和 `characters`。每个角色必须精确包含：

| 字段 | 规则 |
| --- | --- |
| `character_id` | 唯一英文 `snake_case` ID。 |
| `display_name` | 面向制作人员的中文人物名。 |
| `profile` | 非空中文人物信息。 |
| `event_ids` | 非空稳定电话事件 ID 数组；每个事件在整张表中恰好出现一次。 |
| `voice_stream_path` | `res://` 下已导入、可取得正时长的 `AudioStream`。 |

当前测试夜班必须恰好覆盖 11 通电话。罗尼·哈特的 `call_07_ronnie_1` 与 `call_10_ronnie_2` 共同绑定 `ronnie_hart`，因此严格使用同一素材。素材不足以给每人独立音色时，允许不同角色显式复用同一路径，但仍必须分别建档。

电话配音以当前 `StoryEngine.dialogue_changed` 的权威快照触发。目标长度为清理空白及 `[ 对话结束 ]` 标记后的正文字符数除以每秒 34 字；素材不足时按“素材 → 0.5 秒静音 → 素材”排列，静音也计入该句目标时长，最后不足 0.5 秒时仅占用剩余时长，最后一段达到目标长度即停止。对话替换、清空、挂断、02:00 与运行时解绑均停止当前播放，不保存、不恢复半句语音。
