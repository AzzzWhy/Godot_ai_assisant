# Godot AI Assistant — 把大模型接入 Godot

一个 **Godot 4.x** 插件，把任意 **OpenAI 兼容**的大模型接进 Godot 引擎：

- 🖥️ **编辑器内聊天面板**：右侧 Dock 直接对话、流式输出、让 AI 分析/修改你正在编辑的脚本、一键把生成的 GDScript 插入当前脚本。
- 🎮 **游戏内 AI 对话**：自动注册全局单例 `AI`，任意场景一行代码即可调用，适合 NPC 对话、剧情生成、互动叙事。
- 🔌 **任意 OpenAI 兼容后端**：DeepSeek、OpenAI、Kimi(Moonshot)、通义千问、智谱 GLM、本地 Ollama、vLLM 等，只需改 `base_url`。
- 🧠 **模型自动识别**：填入 Key + 地址后自动拉取该账号**真实可用**的模型列表（`GET {base}/models`），不同服务商/Key 模型不同也不怕选错。
- ⭐ **「我的模型」收藏**：API 返回的全部模型不会一股脑堆进下拉框，用「＋加入」把常用的收进自己的列表，面板只显示你选的。
- ⚡ **流式输出（SSE）** + `deepseek-reasoner` 思考过程展示 + 请求队列 + 超时/错误处理。

---

## 一、快速开始（10 秒看到效果）

1. 用 **Godot 4.x** 打开本项目文件夹（`GodotAIAssistant/`，里面自带 `project.godot`）。插件已自动启用：编辑器右侧会出现 **「AI 助手」** 面板。
2. 点面板右上角 **⚙ 设置**，粘贴你的 API Key（DeepSeek 在 [platform.deepseek.com](https://platform.deepseek.com) 申请，其他服务商同理），确认 Base URL / 模型。
3. 点设置窗口里的「**刷新**」（或保存，会自动拉取）→ 在「服务器模型」里选中你想要的 →「**＋加入**」收进「我的模型」。
4. 面板下拉选好模型 → 输入消息，回车 → 完成。

> 想把这套东西装进**你自己的项目**？只要把 `addons/ai_assistant/` 整个文件夹复制到你的项目里，然后在 `项目设置 -> 插件` 中启用 **AI Assistant** 即可。启用时插件会自动注册 `AI` 单例（停用时自动移除，绝不碰你已有的同名配置）。

### 支持的后端配置速查

| 服务商 | Base URL | 模型示例 | 说明 |
|---|---|---|---|
| DeepSeek | `https://api.deepseek.com` | `deepseek-chat` / `deepseek-reasoner` | 默认配置 |
| OpenAI | `https://api.openai.com/v1` | `gpt-4o-mini` | |
| Kimi / Moonshot | `https://api.moonshot.cn/v1` | `moonshot-v1-8k` | |
| 智谱 GLM | `https://open.bigmodel.cn/api/paas/v4` | `glm-4-flash` | |
| 通义千问 | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `qwen-plus` | |
| Ollama（本地免费） | `http://127.0.0.1:11434/v1` | `qwen2.5:7b` | Key 随便填个非空值 |
| vLLM / 任何 OpenAI 兼容服务 | 你的服务地址 | 你的模型名 | |

> 面板设置为**编辑器私用**：**API Key 默认只存在内存（不写盘）**，勾选「记住 API Key」才明文存入编辑器配置，并可在设置里一键清除；**游戏运行时**的配置走 `项目设置` 或环境变量，见下文。

---

## 二、编辑器面板功能

| 功能 | 位置 |
|---|---|
| 对话（流式/非流式） | 输入框回车发送 |
| `/help` `/clear` `/script` | 快捷命令 |
| **自动识别本 Key 可用模型**（保存设置后自动拉取） | ⚙ 设置 → 保存 / 点「刷新」 |
| **「我的模型」收藏**（不把 API 全部模型堆进下拉框） | ⚙ 设置 → 服务器模型「＋加入」/「－移除」 |
| 设置 Base URL / Key / 模型 / 温度 / max_tokens / 超时 / 系统提示词 | `⚙ 设置` |
| 快速切换模型 | 面板顶部下拉 |
| **发送当前脚本**给 AI 分析 | 面板按钮 |
| 把回复中的代码块**插入当前脚本** / **另存为脚本** / **复制** | 面板底部 |
| 运行主场景（体验运行时对话） | 面板底部「运行场景」 |

---

## 三、游戏运行时（NPC 对话 / 剧情生成）

插件启用后自动注册全局单例 **`AI`**（就是一个 `AILLMClient`）。在任意场景：

```gdscript
# 可选：运行时配置（也为 AI 单例提供这些属性直接改）
AI.system_prompt = "你是神秘商店的老板「老陈」，说话慢悠悠，爱卖关子。"

# 发送消息（触发流式信号）
AI.chat("你好呀，老板今天有什么货？")

# 监听流式增量
AI.stream_chunk.connect(func(chunk: String) -> void:
    print_rich("[color=green]%s[/color]" % chunk))

# 思考过程（deepseek-reasoner / 其他推理模型）
AI.reasoning_chunk.connect(func(t: String) -> void: pass)

# 一次请求结束（成功/失败）
AI.request_finished.connect(func(success: bool, err: String) -> void:
    pass)
```

**等待式写法（协程）**，适合剧本/对话系统：

```gdscript
func ask_npc(question: String) -> String:
    AI.chat(question)
    var result: Array = await AI.request_finished   # [success, err_msg]
    if not result[0]:
        return "（NPC 走神了，没听懂）"
    return AI.last_response_text                    # 完整回复
```

**骨架对话节点**：把场景挂一个 `Node` 脚本，`_ready` 里连好信号，即可做打字机效果（参考 `examples/npc_demo.gd`）。

### 运行时配置（优先级：环境变量 > 项目设置 > 默认值）

| 项目设置键 | 环境变量 | 默认值 |
|---|---|---|
| `ai_assistant/api_key` | `AI_API_KEY` | 空 |
| `ai_assistant/base_url` | `AI_BASE_URL` | `https://api.deepseek.com` |
| `ai_assistant/model` | `AI_MODEL` | `deepseek-chat` |
| `ai_assistant/temperature` | — | `1.0`（`-1` 表示不发送） |
| `ai_assistant/max_tokens` | — | `0`（服务端默认） |
| `ai_assistant/stream` | — | `true` |
| `ai_assistant/timeout` (秒) | — | `60` |
| `ai_assistant/system_prompt` | — | 空 |

```bash
# macOS / Linux：导出前先注入 Key（推荐，不会进仓库）
AI_API_KEY=sk-xxxx godot --path . --export-release "Web" build.zip
```

如需把 `AI` 单例换成**独立客户端**（多个 NPC 各用各的历史），直接 `AILLMClient.new()`：

```gdscript
var npc: AILLMClient   # 声明变量
func _ready():
    npc = AILLMClient.new()
    add_child(npc)
    npc.api_key = "sk-..."
    npc.model = "deepseek-chat"
    npc.system_prompt = "你是卫兵，忠于职守，回答简短。"
```

---

## 四、目录结构

```
GodotAIAssistant/
├── project.godot                     # 演示项目（可直接用 Godot 打开）
├── examples/
│   ├── npc_demo.gd / .tscn           # 游戏内 NPC 对话示例（主场景）
└── addons/
    └── ai_assistant/
        ├── plugin.cfg / plugin.gd    # EditorPlugin：注册面板 + AI 单例
        ├── icon.svg
        ├── autoload/ai_assistant.gd  # 全局单例 AI（运行时入口）
        ├── client/llm_client.gd      # 核心：OpenAI 兼容客户端（流式 SSE）
        └── editor/ai_chat_dock.gd    # 编辑器聊天面板
```

---

## 五、测试（可选）

自带两套离线自检脚本，均在 Godot 4.6 下实机验证通过：

```bash
# 1) 离线冒烟测试：信号 / 请求队列 / 历史维护 / SSE 解析（无网络）
godot --headless --path . -s res://tests/smoke_test.gd

# 2) 端到端集成测试：真实 HTTP 流式 / 非流式 / 401 错误处理（需本地 mock，不消费额度）
python3 tests/mock_server.py &   # 后台起一个本地 OpenAI 兼容 mock
godot --headless --path . -s res://tests/integration_test.gd
```

---

## 六、常见问题

- **API Key 存在哪？** 默认**不落盘**，只在当前编辑器会话内存中使用。勾选设置里的「记住 API Key」后才会明文写入编辑器配置（macOS：`~/Library/Application Support/Godot/editor_settings-4.x.tres`），可随时点「清除已保存的 Key」删除。游戏运行时请用环境变量 `AI_API_KEY`。
- **HTTP 404**：Base URL 填错了。Base URL 只需填到服务商根地址（可含 `/v1` 等前缀），**不要**把 `/chat/completions` 也拼进去。客户端会自动拼接并容错（即使误填了完整端点也能正确处理；报错信息里会带上实际请求的完整 URL）。
- **HTTP 401**：API Key 无效或服务商没给该接口权限；检查 Key、Base URL、模型名。设置窗口的「刷新」会直接用**输入框里的 Key** 请求（无需先保存），失败时显示服务商返回的具体原因。
- **模型列表加载失败 / 没有模型**：部分服务商不支持 `GET /models` 接口——没关系，直接在「模型」输入框手填模型名，或用「我的模型」收藏。
- **模型下拉里没有我想要的新模型**：设置里「服务器模型 → 刷新」→「＋加入」，面板下拉只显示你收藏的模型。
- **请求超时**：`deepseek-reasoner` 思考较久，调大 `timeout`；或换成 `deepseek-chat`。
- **连不上 Ollama**：确认 `http://127.0.0.1:11434/v1`、`ollama serve` 已启动、模型已 `ollama pull`；Key 必须非空（填 `ollama` 即可）。
- **导出后插件报错**：编辑器面板（EditorPlugin 相关代码）只在编辑器里加载，不会进入导出包；运行时只依赖 `client/llm_client.gd` 与 `autoload/ai_assistant.gd`，可放心导出。
- **生产环境千万别把 API Key 写进 `project.godot` 提交仓库**，用环境变量注入；插件检测到时会给出警告。

---

## 七、License

MIT —— 随便用、随便改，欢迎提 PR。