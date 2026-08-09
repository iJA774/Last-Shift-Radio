# SettingsManager 设置文件契约（v1）

`SettingsManager` 是《末班电台》用户设置的唯一持久化边界。真实文件固定为
`user://settings.json`，独立于 `user://saves/slot_1.json`、`slot_2.json`、`slot_3.json`；
剧情存档不得嵌入、复制或恢复本文件的任一字段。

## 顶层结构

```json
{
  "format_version": 1,
  "settings": {
    "master_volume": 1.0,
    "ambience_volume": 1.0,
    "ui_phone_volume": 1.0,
    "window_mode": "windowed",
    "text_speed": 1.0,
    "font_size": 100,
    "reduce_flashing": false,
    "crt_enabled": true
  }
}
```

顶层仅允许 `format_version`、`settings` 两个字段；`settings` 也只允许下表列出的八个字段。
缺少字段、未知字段、错误类型、非法范围、顶层非对象、JSON 语法错误或版本不等于 `1`
均会被拒绝，不能用默认值悄悄补齐。

| 字段 | 类型与允许值 | 默认值 | 消费者 |
| --- | --- | --- | --- |
| `master_volume` | 有限数值，`0.0`～`1.0` | `1.0` | AudioManager 的 `Master` Bus |
| `ambience_volume` | 有限数值，`0.0`～`1.0` | `1.0` | AudioManager 的 `Ambience` Bus |
| `ui_phone_volume` | 有限数值，`0.0`～`1.0` | `1.0` | AudioManager 的 `UIPhone` Bus |
| `window_mode` | `windowed` 或 `fullscreen` | `windowed` | 设置 UI / 窗口适配层 |
| `text_speed` | 有限倍率，`0.25`～`4.0`；越大越快 | `1.0` | 电话对白显示层 |
| `font_size` | 整数枚举：`100` 或 `125`（百分比） | `100` | 全部文字 UI |
| `reduce_flashing` | 布尔值 | `false` | 环境、灯光与 CRT 动态效果 |
| `crt_enabled` | 布尔值 | `true` | CRT/噪声显示效果 |

JSON 数字在 Godot 的解析结果可能为浮点数；`format_version` 和 `font_size` 仍必须是数学上
精确的整数，分别只接受 `1`、`100` 或 `125`。

## 生命周期与失败策略

- Autoload 名称为 `SettingsManager`，脚本类名为 `SettingsManagerService`。
- `_ready()` 会调用 `load_settings()`。首次没有文件时，只会在默认文档成功写入、读回并校验后，
  才将默认值确认为已加载。
- 已存在的损坏或不兼容文件会令 `load_settings()` 返回 `{ "ok": false, "error_code": ..., "message": ... }`。
  它保留进程内的确认默认值但标记为未加载，绝不覆盖该文件，也不把读取说成成功。
- `reset_to_defaults()` 是明确的恢复动作，允许用确认默认值替换损坏文件；普通
  `save_settings()` 与单项 setter 在未成功加载时均拒绝写入。
- 每次写入先创建 `settings.json.tmp`，再从磁盘重新解析并校验该临时文件；替换时先将旧文件
  移为 `settings.json.bak`，成功替换后删除备份。替换失败会恢复旧文件，且不会提交新的内存设置。
- 若进程在旧文件移为 `.bak` 后、新文件替换前终止，下一次加载会优先严格校验 `.bak`：有效时
  将其恢复为 `settings.json` 并返回 `recovered_backup: true`；无效或恢复失败时返回明确错误并保留
  `.bak`，绝不建立默认文件覆盖现场。

## 公共接口与即时应用

单项 setter 均同步完成写入后才提交内存状态；成功时按变化字段发出
`setting_changed(setting_id: String, value: Variant)`，随后发出
`settings_applied(settings: Dictionary)` 的深拷贝。`load_settings()` 与
`reset_to_defaults()` 成功后会发出 `settings_applied`，使晚创建的 UI/Audio/FX 可直接应用全量设置。

读取接口为：

- `get_master_volume()`、`get_ambience_volume()`、`get_ui_phone_volume()`
- `get_window_mode()`、`is_fullscreen()`
- `get_text_speed()`、`get_font_size()`
- `is_reduce_flashing_enabled()`、`is_crt_enabled()`
- `get_settings_snapshot()`：仅供设置文件、设置 UI 与测试使用，返回深拷贝；不能放入剧情存档。

写入接口为相应的 `set_*()`、`set_fullscreen()`、`save_settings()` 与
`reset_to_defaults()`，全部返回具有 `ok`、失败时 `error_code` 和中文 `message` 的 `Dictionary`。

## 专项冒烟

专项测试不带参数也可由统一 Headless 批处理直接执行：

```powershell
& $godotConsole --headless --path $projectRoot --script res://tests/smoke/test_settings_manager.gd
```

测试只对 Autoload 检查节点、方法、信号与只读快照合同，不调用它的任何写入或重载接口。
所有可写验证使用独立 `SettingsManagerService` 实例，并仅在
`user://settings_manager_smoke/` 创建文件；测试结束前会删除该目录。

为让**整批**开发验证（包括 Autoload 的首次默认文件创建）不接触产品路径，可在调试或编辑器
构建的 Godot 命令行 `--` 后加入通用开发验证入口：

```powershell
& $godotConsole --headless --path $projectRoot --script res://tests/smoke/test_settings_manager.gd -- --settings-verification-path=user://settings_manager_smoke/settings_smoke_autoload.json
```

`--settings-verification-path` 不依赖任何测试文件名；只接受 `user://` 内、不含 `..`、以
`.json` 结尾的路径，且发布构建会拒绝它。全量阶段验收应统一传入上例路径，并在最后执行
`test_settings_manager.gd`，由它清理 `user://settings_manager_smoke/`。未传参数时，产品仍始终
使用 `user://settings.json`，保持正常启动语义。
