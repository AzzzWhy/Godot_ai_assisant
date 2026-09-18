# Godot AI Assistant

面向 Godot 4.6 的 OpenAI 兼容 AI 编程插件。它把 Chat、脚本生成、代码审查和节点脚本绑定集中到可拖动的「AI 工作台」悬浮窗口中。

## AI 工作台

工作台是独立悬浮窗口（默认约 1280×720），可通过编辑器顶部工具栏按钮或「项目 → 工具 → 打开 AI 工作台」打开。布局接近 Godot 编辑器：左侧任务 Dock、中间结果视口、右侧对话 Inspector。

- 左侧：锁定的场景/节点上下文、任务状态机和 AI 执行计划。
- 中间：受影响文件、完整 Before/After、统一 Diff 和节点操作卡。
- 右侧：Chat/Builder 模式、当前编辑器上下文、对话记录和任务输入框。
- 底部：本轮唯一的「撤销全部 / 应用全部」审查栏。

### Builder

选中一个场景节点，然后用一句话描述完整任务，例如：

> 给 Player 写一个 CharacterBody2D 移动脚本并绑定，支持 WASD 和可调速度。

Builder 会按以下流程执行：

1. 锁定任务发送时的场景、节点路径和脚本版本。
2. 生成计划、多文件 `changes[]` 和节点 `node_operations[]`。
3. 在内存中构建草稿，不立即修改项目。
4. 在独立结果区展示完整源码与 Diff。
5. 点击一次「应用全部」后创建/更新脚本、绑定选中节点并保存场景。
6. 任一步失败时恢复已写文件、编辑器内未保存脚本、节点脚本/导出属性和场景快照，避免半完成状态。
7. 若编辑器在事务中断，恢复记录会跨插件重载保留；重新打开工作台后需先执行「Retry Rollback」才能开始新任务。

更新已有脚本时，模型可以返回精确 `old_string/new_string` 编辑；只有唯一匹配才会生成草稿。Builder 当前只允许：

- `res://` 下的 `.gd`；
- `create` / `update`；
- 给任务开始时选中的一个节点执行 `attach_script`。

它不会执行终端命令，也不会直接生成或改写 `.tscn` 文本。

### Chat

Chat 用于只读问答，不写文件、不绑定节点。支持 OpenAI 兼容流式输出，Builder 有待审查草稿时会阻止切换执行，避免状态混淆。

右侧对话使用独立消息卡片，支持 Markdown 标题、列表、引用、粗体、斜体、行内代码和代码块。模型返回的 `reasoning_content` 会显示在可折叠的「思考过程」区域；生成时展开，结束后自动收起，手动展开/收起会保留你的选择。未返回思考内容的模型只显示等待状态和正文，不生成虚假的思考文字。

「动效」开关控制呼吸指示、流式文字渐进显示、卡片淡入和折叠动画。长思考内容独立滚动，不撑宽窗口；向上翻阅历史后不会强制跳回底部，可点击「回到最新回复」恢复跟随。停止或失败会保留已收到的内容并结束生成动画。

### 版本控制

底部「版本控制」面板保持独立，提供状态、Diff、暂存、取消暂存、丢弃改动、提交和历史。AI 只根据已暂存 Diff 生成提交信息，不会自动提交。

## 快速开始

1. 使用 Godot 4.6 打开项目根目录 `GodotAIAssistant/`。
2. 在「项目 → 项目设置 → 插件」启用 `AI Assistant (OpenAI Compatible)`。
3. 点击顶部工具栏「AI 工作台」打开悬浮窗，再点「设置」。
4. 填写 Base URL、API Key 和模型。
5. 选中场景节点，在 Builder 中发送任务并审查结果。

将插件用于其他项目时，复制 `addons/ai_assistant/` 到目标项目的 `addons/` 下，再从插件设置启用。

## OpenAI 兼容后端

- DeepSeek：`https://api.deepseek.com`
- OpenAI：`https://api.openai.com/v1`
- Moonshot/Kimi：`https://api.moonshot.cn/v1`
- 智谱 GLM：`https://open.bigmodel.cn/api/paas/v4`
- 通义千问：`https://dashscope.aliyuncs.com/compatible-mode/v1`
- Ollama：`http://127.0.0.1:11434/v1`
- vLLM 或其他兼容服务：填写对应兼容端点

设置窗口可以请求服务端 `/models` 列表；不支持该接口的服务可直接手填模型名。

## 安全边界

- API Key 默认只保存在当前编辑器会话内存。
- 只有勾选「记住 API Key」才会明文写入 Godot 编辑器配置。
- 不要把真实 Key 写入 `project.godot` 或提交到仓库。
- Builder 草稿在点击「应用全部」前不会写入磁盘。
- 应用前会再次检查文件、场景和节点是否仍与任务快照一致。
- 路径校验会拒绝目录穿越、反斜杠、非 `.gd` 文件和逃逸项目目录的符号链接。
- 文件采用临时文件、校验备份和重命名进行原子写入；多文件全部写入后才统一校验 GDScript 依赖。
- 每个文件第一次写入前都会在 `user://godot_ai_assistant/snapshots` 保存回滚快照。
- 未完成事务会记录到 `user://godot_ai_assistant/pending_recovery.json`；恢复完成后自动清除。

游戏运行时仍可使用自动加载单例 `AI`；生产环境推荐通过 `AI_API_KEY`、`AI_BASE_URL` 和 `AI_MODEL` 环境变量注入配置。

## 主要代码

完整文件职责和 v2.1.1 旧文件名对应关系见 [文件职责与命名](FILE_PURPOSES.md)。

- `addons/ai_assistant/editor_plugin_entry.gd`：悬浮窗、工具栏入口、设置默认值、VCS 面板和 Autoload 生命周期。
- `addons/ai_assistant/editor/ai_workbench_ui.gd`：三栏 AI 工作台内容。
- `addons/ai_assistant/editor/workbench_task_controller.gd`：唯一状态机、上下文快照、模型请求和 Apply/Rollback 事务。
- `addons/ai_assistant/editor/proposal_review_view.gd`：文件列表、完整源码、Diff 和节点操作卡。
- `addons/ai_assistant/editor/builder_task_timeline.gd`：任务计划和执行阶段。
- `addons/ai_assistant/agent/builder_response_contract.gd`：多文件/节点操作 JSON 契约和校验。
- `addons/ai_assistant/agent/transactional_proposal_store.gd`：内存草稿、路径沙箱、文件快照和原子应用。
- `addons/ai_assistant/agent/exact_text_patch.gd`：唯一片段精确替换。
- `addons/ai_assistant/client/openai_compatible_chat_client.gd`：OpenAI 兼容请求、SSE 和模型列表。
- `addons/ai_assistant/editor/version_control_panel.gd`：独立版本控制面板。

旧的聊天 Dock、任务 Dock、逐提案应用和脚本顶部 Keep/Undo 已退役，避免同时存在多套修改入口。

## 测试

离线冒烟测试：

```bash
godot --headless --path . -s res://tests/plugin_smoke_test.gd
```

聊天 Markdown、思考传递及布局/动画生命周期专项测试（不请求真实模型）：

```bash
godot --headless --path . -s res://tests/chat_markdown_test.gd
godot --headless --path . -s res://tests/reasoning_controller_test.gd
godot --headless --path . -s res://tests/chat_ui_test.gd
```

运行 `godot --path . -s res://tests/chat_ui_test.gd -- --preview` 可查看明确标注为本地模拟数据的交互预览。

本地 HTTP mock 集成测试：

```bash
python3 tests/chat_api_mock_server.py
godot --headless --path . -s res://tests/chat_http_integration_test.gd
```

冒烟测试覆盖 Builder 多文件解析、路径/符号链接沙箱、精确编辑、原子应用/回滚、场景与节点恢复、多文件依赖校验、跨重载事务恢复、审查前不落盘和工作台构建；集成测试覆盖 SSE、非流式 JSON、401 和模型列表。

## License

MIT
