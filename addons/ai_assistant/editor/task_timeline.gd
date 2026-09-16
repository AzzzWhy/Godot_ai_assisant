@tool
class_name AITaskTimeline
extends VBoxContainer
## Left rail: locked editor context and the current Builder lifecycle.

const THEME := preload("res://addons/ai_assistant/editor/ui_theme.gd")

var _controller: AIWorkbenchController
var _context_title: Label
var _context_body: Label
var _state_list: VBoxContainer
var _plan_list: VBoxContainer


func _ready() -> void:
	custom_minimum_size = Vector2(240, 0)
	add_theme_constant_override("separation", 8)
	_build_ui()


func set_controller(controller: AIWorkbenchController) -> void:
	_controller = controller
	if not _controller.state_changed.is_connected(_on_state_changed):
		_controller.state_changed.connect(_on_state_changed)
	if not _controller.draft_changed.is_connected(_render):
		_controller.draft_changed.connect(_render)
	if not _controller.context_changed.is_connected(_on_context_changed):
		_controller.context_changed.connect(_on_context_changed)
	_render()


func _build_ui() -> void:
	var heading := Label.new()
	heading.text = "任务"
	THEME.apply_label(heading, false, 13)
	add_child(heading)

	var context_card := PanelContainer.new()
	context_card.add_theme_stylebox_override("panel", THEME.panel(THEME.BG_CARD, 3))
	var context_box := VBoxContainer.new()
	context_box.add_theme_constant_override("separation", 5)
	context_card.add_child(context_box)
	_context_title = Label.new()
	_context_title.text = "编辑器上下文"
	THEME.apply_label(_context_title, false, 13)
	context_box.add_child(_context_title)
	_context_body = Label.new()
	_context_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	THEME.apply_label(_context_body, true, 12)
	context_box.add_child(_context_body)
	add_child(context_card)

	var flow_label := Label.new()
	flow_label.text = "工作流"
	THEME.apply_label(flow_label, true, 12)
	add_child(flow_label)
	_state_list = VBoxContainer.new()
	_state_list.add_theme_constant_override("separation", 4)
	add_child(_state_list)

	var divider := HSeparator.new()
	divider.modulate = THEME.BORDER
	add_child(divider)
	var plan_label := Label.new()
	plan_label.text = "执行计划"
	THEME.apply_label(plan_label, true, 12)
	add_child(plan_label)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	_plan_list = VBoxContainer.new()
	_plan_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_plan_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_plan_list)


func _render() -> void:
	if _controller == null or _state_list == null:
		return
	_render_context(_controller.captured_context)
	_clear(_state_list)
	var states := [
		["planning", "理解任务"],
		["generating", "生成改动"],
		["review", "审查结果"],
		["applying", "应用并保存"],
		["done", "任务完成"],
	]
	var current_index := _state_index(_controller.state_key)
	for i in range(states.size()):
		var state: Array = states[i]
		var state_name := String(state[0])
		var label := String(state[1])
		var status := "pending"
		if _controller.state_key == "error":
			status = "error" if i == maxi(0, current_index) else ("done" if i < current_index else "pending")
		elif i < current_index:
			status = "done"
		elif state_name == _controller.state_key:
			status = "active"
		_state_list.add_child(_state_row(label, status))
	_clear(_plan_list)
	if _controller.store == null or _controller.store.plan.is_empty():
		var empty := Label.new()
		empty.text = "提交 Builder 任务后，计划会显示在这里。"
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		THEME.apply_label(empty, true, 12)
		_plan_list.add_child(empty)
		return
	for i in range(_controller.store.plan.size()):
		var row := PanelContainer.new()
		row.add_theme_stylebox_override("panel", THEME.panel(THEME.BG_MUTED, 7))
		var text := Label.new()
		text.text = "%d  %s" % [i + 1, String(_controller.store.plan[i])]
		text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		THEME.apply_label(text, false, 12)
		row.add_child(text)
		_plan_list.add_child(row)
	for operation in _controller.store.node_operations:
		var op := PanelContainer.new()
		op.add_theme_stylebox_override("panel", THEME.panel(Color("#10243a"), 7))
		var op_text := Label.new()
		op_text.text = "节点  " + String(operation.get("summary", "挂载脚本"))
		op_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		THEME.apply_label(op_text, false, 12)
		op.add_child(op_text)
		_plan_list.add_child(op)


func _render_context(context: Dictionary) -> void:
	if _context_body == null:
		return
	var node_name := String(context.get("selected_node_name", ""))
	var node_type := String(context.get("selected_node_type", ""))
	var scene_path := String(context.get("scene_path", ""))
	var script_path := String(context.get("script_path", ""))
	var lines := PackedStringArray()
	lines.append("节点：%s%s" % [
		node_name if not node_name.is_empty() else "未选择",
		" · " + node_type if not node_type.is_empty() else "",
	])
	lines.append("场景：%s" % (scene_path.get_file() if not scene_path.is_empty() else "未保存"))
	lines.append("脚本：%s" % (script_path.get_file() if not script_path.is_empty() else "无"))
	_context_body.text = "\n".join(lines)


func _on_state_changed(_state: String, _message: String) -> void:
	_render()


func _on_context_changed(context: Dictionary) -> void:
	_render_context(context)


func _state_row(text: String, status: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var dot := Label.new()
	match status:
		"done":
			dot.text = "●"
			dot.add_theme_color_override("font_color", THEME.SUCCESS)
		"active":
			dot.text = "●"
			dot.add_theme_color_override("font_color", THEME.ACCENT)
		"error":
			dot.text = "●"
			dot.add_theme_color_override("font_color", THEME.DANGER)
		_:
			dot.text = "○"
			dot.add_theme_color_override("font_color", THEME.FG_MUTED)
	row.add_child(dot)
	var label := Label.new()
	label.text = text
	THEME.apply_label(label, status == "pending", 12)
	row.add_child(label)
	return row


func _state_index(state: String) -> int:
	match state:
		"planning":
			return 0
		"generating":
			return 1
		"review":
			return 2
		"applying":
			return 3
		"done":
			return 4
		"error":
			return 2
		_:
			return -1


func _clear(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()
