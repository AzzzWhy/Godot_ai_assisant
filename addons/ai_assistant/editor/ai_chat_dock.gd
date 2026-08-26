@tool
extends VBoxContainer
## 编辑器内的「AI 助手」停靠面板。
## 功能：
## - 与任意 OpenAI 兼容模型对话（流式输出）
## - 设置窗口：base_url / API Key / 模型 / 温度 / 超时 / 系统提示词
## - 一键把回复中的代码块插入当前脚本 / 另存为脚本 / 复制
## - 发送当前脚本给 AI 让其分析

const LLM_CLIENT_SCRIPT := preload("res://addons/ai_assistant/client/llm_client.gd")
const SESSION_CONFIG := preload("res://addons/ai_assistant/editor/session_config.gd")

# 注：不再有 DEFAULT_BASE_URL / DEFAULT_MODEL 常量——面板首次打开 Base URL 与模型留空，
# 用占位符提示，避免「首开凭空出现一个没填过的地址/模型」的困惑；保存过什么就显示什么。
const DEFAULT_SYSTEM_PROMPT := "你是一个嵌入在 Godot 游戏引擎中的 AI 编程助手。你精通 GDScript、Godot 4.x 引擎 API、游戏设计与 AI 集成。回答尽量简洁，给出可直接运行的代码，默认使用中文。"
const QUICK_MODELS := ["deepseek-chat", "deepseek-reasoner", "qwen-turbo", "qwen-plus", "qwen-max", "qwen-long", "gpt-4o-mini", "gpt-4o", "glm-4-flash", "qwen2.5:7b"]
const CUSTOM_MODEL_ITEM := "✦ 自定义…"

const COLOR_USER := Color("#7aa2f7")
const COLOR_AI := Color("#9ece6a")
const COLOR_REASONING := Color("#c0a26e")
const COLOR_SYSTEM := Color("#8f9bb3")
const COLOR_ERROR := Color("#f7768e")
const COLOR_STATUS := Color("#5f6b7f")
const COLOR_BUSY := Color("#e0af68")
const COLOR_OK := Color("#61af8f")

var _client: AILLMClient = null
var _log: RichTextLabel
var _input: LineEdit
var _send_btn: Button
var _model_select: OptionButton
var _stream_check: CheckButton
var _status: Label
var _settings_window: Window
var _systxt_window: AcceptDialog
var _sys_edit: TextEdit
var _remember_key_check: CheckBox
var _model_edit: LineEdit
var _settings_server_select: OptionButton
var _settings_my_select: OptionButton
var _server_models: Array = []
var _my_models: Array = []
var _my_section_start := -1
var _models_fetch_key := ""  # 本次模型列表请求实际使用的 Key（含输入框未保存的情况）

var _busy := false
var _waiter := 0
var _streamed_any := false
var _stream_buffer := ""
var _last_answer := ""
var _last_code_blocks: Array = []
var _custom_model_item_index := -1
var _reasoning_visible := false
var _reasoning_buffer := ""
var _reasoning_rendered := false
var _reasoning_check: CheckButton
var _stop_btn: Button


func _ready() -> void:
	_client = LLM_CLIENT_SCRIPT.new()
	add_child(_client)
	_client.base_url = _load_setting("base_url", "")
	# 隐私优先：API Key 默认不持久化。未勾选「记住」时，顺带清除历史遗留的已存 Key。
	var remember_key := bool(_load_setting("remember_api_key", false))
	if not remember_key:
		_erase_setting("api_key")
	_client.api_key = String(_load_setting("api_key", "")) if remember_key else ""
	_client.model = _load_setting("model", "")
	_my_models = _load_setting("my_models", [])
	_client.temperature = float(_load_setting("temperature", 1.0))
	_client.max_tokens = int(_load_setting("max_tokens", 0))
	_client.stream = bool(_load_setting("stream", true))
	_client.timeout_seconds = float(_load_setting("timeout", 60.0))
	_client.system_prompt = _load_setting("system_prompt", DEFAULT_SYSTEM_PROMPT)
	_client.stream_chunk.connect(_on_stream_chunk)
	_client.reasoning_chunk.connect(_on_reasoning_chunk)
	_client.request_finished.connect(_on_finished)
	_client.models_loaded.connect(_on_models_loaded)
	SESSION_CONFIG.capture(_client)

	_build_ui()
	_apply_config_to_ui()
	_restore_cached_models()
	_set_busy(false)  # 初始为就绪状态：发送按钮应保持可用
	_log.append_text("\n[color=%s]🤖 你好！我是接入 Godot 的 AI 助手。\n支持 DeepSeek / OpenAI / Ollama 等任意 OpenAI 兼容接口。\n输入消息即可开始；点击「设置」配置 API Key 与模型。\n[color=%s]小提示：[/color] /help 查看命令 · 「发送当前脚本」可让 AI 分析你正在编辑的代码。[/color]\n" % [_color_str(COLOR_SYSTEM), _color_str(COLOR_SYSTEM)])
	_set_status("就绪 · " + _client.model, COLOR_STATUS)
	# 已填 Key 且无缓存模型时，自动从服务器拉取可用模型
	if not _client.api_key.is_empty() and _server_models.is_empty():
		_fetch_models()


func _process(_delta: float) -> void:
	if _busy:
		# 自愈保护：客户端已完成但面板漏了信号时，恢复 UI 状态
		if not _client.is_busy():
			_set_busy(false)
			return
		_waiter += 1
		var spins := ["◐", "◓", "◑", "◒"]
		_set_status("思考中 %s · %s" % [spins[_waiter % 4], _client.model], COLOR_BUSY)


# ------------------------- 设置存取 -------------------------

func _load_setting(key: String, default: Variant) -> Variant:
	if not Engine.is_editor_hint():
		return default
	var es := EditorInterface.get_editor_settings()
	if es.has_setting("ai_assistant/" + key):
		return es.get_setting("ai_assistant/" + key)
	return default


func _save_setting(key: String, value: Variant) -> void:
	if not Engine.is_editor_hint():
		return
	EditorInterface.get_editor_settings().set_setting("ai_assistant/" + key, value)


## 从编辑器配置中彻底删除某个设置项（API Key 清除用）
func _erase_setting(key: String) -> void:
	if not Engine.is_editor_hint():
		return
	var es := EditorInterface.get_editor_settings()
	var path := "ai_assistant/" + key
	if es.has_method("erase"):
		if es.has_setting(path):
			es.erase(path)
	else:
		es.set_setting(path, "")  # 老版本兜底：置空等效清除


func _apply_config_to_ui() -> void:
	_stream_check.set_pressed_no_signal(_client.stream)
	_rebuild_model_list()
	if _model_edit != null:
		_model_edit.text = _client.model


## 重建模型下拉：快捷模型 + 「我的模型」（手动收藏）+ 自定义项
## 说明：API 返回的“全部模型”不直接堆进面板下拉，用户用「＋加入」收藏到「我的模型」后再显示
func _rebuild_model_list() -> void:
	if _model_select == null:
		return
	_model_select.clear()
	var my_only: Array = []
	for mm in _my_models:
		if not QUICK_MODELS.has(mm) and not my_only.has(mm):
			my_only.append(mm)
	for m in QUICK_MODELS:
		_model_select.add_item(m)
	_my_section_start = -1
	if not my_only.is_empty():
		_model_select.add_separator()
		_my_section_start = _model_select.item_count
		for mm in my_only:
			_model_select.add_item(mm)
	_model_select.add_separator()
	var custom_idx := _model_select.item_count
	_model_select.add_item(CUSTOM_MODEL_ITEM)
	_model_select.tooltip_text = "选择模型；在「设置 → 我的模型」里收藏常用模型（API 返回的全部模型不直接堆在这里）"

	var cur := _client.model
	var found_idx := -1
	if QUICK_MODELS.has(cur):
		found_idx = QUICK_MODELS.find(cur)
	elif _my_models.has(cur):
		var idx := my_only.find(cur)
		if idx != -1:
			found_idx = _my_section_start + idx
	if found_idx != -1:
		_model_select.select(found_idx)
	elif not cur.is_empty():
		# 当前模型不在任何列表中：追加为一项并选中
		var real_idx := _model_select.item_count
		_model_select.add_item(cur, -1)
		_model_select.select(real_idx)
	else:
		_model_select.select(0)
	_custom_model_item_index = custom_idx


# ------------------------- UI 构建 -------------------------

func _build_ui() -> void:
	var header := HBoxContainer.new()
	var title := Label.new()
	title.text = "AI 助手"
	title.add_theme_font_size_override("font_size", 15)
	header.add_child(title)
	var hspacer := Control.new()
	hspacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(hspacer)
	var settings_btn := Button.new()
	settings_btn.text = "⚙ 设置"
	settings_btn.pressed.connect(_open_settings)
	header.add_child(settings_btn)
	add_child(header)

	var toolbar := HBoxContainer.new()
	_model_select = OptionButton.new()
	for m in QUICK_MODELS:
		_model_select.add_item(m)
	_model_select.tooltip_text = "选择模型（点右侧「刷新模型」可拉取服务器上本 Key 可用的模型）"
	_model_select.item_selected.connect(_on_model_selected)
	toolbar.add_child(_model_select)
	var refresh_btn := Button.new()
	refresh_btn.text = "刷新模型"
	refresh_btn.tooltip_text = "从服务器拉取当前 API Key 可用的模型列表（GET {base}/models）"
	refresh_btn.pressed.connect(_fetch_models)
	toolbar.add_child(refresh_btn)
	_stream_check = CheckButton.new()
	_stream_check.text = "流式"
	_stream_check.tooltip_text = "打字机式流式输出"
	_stream_check.toggled.connect(_on_stream_toggled)
	toolbar.add_child(_stream_check)
	_reasoning_check = CheckButton.new()
	_reasoning_check.text = "🧠 思考"
	_reasoning_check.tooltip_text = "默认收起模型思考内容；需要时可展开查看。"
	_reasoning_check.toggled.connect(_on_reasoning_toggled)
	toolbar.add_child(_reasoning_check)
	var clear_btn := Button.new()
	clear_btn.text = "清空"
	clear_btn.pressed.connect(_clear_chat)
	toolbar.add_child(clear_btn)
	var sys_btn := Button.new()
	sys_btn.text = "系统提示词"
	sys_btn.pressed.connect(_open_system_prompt)
	toolbar.add_child(sys_btn)
	var script_btn := Button.new()
	script_btn.text = "发送当前脚本"
	script_btn.tooltip_text = "把脚本编辑器中当前打开的脚本发给 AI 分析"
	script_btn.pressed.connect(_send_current_script)
	toolbar.add_child(script_btn)
	add_child(toolbar)

	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.custom_minimum_size = Vector2(0, 240)
	_log.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_log)

	var input_row := HBoxContainer.new()
	_input = LineEdit.new()
	_input.placeholder_text = "输入消息，回车发送（/help 查看命令）"
	_input.custom_minimum_size = Vector2(0, 34)
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.text_submitted.connect(_on_text_submitted)
	input_row.add_child(_input)
	_send_btn = Button.new()
	_send_btn.text = "发送"
	_send_btn.pressed.connect(func() -> void: _on_text_submitted(_input.text))
	input_row.add_child(_send_btn)
	_stop_btn = Button.new()
	_stop_btn.text = "停止"
	_stop_btn.tooltip_text = "停止当前模型请求，已收到的文本会保留。"
	_stop_btn.pressed.connect(_cancel_request)
	input_row.add_child(_stop_btn)
	add_child(input_row)

	var actions := HBoxContainer.new()
	var copy_btn := Button.new()
	copy_btn.text = "复制回复"
	copy_btn.pressed.connect(_copy_last_answer)
	actions.add_child(copy_btn)
	var insert_btn := Button.new()
	insert_btn.text = "插入到当前脚本"
	insert_btn.tooltip_text = "把回复中第一个代码块追加到脚本编辑器当前脚本末尾"
	insert_btn.pressed.connect(_insert_to_current_script)
	actions.add_child(insert_btn)
	var save_btn := Button.new()
	save_btn.text = "另存为脚本"
	save_btn.pressed.connect(_save_as_script)
	actions.add_child(save_btn)
	var run_btn := Button.new()
	run_btn.text = "运行场景"
	run_btn.tooltip_text = "运行当前项目主场景（演示运行时 AI 对话）"
	run_btn.pressed.connect(_run_scene)
	actions.add_child(run_btn)
	add_child(actions)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 11)
	add_child(_status)

	_build_settings_window()
	_build_sys_prompt_window()


## 让子窗口可被用户拖拽缩放（兼容 Godot 4.0~4.4 的 resizable 与 4.5+ 的 unresizable）
func _set_window_resizable(w: Window) -> void:
	var names: PackedStringArray = []
	for p in w.get_property_list():
		names.append(String(p.get("name", "")))
	if names.has("unresizable"):
		w.set("unresizable", false)
	elif names.has("resizable"):
		w.set("resizable", true)


func _build_settings_window() -> void:
	_settings_window = Window.new()
	_settings_window.title = "AI 助手 · 设置"
	_set_window_resizable(_settings_window)
	_settings_window.wrap_controls = true
	_settings_window.close_requested.connect(_settings_window.hide)
	add_child(_settings_window)

	# MarginContainer 避免内容贴边；显式尺寸 + wrap_controls 保证弹窗大小稳定、可调、不被裁切
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_settings_window.add_child(margin)

	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 8)
	root.add_child(grid)

	var url_label := Label.new(); url_label.text = "Base URL"
	var url_edit := LineEdit.new(); url_edit.placeholder_text = "https://api.deepseek.com"
	url_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(url_label); grid.add_child(url_edit)

	var key_label := Label.new(); key_label.text = "API Key"
	var key_edit := LineEdit.new(); key_edit.secret = true
	key_edit.placeholder_text = "sk-..."
	key_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(key_label); grid.add_child(key_edit)

	var model_label := Label.new(); model_label.text = "模型"
	_model_edit = LineEdit.new(); _model_edit.placeholder_text = "deepseek-chat"
	_model_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(model_label); grid.add_child(_model_edit)

	var temp_label := Label.new(); temp_label.text = "温度 (0~2)"
	var temp_spin := SpinBox.new(); temp_spin.min_value = -1.0; temp_spin.max_value = 2.0; temp_spin.step = 0.1; temp_spin.suffix = ""
	temp_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(temp_label); grid.add_child(temp_spin)

	var tok_label := Label.new(); tok_label.text = "max_tokens (0=默认)"
	var tok_spin := SpinBox.new(); tok_spin.min_value = 0; tok_spin.max_value = 32768; tok_spin.step = 1
	tok_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(tok_label); grid.add_child(tok_spin)

	var timeout_label := Label.new(); timeout_label.text = "超时（秒）"
	var timeout_spin := SpinBox.new(); timeout_spin.min_value = 5; timeout_spin.max_value = 600; timeout_spin.step = 1
	timeout_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(timeout_label); grid.add_child(timeout_spin)

	var sys_label := Label.new(); sys_label.text = "系统提示词"
	sys_label.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	grid.add_child(sys_label)
	var sys_edit := TextEdit.new()
	sys_edit.custom_minimum_size = Vector2(380, 140)
	sys_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sys_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid.add_child(sys_edit)

	url_edit.text = _client.base_url
	key_edit.text = _client.api_key
	_model_edit.text = _client.model
	temp_spin.value = _client.temperature
	tok_spin.value = _client.max_tokens
	timeout_spin.value = _client.timeout_seconds
	sys_edit.text = _client.system_prompt

	# 服务器模型列表：点「刷新」从 {base}/models 拉取本 Key 可用的模型，选中后填入「模型」输入框
	var server_row := HBoxContainer.new()
	var server_label := Label.new(); server_label.text = "服务器模型"
	server_label.tooltip_text = "从服务器拉取的模型；不同 API Key / 服务商可用模型不同"
	server_row.add_child(server_label)
	_settings_server_select = OptionButton.new()
	_settings_server_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_settings_server_select.tooltip_text = "选择后自动填入上方「模型」输入框（仍需点「保存」生效）"
	_settings_server_select.item_selected.connect(func(idx: int) -> void:
		if idx >= 0 and _model_edit != null:
			_model_edit.text = _settings_server_select.get_item_text(idx)
	)
	server_row.add_child(_settings_server_select)
	var models_refresh := Button.new()
	models_refresh.text = "刷新"
	models_refresh.tooltip_text = "用上方「API Key」输入框的值拉取模型列表（无需先点保存）"
	models_refresh.pressed.connect(func() -> void: _fetch_models(key_edit.text.strip_edges()))
	server_row.add_child(models_refresh)
	root.add_child(server_row)

	# 我的模型：用户手动收藏的常用模型（面板下拉只显示这些，不显示 API 返回的全部模型）
	var my_row := HBoxContainer.new()
	var my_label := Label.new(); my_label.text = "我的模型"
	my_label.tooltip_text = "你常用的模型。面板下拉只会显示：快捷模型 + 我的模型 + 自定义"
	my_row.add_child(my_label)
	_settings_my_select = OptionButton.new()
	_settings_my_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_settings_my_select.tooltip_text = "选择后自动填入上方「模型」输入框（仍需点「保存」生效）"
	_settings_my_select.item_selected.connect(func(idx: int) -> void:
		if idx >= 0 and _model_edit != null:
			_model_edit.text = _settings_my_select.get_item_text(idx)
	)
	my_row.add_child(_settings_my_select)
	var add_my_btn := Button.new()
	add_my_btn.text = "＋加入"
	add_my_btn.tooltip_text = "把上方「服务器模型」下拉中选中的模型加入我的模型"
	add_my_btn.pressed.connect(_add_my_model_from_server)
	my_row.add_child(add_my_btn)
	var remove_my_btn := Button.new()
	remove_my_btn.text = "－移除"
	remove_my_btn.tooltip_text = "从我的模型中移除当前选中项"
	remove_my_btn.pressed.connect(_remove_my_model)
	my_row.add_child(remove_my_btn)
	root.add_child(my_row)

	var key_row := HBoxContainer.new()
	_remember_key_check = CheckBox.new()
	_remember_key_check.text = "记住 API Key"
	_remember_key_check.tooltip_text = "勾选后 Key 会明文写入编辑器配置；不勾选则仅本次会话内存中使用，关闭编辑器即失效。"
	_remember_key_check.button_pressed = bool(_load_setting("remember_api_key", false))
	key_row.add_child(_remember_key_check)
	var clear_key_btn := Button.new()
	clear_key_btn.text = "清除已保存的 Key"
	clear_key_btn.tooltip_text = "从编辑器配置中删除已保存的 Key 并清空输入框"
	clear_key_btn.pressed.connect(func() -> void: _clear_saved_key(key_edit))
	key_row.add_child(clear_key_btn)
	root.add_child(key_row)

	var note := Label.new()
	note.text = "安全说明：API Key 默认不写入磁盘，仅本次会话内存中使用；勾选「记住」后才明文存入编辑器配置（可随时点击上面的按钮清除）。游戏运行时请改用环境变量 AI_API_KEY 或 项目设置→ai_assistant/api_key。"
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.modulate = COLOR_STATUS
	root.add_child(note)

	var btns := HBoxContainer.new()
	var ok := Button.new(); ok.text = "保存"; ok.size_flags_horizontal = Control.SIZE_EXPAND_FILL; ok.pressed.connect(func() -> void: _save_settings_from_window(url_edit, key_edit, _model_edit, temp_spin, tok_spin, timeout_spin, sys_edit))
	var cancel := Button.new(); cancel.text = "取消"; cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL; cancel.pressed.connect(_settings_window.hide)
	btns.add_child(ok); btns.add_child(cancel)
	root.add_child(btns)


func _build_sys_prompt_window() -> void:
	_systxt_window = AcceptDialog.new()
	_systxt_window.title = "系统提示词"
	_systxt_window.ok_button_text = "保存"
	_systxt_window.dialog_text = ""
	_set_window_resizable(_systxt_window)
	add_child(_systxt_window)
	_sys_edit = TextEdit.new()
	_sys_edit.custom_minimum_size = Vector2(560, 260)
	_sys_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sys_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_systxt_window.add_child(_sys_edit)
	_systxt_window.confirmed.connect(func() -> void:
		_client.system_prompt = _sys_edit.text
		_save_setting("system_prompt", _sys_edit.text)
		_set_status("系统提示词已更新", COLOR_OK)
	)


# ------------------------- 交互 -------------------------

func _open_settings() -> void:
	if _settings_window == null:
		return
	_settings_window.size = Vector2i(520, 620)
	_settings_window.min_size = Vector2i(480, 520)
	_settings_window.popup_centered()


## 供插件菜单调用的公开入口
func open_settings_dialog() -> void:
	_open_settings()


func _open_system_prompt() -> void:
	_sys_edit.text = _client.system_prompt
	_systxt_window.size = Vector2i(640, 460)
	_systxt_window.min_size = Vector2i(600, 420)
	_systxt_window.popup_centered()


func _save_settings_from_window(url_edit: LineEdit, key_edit: LineEdit, model_edit: LineEdit, temp_spin: SpinBox, tok_spin: SpinBox, timeout_spin: SpinBox, sys_edit: TextEdit) -> void:
	_save_setting("base_url", url_edit.text.strip_edges())
	var key := key_edit.text.strip_edges()
	var want_remember := _remember_key_check != null and _remember_key_check.button_pressed
	if want_remember and not key.is_empty():
		_save_setting("remember_api_key", true)
		_save_setting("api_key", key)
	else:
		_save_setting("remember_api_key", false)
		_erase_setting("api_key")
	_save_setting("model", model_edit.text.strip_edges())
	_save_setting("temperature", temp_spin.value)
	_save_setting("max_tokens", int(tok_spin.value))
	_save_setting("timeout", timeout_spin.value)
	_save_setting("system_prompt", sys_edit.text)
	_client.base_url = url_edit.text.strip_edges()
	_client.api_key = key  # 本次会话内始终可用（未勾选「记住」时也只在内存中）
	_client.model = model_edit.text.strip_edges()
	_client.temperature = temp_spin.value
	_client.max_tokens = int(tok_spin.value)
	_client.timeout_seconds = timeout_spin.value
	_client.system_prompt = sys_edit.text
	SESSION_CONFIG.capture(_client)
	if _client.api_key.is_empty():
		_clear_cached_models()
	_apply_config_to_ui()
	_settings_window.hide()
	if not _client.api_key.is_empty():
		_fetch_models()  # 根据新 Key + Base URL 自动确认可用模型
	else:
		_set_status("设置已保存 · %s（未填 API Key）" % _client.model, COLOR_OK)


## 一键清除已保存的 API Key（从编辑器配置中删除并清空输入框）
func _clear_saved_key(key_edit: LineEdit) -> void:
	_erase_setting("api_key")
	_save_setting("remember_api_key", false)
	if _remember_key_check != null:
		_remember_key_check.set_pressed_no_signal(false)
	key_edit.clear()
	_client.api_key = ""
	SESSION_CONFIG.capture(_client)
	_set_status("已清除保存的 API Key", COLOR_OK)


func _on_model_selected(idx: int) -> void:
	if idx == _custom_model_item_index:
		_open_settings()
		return
	if _model_select.is_item_separator(idx):
		return
	var m := _model_select.get_item_text(idx)
	if m.is_empty() or m == CUSTOM_MODEL_ITEM:
		return
	_client.model = m
	_save_setting("model", m)
	if _model_edit != null:
		_model_edit.text = m
	_set_status("模型切换为 %s" % m, COLOR_STATUS)


## 拉取服务器模型列表（工具栏「刷新模型」/ 设置窗口「刷新」共用）
## key_override：设置窗口传入输入框里的 Key（无需先保存即可用）
func _fetch_models(key_override := "") -> void:
	if _client == null:
		return
	var use_key := key_override.strip_edges() if not key_override.is_empty() else _client.api_key.strip_edges()
	if use_key.is_empty():
		_set_status("请先填写 API Key（设置里填好后点「保存」，或填在输入框直接点「刷新」）", COLOR_ERROR)
		return
	_models_fetch_key = use_key
	_set_status("正在从服务器加载模型列表…", COLOR_BUSY)
	_client.fetch_models(use_key)


func _on_models_loaded(models: Array, error_message: String) -> void:
	if not error_message.is_empty():
		_set_status("加载模型列表失败：" + error_message, COLOR_ERROR)
		if _settings_server_select != null and _settings_server_select.item_count == 0:
			_settings_server_select.add_item("（加载失败：" + error_message + "）")
		return
	var prev_model := _client.model
	_server_models = models.duplicate()
	_save_cached_models()
	# 仅当用户还没选模型时，自动选中第一个可用模型（有「我的模型」则优先选它）
	if prev_model.is_empty():
		var first := ""
		if not _my_models.is_empty():
			first = String(_my_models[0])
		elif not _server_models.is_empty():
			first = String(_server_models[0])
		if not first.is_empty():
			_client.model = first
			_save_setting("model", _client.model)
			if _model_edit != null:
				_model_edit.text = _client.model
	# 服务器全部模型只进「设置窗口」做发现用，不直接堆进面板下拉
	if _settings_server_select != null:
		var cur := _settings_server_select.get_item_text(_settings_server_select.selected)
		_settings_server_select.clear()
		for sm in _server_models:
			_settings_server_select.add_item(sm)
		var select_idx := _server_models.find(_client.model)
		_settings_server_select.select(select_idx if select_idx != -1 else -1)
		if cur != "" and _model_edit != null and _model_edit.text.is_empty():
			_model_edit.text = cur
	_sync_my_models_ui()
	_rebuild_model_list()
	if prev_model != _client.model:
		_set_status("已加载 %d 个可用模型，当前模型：%s" % [_server_models.size(), _client.model], COLOR_OK)
	else:
		_set_status("已加载 %d 个可用模型（用「＋加入」收藏到我的模型）" % _server_models.size(), COLOR_OK)


# ------------------------- 模型列表缓存（按 Key+地址指纹，重启不重复请求） -------------------------

const MODELS_CACHE_KEY := "ai_assistant/cached_models"


func _models_fingerprint(key := "") -> String:
	var k := key if not key.is_empty() else _client.api_key
	return _client.base_url + "|" + k.sha256_text()


func _save_cached_models() -> void:
	if not Engine.is_editor_hint() or _server_models.is_empty():
		return
	_save_setting("cached_models", {
		"fingerprint": _models_fingerprint(_models_fetch_key),
		"models": _server_models.duplicate(),
	})


func _restore_cached_models() -> void:
	if not Engine.is_editor_hint() or _client == null:
		return
	var data: Variant = _load_setting("cached_models", null)
	if data is Dictionary and String(data.get("fingerprint", "")) == _models_fingerprint():
		var models: Variant = data.get("models", [])
		if models is Array and not models.is_empty():
			_server_models = models.duplicate()
			# 同步设置窗口的「服务器模型」下拉（发现用）
			if _settings_server_select != null:
				_settings_server_select.clear()
				for sm in _server_models:
					_settings_server_select.add_item(sm)
	_sync_my_models_ui()
	_rebuild_model_list()


func _clear_cached_models() -> void:
	_erase_setting("cached_models")
	_server_models = []


# ------------------------- 我的模型（用户手动收藏，持久化） -------------------------

func _sync_my_models_ui() -> void:
	if _settings_my_select == null:
		return
	var prev_sel := _settings_my_select.selected
	_settings_my_select.clear()
	for mm in _my_models:
		_settings_my_select.add_item(mm)
	if prev_sel >= 0 and prev_sel < _my_models.size():
		_settings_my_select.select(prev_sel)
	elif not _my_models.is_empty():
		_settings_my_select.select(0)


func _add_my_model_from_server() -> void:
	if _settings_server_select == null or _settings_server_select.selected < 0:
		_set_status("请先在「服务器模型」下拉中选择要加入的模型", COLOR_STATUS)
		return
	var m := _settings_server_select.get_item_text(_settings_server_select.selected)
	if m.is_empty() or m.begins_with("（"):
		_set_status("请先获取模型列表，再选择要加入的模型", COLOR_STATUS)
		return
	if _my_models.has(m):
		_set_status("已在我的模型中：%s" % m, COLOR_STATUS)
		return
	_my_models.append(m)
	_save_setting("my_models", _my_models)
	_sync_my_models_ui()
	_rebuild_model_list()
	if _model_edit != null:
		_model_edit.text = m
	_set_status("已加入我的模型：%s" % m, COLOR_OK)


func _remove_my_model() -> void:
	if _settings_my_select == null or _settings_my_select.selected < 0:
		return
	var m := _settings_my_select.get_item_text(_settings_my_select.selected)
	if m.is_empty():
		return
	_my_models.erase(m)
	_save_setting("my_models", _my_models)
	_sync_my_models_ui()
	_rebuild_model_list()
	if _client.model == m:
		_client.model = ""
		if _model_edit != null:
			_model_edit.text = ""
	_set_status("已从我的模型移除：%s" % m, COLOR_STATUS)


func _on_stream_toggled(v: bool) -> void:
	_client.stream = v
	_save_setting("stream", v)


func _on_reasoning_toggled(show: bool) -> void:
	_reasoning_visible = show
	if show and not _reasoning_buffer.is_empty() and not _reasoning_rendered:
		_log.append_text("\n[color=%s][i]🧠 思考过程\n%s[/i][/color]\n" % [_color_str(COLOR_REASONING), _escape_bbcode(_reasoning_buffer)])
		_reasoning_rendered = true


func _cancel_request() -> void:
	if _busy:
		_client.cancel()


func _on_text_submitted(text: String) -> void:
	var t := text.strip_edges()
	if t.is_empty():
		return
	if t.begins_with("/"):
		_handle_command(t)
		return
	if _busy:
		_set_status("上一请求还在进行中…", COLOR_BUSY)
		return
	_input.clear()
	_append_user(t)
	_stream_buffer = ""
	_streamed_any = false
	_reasoning_buffer = ""
	_reasoning_rendered = false
	_set_busy(true)
	_client.chat(t)


func _handle_command(cmd: String) -> void:
	match cmd:
		"/clear":
			_clear_chat()
		"/help":
			_append_system("可用命令：\n/clear 清空对话  ·  /script 发送当前脚本  ·  /help 本帮助")
		"/script":
			_send_current_script()
		_:
			_append_system("未知命令: %s（/help 查看帮助）" % cmd)


func _clear_chat() -> void:
	if _busy:
		_client.cancel()
	_log.clear()
	_append_system("对话已清空（客户端历史已重置）。")
	_client.clear_history()
	_last_answer = ""
	_last_code_blocks = []
	_set_status("已清空 · %s" % _client.model, COLOR_STATUS)


func _send_current_script() -> void:
	if not Engine.is_editor_hint():
		return
	if _busy:
		_set_status("上一请求还在进行中…", COLOR_BUSY)
		return
	var script_editor := EditorInterface.get_script_editor()
	if script_editor == null:
		return
	var script: Script = script_editor.get_current_script()
	if script == null:
		_append_system("没有打开的脚本。请先在脚本编辑器中打开一个脚本。")
		return
	var src: String = script.source_code
	if src.is_empty():
		_append_system("当前脚本没有可发送的源码。")
		return
	var msg := "（用户把当前脚本发给你，请分析代码并给出改进建议，指出潜在 Bug）\n脚本路径: %s\n\n```gdscript\n%s\n```" % [script.resource_path, src]
	_append_user(msg)
	_stream_buffer = ""
	_streamed_any = false
	_reasoning_buffer = ""
	_reasoning_rendered = false
	_set_busy(true)
	_client.chat(msg)
	_set_status("已发送脚本 %s" % script.resource_path.get_file(), COLOR_STATUS)


func _run_scene() -> void:
	if not Engine.is_editor_hint():
		return
	if EditorInterface.has_method("play_main_scene"):
		EditorInterface.play_main_scene()
	else:
		_set_status("当前 Godot 版本不支持 play_main_scene，请用编辑器顶部的 ▶ 运行", COLOR_BUSY)


# ------------------------- 展示 -------------------------

func _append_user(text: String) -> void:
	_log.append_text("\n[color=%s][b]🧑 你[/b][/color]\n" % _color_str(COLOR_USER))
	_log.append_text(_markdown_to_bbcode(text) + "\n")


func _append_system(text: String) -> void:
	_log.append_text("\n[color=%s]〔系统〕%s[/color]\n" % [_color_str(COLOR_SYSTEM), _escape_bbcode(text)])


func _on_stream_chunk(text: String) -> void:
	_streamed_any = true
	_stream_buffer += text
	_log.append_text(_escape_bbcode(text))


func _on_reasoning_chunk(text: String) -> void:
	_reasoning_buffer += text
	if _reasoning_visible:
		if not _reasoning_rendered:
			_log.append_text("\n[color=%s][i]🧠 思考过程\n%s[/i][/color]" % [_color_str(COLOR_REASONING), _escape_bbcode(_reasoning_buffer)])
			_reasoning_rendered = true
		else:
			_log.append_text(_escape_bbcode(text))


func _on_finished(success: bool, error_message: String) -> void:
	_set_busy(false)
	if not success:
		_log.append_text("\n[color=%s]⚠ %s[/color]\n" % [_color_str(COLOR_ERROR), _escape_bbcode(error_message)])
		_set_status("请求失败", COLOR_ERROR)
		return
	_last_answer = _client.last_response_text
	_last_code_blocks = _extract_code_blocks(_last_answer)
	if not _streamed_any:
		# 非流式：整段渲染（含 Markdown）
		_log.append_text("\n[color=%s][b]🤖 AI[/b][/color]\n" % _color_str(COLOR_AI))
		_log.append_text(_markdown_to_bbcode(_last_answer) + "\n")
	else:
		_log.append_text("\n")
	if not _reasoning_buffer.is_empty() and not _reasoning_visible:
		_log.append_text("[color=%s][i]🧠 思考过程已收起（%d 字），打开「思考」可查看。[/i][/color]\n" % [_color_str(COLOR_REASONING), _reasoning_buffer.length()])
	var tail := "完成"
	if not _last_code_blocks.is_empty():
		tail = "完成 · %d 个代码块" % _last_code_blocks.size()
	_set_status(tail + " · " + _client.model, COLOR_OK)


func _set_busy(b: bool) -> void:
	_busy = b
	_send_btn.disabled = b  # 忙时禁用发送按钮；输入框仍可继续输入（回车会提示"上一请求进行中"）
	if _stop_btn != null:
		_stop_btn.disabled = not b


func _set_status(text: String, color: Color) -> void:
	if _status != null:
		_status.text = text
		_status.modulate = color


# ------------------------- 代码操作 -------------------------

func _copy_last_answer() -> void:
	if _last_answer.is_empty():
		_set_status("还没有回复可复制", COLOR_BUSY)
		return
	DisplayServer.clipboard_set(_last_answer)
	_set_status("已复制回复", COLOR_OK)


func _insert_to_current_script() -> void:
	if not Engine.is_editor_hint():
		return
	var code := _pick_code()
	if code.is_empty():
		_append_system("回复中没有可插入的代码块，已把全文复制到剪贴板。")
		DisplayServer.clipboard_set(_last_answer)
		return
	var script_editor := EditorInterface.get_script_editor()
	var script: Script = script_editor.get_current_script()
	if script == null:
		_append_system("请先在脚本编辑器中打开目标脚本。")
		return
	var merged := script.source_code
	if not merged.is_empty() and not merged.ends_with("\n"):
		merged += "\n"
	merged += "\n# ---------- 由 AI 生成 ----------\n" + code.rstrip("\n") + "\n"
	script.source_code = merged
	if not script.resource_path.is_empty():
		var err := ResourceSaver.save(script, script.resource_path)
		if err != OK:
			_set_status("保存脚本失败: %s" % error_string(err), COLOR_ERROR)
			return
		if script_editor.has_method("reload_script_from_disk"):
			script_editor.reload_script_from_disk(script)
	_set_status("已插入 %d 行代码到 %s" % [code.count("\n") + 1, script.resource_path.get_file() if not script.resource_path.is_empty() else "当前脚本"], COLOR_OK)


func _save_as_script() -> void:
	if not Engine.is_editor_hint():
		return
	var code := _pick_code()
	if code.is_empty():
		code = _last_answer
	if code.is_empty():
		_set_status("没有可保存的内容", COLOR_BUSY)
		return
	var dir := "res://generated/ai"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var stamp := Time.get_datetime_string_from_system().replace(":", "").replace("-", "").replace(" ", "")
	var path := dir + "/ai_gen_" + stamp + ".gd"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_set_status("无法创建文件", COLOR_ERROR)
		return
	f.store_string("# 由 AI 助手生成 %s\n" % Time.get_datetime_string_from_system() + code)
	f.close()
	EditorInterface.get_resource_filesystem().scan()
	var script := load(path)
	if script != null and EditorInterface.get_script_editor().has_method("open_script"):
		EditorInterface.get_script_editor().open_script(script)
	_set_status("已保存 %s" % path, COLOR_OK)


func _pick_code() -> String:
	if not _last_code_blocks.is_empty():
		return String(_last_code_blocks[0])
	return ""


func _extract_code_blocks(text: String) -> Array:
	var blocks: Array = []
	var re := RegEx.new()
	re.compile("```[\\w-]*\\n?([\\s\\S]*?)```")
	for m in re.search_all(text):
		blocks.append(m.get_string(1))
	return blocks


# ------------------------- Markdown 轻渲染 -------------------------

func _markdown_to_bbcode(raw: String) -> String:
	if raw.is_empty():
		return ""
	var escaped := raw.replace("[", "[lb]").replace("]", "[rb]")
	var lines := escaped.split("\n")
	var out := PackedStringArray()
	var in_code := false
	var code_buf := PackedStringArray()
	for line in lines:
		var stripped := line.strip_edges()
		if stripped.begins_with("```"):
			if in_code:
				out.append("[color=#d4d4e8][code]" + "\n".join(code_buf) + "[/code][/color]")
				code_buf = PackedStringArray()
				in_code = false
			else:
				in_code = true
			continue
		if in_code:
			code_buf.append(line.replace("[lb]", "[").replace("[rb]", "]"))
			continue
		var l := line
		if stripped.begins_with("###"):
			l = "[b]" + l + "[/b]"
		elif stripped.begins_with("##"):
			l = "[b]" + l + "[/b]"
		elif stripped.begins_with("#"):
			l = "[b]" + l + "[/b]"
		elif stripped.begins_with("- ") or stripped.begins_with("* "):
			l = "  •  " + l.substr(2)
		l = _inline_code(l)
		l = _inline_bold(l)
		out.append(l)
	if in_code:
		out.append("[color=#d4d4e8][code]" + "\n".join(code_buf) + "[/code][/color]")
	return "\n".join(out)


func _inline_code(s: String) -> String:
	var parts := s.split("`")
	for i in range(parts.size()):
		if i % 2 == 1:
			parts[i] = "[code]" + parts[i] + "[/code]"
	return "".join(parts)


func _inline_bold(s: String) -> String:
	var parts := s.split("**")
	for i in range(parts.size()):
		if i % 2 == 1:
			parts[i] = "[b]" + parts[i] + "[/b]"
	return "".join(parts)


func _escape_bbcode(text: String) -> String:
	return text.replace("[", "[lb]").replace("]", "[rb]")


func _color_str(c: Color) -> String:
	return c.to_html(false)
