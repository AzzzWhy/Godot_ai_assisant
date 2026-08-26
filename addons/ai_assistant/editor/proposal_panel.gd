@tool
class_name AIProposalPanel
extends VBoxContainer
## Compact review surface for the proposal store. File writes only occur from its Apply buttons.

var _store: AIProposalStore
var _title: Label
var _list: VBoxContainer
var _rollback: Button


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	_title = Label.new()
	_title.text = "改动提案"
	_title.add_theme_font_size_override("font_size", 15)
	add_child(_title)
	var actions := HBoxContainer.new()
	var apply_all := Button.new()
	apply_all.text = "应用安全项"
	apply_all.tooltip_text = "应用新增或更新脚本；删除项仍需逐项确认。"
	apply_all.pressed.connect(func() -> void:
		if _store != null:
			_store.apply_all()
	)
	actions.add_child(apply_all)
	_rollback = Button.new()
	_rollback.text = "回滚本轮"
	_rollback.tooltip_text = "还原本轮已经应用的脚本改动。"
	_rollback.pressed.connect(func() -> void:
		if _store != null:
			_store.rollback_session()
	)
	actions.add_child(_rollback)
	add_child(actions)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 180)
	add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)
	_render()


func set_store(store: AIProposalStore) -> void:
	if _store != null and _store.changed.is_connected(_render):
		_store.changed.disconnect(_render)
	_store = store
	if _store != null:
		_store.changed.connect(_render)
	_render()


func _render() -> void:
	if _list == null:
		return
	for child in _list.get_children():
		child.queue_free()
	if _store == null or _store.proposals.is_empty():
		_title.text = "改动提案（等待 AI 计划）"
		return
	_title.text = "改动提案 · %d 项" % _store.proposals.size()
	for proposal in _store.proposals:
		_list.add_child(_proposal_row(proposal))


func _proposal_row(proposal: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	var heading := Label.new()
	heading.text = "%s  %s" % [String(proposal.get("action", "update")).to_upper(), String(proposal.get("path", ""))]
	heading.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(heading)
	var summary := Label.new()
	summary.text = String(proposal.get("summary", "")) + " · " + String(proposal.get("status", "pending"))
	summary.modulate = Color("9ca3af")
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(summary)
	if String(proposal.get("status", "")) == "pending":
		var buttons := HBoxContainer.new()
		var apply := Button.new()
		apply.text = "确认删除" if bool(proposal.get("requires_confirmation", false)) else "应用"
		apply.pressed.connect(func() -> void:
			_store.apply(String(proposal.id), bool(proposal.get("requires_confirmation", false)))
		)
		buttons.add_child(apply)
		var skip := Button.new()
		skip.text = "跳过"
		skip.pressed.connect(func() -> void: _store.skip(String(proposal.id)))
		buttons.add_child(skip)
		box.add_child(buttons)
	return box
