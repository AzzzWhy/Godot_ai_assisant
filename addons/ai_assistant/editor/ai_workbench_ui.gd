@tool
class_name AIWorkbenchMain
extends Control
## Floating workbench content: task timeline, result review and Chat/Builder composer.

const CONTROLLER_SCRIPT := preload("res://addons/ai_assistant/editor/workbench_task_controller.gd")
const TIMELINE_SCRIPT := preload("res://addons/ai_assistant/editor/builder_task_timeline.gd")
const PREVIEW_SCRIPT := preload("res://addons/ai_assistant/editor/proposal_review_view.gd")
const THEME := preload("res://addons/ai_assistant/editor/workbench_dark_theme.gd")
const CHAT_CARD := preload("res://addons/ai_assistant/editor/chat_message_card.gd")
const CHAT_MARKDOWN := preload("res://addons/ai_assistant/editor/chat_markdown.gd")
const TASK_AUTO_COLLAPSE_WIDTH := 900.0
const TASK_RAIL_MIN := 250.0
const TASK_RAIL_MAX := 300.0
const CHAT_RAIL_MIN := 340.0
const CHAT_RAIL_MAX := 400.0
const TASK_DOCK_WIDTH := 260.0
const CHAT_DOCK_WIDTH := 360.0
const QUICK_START_SETTING := "ai_assistant/quick_start_dismissed"
const QUICK_START_TEXT := """连接设置已保存，可以开始使用 AI 工作台。

1. 保存场景
使用 Builder 前，请先创建并保存当前场景。

2. 选择目标节点
在 Godot 场景树中选中需要添加或修改脚本的节点。

3. 选择使用模式
• Builder：创建或修改脚本，并执行脚本绑定。
• Chat：询问 Godot 或 GDScript 问题，不会修改工程。

4. 描述完整任务
请说明脚本路径、需要实现的功能，以及是否绑定到当前节点。

示例：创建 res://player.gd，实现 WASD 移动，并把脚本绑定到当前选中的 CharacterBody2D 节点。

5. 检查生成结果
Builder 不会立即修改工程。请先检查代码、Diff 和节点操作。

6. 应用修改
确认无误后点击“应用全部”；不需要这些修改时点击“撤销全部”。

提示：如果需要自动绑定脚本，请在任务中明确写出“绑定到当前选中的节点”。"""

var controller: AIWorkbenchController
var _timeline: AITaskTimeline
var _preview: AIResultPreview
var _body_split: HSplitContainer
var _center_split: HSplitContainer
var _left_card: PanelContainer
var _chat_scroll: ScrollContainer
var _chat_messages: VBoxContainer
var _active_response: Variant = null
var _clear_button: Button
var _motion_toggle: CheckButton
var _latest_button: Button
var _follow_chat := true
var _scroll_pending := false
var _scroll_programmatic := false
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
var _task_panel_visible := true
var _task_panel_manually_set := false
var _layout_initialized := false

var _settings_window: Window
var _url_edit: LineEdit
var _key_edit: LineEdit
var _model_edit: LineEdit
var _max_tokens: SpinBox
var _max_tokens_unlimited: CheckBox
var _timeout: SpinBox
var _timeout_unlimited: CheckBox
var _stream: CheckBox
var _remember: CheckBox
var _system_prompt: TextEdit
var _server_models: OptionButton
var _models_refresh: Button
var _models_status: Label
var _settings_body_scroll: ScrollContainer
var _settings_footer: HBoxContainer
var _notice_dialog: AcceptDialog
var _quick_start_window: Window
var _quick_start_body: Label
var _quick_start_hide_check: CheckBox
var _quick_start_footer: HBoxContainer
var _model_fetching := false


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
	if active:
		call_deferred("_maybe_show_quick_start")
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
	if _notice_dialog != null:
		_notice_dialog.queue_free()
		_notice_dialog = null
	if _quick_start_window != null:
		_quick_start_window.queue_free()
		_quick_start_window = null


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
	_clear_button = clear
	clear.text = "清空"
	THEME.apply_button(clear, "ghost")
	clear.pressed.connect(_clear_chat)
	heading_row.add_child(clear)
	_motion_toggle = CheckButton.new()
	_motion_toggle.text = "动效"
	_motion_toggle.button_pressed = true
	_motion_toggle.add_theme_font_size_override("font_size", 11)
	_motion_toggle.tooltip_text = "开启或关闭呼吸、文字渐显和折叠动画"
	_motion_toggle.toggled.connect(_on_motion_toggled)
	heading_row.add_child(_motion_toggle)
	box.add_child(heading_row)

	var context_card := PanelContainer.new()
	context_card.add_theme_stylebox_override("panel", THEME.panel(Color("#243044"), 3))
	_context_text = Label.new()
	_context_text.text = "上下文：未选择节点"
	_context_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	THEME.apply_label(_context_text, true, 12)
	context_card.add_child(_context_text)
	box.add_child(context_card)

	_chat_scroll = ScrollContainer.new()
	_chat_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_chat_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chat_messages = VBoxContainer.new()
	_chat_messages.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_messages.add_theme_constant_override("separation", 12)
	_chat_scroll.add_child(_chat_messages)
	box.add_child(_chat_scroll)
	var scrollbar := _chat_scroll.get_v_scroll_bar()
	scrollbar.value_changed.connect(_on_chat_scrolled)
	scrollbar.changed.connect(_schedule_chat_scroll)
	_latest_button = Button.new()
	_latest_button.text = "↓ 回到最新回复"
	_latest_button.visible = false
	THEME.apply_button(_latest_button, "ghost")
	_latest_button.pressed.connect(func() -> void:
		_follow_chat = true
		_latest_button.hide()
		_schedule_chat_scroll()
	)
	box.add_child(_latest_button)

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
	controller.token_usage_threshold_reached.connect(_on_token_usage_threshold_reached)
	controller.response_stalled.connect(_on_response_stalled)
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
	if state in ["planning", "generating"]:
		_ensure_response()
	elif state in ["idle", "review", "done", "error", "cancelled"]:
		_finish_response(state)
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
	_clear_button.disabled = busy
	_clear_button.tooltip_text = "请先停止当前回复再清空" if busy else "清空当前会话"
	_refresh_review_bar()


func _on_message_added(role: String, text: String) -> void:
	if role == "user":
		_finish_response("idle")
		_follow_chat = true
		_append_message(role, text)
	elif role == "assistant":
		_ensure_response().set_answer(text)
	else:
		_append_message(role, text)


func _on_stream_text(text: String) -> void:
	if not text.is_empty():
		_ensure_response().append_answer(text)


func _on_reasoning_text(text: String) -> void:
	if not text.is_empty():
		_ensure_response().append_reasoning(text)


func _append_message(role: String, text: String) -> void:
	if _chat_messages == null or text.is_empty():
		return
	var card := _new_chat_card(role)
	card.set_answer(text)


func _new_chat_card(role: String) -> Variant:
	var card := CHAT_CARD.new()
	card.role = role
	card.animations_enabled = _motion_toggle.button_pressed
	_chat_messages.add_child(card)
	card.content_changed.connect(_schedule_chat_scroll)
	_schedule_chat_scroll()
	return card


func _ensure_response() -> Variant:
	if not is_instance_valid(_active_response):
		_active_response = _new_chat_card("assistant")
		_active_response.begin()
	return _active_response


func _finish_response(state: String) -> void:
	if is_instance_valid(_active_response):
		_active_response.finish(state)
	_active_response = null


func _on_motion_toggled(enabled: bool) -> void:
	for card in _chat_messages.get_children():
		card.set_animations(enabled)


func _on_chat_scrolled(value: float) -> void:
	if _scroll_programmatic or _scroll_pending:
		return
	var bar := _chat_scroll.get_v_scroll_bar()
	_follow_chat = value >= bar.max_value - bar.page - 28.0
	_latest_button.visible = not _follow_chat


func _schedule_chat_scroll() -> void:
	if _scroll_pending or not _follow_chat or _chat_scroll == null:
		return
	_scroll_pending = true
	_scroll_chat_after_layout.call_deferred()


func _scroll_chat_after_layout() -> void:
	# Containers settle after streamed text changes their minimum height.
	await get_tree().process_frame
	if not is_inside_tree():
		return
	if _follow_chat:
		_scroll_programmatic = true
		_chat_scroll.scroll_vertical = int(_chat_scroll.get_v_scroll_bar().max_value)
		_scroll_programmatic = false
	_scroll_pending = false


func _clear_chat() -> void:
	if controller.is_busy():
		return
	_finish_response("cancelled")
	for card in _chat_messages.get_children():
		_chat_messages.remove_child(card)
		card.queue_free()
	_follow_chat = true
	_latest_button.hide()
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


func _attach_quick_start_window() -> void:
	if _quick_start_window == null:
		return
	var host := _settings_host()
	if host == null or _quick_start_window.get_parent() == host:
		return
	if _quick_start_window.get_parent() != null:
		_quick_start_window.get_parent().remove_child(_quick_start_window)
	host.add_child(_quick_start_window)


func _build_settings_window() -> void:
	_settings_window = Window.new()
	_settings_window.title = "AI 工作台设置"
	var editor_scale := maxf(EditorInterface.get_editor_scale(), 1.0) if Engine.is_editor_hint() else 1.0
	_settings_window.content_scale_factor = editor_scale
	var settings_size := Vector2i(roundi(560 * editor_scale), roundi(620 * editor_scale))
	var settings_minimum := Vector2i(roundi(360 * editor_scale), roundi(360 * editor_scale))
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
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	panel.add_child(margin)
	var layout := VBoxContainer.new()
	layout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_theme_constant_override("separation", 10)
	margin.add_child(layout)
	_settings_body_scroll = ScrollContainer.new()
	_settings_body_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_settings_body_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_settings_body_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_settings_body_scroll.follow_focus = true
	layout.add_child(_settings_body_scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 8)
	_settings_body_scroll.add_child(box)
	var heading := Label.new()
	heading.text = "模型连接"
	THEME.apply_label(heading, false, 18)
	box.add_child(heading)
	var note := Label.new()
	note.text = "API Key 默认只保存在当前 Godot 会话。"
	THEME.apply_label(note, true, 12)
	box.add_child(note)
	var fields := VBoxContainer.new()
	fields.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fields.add_theme_constant_override("separation", 6)
	box.add_child(fields)
	_url_edit = _settings_line(fields, "Base URL", "https://api.deepseek.com")
	_key_edit = _settings_line(fields, "API Key", "sk-...")
	_key_edit.secret = true
	_model_edit = _settings_line(fields, "模型", "deepseek-chat")
	_max_tokens = _settings_spin(fields, "max_tokens", 1, 131072, 1)
	_max_tokens_unlimited = _settings_unlimited_toggle(
		fields,
		"无上限（不向模型服务发送 max_tokens）",
		_max_tokens,
	)
	_timeout = _settings_spin(fields, "最大响应时间（秒）", 5, 600, 1)
	_timeout_unlimited = _settings_unlimited_toggle(
		fields,
		"无上限（300 秒无响应时仅提醒，不中断）",
		_timeout,
	)
	_url_edit.text_changed.connect(func(_text: String) -> void: _update_model_query_state())
	_key_edit.text_changed.connect(func(_text: String) -> void: _update_model_query_state())
	var server_label := Label.new()
	server_label.text = "服务器模型"
	THEME.apply_label(server_label, true, 12)
	box.add_child(server_label)
	var model_row := HBoxContainer.new()
	model_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_server_models = OptionButton.new()
	_server_models.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_server_models.fit_to_longest_item = false
	_server_models.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_server_models.add_theme_font_size_override("font_size", 13)
	_server_models.item_selected.connect(func(index: int) -> void:
		if index >= 0:
			_model_edit.text = _server_models.get_item_text(index)
	)
	model_row.add_child(_server_models)
	_models_refresh = Button.new()
	_models_refresh.text = "刷新"
	THEME.apply_button(_models_refresh, "ghost")
	_models_refresh.pressed.connect(_request_models)
	model_row.add_child(_models_refresh)
	box.add_child(model_row)
	_models_status = Label.new()
	_models_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_models_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_models_status.max_lines_visible = 2
	_models_status.custom_minimum_size.x = 0
	THEME.apply_label(_models_status, true, 11)
	box.add_child(_models_status)
	_stream = CheckBox.new()
	_stream.text = "Chat 使用流式输出"
	_stream.add_theme_font_size_override("font_size", 13)
	box.add_child(_stream)
	_remember = CheckBox.new()
	_remember.text = "记住 API Key（明文写入 Godot 编辑器配置）"
	_remember.add_theme_font_size_override("font_size", 13)
	box.add_child(_remember)
	var prompt_label := Label.new()
	prompt_label.text = "Chat 系统提示词"
	THEME.apply_label(prompt_label, true, 12)
	box.add_child(prompt_label)
	_system_prompt = TextEdit.new()
	_system_prompt.custom_minimum_size = Vector2(0, 120)
	THEME.apply_line_edit(_system_prompt)
	box.add_child(_system_prompt)
	_settings_footer = HBoxContainer.new()
	_settings_footer.custom_minimum_size.y = 34
	var cancel := Button.new()
	cancel.text = "取消"
	THEME.apply_button(cancel, "ghost")
	cancel.pressed.connect(_settings_window.hide)
	_settings_footer.add_child(cancel)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_settings_footer.add_child(spacer)
	var save := Button.new()
	save.text = "保存设置"
	THEME.apply_button(save, "primary")
	save.pressed.connect(_save_settings)
	_settings_footer.add_child(save)
	layout.add_child(_settings_footer)


func _build_quick_start_window() -> void:
	if _quick_start_window != null and is_instance_valid(_quick_start_window):
		_attach_quick_start_window()
		return
	_quick_start_window = Window.new()
	_quick_start_window.title = "AI 工作台快速上手"
	var editor_scale := maxf(EditorInterface.get_editor_scale(), 1.0) if Engine.is_editor_hint() else 1.0
	_quick_start_window.content_scale_factor = editor_scale
	var guide_size := Vector2i(roundi(560 * editor_scale), roundi(600 * editor_scale))
	var guide_minimum := Vector2i(roundi(360 * editor_scale), roundi(360 * editor_scale))
	if Engine.is_editor_hint():
		var usable := DisplayServer.screen_get_usable_rect(DisplayServer.SCREEN_OF_MAIN_WINDOW)
		if usable.size.x > 0 and usable.size.y > 0:
			var available := Vector2i(maxi(1, usable.size.x - 40), maxi(1, usable.size.y - 40))
			guide_size = guide_size.min(available)
			guide_minimum = guide_minimum.min(available)
	_quick_start_window.size = guide_size
	_quick_start_window.min_size = guide_minimum
	_quick_start_window.wrap_controls = false
	_quick_start_window.transient = true
	_quick_start_window.exclusive = false
	_quick_start_window.unresizable = false
	_quick_start_window.visible = false
	_quick_start_window.close_requested.connect(_close_quick_start)
	_attach_quick_start_window()

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_theme_stylebox_override("panel", THEME.panel(THEME.BG, 0))
	_quick_start_window.add_child(panel)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 14)
	panel.add_child(margin)
	var layout := VBoxContainer.new()
	layout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_theme_constant_override("separation", 10)
	margin.add_child(layout)
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	layout.add_child(scroll)
	_quick_start_body = Label.new()
	_quick_start_body.text = QUICK_START_TEXT
	_quick_start_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_quick_start_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_quick_start_body.custom_minimum_size.x = 0
	THEME.apply_label(_quick_start_body, false, 13)
	scroll.add_child(_quick_start_body)
	_quick_start_footer = HBoxContainer.new()
	_quick_start_footer.custom_minimum_size.y = 34
	_quick_start_hide_check = CheckBox.new()
	_quick_start_hide_check.text = "不再提示"
	_quick_start_hide_check.add_theme_font_size_override("font_size", 13)
	_quick_start_footer.add_child(_quick_start_hide_check)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_quick_start_footer.add_child(spacer)
	var close := Button.new()
	close.text = "我知道了"
	THEME.apply_button(close, "primary")
	close.pressed.connect(_close_quick_start)
	_quick_start_footer.add_child(close)
	layout.add_child(_quick_start_footer)


func _maybe_show_quick_start() -> void:
	if not _active or controller == null or not controller.is_configured():
		return
	if Engine.is_editor_hint():
		var settings := EditorInterface.get_editor_settings()
		var dismissed := (
			bool(settings.get_setting(QUICK_START_SETTING))
			if settings.has_setting(QUICK_START_SETTING)
			else false
		)
		if dismissed:
			return
	_show_quick_start()


func _show_quick_start() -> void:
	_build_quick_start_window()
	_quick_start_hide_check.button_pressed = false
	_quick_start_window.popup_centered(_quick_start_window.size)


func _close_quick_start() -> void:
	if _quick_start_window == null:
		return
	if _quick_start_hide_check != null and _quick_start_hide_check.button_pressed and Engine.is_editor_hint():
		EditorInterface.get_editor_settings().set_setting(QUICK_START_SETTING, true)
	_quick_start_window.hide()


func _settings_line(container: VBoxContainer, label_text: String, placeholder: String) -> LineEdit:
	var label := Label.new()
	label.text = label_text
	THEME.apply_label(label, true, 12)
	container.add_child(label)
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.custom_minimum_size.x = 0
	THEME.apply_line_edit(edit)
	container.add_child(edit)
	return edit


func _settings_spin(
	container: VBoxContainer,
	label_text: String,
	minimum: float,
	maximum: float,
	step: float,
) -> SpinBox:
	var label := Label.new()
	label.text = label_text
	THEME.apply_label(label, true, 12)
	container.add_child(label)
	var spin := SpinBox.new()
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.custom_minimum_size.x = 0
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.get_line_edit().add_theme_font_size_override("font_size", 13)
	container.add_child(spin)
	return spin


func _settings_unlimited_toggle(
	container: VBoxContainer,
	text: String,
	spin: SpinBox,
) -> CheckBox:
	var toggle := CheckBox.new()
	toggle.text = text
	toggle.add_theme_font_size_override("font_size", 12)
	toggle.toggled.connect(func(enabled: bool) -> void: spin.editable = not enabled)
	container.add_child(toggle)
	return toggle


func _fill_settings() -> void:
	var config := controller.get_config()
	_url_edit.text = String(config.get("base_url", ""))
	_key_edit.text = String(config.get("api_key", ""))
	_model_edit.text = String(config.get("model", ""))
	var configured_max_tokens := int(config.get("max_tokens", 0))
	_max_tokens.value = configured_max_tokens if configured_max_tokens > 0 else 4096
	_max_tokens_unlimited.button_pressed = configured_max_tokens <= 0
	_max_tokens.editable = not _max_tokens_unlimited.button_pressed
	var configured_timeout := float(config.get("timeout", 60.0))
	_timeout.value = configured_timeout if configured_timeout > 0.0 else 60.0
	_timeout_unlimited.button_pressed = configured_timeout <= 0.0
	_timeout.editable = not _timeout_unlimited.button_pressed
	_stream.button_pressed = bool(config.get("stream", true))
	_system_prompt.text = String(config.get("system_prompt", ""))
	var settings := EditorInterface.get_editor_settings()
	_remember.button_pressed = (
		bool(settings.get_setting("ai_assistant/remember_api_key"))
		if settings.has_setting("ai_assistant/remember_api_key")
		else false
	)
	_update_model_query_state()


func _connection_form_issue() -> String:
	var url := _url_edit.text.strip_edges()
	var key := _key_edit.text.strip_edges()
	if url.is_empty():
		return "请先填写 Base URL。"
	if not (url.begins_with("https://") or url.begins_with("http://")):
		return "Base URL 需以 http:// 或 https:// 开头。"
	var without_scheme := url.substr(url.find("://") + 3)
	if without_scheme.get_slice("/", 0).strip_edges().is_empty():
		return "Base URL 缺少服务器地址。"
	if key.is_empty():
		return "请先填写 API Key。"
	if key.length() < 8 or key.contains(" "):
		return "API Key 看起来不完整。"
	return ""


func _update_model_query_state(update_message := true) -> void:
	if _models_refresh == null or _models_status == null:
		return
	var issue := _connection_form_issue()
	_models_refresh.disabled = _model_fetching or not issue.is_empty()
	if update_message and not _model_fetching:
		_models_status.text = issue if not issue.is_empty() else "连接信息完整，可以查询模型。"


func _request_models() -> void:
	var issue := _connection_form_issue()
	if not issue.is_empty():
		_models_status.text = issue
		_update_model_query_state(false)
		return
	_model_fetching = true
	_models_refresh.disabled = true
	_server_models.clear()
	_server_models.add_item("正在查询…")
	_models_status.text = "正在查询服务器模型…"
	controller.fetch_models(_key_edit.text.strip_edges(), _url_edit.text.strip_edges())


func _save_settings() -> void:
	controller.save_config({
		"base_url": _url_edit.text,
		"api_key": _key_edit.text,
		"model": _model_edit.text,
		"max_tokens": 0 if _max_tokens_unlimited.button_pressed else int(_max_tokens.value),
		"timeout": 0.0 if _timeout_unlimited.button_pressed else _timeout.value,
		"stream": _stream.button_pressed,
		"system_prompt": _system_prompt.text,
	}, _remember.button_pressed)
	_model_text.text = _model_edit.text if not _model_edit.text.is_empty() else "未配置模型"
	_settings_window.hide()
	_on_state_changed(controller.state_key, "设置已保存")
	call_deferred("_maybe_show_quick_start")


func _on_models_loaded(models: Array, error_message: String) -> void:
	_model_fetching = false
	_server_models.clear()
	if not error_message.is_empty():
		var compact := _compact_model_error(error_message)
		_server_models.add_item("获取失败")
		_models_status.text = compact
		_models_status.tooltip_text = error_message
		_update_model_query_state(false)
		return
	for model in models:
		_server_models.add_item(String(model))
	if not models.is_empty():
		_model_edit.text = String(models[0])
		_models_status.text = "已获取 %d 个模型。" % models.size()
	else:
		_server_models.add_item("未返回模型")
		_models_status.text = "服务器没有返回模型，可手动填写模型名。"
	_models_status.tooltip_text = ""
	_update_model_query_state(false)


func _on_token_usage_threshold_reached(total_tokens: int, threshold: int) -> void:
	_show_notice(
		"Token 使用提醒",
		"累计 Token 消耗已超过 %s。\n当前累计：%s。\n\n此提醒每增加一千万 Token 显示一次。" % [
			_format_integer(threshold),
			_format_integer(total_tokens),
		],
	)


func _on_response_stalled(elapsed_seconds: int) -> void:
	_show_notice(
		"响应时间过长",
		"工作区已连续 %d 秒没有收到模型响应。\n\n请求仍在继续；你可以继续等待，或点击工作台中的“停止”。" % elapsed_seconds,
	)


func _show_notice(title: String, message: String) -> void:
	if _notice_dialog == null or not is_instance_valid(_notice_dialog):
		_notice_dialog = AcceptDialog.new()
		_notice_dialog.ok_button_text = "知道了"
		_notice_dialog.min_size = Vector2i(420, 180)
		var host := _settings_host()
		if host != null:
			host.add_child(_notice_dialog)
	_notice_dialog.title = title
	_notice_dialog.dialog_text = message
	_notice_dialog.popup_centered(Vector2i(460, 210))


func _format_integer(value: int) -> String:
	var raw := str(absi(value))
	var grouped := ""
	while raw.length() > 3:
		grouped = "," + raw.right(3) + grouped
		raw = raw.left(raw.length() - 3)
	return ("-" if value < 0 else "") + raw + grouped


func _compact_model_error(error_message: String) -> String:
	var one_line := error_message.replace("\r", " ").replace("\n", " ").strip_edges()
	var lower := one_line.to_lower()
	if lower.contains("http 401") or lower.contains("401"):
		return "API Key 无效或未发送（HTTP 401）。"
	if lower.contains("http 403") or lower.contains("403"):
		return "当前 API Key 没有访问权限（HTTP 403）。"
	if lower.contains("http 404") or lower.contains("404"):
		return "模型列表地址不存在（HTTP 404）。"
	if lower.contains("http 429") or lower.contains("429"):
		return "请求过于频繁或额度不足（HTTP 429）。"
	if lower.contains("result=") or lower.contains("连接") or lower.contains("network"):
		return "无法连接服务器，请检查网络和 Base URL。"
	if one_line.length() > 72:
		return one_line.left(69) + "…"
	return one_line


func _markdown_to_bbcode(text: String) -> String:
	return CHAT_MARKDOWN.render(text)


func _escape_bbcode(text: String) -> String:
	return CHAT_MARKDOWN.escape_bbcode(text)


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
