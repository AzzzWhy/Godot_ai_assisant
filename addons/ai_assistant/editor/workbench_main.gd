@tool
class_name AIWorkbenchMain
extends Control
## Floating workbench content: task timeline, result review and Chat/Builder composer.

const CONTROLLER_SCRIPT := preload("res://addons/ai_assistant/editor/workbench_controller.gd")
const TIMELINE_SCRIPT := preload("res://addons/ai_assistant/editor/task_timeline.gd")
const PREVIEW_SCRIPT := preload("res://addons/ai_assistant/editor/result_preview.gd")
const THEME := preload("res://addons/ai_assistant/editor/ui_theme.gd")
const TASK_AUTO_COLLAPSE_WIDTH := 900.0
const TASK_RAIL_MIN := 250.0
const TASK_RAIL_MAX := 300.0
const CHAT_RAIL_MIN := 340.0
const CHAT_RAIL_MAX := 400.0
const TASK_DOCK_WIDTH := 260.0
const CHAT_DOCK_WIDTH := 360.0

var controller: AIWorkbenchController
var _timeline: AITaskTimeline
var _preview: AIResultPreview
var _body_split: HSplitContainer
var _center_split: HSplitContainer
var _left_card: PanelContainer
var _chat_log: RichTextLabel
var _composer: TextEdit
var _send: Button
var _stop: Button
var _apply: Button
var _discard: Button
var _review_bar: PanelContainer
var _review_text: Label
var _mode_chat: Button
var _mode_builder: Button
var _task_toggle: Button
var _status_dot: Label
var _status_text: Label
var _model_text: Label
var _context_text: Label
var _builder_mode := true
var _active := false
var _streaming_answer := false
var _task_panel_visible := true
var _task_panel_manually_set := false
var _layout_initialized := false

var _settings_window: Window
var _url_edit: LineEdit
var _key_edit: LineEdit
var _model_edit: LineEdit
var _temperature: SpinBox
var _max_tokens: SpinBox
var _timeout: SpinBox
var _stream: CheckBox
var _remember: CheckBox
var _system_prompt: TextEdit
var _server_models: OptionButton


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	controller = CONTROLLER_SCRIPT.new()
	add_child(controller)
	_build_ui()
	resized.connect(_update_workspace_layout)
	call_deferred("_update_workspace_layout")
	_connect_controller()
	_timeline.set_controller(controller)
	_preview.set_controller(controller)
	_append_message(
		"system",
		"Builder 会把生成的脚本、代码差异和节点绑定放在中间结果区。"
		+ "确认无误后，只需点击一次「应用全部」。",
	)
	call_deferred("_refresh_editor_context")


func set_active(active: bool) -> void:
	_active = active
	if not Engine.is_editor_hint():
		return
	var selection := EditorInterface.get_selection()
	if selection == null:
		return
	if active:
		if not selection.selection_changed.is_connected(_refresh_editor_context):
			selection.selection_changed.connect(_refresh_editor_context)
		_refresh_editor_context()
	else:
		if selection.selection_changed.is_connected(_refresh_editor_context):
			selection.selection_changed.disconnect(_refresh_editor_context)


func open_settings_dialog() -> void:
	if _settings_window == null:
		_build_settings_window()
	_attach_settings_window()
	_fill_settings()
	_settings_window.popup_centered(_settings_window.size)


func has_pending_draft() -> bool:
	return controller != null and controller.has_pending_draft()


func shutdown() -> void:
	set_active(false)
	if controller != null:
		controller.cancel()
		controller.discard_draft()
	if _settings_window != null:
		_settings_window.queue_free()
		_settings_window = null


func _build_ui() -> void:
	var background := PanelContainer.new()
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.add_theme_stylebox_override("panel", THEME.panel(THEME.BG, 0))
	add_child(background)
	var shell := VBoxContainer.new()
	shell.add_theme_constant_override("separation", 0)
	background.add_child(shell)
	shell.add_child(_build_header())
	var line := HSeparator.new()
	line.modulate = THEME.BORDER
	shell.add_child(line)
	_body_split = HSplitContainer.new()
	_body_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_style_split(_body_split)
	shell.add_child(_body_split)

	_left_card = PanelContainer.new()
	_left_card.custom_minimum_size = Vector2(TASK_RAIL_MIN, 0)
	_left_card.add_theme_stylebox_override("panel", _surface(THEME.BG_MUTED, 3, 8))
	_timeline = TIMELINE_SCRIPT.new()
	_left_card.add_child(_timeline)
	_body_split.add_child(_left_card)

	_center_split = HSplitContainer.new()
	_center_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_split(_center_split)
	_body_split.add_child(_center_split)
	var result_column := VBoxContainer.new()
	result_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	result_column.add_theme_constant_override("separation", 0)
	var result_surface := PanelContainer.new()
	result_surface.size_flags_vertical = Control.SIZE_EXPAND_FILL
	result_surface.add_theme_stylebox_override("panel", _surface(THEME.BG_INSET, 3, 8))
	_preview = PREVIEW_SCRIPT.new()
	result_surface.add_child(_preview)
	result_column.add_child(result_surface)
	_review_bar = _build_review_bar()
	result_column.add_child(_review_bar)
	_center_split.add_child(result_column)
	_center_split.add_child(_build_chat_rail())
	_build_settings_window()


func _build_header() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(0, 36)
	panel.add_theme_stylebox_override("panel", _surface(THEME.BG_MUTED, 0, 8))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	panel.add_child(row)
	var title := Label.new()
	title.text = "AI 工作台"
	THEME.apply_label(title, false, 13)
	row.add_child(title)
	var separator := VSeparator.new()
	separator.modulate = THEME.BORDER
	row.add_child(separator)
	_mode_builder = Button.new()
	_mode_builder.text = "Builder"
	_mode_builder.toggle_mode = true
	_mode_builder.button_pressed = true
	_mode_builder.pressed.connect(func() -> void: _set_mode(true))
	row.add_child(_mode_builder)
	_mode_chat = Button.new()
	_mode_chat.text = "Chat"
	_mode_chat.toggle_mode = true
	_mode_chat.pressed.connect(func() -> void: _set_mode(false))
	row.add_child(_mode_chat)
	_task_toggle = Button.new()
	_task_toggle.text = "任务栏"
	_task_toggle.toggle_mode = true
	_task_toggle.button_pressed = true
	_task_toggle.pressed.connect(_on_task_toggle)
	row.add_child(_task_toggle)
	_style_mode_buttons()
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	_status_dot = Label.new()
	_status_dot.text = "●"
	_status_dot.add_theme_color_override("font_color", THEME.FG_MUTED)
	row.add_child(_status_dot)
	_status_text = Label.new()
	_status_text.text = "等待任务"
	THEME.apply_label(_status_text, true, 12)
	row.add_child(_status_text)
	var model_chip := PanelContainer.new()
	model_chip.add_theme_stylebox_override("panel", THEME.panel(THEME.CHIP_BG, 3))
	_model_text = Label.new()
	_model_text.text = "未配置模型"
	THEME.apply_label(_model_text, true, 12)
	model_chip.add_child(_model_text)
	row.add_child(model_chip)
	var settings := Button.new()
	settings.text = "设置"
	THEME.apply_button(settings, "ghost")
	settings.pressed.connect(open_settings_dialog)
	row.add_child(settings)
	return panel


func _build_chat_rail() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(CHAT_RAIL_MIN, 0)
	panel.add_theme_stylebox_override("panel", _surface(THEME.BG_MUTED, 3, 8))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	var heading_row := HBoxContainer.new()
	var heading := Label.new()
	heading.text = "对话"
	THEME.apply_label(heading, false, 13)
	heading_row.add_child(heading)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading_row.add_child(spacer)
	var clear := Button.new()
	clear.text = "清空"
	THEME.apply_button(clear, "ghost")
	clear.pressed.connect(_clear_chat)
	heading_row.add_child(clear)
	box.add_child(heading_row)

	var context_card := PanelContainer.new()
	context_card.add_theme_stylebox_override("panel", THEME.panel(Color("#243044"), 3))
	_context_text = Label.new()
	_context_text.text = "上下文：未选择节点"
	_context_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	THEME.apply_label(_context_text, true, 12)
	context_card.add_child(_context_text)
	box.add_child(context_card)

	_chat_log = RichTextLabel.new()
	_chat_log.bbcode_enabled = true
	_chat_log.scroll_following = true
	_chat_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chat_log.add_theme_color_override("default_color", THEME.FG)
	_chat_log.add_theme_font_size_override("normal_font_size", 13)
	box.add_child(_chat_log)

	var composer_card := PanelContainer.new()
	composer_card.add_theme_stylebox_override("panel", THEME.panel(THEME.BG_CARD, 3))
	var composer_box := VBoxContainer.new()
	composer_box.add_theme_constant_override("separation", 8)
	composer_card.add_child(composer_box)
	_composer = TextEdit.new()
	_composer.placeholder_text = "描述完整任务，例如：给 Player 写移动脚本并绑定"
	_composer.custom_minimum_size = Vector2(0, 72)
	_composer.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_composer.gui_input.connect(_on_composer_input)
	THEME.apply_line_edit(_composer)
	composer_box.add_child(_composer)
	var action_row := HBoxContainer.new()
	var hint := Label.new()
	hint.text = "Enter 发送 · Shift+Enter 换行"
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	THEME.apply_label(hint, true, 11)
	action_row.add_child(hint)
	_stop = Button.new()
	_stop.text = "停止"
	_stop.visible = false
	THEME.apply_button(_stop, "danger")
	_stop.pressed.connect(controller.cancel)
	action_row.add_child(_stop)
	_send = Button.new()
	_send.text = "发送任务"
	THEME.apply_button(_send, "primary")
	_send.pressed.connect(_send_message)
	action_row.add_child(_send)
	composer_box.add_child(action_row)
	box.add_child(composer_card)
	return panel


func _build_review_bar() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.visible = false
	panel.add_theme_stylebox_override("panel", _surface(THEME.BG_CARD, 3, 8))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	panel.add_child(row)
	_review_text = Label.new()
	_review_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	THEME.apply_label(_review_text, true, 12)
	row.add_child(_review_text)
	_discard = Button.new()
	_discard.text = "撤销全部"
	THEME.apply_button(_discard, "danger")
	_discard.pressed.connect(controller.discard_draft)
	row.add_child(_discard)
	_apply = Button.new()
	_apply.text = "应用全部"
	THEME.apply_button(_apply, "primary")
	_apply.pressed.connect(_apply_all)
	row.add_child(_apply)
	return panel


func _connect_controller() -> void:
	controller.state_changed.connect(_on_state_changed)
	controller.message_added.connect(_on_message_added)
	controller.stream_text.connect(_on_stream_text)
	controller.reasoning_text.connect(_on_reasoning_text)
	controller.draft_changed.connect(_refresh_review_bar)
	controller.context_changed.connect(_on_context_changed)
	controller.models_loaded.connect(_on_models_loaded)
	var config := controller.get_config()
	_model_text.text = String(config.get("model", "未配置模型"))
	_refresh_review_bar()
	_on_state_changed(controller.state_key, controller.state_message)


func _set_mode(builder: bool) -> void:
	_builder_mode = builder
	_style_mode_buttons()
	_composer.placeholder_text = (
		"描述完整任务，例如：给 Player 写移动脚本并绑定"
		if builder
		else "询问 Godot 或 GDScript 问题"
	)
	_send.text = "发送任务" if builder else "发送"


func _style_mode_buttons() -> void:
	if _mode_builder == null:
		return
	_mode_builder.button_pressed = _builder_mode
	_mode_chat.button_pressed = not _builder_mode
	THEME.apply_button(_mode_builder, "selected" if _builder_mode else "ghost")
	THEME.apply_button(_mode_chat, "selected" if not _builder_mode else "ghost")
	if _task_toggle != null:
		_task_toggle.button_pressed = _task_panel_visible
		THEME.apply_button(_task_toggle, "selected" if _task_panel_visible else "ghost")


func _on_task_toggle() -> void:
	_task_panel_manually_set = true
	_task_panel_visible = _task_toggle.button_pressed
	_update_workspace_layout()


func _update_workspace_layout(width_override: float = -1.0) -> void:
	if _body_split == null or _center_split == null or _left_card == null:
		return
	var workspace_width := width_override if width_override > 0.0 else size.x
	if workspace_width <= 0.0:
		return
	if not _layout_initialized or not _task_panel_manually_set:
		_task_panel_visible = workspace_width >= TASK_AUTO_COLLAPSE_WIDTH
	_layout_initialized = true
	_left_card.visible = _task_panel_visible
	if _task_panel_visible:
		var task_width := TASK_DOCK_WIDTH
		if workspace_width < 1200.0:
			task_width = clampf(workspace_width * 0.22, TASK_RAIL_MIN, TASK_RAIL_MAX)
		_body_split.split_offset = int(round(task_width))
	var chat_width := CHAT_DOCK_WIDTH
	if workspace_width < 1200.0:
		chat_width = clampf(workspace_width * 0.30, CHAT_RAIL_MIN, CHAT_RAIL_MAX)
	_center_split.split_offset = -int(round(chat_width))
	_style_mode_buttons()


func _send_message() -> void:
	var message := _composer.text.strip_edges()
	if message.is_empty():
		return
	var started := false
	if _builder_mode:
		started = controller.run_builder(message, _selected_node())
	else:
		started = controller.run_chat(message)
	if started:
		_composer.clear()


func _on_composer_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if key.pressed and not key.echo and key.keycode == KEY_ENTER and not key.shift_pressed:
		_send_message()
		_composer.accept_event()


func _apply_all() -> void:
	controller.apply_all()


func _refresh_review_bar() -> void:
	if _review_bar == null or controller == null:
		return
	var state := controller.state_key
	_review_bar.visible = ["review", "applying", "done", "error"].has(state) and not controller.store.proposals.is_empty()
	var files := controller.store.proposals.size()
	var operations := controller.store.node_operations.size()
	_review_text.text = "%d 个文件 · %d 个节点操作" % [files, operations]
	_apply.visible = state == "review"
	_apply.disabled = state != "review"
	_discard.visible = state != "applying"
	if controller.has_unresolved_transaction():
		_discard.text = "重试回滚"
	else:
		_discard.text = "清除结果" if state == "done" else "撤销全部"
	if state == "done":
		if _discard.pressed.is_connected(controller.discard_draft):
			_discard.pressed.disconnect(controller.discard_draft)
		if not _discard.pressed.is_connected(controller.clear_finished):
			_discard.pressed.connect(controller.clear_finished)
	elif _discard.pressed.is_connected(controller.clear_finished):
		_discard.pressed.disconnect(controller.clear_finished)
		if not _discard.pressed.is_connected(controller.discard_draft):
			_discard.pressed.connect(controller.discard_draft)


func _on_state_changed(state: String, message: String) -> void:
	_status_text.text = message
	match state:
		"planning", "generating", "applying":
			_status_dot.add_theme_color_override("font_color", THEME.ATTENTION)
		"review":
			_status_dot.add_theme_color_override("font_color", THEME.ACCENT)
		"done":
			_status_dot.add_theme_color_override("font_color", THEME.SUCCESS)
		"error":
			_status_dot.add_theme_color_override("font_color", THEME.DANGER)
			_append_message("system", message)
		_:
			_status_dot.add_theme_color_override("font_color", THEME.FG_MUTED)
	var busy := controller.is_busy()
	_send.disabled = busy
	_stop.visible = busy
	_refresh_review_bar()


func _on_message_added(role: String, text: String) -> void:
	_streaming_answer = false
	_append_message(role, text)


func _on_stream_text(text: String) -> void:
	if not _streaming_answer:
		_streaming_answer = true
		_chat_log.append_text("\n[color=#%s][b]AI[/b][/color]\n" % THEME.SUCCESS.to_html(false))
	_chat_log.append_text(_escape_bbcode(text))


func _on_reasoning_text(_text: String) -> void:
	pass


func _append_message(role: String, text: String) -> void:
	if _chat_log == null or text.is_empty():
		return
	var label := "AI"
	var color := THEME.SUCCESS
	match role:
		"user":
			label = "你"
			color = THEME.ACCENT
		"system":
			label = "系统"
			color = THEME.FG_MUTED
	_chat_log.append_text("\n[color=#%s][b]%s[/b][/color]\n%s\n" % [
		color.to_html(false),
		label,
		_markdown_to_bbcode(text),
	])


func _clear_chat() -> void:
	_chat_log.clear()
	controller.clear_chat_history()
	_append_message("system", "对话已清空。当前 Builder 草稿不会被删除。")


func _refresh_editor_context() -> void:
	if controller == null:
		return
	controller.capture_context(_selected_node())


func _on_context_changed(context: Dictionary) -> void:
	if _context_text == null:
		return
	var node_name := String(context.get("selected_node_name", ""))
	var node_type := String(context.get("selected_node_type", ""))
	var script_path := String(context.get("script_path", ""))
	_context_text.text = "上下文：%s%s\n脚本：%s" % [
		node_name if not node_name.is_empty() else "未选择节点",
		" · " + node_type if not node_type.is_empty() else "",
		script_path if not script_path.is_empty() else "无",
	]


func _selected_node() -> Node:
	if not Engine.is_editor_hint():
		return null
	var selection := EditorInterface.get_selection()
	if selection == null:
		return null
	var nodes := selection.get_selected_nodes()
	return nodes[0] if not nodes.is_empty() and nodes[0] is Node else null


func _settings_host() -> Node:
	if Engine.is_editor_hint():
		return EditorInterface.get_base_control()
	var host := get_window()
	return host if host != null else self


func _attach_settings_window() -> void:
	if _settings_window == null:
		return
	var host := _settings_host()
	if host == null or _settings_window.get_parent() == host:
		return
	if _settings_window.get_parent() != null:
		_settings_window.get_parent().remove_child(_settings_window)
	host.add_child(_settings_window)


func _build_settings_window() -> void:
	_settings_window = Window.new()
	_settings_window.title = "AI 工作台设置"
	var editor_scale := maxf(EditorInterface.get_editor_scale(), 1.0) if Engine.is_editor_hint() else 1.0
	_settings_window.content_scale_factor = editor_scale
	var settings_size := Vector2i(roundi(600 * editor_scale), roundi(650 * editor_scale))
	var settings_minimum := Vector2i(roundi(520 * editor_scale), roundi(560 * editor_scale))
	if Engine.is_editor_hint():
		var usable := DisplayServer.screen_get_usable_rect(DisplayServer.SCREEN_OF_MAIN_WINDOW)
		if usable.size.x > 0 and usable.size.y > 0:
			var available := Vector2i(maxi(1, usable.size.x - 40), maxi(1, usable.size.y - 40))
			settings_size = settings_size.min(available)
			settings_minimum = settings_minimum.min(available)
	_settings_window.size = settings_size
	_settings_window.min_size = settings_minimum
	_settings_window.wrap_controls = false
	_settings_window.transient = true
	_settings_window.exclusive = false
	_settings_window.unresizable = false
	_settings_window.visible = false
	_settings_window.close_requested.connect(_settings_window.hide)
	_attach_settings_window()
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_theme_stylebox_override("panel", THEME.panel(THEME.BG, 0))
	_settings_window.add_child(panel)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 18)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 10)
	margin.add_child(box)
	var heading := Label.new()
	heading.text = "模型连接"
	THEME.apply_label(heading, false, 18)
	box.add_child(heading)
	var note := Label.new()
	note.text = "API Key 默认只保存在当前 Godot 会话。"
	THEME.apply_label(note, true, 12)
	box.add_child(note)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 8)
	box.add_child(grid)
	_url_edit = _settings_line(grid, "Base URL", "https://api.deepseek.com")
	_key_edit = _settings_line(grid, "API Key", "sk-...")
	_key_edit.secret = true
	_model_edit = _settings_line(grid, "模型", "deepseek-chat")
	_temperature = _settings_spin(grid, "温度", -1, 2, 0.1)
	_max_tokens = _settings_spin(grid, "max_tokens", 0, 131072, 1)
	_timeout = _settings_spin(grid, "超时（秒）", 5, 600, 1)
	var model_row := HBoxContainer.new()
	var server_label := Label.new()
	server_label.text = "服务器模型"
	THEME.apply_label(server_label, true, 12)
	model_row.add_child(server_label)
	_server_models = OptionButton.new()
	_server_models.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_server_models.item_selected.connect(func(index: int) -> void:
		if index >= 0:
			_model_edit.text = _server_models.get_item_text(index)
	)
	model_row.add_child(_server_models)
	var refresh := Button.new()
	refresh.text = "刷新"
	THEME.apply_button(refresh, "ghost")
	refresh.pressed.connect(func() -> void:
		controller.fetch_models(_key_edit.text.strip_edges())
	)
	model_row.add_child(refresh)
	box.add_child(model_row)
	_stream = CheckBox.new()
	_stream.text = "Chat 使用流式输出"
	box.add_child(_stream)
	_remember = CheckBox.new()
	_remember.text = "记住 API Key（明文写入 Godot 编辑器配置）"
	box.add_child(_remember)
	var prompt_label := Label.new()
	prompt_label.text = "Chat 系统提示词"
	THEME.apply_label(prompt_label, true, 12)
	box.add_child(prompt_label)
	_system_prompt = TextEdit.new()
	_system_prompt.custom_minimum_size = Vector2(0, 120)
	THEME.apply_line_edit(_system_prompt)
	box.add_child(_system_prompt)
	var buttons := HBoxContainer.new()
	var cancel := Button.new()
	cancel.text = "取消"
	THEME.apply_button(cancel, "ghost")
	cancel.pressed.connect(_settings_window.hide)
	buttons.add_child(cancel)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(spacer)
	var save := Button.new()
	save.text = "保存设置"
	THEME.apply_button(save, "primary")
	save.pressed.connect(_save_settings)
	buttons.add_child(save)
	box.add_child(buttons)


func _settings_line(grid: GridContainer, label_text: String, placeholder: String) -> LineEdit:
	var label := Label.new()
	label.text = label_text
	THEME.apply_label(label, true, 12)
	grid.add_child(label)
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	THEME.apply_line_edit(edit)
	grid.add_child(edit)
	return edit


func _settings_spin(
	grid: GridContainer,
	label_text: String,
	minimum: float,
	maximum: float,
	step: float,
) -> SpinBox:
	var label := Label.new()
	label.text = label_text
	THEME.apply_label(label, true, 12)
	grid.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	grid.add_child(spin)
	return spin


func _fill_settings() -> void:
	var config := controller.get_config()
	_url_edit.text = String(config.get("base_url", ""))
	_key_edit.text = String(config.get("api_key", ""))
	_model_edit.text = String(config.get("model", ""))
	_temperature.value = float(config.get("temperature", 1.0))
	_max_tokens.value = int(config.get("max_tokens", 0))
	_timeout.value = float(config.get("timeout", 60.0))
	_stream.button_pressed = bool(config.get("stream", true))
	_system_prompt.text = String(config.get("system_prompt", ""))
	var settings := EditorInterface.get_editor_settings()
	_remember.button_pressed = (
		bool(settings.get_setting("ai_assistant/remember_api_key"))
		if settings.has_setting("ai_assistant/remember_api_key")
		else false
	)


func _save_settings() -> void:
	controller.save_config({
		"base_url": _url_edit.text,
		"api_key": _key_edit.text,
		"model": _model_edit.text,
		"temperature": _temperature.value,
		"max_tokens": int(_max_tokens.value),
		"timeout": _timeout.value,
		"stream": _stream.button_pressed,
		"system_prompt": _system_prompt.text,
	}, _remember.button_pressed)
	_model_text.text = _model_edit.text if not _model_edit.text.is_empty() else "未配置模型"
	_settings_window.hide()
	_on_state_changed(controller.state_key, "设置已保存")


func _on_models_loaded(models: Array, error_message: String) -> void:
	_server_models.clear()
	if not error_message.is_empty():
		_server_models.add_item("加载失败：" + error_message)
		return
	for model in models:
		_server_models.add_item(String(model))
	if not models.is_empty():
		_model_edit.text = String(models[0])


func _markdown_to_bbcode(text: String) -> String:
	var escaped := _escape_bbcode(text)
	var output := PackedStringArray()
	for line in escaped.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.begins_with("### "):
			output.append("[b]" + line.substr(line.find("### ") + 4) + "[/b]")
		elif trimmed.begins_with("## "):
			output.append("[b]" + line.substr(line.find("## ") + 3) + "[/b]")
		elif trimmed.begins_with("- "):
			output.append("  • " + line.substr(line.find("- ") + 2))
		else:
			output.append(line)
	return "\n".join(output)


func _escape_bbcode(text: String) -> String:
	return (
		text
		.replace("[", "\u0001")
		.replace("]", "\u0002")
		.replace("\u0001", "[lb]")
		.replace("\u0002", "[rb]")
	)


func _style_split(split: HSplitContainer) -> void:
	var bar := StyleBoxFlat.new()
	bar.bg_color = THEME.BORDER
	split.add_theme_stylebox_override("split_bar_background", bar)
	split.add_theme_constant_override("separation", 8)
	split.add_theme_constant_override("minimum_grab_thickness", 8)
	split.dragger_visibility = SplitContainer.DRAGGER_VISIBLE


func _surface(color: Color, radius: int, margin: int) -> StyleBoxFlat:
	var style := THEME.panel(color, radius)
	style.content_margin_left = margin
	style.content_margin_right = margin
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	return style
