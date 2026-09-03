@tool
extends VBoxContainer
## A review-first AI task surface. The model may plan and propose, but never writes directly.

const CLIENT_SCRIPT := preload("res://addons/ai_assistant/client/llm_client.gd")
const PARSER := preload("res://addons/ai_assistant/agent/proposal_parser.gd")
const STORE := preload("res://addons/ai_assistant/agent/proposal_store.gd")
const PROPOSAL_PANEL := preload("res://addons/ai_assistant/editor/proposal_panel.gd")
const SCENE_CONTEXT := preload("res://addons/ai_assistant/editor/scene_context.gd")
const SESSION_CONFIG := preload("res://addons/ai_assistant/editor/session_config.gd")

var _client: AILLMClient
var _store: AIProposalStore
var _input: TextEdit
var _context: TextEdit
var _status: Label
var _run: Button
var _stop: Button
var _plan_view: RichTextLabel
var _attach_check: CheckBox
var _attach_node: Node


func _ready() -> void:
	name = "AI 任务"
	add_theme_constant_override("separation", 8)
	_client = CLIENT_SCRIPT.new()
	add_child(_client)
	_client.stream = false
	_client.request_finished.connect(_on_finished)
	_store = STORE.new()
	_store.error.connect(_show_error)
	_store.applied.connect(_on_proposal_applied)
	_build_ui()
	_load_config()


func _build_ui() -> void:
	var title := Label.new()
	title.text = "AI 任务"
	title.add_theme_font_size_override("font_size", 16)
	add_child(title)
	var description := Label.new()
	description.text = "先生成计划和脚本提案，确认后才写入项目。"
	description.modulate = Color("9ca3af")
	add_child(description)
	_input = TextEdit.new()
	_input.placeholder_text = "描述要完成的 Godot 脚本任务…"
	_input.custom_minimum_size = Vector2(0, 90)
	_input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	add_child(_input)
	var context_label := Label.new()
	context_label.text = "上下文（可编辑）"
	add_child(context_label)
	_context = TextEdit.new()
	_context.placeholder_text = "可选择场景节点后自动填入，或补充约束。"
	_context.custom_minimum_size = Vector2(0, 80)
	_context.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	add_child(_context)
	var controls := HBoxContainer.new()
	var node_context := Button.new()
	node_context.text = "读取当前节点"
	node_context.pressed.connect(_load_selected_node)
	controls.add_child(node_context)
	_attach_check = CheckBox.new()
	_attach_check.text = "应用后挂载"
	_attach_check.tooltip_text = "仅在“当前节点脚本提案”任务中使用；应用脚本后将它挂载到所选节点，场景仍需由你保存。"
	controls.add_child(_attach_check)
	_run = Button.new()
	_run.text = "生成计划"
	_run.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_run.pressed.connect(_run_plan)
	controls.add_child(_run)
	_stop = Button.new()
	_stop.text = "停止"
	_stop.disabled = true
	_stop.pressed.connect(func() -> void: _client.cancel())
	controls.add_child(_stop)
	add_child(controls)
	_plan_view = RichTextLabel.new()
	_plan_view.bbcode_enabled = true
	_plan_view.custom_minimum_size = Vector2(0, 80)
	_plan_view.fit_content = true
	_plan_view.scroll_active = false
	add_child(_plan_view)
	var proposals: AIProposalPanel = PROPOSAL_PANEL.new()
	proposals.set_store(_store)
	proposals.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(proposals)
	_status = Label.new()
	_status.modulate = Color("9ca3af")
	add_child(_status)


func open_node_script_task(node: Node) -> void:
	_load_selected_node(node)
	_input.text = "为当前节点创建或更新脚本。根据节点类型、信号和子节点实现合理的基础行为。"


func _load_selected_node(explicit_node: Node = null) -> void:
	var node := explicit_node
	if node == null and Engine.is_editor_hint():
		var selection := EditorInterface.get_selection()
		var selected := selection.get_selected_nodes() if selection != null else []
		if not selected.is_empty() and selected[0] is Node:
			node = selected[0]
	if node == null:
		_show_error("请先在场景树中选择一个节点。")
		return
	_attach_node = node
	_context.text = SCENE_CONTEXT.from_node(node)
	_show_status("已读取节点上下文：%s" % node.name)


func _load_config() -> void:
	var settings := EditorInterface.get_editor_settings()
	_client.base_url = String(_setting_value(settings, "ai_assistant/base_url", ""))
	_client.api_key = String(_setting_value(settings, "ai_assistant/api_key", ""))
	_client.model = String(_setting_value(settings, "ai_assistant/model", ""))
	_client.temperature = float(_setting_value(settings, "ai_assistant/temperature", 0.2))
	_client.max_tokens = int(_setting_value(settings, "ai_assistant/max_tokens", 0))
	_client.timeout_seconds = float(_setting_value(settings, "ai_assistant/timeout", 90.0))
	_client.system_prompt = "你是谨慎的 Godot 4.x 编程助手。只提供可审查的 JSON 脚本提案。"
	SESSION_CONFIG.apply_to(_client)


func _setting_value(settings: EditorSettings, key: String, fallback: Variant) -> Variant:
	return settings.get_setting(key) if settings.has_setting(key) else fallback


func _run_plan() -> void:
	var request := _input.text.strip_edges()
	if request.is_empty():
		_show_error("请先描述任务。")
		return
	_load_config()
	if _client.api_key.is_empty() or _client.base_url.is_empty() or _client.model.is_empty():
		_show_error("请先在 AI 助手设置中填写 Base URL、API Key 和模型。")
		return
	_store.begin_session()
	_plan_view.clear()
	_show_status("正在生成计划与改动提案…")
	_run.disabled = true
	_stop.disabled = false
	_client.chat(PARSER.planning_prompt(request, _context.text.strip_edges()))


func _on_finished(success: bool, error_message: String) -> void:
	_run.disabled = false
	_stop.disabled = true
	if not success:
		_show_error(error_message)
		return
	var parsed := PARSER.parse(_client.last_response_text)
	if parsed.has("error"):
		_show_error(String(parsed.error))
		return
	var steps: Array = parsed.get("plan", [])
	_store.plan = steps.duplicate()
	var added := _store.add_changes(parsed.get("changes", []))
	var lines := PackedStringArray(["[b]计划[/b]"])
	for i in range(steps.size()):
		lines.append("%d. %s" % [i + 1, String(steps[i])])
	_plan_view.append_text("\n".join(lines))
	_show_status("已生成 %d 项待审查改动。" % added)


func _on_proposal_applied(proposal: Dictionary) -> void:
	if _attach_check == null or not _attach_check.button_pressed or not is_instance_valid(_attach_node):
		return
	if String(proposal.get("action", "")) == "delete":
		return
	var script := load(String(proposal.get("path", "")))
	if script is Script:
		_attach_node.set_script(script)
		_show_status("脚本已应用并挂载到节点 %s；请保存场景。" % _attach_node.name)


func _show_error(message: String) -> void:
	_status.text = "错误：" + message
	_status.modulate = Color("f87171")


func _show_status(message: String) -> void:
	_status.text = message
	_status.modulate = Color("9ca3af")
