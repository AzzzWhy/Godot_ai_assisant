# Godot_ai_assisant

一个简单的Godot插件，可以实现将任意 _OpenAI兼容的_ 大模型接入Godot之中以此来辅助完成基本的脚本文件。

## 已实现功能：

- 编辑器内聊天面板：右侧Dock直接对话、流式输出、让AI分析脚本、一键把生成的GDScript插入当前脚本。
- 任何 OpenAI 兼容桌面：DeepSeek、OpenAI、Kimi(Moonshot)、通义千问、智谱 GLM、本地 Ollama、vLLM 等，仅需修改base_url。
- 模型自动识别：填入Key + 地址后自动拉取该账号真实可用的模型列表。

---

## 一，快速开始

1，测试阶段：使用Godot 4.x打开本项目文件夹（GodotAIAssistant/，里面自带project.godot）。插件已自动添加：编辑器右侧会出现「AI助手」面板，接入api以及地址，选取模型进行测试。

2，将本项目文件夹内addons/ai_assistant作为插件导入godot之中，接入api以及地址，选取模型进行测试。

---

## 二，支持的后端配置速查

| 服务商                      | Base URL                                            | 模型示例                              | 说明              |
| :-------------------------- | :-------------------------------------------------- | :------------------------------------ | :---------------- |
| DeepSeek                    | `https://api.deepseek.com`                          | `deepseek-chat` / `deepseek-reasoner` | 默认配置          |
| OpenAI                      | `https://api.openai.com/v1`                         | `gpt-4o-mini`                         |                   |
| Kimi/Moonshot               | `https://api.moonshot.cn/v1`                        | `moonshot-v1-8k`                      |                   |
| 智谱GLM                     | `https://open.bigmodel.cn/api/paas/v4`              | `glm-4-flash`                         |                   |
| 通义千问                    | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `qwen-plus`                           |                   |
| Ollama（本地免费）          | `http://127.0.0.1:11434/v1` 或者其他                | `qwen2.5:7b`                          | Key随便填个非空值 |
| vLLM / 任何 OpenAI 兼容服务 | 你的服务地址                                        | 你的模型名                            |                   |

---

### 三，编辑器面板功能

| 功能                                             | 位置                               |
| :----------------------------------------------- | :--------------------------------- |
| 对话（流式/非流式）                              | 输入框回车发送                     |
| `/help` / `/clear` / `/script`                   | 快捷命令                           |
| 自动识别本Key可用模型（保存设置后自动拉取）      | 设置→保存 / 点「刷新」             |
| 「我的模型」收藏（不把API全部模型堆进下拉框）    | 设置→服务器模型「+加入」/「—移除」 |
| 词                                               | 设置                               |
| 快速切换模型                                     | 面板顶部下拉                       |
| 发送当前脚本给AI分析                             | 面板按钮                           |
| 把回复中的代码块插入当前脚本 / 另存为脚本 / 复制 | 面板底部                           |
| 运行主场景（体验运行时对话）                     | 面板底部「运行场景」               |

---

### 四，目录结构

| 路径                                           | 说明                                       |
| ---------------------------------------------- | ------------------------------------------ |
| `project.godot`                                | Godot 项目配置文件                         |
| `examples/npc_demo.gd/.tscn`                   | 游戏内 NPC 对话示例场景（可直接运行）      |
| `addons/ai_assistant/plugin.cfg`               | 插件基本信息（名称、版本、作者等）         |
| `addons/ai_assistant/plugin.gd`                | 编辑器插件入口，负责注册 AI 聊天面板和单例 |
| `addons/ai_assistant/icon.svg`                 | 插件图标（在插件管理器中显示）             |
| `addons/ai_assistant/autoload/ai_assistant.gd` | 全局单例，提供运行时 AI 调用接口           |
| `addons/ai_assistant/client/llm_client.gd`     | OpenAI 兼容大模型客户端（支持流式 SSE）    |
| `addons/ai_assistant/editor/ai_chat_dock.gd`   | 编辑器底部/侧边栏的 AI 对话面板            |

---

### 五、常见问题

- **API Key ？** 默认不落盘，只在当前编辑器会话内存中使用。勾选设置里的「记住 API Key」后才会明文写入编辑器配置（macOS: `~/Library/Application Support/Godot/editor_settings-4.x.tres`）（windows：`C:\Users\<你的用户名>\AppData\Roaming\Godot\editor_settings-4.x.tres`），可随时点「清除已保存的 Key」删除。游戏运行时请用环境变量 `AI_API_KEY`。

- **HTTP 404: Base URL 填错。** Base URL 只需填到服务商根地址（可含 `/v1` 等前缀），不要把 `/chat/completions` 也拼进去。客户端会自动拼接并容错（即使误填了完整端点也能正确处理；报错信息里会带上实际请求的完整 URL）。

- **HTTP 401: API Key 无效或服务商没给该接口权限；检查 Key、Base URL、模型名。** 设置窗口的「刷新」会直接用输入框里的 Key 请求（无需先保存），失败时显示服务商返回的具体原因。

- **模型列表加载失败 / 没有模型：** 部分服务商不支持 GET /models 接口——没关系，直接在「模型」输入框手动填模型名，或用「我的模型」收藏。

- **模型下拉里没有我想要的新模型：** 设置里「服务器模型 → 刷新」→「+加入」，面板下拉只显示你收藏的模型。

- **请求超时：** `deepseek-reasoner` 思考较久，调大 `timeout`；或换成 `deepseek-chat`。

- **连不上 Ollama：** 确认 `http://127.0.0.1:11434/v1`、`ollama serve` 已启动、模型已 `ollama pull`；Key 必须非空（填 `ollama` 即可）。

- **导出后插件报错：** 编辑器面板（`EditorPlugin` 相关代码）只在编辑器里加载，不会进入导出包；运行时只依赖 `client/llm_client.gd` 与 `autoload/ai_assistant.gd`，可放心导出。

- **生产环境 不要！ 不要！ 别把 API Key 写进 `project.godot` 提交仓库，用环境变量注入；**

---

### 七，licence

---

MIT开源协议，有任何问题欢迎提交PR
