@tool
extends VBoxContainer
## Project-local source control panel. It exposes explicit user actions, never AI commands.

const BRIDGE := preload("res://addons/ai_assistant/editor/git_bridge.gd")
const DIFF_VIEW := preload("res://addons/ai_assistant/editor/diff_view.gd")
const CLIENT := preload("res://addons/ai_assistant/client/llm_client.gd")
const SESSION_CONFIG := preload("res://addons/ai_assistant/editor/session_config.gd")

var _git: AIGitBridge
var _client: AILLMClient
var _files: ItemList
var _diff: AIDiffView
var _message: LineEdit
var _status: Label
var _pending_action := ""
var _selected_path := ""
var _discard_dialog: ConfirmationDialog


func _ready() -> void:
	name = "版本控制"
	_git = BRIDGE.new()
	add_child(_git)
	_git.completed.connect(_on_git_completed)
	_client = CLIENT.new()
	add_child(_client)
	_client.stream = false
	_client.request_finished.connect(_on_ai_finished)
	_build_ui()
	_refresh()


func _build_ui() -> void:
	var toolbar := HBoxContainer.new()
	var refresh := Button.new()
	refresh.text = "刷新"
	refresh.pressed.connect(_refresh)
	toolbar.add_child(refresh)
	var stage := Button.new()
	stage.text = "暂存"
	stage.pressed.connect(func() -> void: _run_selected("stage"))
	toolbar.add_child(stage)
	var unstage := Button.new()
	unstage.text = "取消暂存"
	unstage.pressed.connect(func() -> void: _run_selected("unstage"))
	toolbar.add_child(unstage)
	var discard := Button.new()
	discard.text = "丢弃工作区改动"
	discard.tooltip_text = "仅对已跟踪文件有效；此操作会覆盖磁盘内容。"
	discard.pressed.connect(func() -> void: _run_selected("discard"))
	toolbar.add_child(discard)
	add_child(toolbar)
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.custom_minimum_size = Vector2(0, 240)
	add_child(split)
	_files = ItemList.new()
	_files.custom_minimum_size = Vector2(220, 0)
	_files.item_selected.connect(_on_file_selected)
	split.add_child(_files)
	_diff = DIFF_VIEW.new()
	_diff.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_diff.fit_content = false
	split.add_child(_diff)
	var commit_row := HBoxContainer.new()
	_message = LineEdit.new()
	_message.placeholder_text = "提交信息（例如 feat: add proposal review）"
	_message.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	commit_row.add_child(_message)
	var generate := Button.new()
	generate.text = "AI 生成"
	generate.tooltip_text = "仅根据已暂存 diff 生成提交信息，不会自动提交。"
	generate.pressed.connect(_generate_commit_message)
	commit_row.add_child(generate)
	var commit := Button.new()
	commit.text = "提交"
	commit.pressed.connect(_commit)
	commit_row.add_child(commit)
	var history := Button.new()
	history.text = "历史"
	history.pressed.connect(_history)
	commit_row.add_child(history)
	add_child(commit_row)
	_status = Label.new()
	_status.modulate = Color("9ca3af")
	add_child(_status)
	_discard_dialog = ConfirmationDialog.new()
	_discard_dialog.title = "丢弃工作区改动"
	_discard_dialog.dialog_text = "这会用 Git 中的版本覆盖所选文件，无法通过本面板恢复。"
	_discard_dialog.confirmed.connect(_discard_confirmed)
	add_child(_discard_dialog)


func _refresh() -> void:
	_run("status", PackedStringArray(["status", "--short"]))


func _run_selected(action: String) -> void:
	if _selected_path.is_empty():
		_set_status("请先选择一个文件。", true)
		return
	match action:
		"stage": _run(action, PackedStringArray(["add", "--", _selected_path]))
		"unstage": _run(action, PackedStringArray(["restore", "--staged", "--", _selected_path]))
		"discard": _confirm_discard()


func _confirm_discard() -> void:
	_discard_dialog.dialog_text = "确定丢弃 %s 的工作区改动吗？这会用 Git 中的版本覆盖该文件。" % _selected_path
	_discard_dialog.popup_centered()


func _discard_confirmed() -> void:
	if not _selected_path.is_empty():
		_run("discard", PackedStringArray(["restore", "--worktree", "--", _selected_path]))


func _run(action: String, args: PackedStringArray) -> void:
	if _git.is_busy():
		return
	_pending_action = action
	_set_status("正在执行 %s…" % action)
	_git.run(args)


func _on_git_completed(result: Dictionary) -> void:
	var action := _pending_action
	_pending_action = ""
	if not bool(result.get("ok", false)):
		_set_status(String(result.get("output", "Git 操作失败")), true)
		return
	var output := String(result.get("output", ""))
	match action:
		"status": _render_status(output)
		"diff": _diff.render_diff(output if not output.is_empty() else "该文件没有可显示的工作区 diff。")
		"ai_diff": _ask_commit_ai(output)
		"history": _diff.render_diff(output)
		_:
			_set_status("已完成：%s" % action)
			_refresh()


func _render_status(output: String) -> void:
	_files.clear()
	_selected_path = ""
	if output.strip_edges().is_empty():
		_diff.render_diff("工作区干净。")
		_set_status("工作区干净。")
		return
	for line in output.split("\n", false):
		if line.length() < 4:
			continue
		var code := line.substr(0, 2)
		var path := line.substr(3)
		var label := _status_label(code) + "  " + path
		var index := _files.get_item_count()
		_files.add_item(label)
		_files.set_item_metadata(index, path)
		_files.set_item_tooltip(index, code + " " + path)
	_set_status("%d 个待处理文件。" % _files.item_count)


func _status_label(code: String) -> String:
	if code.substr(0, 1) != " ":
		return "已暂存"
	if code.substr(1, 1) == "?":
		return "未跟踪"
	return "更改"


func _on_file_selected(index: int) -> void:
	_selected_path = String(_files.get_item_metadata(index))
	_run("diff", PackedStringArray(["diff", "--", _selected_path]))


func _generate_commit_message() -> void:
	_load_ai_config()
	if _client.api_key.is_empty() or _client.base_url.is_empty() or _client.model.is_empty():
		_set_status("请先在 AI 助手设置中配置模型。", true)
		return
	_run("ai_diff", PackedStringArray(["diff", "--cached"]))


func _ask_commit_ai(diff: String) -> void:
	if diff.strip_edges().is_empty():
		_set_status("暂存区没有改动，无法生成提交信息。", true)
		return
	_client.chat("根据以下已暂存 diff，只返回一条简洁的 Conventional Commit 提交信息，不要 Markdown，不超过 90 个字符：\n\n" + diff.substr(0, 12000))
	_set_status("正在生成提交信息…")


func _load_ai_config() -> void:
	var settings := EditorInterface.get_editor_settings()
	_client.base_url = String(settings.get_setting("ai_assistant/base_url", ""))
	_client.api_key = String(settings.get_setting("ai_assistant/api_key", ""))
	_client.model = String(settings.get_setting("ai_assistant/model", ""))
	_client.temperature = 0.2
	_client.timeout_seconds = float(settings.get_setting("ai_assistant/timeout", 90.0))
	SESSION_CONFIG.apply_to(_client)


func _on_ai_finished(success: bool, error_message: String) -> void:
	if not success:
		_set_status(error_message, true)
		return
	_message.text = _client.last_response_text.strip_edges().split("\n")[0]
	_set_status("已生成提交信息，请审阅后再提交。")


func _commit() -> void:
	var text := _message.text.strip_edges()
	if text.is_empty():
		_set_status("请填写提交信息。", true)
		return
	_run("commit", PackedStringArray(["commit", "-m", text]))


func _history() -> void:
	_run("history", PackedStringArray(["log", "--oneline", "-12"]))


func _set_status(text: String, bad := false) -> void:
	_status.text = text
	_status.modulate = Color("f87171") if bad else Color("9ca3af")
