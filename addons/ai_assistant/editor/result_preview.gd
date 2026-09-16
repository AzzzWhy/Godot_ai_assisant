@tool
class_name AIResultPreview
extends VBoxContainer
## Dedicated result surface: files, full source comparison, unified diff and node operations.

const THEME := preload("res://addons/ai_assistant/editor/ui_theme.gd")
const DIFF_VIEW := preload("res://addons/ai_assistant/editor/diff_view.gd")

var _controller: AIWorkbenchController
var _summary: Label
var _count_badge: Label
var _files: ItemList
var _before: CodeEdit
var _after: CodeEdit
var _diff: AIDiffView
var _tabs: TabContainer
var _node_list: VBoxContainer
var _empty: CenterContainer
var _content: HSplitContainer
var _compare: HSplitContainer


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 10)
	_build_ui()


func set_controller(controller: AIWorkbenchController) -> void:
	_controller = controller
	if not _controller.draft_changed.is_connected(_render):
		_controller.draft_changed.connect(_render)
	if not _controller.state_changed.is_connected(_on_state_changed):
		_controller.state_changed.connect(_on_state_changed)
	_render()


func _build_ui() -> void:
	var header := HBoxContainer.new()
	var title := Label.new()
	title.text = "生成结果"
	THEME.apply_label(title, false, 13)
	header.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	_count_badge = Label.new()
	THEME.apply_label(_count_badge, true, 12)
	header.add_child(_count_badge)
	add_child(header)
	_summary = Label.new()
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	THEME.apply_label(_summary, true, 13)
	add_child(_summary)

	_empty = CenterContainer.new()
	_empty.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var empty_box := VBoxContainer.new()
	empty_box.alignment = BoxContainer.ALIGNMENT_CENTER
	var empty_title := Label.new()
	empty_title.text = "结果会显示在这里"
	empty_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	THEME.apply_label(empty_title, false, 14)
	empty_box.add_child(empty_title)
	var empty_body := Label.new()
	empty_body.text = "在右侧选择 Builder，输入一句完整任务。\n脚本和节点操作生成后会先进入审查，不会立即写入。"
	empty_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	empty_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	THEME.apply_label(empty_body, true, 13)
	empty_box.add_child(empty_body)
	_empty.add_child(empty_box)
	add_child(_empty)

	_content = HSplitContainer.new()
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.visible = false
	_content.resized.connect(_update_split_layout)
	add_child(_content)
	var file_card := PanelContainer.new()
	file_card.custom_minimum_size = Vector2(180, 0)
	file_card.add_theme_stylebox_override("panel", THEME.panel(THEME.BG_CARD, 3))
	var file_box := VBoxContainer.new()
	file_box.add_theme_constant_override("separation", 6)
	file_card.add_child(file_box)
	var files_title := Label.new()
	files_title.text = "改动文件"
	THEME.apply_label(files_title, true, 12)
	file_box.add_child(files_title)
	_files = ItemList.new()
	_files.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_files.item_selected.connect(_show_file)
	file_box.add_child(_files)
	_content.add_child(file_card)

	_tabs = TabContainer.new()
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_child(_tabs)
	_compare = HSplitContainer.new()
	_compare.name = "完整代码"
	_compare.resized.connect(_update_split_layout)
	_before = _code_view()
	_after = _code_view()
	_compare.add_child(_code_panel("修改前", _before, Color("#2b171a")))
	_compare.add_child(_code_panel("生成后", _after, Color("#122117")))
	_tabs.add_child(_compare)

	_diff = DIFF_VIEW.new()
	_diff.name = "Diff"
	_diff.fit_content = false
	_diff.scroll_active = true
	_diff.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_diff.add_theme_color_override("default_color", THEME.FG)
	_tabs.add_child(_diff)

	var operations_scroll := ScrollContainer.new()
	operations_scroll.name = "节点操作"
	operations_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_node_list = VBoxContainer.new()
	_node_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_node_list.add_theme_constant_override("separation", 8)
	operations_scroll.add_child(_node_list)
	_tabs.add_child(operations_scroll)
	call_deferred("_update_split_layout")


func _update_split_layout() -> void:
	if _content != null and _content.size.x > 0.0:
		var file_width := clampf(_content.size.x * 0.28, 180.0, 240.0)
		_content.split_offset = int(round(file_width))
	if _compare != null and _compare.size.x > 0.0:
		_compare.split_offset = int(round(_compare.size.x * 0.5))


func _render() -> void:
	if _controller == null or _files == null:
		return
	var proposals := _controller.store.proposals
	var has_results := not proposals.is_empty()
	_empty.visible = not has_results
	_content.visible = has_results
	_summary.text = _controller.store.summary if has_results else ""
	_count_badge.text = ("%d 个文件 · %d 个节点操作" % [
		proposals.size(),
		_controller.store.node_operations.size(),
	]) if has_results else ""
	_files.clear()
	for i in range(proposals.size()):
		var proposal: Dictionary = proposals[i]
		var action := String(proposal.get("action", "update")).to_upper()
		var status := String(proposal.get("status", "pending"))
		_files.add_item("%s   %s\n%s" % [
			action,
			String(proposal.get("path", "")).get_file(),
			_status_text(status),
		])
		_files.set_item_metadata(i, i)
		_files.set_item_tooltip(i, String(proposal.get("path", "")))
	_render_node_operations()
	if has_results:
		_files.select(0)
		_show_file(0)
	else:
		_before.text = ""
		_after.text = ""
		_diff.clear()


func _show_file(item_index: int) -> void:
	if _controller == null or item_index < 0:
		return
	var proposal_index := int(_files.get_item_metadata(item_index))
	if proposal_index < 0 or proposal_index >= _controller.store.proposals.size():
		return
	var proposal: Dictionary = _controller.store.proposals[proposal_index]
	var before := String(proposal.get("before", ""))
	var after := String(proposal.get("content", ""))
	var path := String(proposal.get("path", ""))
	_before.text = before
	_after.text = after
	_highlight_changes(before, after)
	_diff.render_diff(_unified_diff(before, after, path))


func _render_node_operations() -> void:
	_clear(_node_list)
	if _controller.store.node_operations.is_empty():
		var none := Label.new()
		none.text = "本轮没有节点操作。"
		THEME.apply_label(none, true, 13)
		_node_list.add_child(none)
		return
	var target_name := String(_controller.captured_context.get("selected_node_name", "选中节点"))
	var target_type := String(_controller.captured_context.get("selected_node_type", "Node"))
	for operation in _controller.store.node_operations:
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", THEME.panel(Color("#10243a"), 8))
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 5)
		card.add_child(box)
		var heading := Label.new()
		heading.text = "绑定脚本到节点"
		THEME.apply_label(heading, false, 14)
		box.add_child(heading)
		var detail := Label.new()
		detail.text = "%s (%s)\n← %s" % [
			target_name,
			target_type,
			String(operation.get("script_path", "")),
		]
		detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		THEME.apply_label(detail, true, 12)
		box.add_child(detail)
		_node_list.add_child(card)


func _code_view() -> CodeEdit:
	var code := CodeEdit.new()
	code.editable = false
	code.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	code.size_flags_vertical = Control.SIZE_EXPAND_FILL
	code.wrap_mode = TextEdit.LINE_WRAPPING_NONE
	code.highlight_current_line = false
	code.minimap_draw = false
	code.gutters_draw_line_numbers = true
	code.add_theme_color_override("background_color", THEME.BG_INSET)
	code.add_theme_color_override("font_color", THEME.FG)
	return code


func _code_panel(title_text: String, code: CodeEdit, tint: Color) -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", THEME.panel(tint, 8))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	panel.add_child(box)
	var title := Label.new()
	title.text = title_text
	THEME.apply_label(title, true, 12)
	box.add_child(title)
	box.add_child(code)
	return panel


func _highlight_changes(before: String, after: String) -> void:
	for line in range(_before.get_line_count()):
		_before.set_line_background_color(line, Color(0, 0, 0, 0))
	for line in range(_after.get_line_count()):
		_after.set_line_background_color(line, Color(0, 0, 0, 0))
	var old_lines := before.split("\n")
	var new_lines := after.split("\n")
	var limit := maxi(old_lines.size(), new_lines.size())
	for i in range(limit):
		var old_line := String(old_lines[i]) if i < old_lines.size() else ""
		var new_line := String(new_lines[i]) if i < new_lines.size() else ""
		if old_line == new_line and i < old_lines.size() and i < new_lines.size():
			continue
		if i < _before.get_line_count():
			_before.set_line_background_color(i, Color("#f8514930"))
		if i < _after.get_line_count():
			_after.set_line_background_color(i, Color("#3fb95030"))


func _unified_diff(before: String, after: String, path: String) -> String:
	var old_lines := before.split("\n")
	var new_lines := after.split("\n")
	var prefix := 0
	while prefix < old_lines.size() and prefix < new_lines.size() and old_lines[prefix] == new_lines[prefix]:
		prefix += 1
	var suffix := 0
	while (
		suffix < old_lines.size() - prefix
		and suffix < new_lines.size() - prefix
		and old_lines[old_lines.size() - 1 - suffix] == new_lines[new_lines.size() - 1 - suffix]
	):
		suffix += 1
	var context_start := maxi(0, prefix - 3)
	var old_change_end := old_lines.size() - suffix
	var new_change_end := new_lines.size() - suffix
	var lines := PackedStringArray([
		"--- %s (修改前)" % path,
		"+++ %s (生成后)" % path,
		"@@ -%d,%d +%d,%d @@" % [
			context_start + 1,
			old_lines.size() - context_start,
			context_start + 1,
			new_lines.size() - context_start,
		],
	])
	for i in range(context_start, prefix):
		lines.append(" " + String(old_lines[i]))
	for i in range(prefix, old_change_end):
		lines.append("-" + String(old_lines[i]))
	for i in range(prefix, new_change_end):
		lines.append("+" + String(new_lines[i]))
	for i in range(suffix - 1, -1, -1):
		if i >= 3:
			continue
		lines.append(" " + String(new_lines[new_lines.size() - 1 - i]))
	return "\n".join(lines)


func _status_text(status: String) -> String:
	match status:
		"applied":
			return "已应用"
		"rolled_back":
			return "已回滚"
		"skipped":
			return "已跳过"
		_:
			return "等待审查"


func _on_state_changed(_state: String, _message: String) -> void:
	_render()


func _clear(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()
