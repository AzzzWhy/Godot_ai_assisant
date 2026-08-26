@tool
class_name AIProposalStore
extends RefCounted
## Owns reviewable AI file proposals. Nothing is written before apply() is called.

signal changed
signal applied(proposal: Dictionary)
signal error(message: String)

const SNAPSHOT_ROOT := "user://godot_ai_assistant/snapshots"
const ALLOWED_EXTENSION := ".gd"

var session_id := ""
var plan: Array = []
var proposals: Array[Dictionary] = []


func begin_session(new_plan: Array = []) -> void:
	session_id = Time.get_datetime_string_from_system().replace(":", "").replace("-", "").replace(" ", "_")
	plan = new_plan.duplicate()
	proposals.clear()
	changed.emit()


func add_changes(raw_changes: Array) -> int:
	if session_id.is_empty():
		begin_session()
	var added := 0
	for raw in raw_changes:
		if not (raw is Dictionary):
			continue
		var item: Dictionary = raw
		var path := String(item.get("path", "")).strip_edges()
		var action := String(item.get("action", "update")).strip_edges().to_lower()
		if not _valid_path(path):
			error.emit("已拒绝不安全路径：%s（只允许 res:// 下的 .gd 脚本）" % path)
			continue
		if not ["create", "update", "delete"].has(action):
			error.emit("已拒绝未知操作：%s" % action)
			continue
		var content := String(item.get("content", ""))
		if action != "delete" and content.is_empty():
			error.emit("%s 缺少完整脚本内容，未加入提案。" % path)
			continue
		proposals.append({
			"id": "%s-%03d" % [session_id, proposals.size() + 1],
			"path": path,
			"action": action,
			"summary": String(item.get("summary", "AI 脚本改动")),
			"content": content,
			"status": "pending",
			"requires_confirmation": action == "delete",
		})
		added += 1
	if added > 0:
		changed.emit()
	return added


func apply(id: String, confirmed := false) -> bool:
	var index := _proposal_index(id)
	if index < 0:
		error.emit("找不到该提案。")
		return false
	var proposal := proposals[index]
	if String(proposal.status) != "pending":
		return false
	if bool(proposal.requires_confirmation) and not confirmed:
		error.emit("删除脚本需要明确确认。")
		return false
	var path := String(proposal.path)
	var before := _read_file(path)
	var existed := FileAccess.file_exists(path)
	if not _save_snapshot(path, existed, before):
		error.emit("无法创建回滚快照，已取消应用。")
		return false
	var action := String(proposal.action)
	var ok := false
	if action == "delete":
		ok = DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK
	else:
		ok = _write_file(path, String(proposal.content))
	if not ok:
		error.emit("写入失败：%s" % path)
		return false
	proposal.status = "applied"
	proposals[index] = proposal
	changed.emit()
	applied.emit(proposal)
	return true


func apply_all() -> int:
	var count := 0
	for proposal in proposals:
		if String(proposal.status) == "pending" and not bool(proposal.requires_confirmation):
			if apply(String(proposal.id)):
				count += 1
	return count


func skip(id: String) -> void:
	var index := _proposal_index(id)
	if index < 0:
		return
	var proposal := proposals[index]
	if String(proposal.status) == "pending":
		proposal.status = "skipped"
		proposals[index] = proposal
		changed.emit()


func rollback_session() -> int:
	if session_id.is_empty():
		return 0
	var directory := SNAPSHOT_ROOT.path_join(session_id)
	var dir := DirAccess.open(directory)
	if dir == null:
		return 0
	var restored := 0
	for name in dir.get_files():
		if not name.ends_with(".json"):
			continue
		var file := FileAccess.open(directory.path_join(name), FileAccess.READ)
		if file == null:
			continue
		var json := JSON.new()
		var text := file.get_as_text()
		file.close()
		if json.parse(text) != OK or not (json.data is Dictionary):
			continue
		var snapshot: Dictionary = json.data
		var path := String(snapshot.get("path", ""))
		if not _valid_path(path):
			continue
		if bool(snapshot.get("existed", false)):
			if _write_file(path, String(snapshot.get("content", ""))):
				restored += 1
		elif FileAccess.file_exists(path):
			if DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK:
				restored += 1
	for i in range(proposals.size()):
		var proposal := proposals[i]
		if String(proposal.status) == "applied":
			proposal.status = "rolled_back"
			proposals[i] = proposal
	changed.emit()
	return restored


func _valid_path(path: String) -> bool:
	return path.begins_with("res://") and path.ends_with(ALLOWED_EXTENSION) and not path.contains("..")


func _proposal_index(id: String) -> int:
	for i in range(proposals.size()):
		if String(proposals[i].get("id", "")) == id:
			return i
	return -1


func _read_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""


func _write_file(path: String, content: String) -> bool:
	var absolute := ProjectSettings.globalize_path(path)
	if DirAccess.make_dir_recursive_absolute(absolute.get_base_dir()) != OK:
		return false
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(content)
	file.close()
	return true


func _save_snapshot(path: String, existed: bool, content: String) -> bool:
	var directory := SNAPSHOT_ROOT.path_join(session_id)
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory)) != OK:
		return false
	var name := "%s.json" % path.trim_prefix("res://").replace("/", "__").replace(".gd", "")
	var snapshot_path := directory.path_join(name)
	# Preserve the state before the first change to this path in the session.
	if FileAccess.file_exists(snapshot_path):
		return true
	var file := FileAccess.open(snapshot_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify({"path": path, "existed": existed, "content": content}))
	file.close()
	return true
