# 文件职责与命名

本项目使用英文 `snake_case` 文件名，名称直接说明文件承担的职责。下表列出仓库中的每个实际文件；表中每个 `.gd` 脚本都还有一个**同路径、同名加 `.uid` 后缀**的文件，例如 `ai_workbench_ui.gd.uid`。这些 `.uid` 文件逐一对应表中的脚本，保存 Godot 的资源标识，重命名时已同步移动，内容保持不变。

`旧名` 列用于从 v2.1.1 的目录定位新文件。未列旧名表示名称已能说明用途，或属于 Godot/项目约定的固定名称。

脚本中的 `class_name` 和运行时单例名 `AI` 保持不变。外部项目如果直接 `preload` 或 `load` 了旧路径，需要按下表更新路径。

## 项目根目录

| 当前文件 | 旧名 | 作用 |
| --- | --- | --- |
| `.gitignore` | — | 排除 Godot 缓存、系统文件、密钥环境文件和本地打包产物。 |
| `README.md` | — | 项目介绍、使用方法、设置、安全边界与测试命令。 |
| `FILE_PURPOSES.md` | — | 本文件；说明文件职责、改名对应关系和保留原名的原因。 |
| `CHANGELOG.md` | — | 记录各版本已经发布的功能和修复。 |
| `LICENSE` | — | MIT 开源许可文本；标准文件名便于工具识别。 |
| `project.godot` | — | Godot 项目配置，包括主场景、自动加载单例、插件启用和项目图标；文件名由 Godot 固定。 |
| `project_icon.svg` | `icon.svg` | Godot 项目图标，由 `project.godot` 的 `config/icon` 引用。 |
| `project_icon.svg.import` | `icon.svg.import` | 项目图标的 Godot 导入设置和稳定资源 UID；随图标同步改名。 |

## 插件入口与运行时

| 当前文件 | 旧名 | 作用 |
| --- | --- | --- |
| `addons/ai_assistant/plugin.cfg` | — | Godot 编辑器插件清单，声明名称、版本和入口脚本；文件名由 Godot 固定。 |
| `addons/ai_assistant/editor_plugin_entry.gd` | `plugin.gd` | `EditorPlugin` 入口：注册工具栏与菜单、创建工作台和版本控制面板、维护设置及 AI 自动加载单例。 |
| `addons/ai_assistant/workbench_toolbar_icon.svg` | `icon.svg` | 工作台工具栏按钮使用的插件图标。 |
| `addons/ai_assistant/workbench_toolbar_icon.svg.import` | `icon.svg.import` | 工具栏图标的 Godot 导入设置和稳定资源 UID；随图标同步改名。 |
| `addons/ai_assistant/autoload/global_ai_chat.gd` | `ai_assistant.gd` | 游戏运行时的全局 `AI` 单例；读取环境变量和项目设置，并提供聊天客户端能力。 |
| `addons/ai_assistant/client/openai_compatible_chat_client.gd` | `llm_client.gd` | OpenAI 兼容 HTTP 客户端：发起聊天、获取模型列表、解析 SSE/JSON、处理队列、超时和对话历史。 |

## Builder 草稿与文件修改

| 当前文件 | 旧名 | 作用 |
| --- | --- | --- |
| `addons/ai_assistant/agent/builder_response_contract.gd` | `builder_contract.gd` | 生成 Builder 请求提示词，解析并规范化返回的多文件和节点操作 JSON，检查脚本路径。 |
| `addons/ai_assistant/agent/exact_text_patch.gd` | `inline_patch.gd` | 对脚本做唯一匹配的精确文本替换，解析代码块，并生成修改片段信息。 |
| `addons/ai_assistant/agent/transactional_proposal_store.gd` | `proposal_store.gd` | 保存待审查草稿，校验项目路径，原子写入文件，记录快照、恢复信息并执行回滚。 |

## 编辑器工作台

| 当前文件 | 旧名 | 作用 |
| --- | --- | --- |
| `addons/ai_assistant/editor/ai_workbench_ui.gd` | `workbench_main.gd` | 构建悬浮工作台、Chat/Builder 输入区、审查操作栏和模型设置窗口。 |
| `addons/ai_assistant/editor/chat_message_card.gd` | — | 单条对话卡片：思考折叠区、Markdown 正文、生成状态和动画生命周期。 |
| `addons/ai_assistant/editor/chat_markdown.gd` | — | 将聊天 Markdown 安全转换为 Godot BBCode，兼容流式未完成格式。 |
| `addons/ai_assistant/editor/workbench_task_controller.gd` | `workbench_controller.gd` | 协调 Chat、Builder、上下文快照、草稿审查、文件/节点应用和失败回滚。 |
| `addons/ai_assistant/editor/builder_task_timeline.gd` | `task_timeline.gd` | 显示已锁定的编辑器上下文及 Builder 各执行阶段。 |
| `addons/ai_assistant/editor/proposal_review_view.gd` | `result_preview.gd` | 显示待审查文件、修改前后源码、统一 Diff 和节点操作。 |
| `addons/ai_assistant/editor/colored_diff_view.gd` | `diff_view.gd` | 对统一 Diff 的增删行、文件头和普通行着色。 |
| `addons/ai_assistant/editor/selected_scene_summary.gd` | `scene_context.gd` | 将当前选中场景节点的信息整理成可供 AI 使用的文本。 |
| `addons/ai_assistant/editor/editor_session_config.gd` | `session_config.gd` | 在编辑器会话内共享模型连接参数和 API Key，并将其应用到客户端。 |
| `addons/ai_assistant/editor/workbench_dark_theme.gd` | `ui_theme.gd` | 定义工作台深色配色、面板、按钮、输入框等控件样式。 |
| `addons/ai_assistant/editor/version_control_panel.gd` | `vcs_panel.gd` | 版本控制界面：查看状态和 Diff，执行明确的 Git 操作，辅助生成提交信息。 |
| `addons/ai_assistant/editor/restricted_git_runner.gd` | `git_bridge.gd` | 在受限命令列表内异步执行项目 Git 命令并返回结果。 |

## 示例与测试

| 当前文件 | 旧名 | 作用 |
| --- | --- | --- |
| `examples/npc_chat_demo.tscn` | `npc_demo.tscn` | 可运行的 NPC 聊天示例场景，也是项目默认启动场景。 |
| `examples/npc_chat_demo.gd` | `npc_demo.gd` | 示例场景的交互界面和 `AI` 单例调用逻辑。 |
| `tests/plugin_smoke_test.gd` | `smoke_test.gd` | 离线冒烟测试：客户端、草稿、事务回滚、场景恢复及工作台构建。 |
| `tests/chat_markdown_test.gd` | — | 验证 Markdown 格式、安全转义、不完整代码块和窄栏换行。 |
| `tests/reasoning_controller_test.gd` | — | 验证流式/非流式思考传递、去重和取消后的迟到事件。 |
| `tests/chat_ui_test.gd` | — | 验证消息卡片布局、折叠、动效和停止状态；支持本地模拟预览。 |
| `tests/chat_http_integration_test.gd` | `integration_test.gd` | 经本地 HTTP 模拟服务验证流式/非流式响应、模型列表和错误处理。 |
| `tests/chat_api_mock_server.py` | `mock_server.py` | 为 HTTP 集成测试提供 OpenAI 兼容接口的本地模拟服务。 |

## 自动生成文件

Godot 为每个 `.gd` 文件生成对应的 `.gd.uid`。它们作为资源引用的稳定标识随脚本一起管理；不单独编辑。两个 SVG 的 `.import` 文件也随图标一起纳入版本控制，并保留原资源 UID。`.godot/` 中的缓存由 `.gitignore` 排除，重新打开项目时可自动生成。

## 运行检查

```bash
godot --headless --path . -s res://tests/plugin_smoke_test.gd
python3 tests/chat_api_mock_server.py
godot --headless --path . -s res://tests/chat_http_integration_test.gd
```

后两条分别在不同终端运行，集成测试连接 `127.0.0.1:8765`。
