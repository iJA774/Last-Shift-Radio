# 末班电台 / Last Shift Radio

《末班电台》（Last Shift Radio）是一款使用 **Godot 4.7.1** 开发的纯 2D、固定多视图心理恐怖游戏。玩家独自值守一座地方电台，通过电话、新闻、短信、广播与工作室里细微的环境变化，拼凑一场始终无法被亲眼确认的异常事件。

> [!WARNING]
> **当前版本为 Beta / 内部开发测试版本。**
>
> 剧情与玩法仍未完成，现有内容不代表最终游戏体验；项目仍在持续开发和重构中，**可能包含大量 Bug、未完成流程、临时内容以及行为不稳定的功能**。如果你只是想体验完整成品，建议等待后续更稳定的版本。

## 游戏概念

当前验证内容发生在 1999 年的虚构工业小城米尔黑文（Millhaven）。玩家是 WMLH 780 AM 电台唯一的夜间值守人员，在固定工作室内接收来自城市的碎片化信息。

游戏的恐怖核心不是战斗、追逐或直接展示怪物，而是信息之间逐渐出现无法解释的矛盾：

- 一座已经封闭的桥，仍有人声称刚刚经过；
- 不同来电者描述出彼此呼应、却又互相冲突的细节；
- 新闻、短信、电话记录与广播内容开始无法完全对应；
- 工作室之外似乎正在发生什么，但玩家始终缺乏足够视野去确认真相。

核心原则是：**看不见的，比看得见的更恐怖。**

## 当前内容

目前项目已经具备一套可运行的内部验证框架，主要包括：

- 工作室总览、电话、电脑、门与观察窗等固定视图；
- 01:00～02:00 的测试夜班流程与强制收束；
- 游戏时间、事件调度、剧情事实与条件系统；
- 来电、接听、挂断、漏接与电话记录；
- 新闻、短信、值班信息与电脑界面；
- 中央麦克风广播任务与已收集信息选择；
- 3 个本地手动存档槽；
- 音量、显示、CRT 与减少闪烁等设置；
- 环境音、BGM、电话音效、UI 音效与角色短音色；
- Director / Actor Agent 架构；
- Agent Dialogue v2 自由文本电话对话路径；
- WorldBook、Signal、Delivery 等 Agent 扩展基础模块及对应验证代码。

其中一部分 Agent 与完整游戏扩展仍处于开发和集成阶段，不能视为已经完成的最终玩法。

## 当前开发状态

当前项目为“可持续迭代的内部验证版”，而不是内容完整的正式 Demo。

特别需要注意：

- **剧情尚未完成。** 当前测试夜班只覆盖完整游戏设想的一小部分。
- **玩法尚未完成。** 部分系统仍在扩展、调整或替换旧验证路径。
- **可能存在大量 Bug。** 包括流程中断、UI 状态异常、Agent 网络请求失败、内容数据问题以及尚未覆盖的边界条件。
- Agent 扩展仍有尚未完成端到端验证的部分，真实模型端点下的行为可能与本地确定性测试不同。
- 当前的 UI、美术、音频、数值、文本和剧情数据均可能继续调整。

如果你在开发或游玩过程中发现异常，请优先保留可复现步骤、相关日志、当前游戏时间、所在视图与触发事件 ID。

## 技术栈

| 项目 | 当前选型 |
| --- | --- |
| 游戏引擎 | Godot 4.7.1 Standard |
| 编程语言 | GDScript |
| 场景 | 纯 2D，以 `Control` 为主 |
| 设计基准 | 1920×1080 / 16:9 |
| 当前目标平台 | Windows PC |
| 剧情内容 | UTF-8 JSON |
| 存档 | `user://` 下的本地 JSON，3 个手动槽 |
| 自动验证 | Godot Headless + 项目内 smoke / validation 脚本 |
| Agent 协议 | OpenAI Chat Completions 兼容接口 |

项目的确定性世界状态仍由 `StoryEngine`、`PhoneSystem`、`GameClock` 等本地系统掌握。Director 与 Actor 只能生成 proposal，不能直接修改世界事实或跳过系统校验。

## 运行项目

### 环境要求

请使用 **Godot 4.7.1 Standard**。项目当前没有承诺兼容其他 Godot 版本。

主场景：

```text
res://scenes/app/main.tscn
```

### 使用编辑器

在 Godot 4.7.1 中导入仓库根目录的 `project.godot`，然后运行项目即可。

也可以在 PowerShell 中从项目根目录启动：

```powershell
& 'path\to\Godot_v4.7.1-stable_win64.exe' --editor --path .
```

进行基础 Headless 启动检查：

```powershell
& 'path\to\Godot_v4.7.1-stable_win64_console.exe' --headless --path . --quit
```

项目开发环境目前固定使用 Godot 4.7.1；不要仅因为更高版本可以打开工程，就默认升级项目版本。

## Agent / LLM 配置

当前正式电话内容已经进入 **Agent Dialogue v2**。如需运行依赖真实模型的 Agent 路径，需要配置 `AgentRuntime`。

仓库提供模板：

```text
config/agent_runtime.example.json
```

开发时可以复制为：

```text
config/agent_runtime.local.json
```

然后配置 Director 与 Actor 各自的：

- `url`
- `model`
- `api_key`
- 温度、Token 上限与超时等参数

当前支持 `openai_chat_completions` 兼容协议，`url` 应填写完整的 Chat Completions 请求地址。

示意配置：

```json
{
  "schema_version": 1,
  "enabled": true,
  "director": {
    "protocol": "openai_chat_completions",
    "url": "https://your-provider.example/v1/chat/completions",
    "model": "your-director-model",
    "api_key": "YOUR_KEY"
  },
  "actor": {
    "protocol": "openai_chat_completions",
    "url": "https://your-provider.example/v1/chat/completions",
    "model": "your-actor-model",
    "api_key": "YOUR_KEY"
  }
}
```

实际配置还包含重试、Token、超时、额外 Header / Body 等字段，请直接参考 `config/agent_runtime.example.json`。

> [!CAUTION]
> 不要把真实 API Key 提交到仓库。`config/agent_runtime.local.json` 用于本机开发；正式分发更推荐使用 `user://agent_runtime.json`。

模型配置与游戏内普通设置相互独立，当前设置界面不会读取或修改 Agent URL、Model 或 API Key。

## 项目结构

```text
Last Shift Radio/
├─ project.godot              # Godot 工程配置
├─ scenes/                    # 应用、工作室和 UI 场景
├─ scripts/
│  ├─ core/                   # 剧情、时间、内容与事件核心
│  ├─ systems/                # 电话、电脑、音频、存档、Agent 运行时等
│  ├─ agents/                 # Director / Actor / LLM Gateway 与会话协议
│  └─ ui/                     # 固定视图与界面逻辑
├─ data/                      # 剧情、角色与数据契约
├─ worldbooks/                # Agent WorldBook 内容
├─ config/                    # Agent 配置模板与本地开发配置
├─ resources/                 # Godot 主题与资源
├─ art/                       # 美术源文件、运行时资产与生成记录
├─ UI美术/                    # 当前 UI 图片资源
├─ 音效/                      # BGM、电话、对白提示与 UI 音效
└─ tests/                     # smoke、fixtures 与视觉测试产物
```

## 核心架构原则

### 确定性世界权威

`StoryEngine` 是剧情状态的单一权威来源。UI 负责展示状态和提交玩家意图，不应该自行维护第二套剧情真相。

电话、电脑、广播、Agent 和其他系统最终都必须经过确定性世界规则校验。即使 Director 或 Actor 给出模型输出，也不能直接覆盖世界状态。

### Agent 权限边界

当前 Agent 架构大致为：

```text
World Kernel
    ↑   ↓
AgentRuntime
 ├─ Director：低频全局规划 / 恢复
 └─ Actor：高频角色局部决策
```

Actor 只能从系统允许的动作与可披露信息中选择；Director 也不能创造绕过规则的新世界事实。

### 固定空间恐怖

项目不会以自由行走、战斗或复杂物品谜题作为核心。玩家的主要行为是：

```text
接收信息
  ↓
判断 / 追问 / 核实
  ↓
查看其他来源
  ↓
发现冲突
  ↓
决定是否相信或广播
  ↓
继续值守
```

## 开发与验证

运行逻辑、剧情数据或存档契约发生变化后，应优先执行相关 Headless / smoke 验证。

项目测试集中在：

```text
tests/smoke/
```

重点回归边界包括：

- 事件调度与占线队列；
- 响铃状态的保存 / 读取；
- 电话与自由文本 Agent 对话生命周期；
- Agent stale-response 丢弃；
- 广播任务与信息选择；
- 02:00 在不同界面和电话状态下的强制收束；
- 损坏内容或存档数据被明确拒绝；
- UI、音频、设置和固定视图状态同步。

历史测试结果只能作为历史基线。修改相关模块后，应以当前工作树实际执行的结果为准，不要把旧的通过记录当作当前版本已经通过。

---

**再次提醒：当前为 Beta 开发版本，剧情与玩法尚不完整，并可能包含大量 Bug。**
