extends Control
## 演示：游戏运行时通过全局 AI 单例（AI）与 NPC 对话。
##
## 运行前请配置 API：
##   - 方式一（推荐）：环境变量 export AI_API_KEY=sk-...
##   - 方式二：项目设置 -> ai_assistant/api_key 填入 Key
## 模型 / 地址 / 温度等可在 项目设置 -> ai_assistant/* 或环境变量中调整。

const NPC_SYSTEM_PROMPT := "你是《深蓝小镇》码头边的一位老渔夫「阿伯」。你的性格：憨厚、健谈、爱讲年轻时的航海故事，偶尔抱怨天气。" \
	+ "玩家是来码头散步的年轻人。请用中文、口语化地回应，每次回答控制在 3 句以内。"

const COLOR_USER := "#7aa2f7"
const COLOR_AI := "#9ece6a"
const COLOR_SYS := "#8f9bb3"
const COLOR_ERR := "#f7768e"

var _log: RichTextLabel
var _input: LineEdit
var _status: Label
var _busy := false
var _streamed_any := false


func _ready() -> void:
	_build_ui()
	AI.set_system_prompt(NPC_SYSTEM_PROMPT)
	AI.stream_chunk.connect(_on_stream_chunk)
	AI.reasoning_chunk.connect(_on_reasoning_chunk)
	AI.response_received.connect(_on_response)
	AI.request_finished.connect(_on_finished)

	_line("[color=%s][b]〔阿伯〕[/b] 嘿嘿，年轻人，今天风不错。有啥想问的？[/color]" % COLOR_SYS)
	if AI.api_key.is_empty():
		_line("[color=%s][b]〔提示〕[/b] 尚未配置 API Key：请设置环境变量 AI_API_KEY，或在 项目设置 -> ai_assistant/api_key 中填写。[/color]" % COLOR_ERR)
	else:
		_line("[color=%s]已连接 %s · 模型 %s[/color]" % [COLOR_SYS, AI.base_url, AI.model])


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_bottom", 24)
	add_child(margin)

	var panel := VBoxContainer.new()
	panel.add_theme_constant_override("separation", 12)
	margin.add_child(panel)

	var title := Label.new()
	title.text = "🎣 码头 · 老渔夫阿伯（AI NPC 演示）"
	title.add_theme_font_size_override("font_size", 26)
	panel.add_child(title)

	var hint := Label.new()
	hint.text = "这是游戏运行时调用 AI 单例的例子，源码见 examples/npc_demo.gd"
	hint.modulate = Color(0.7, 0.7, 0.7)
	panel.add_child(hint)

	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.custom_minimum_size = Vector2(0, 260)
	panel.add_child(_log)

	var row := HBoxContainer.new()
	_input = LineEdit.new()
	_input.placeholder_text = "对老渔夫说点什么…（回车发送）"
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.text_submitted.connect(func(t: String) -> void: _send(t))
	row.add_child(_input)
	var send_btn := Button.new()
	send_btn.text = "发送"
	send_btn.pressed.connect(func() -> void: _send(_input.text))
	row.add_child(send_btn)
	panel.add_child(row)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 11)
	_status.modulate = Color(0.6, 0.6, 0.6)
	_status.text = "就绪"
	panel.add_child(_status)


func _send(text: String) -> void:
	var t := text.strip_edges()
	if t.is_empty() or _busy:
		return
	_input.clear()
	_line("[color=%s][b]你[/b]  %s[/color]" % [COLOR_USER, _esc(t)])
	_streamed_any = false
	_busy = true
	_status.text = "阿伯思考中…"
	AI.chat(t)


func _on_stream_chunk(text: String) -> void:
	_streamed_any = true
	_log.append_text(_esc(text))


func _on_reasoning_chunk(text: String) -> void:
	_log.append_text("[color=#a8814f][i]（阿伯寻思：%s）[/i][/color]" % _esc(text))


func _on_response(res: Dictionary) -> void:
	# 非流式模式兜底：整段渲染
	if _streamed_any:
		return
	var content: String = res.get("content", "")
	_log.append_text("\n[color=%s][b]〔阿伯〕[/b][/color]\n" % COLOR_AI)
	_log.append_text(_fmt(content) + "\n")


func _on_finished(success: bool, error_message: String) -> void:
	_busy = false
	_status.text = "就绪" if success else "出错了"
	if not success:
		_log.append_text("\n[color=%s][b]〔报错〕[/b] %s[/color]\n" % [COLOR_ERR, _esc(error_message)])
	elif _streamed_any:
		_log.append_text("\n")


# ------------------------- 工具 -------------------------

func _line(bbcode: String) -> void:
	_log.append_text(bbcode + "\n")


func _esc(s: String) -> String:
	return s.replace("[", "[lb]").replace("]", "[rb]")


## 简易 markdown：代码块染成等宽字体，其余转义
func _fmt(raw: String) -> String:
	var out := ""
	var in_code := false
	var buf := ""
	for line in raw.replace("[", "[lb]").replace("]", "[rb]").split("\n"):
		if line.strip_edges().begins_with("```"):
			if in_code:
				out += "[color=#d4d4e8][code]" + buf + "[/code][/color]\n"
				buf = ""
			in_code = not in_code
			continue
		if in_code:
			buf += line + "\n"
		else:
			out += line + "\n"
	if in_code:
		out += "[color=#d4d4e8][code]" + buf + "[/code][/color]\n"
	return out.strip_edges()