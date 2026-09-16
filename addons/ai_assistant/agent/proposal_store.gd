@tool
class_name AIProposalStore
extends RefCounted
## Reviewable multi-file draft store with project sandboxing and verified rollback snapshots.

signal changed
signal applied(proposal: Dictionary)
signal error(message: String)

const SNAPSHOT_ROOT := "user://godot_ai_assistant/snapshots"
const RECOVERY_FILE := "user://godot_ai_assistant/pending_recovery.json"
const ALLOWED_EXTENSION := ".gd"

var session_id := ""
var summary := ""
var plan: Array = []
var proposals: Array[Dictionary] = []
var node_operations: Array[Dictionary] = []
var last_error := ""
var rollback_incomplete := false
var recovery_data: Dictionary = {}


func _init() -> void:
	_load_recovery()


func begin_session(new_plan: Array = [], new_summary := "") -> void:
	if has_unresolved_transaction():
		_fail("上一次事务尚未完整回滚，不能开始新会话。")
		return
	session_id = (
		Time.get_datetime_string_from_system().replace(":", "").replace("-", "").replace(" ", "_")
		+ "_%d" % Time.get_ticks_msec()
	)
	summary = new_summary
	plan = new_plan.duplicate()
	proposals.clear()
	node_operations.clear()
	last_error = ""
	rollback_incomplete = false
	changed.emit()


func add_changes(raw_changes: Array) -> int:
	if session_id.is_empty():
		begin_session()
	var added := 0
	for raw in raw_changes:
		if not (raw is Dictionary):
			_fail("changes 中存在无效项目。")
			continue
		var item: Dictionary = raw
		var path := String(item.get("path", "")).strip_edges()
		var action := String(item.get("action", "update")).strip_edges().to_lower()
		if not _valid_path(path):
			_fail("已拒绝不安全路径：%s（只允许项目内真实目录下的 .gd）" % path)
			continue
		if not ["create", "update", "delete"].has(action):
			_fail("已拒绝未知操作：%s" % action)
			continue
		var content := String(item.get("content", ""))
		if action != "delete" and content.is_empty():
			_fail("%s 缺少完整脚本内容，未加入草稿。" % path)
			continue
		var existed := FileAccess.file_exists(path)
		var disk_before := ""
		if existed:
			var read_result := _read_text(path)
			if not bool(read_result.get("ok", false)):
				_fail(String(read_result.get("error", "无法读取 %s" % path)))
				continue
			disk_before = String(read_result.get("content", ""))
		var preview_before := String(item.get("preview_before", disk_before))
		if action == "create" and existed:
			_fail("create 目标已经存在，请重新生成：%s" % path)
			continue
		if action == "update" and not existed:
			_fail("update 目标不存在，请改用 create：%s" % path)
			continue
		proposals.append({
			"id": "%s-%03d" % [session_id, proposals.size() + 1],
			"path": path,
			"action": action,
			"summary": String(item.get("summary", "AI 脚本改动")),
			"content": content,
			"before": preview_before,
			"existed": existed,
			"source_hash": preview_before.sha256_text(),
			"disk_hash": disk_before.sha256_text(),
			"status": "pending",
			"requires_confirmation": action == "delete",
		})
		added += 1
	if added > 0:
		changed.emit()
	return added


func set_node_operations(raw_operations: Array) -> void:
	node_operations.clear()
	for raw in raw_operations:
		if raw is Dictionary:
			node_operations.append((raw as Dictionary).duplicate(true))
	changed.emit()


func has_pending() -> bool:
	for proposal in proposals:
		if String(proposal.get("status", "")) == "pending":
			return true
	return false


func has_unresolved_transaction() -> bool:
	return rollback_incomplete


func mark_unresolved(reason: String) -> void:
	rollback_incomplete = true
	last_error = reason
	_persist_recovery()
	changed.emit()


func arm_recovery(data: Dictionary = {}) -> bool:
	recovery_data = data.duplicate(true)
	rollback_incomplete = true
	return _persist_recovery()


func update_recovery_data(data: Dictionary) -> bool:
	recovery_data = data.duplicate(true)
	return _persist_recovery() if rollback_incomplete else true


func disarm_recovery() -> void:
	rollback_incomplete = false
	recovery_data.clear()
	_clear_recovery_file()


func pending_count() -> int:
	var count := 0
	for proposal in proposals:
		if String(proposal.get("status", "")) == "pending":
			count += 1
	return count


func is_safe_path(path: String) -> bool:
	return _valid_path(path)


func capture_scene_snapshot(path: String) -> Dictionary:
	if not _valid_project_file(path, PackedStringArray([".tscn"])):
		return {"ok": false, "content": "", "hash": "", "error": "场景路径不安全：%s" % path}
	var result := _read_text(path, false)
	if bool(result.get("ok", false)):
		result.hash = String(result.get("content", "")).sha256_text()
	return result


func restore_scene_snapshot(path: String, content: String) -> bool:
	if not _valid_project_file(path, PackedStringArray([".tscn"])):
		return false
	return _write_absolute_atomic(ProjectSettings.globalize_path(path), content)


func discard_draft() -> bool:
	if has_unresolved_transaction():
		_fail("上一次事务尚未完整回滚，请先重试回滚。")
		return false
	summary = ""
	plan.clear()
	proposals.clear()
	node_operations.clear()
	last_error = ""
	rollback_incomplete = false
	recovery_data.clear()
	session_id = ""
	_clear_recovery_file()
	changed.emit()
	return true


func apply(id: String, confirmed := false) -> bool:
	var index := _proposal_index(id)
	if index < 0:
		_fail("找不到该草稿。")
		return false
	var proposal := proposals[index]
	if String(proposal.get("status", "")) != "pending":
		return false
	if bool(proposal.get("requires_confirmation", false)) and not confirmed:
		_fail("删除脚本需要明确确认。")
		return false
	var path := String(proposal.get("path", ""))
	if not _valid_path(path):
		_fail("应用前路径安全校验失败：%s" % path)
		return false
	var exists_now := FileAccess.file_exists(path)
	if exists_now != bool(proposal.get("existed", false)):
		_fail("生成草稿后文件状态已变化，请重新生成：%s" % path)
		return false
	var before_now := ""
	if exists_now:
		var read_result := _read_text(path)
		if not bool(read_result.get("ok", false)):
			_fail(String(read_result.get("error", "无法读取 %s" % path)))
			return false
		before_now = String(read_result.get("content", ""))
	if before_now.sha256_text() != String(proposal.get("disk_hash", "")):
		_fail("生成草稿后文件内容已变化，请重新生成：%s" % path)
		return false
	if not _save_snapshot(path, exists_now, before_now):
		_fail("无法创建回滚快照，已取消应用：%s" % path)
		return false
	proposal.status = "write_started"
	proposals[index] = proposal
	if rollback_incomplete:
		_persist_recovery()
	changed.emit()
	var action := String(proposal.get("action", ""))
	var ok := false
	if action == "delete":
		ok = DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK
	else:
		ok = _write_file(path, String(proposal.get("content", "")))
	if not ok:
		_fail("写入失败，原文件未被替换：%s" % path)
		return false
	proposal.status = "applied"
	proposals[index] = proposal
	if rollback_incomplete:
		_persist_recovery()
	changed.emit()
	applied.emit(proposal)
	return true


func apply_all() -> int:
	var result := apply_all_transactional(false)
	return int(result.get("count", 0)) if bool(result.get("ok", false)) else 0


func apply_all_transactional(include_deletes := false) -> Dictionary:
	last_error = ""
	var ids := PackedStringArray()
	for proposal in proposals:
		if String(proposal.get("status", "")) != "pending":
			continue
		if bool(proposal.get("requires_confirmation", false)) and not include_deletes:
			_fail("批量应用不包含删除项。")
			return {"ok": false, "count": 0, "error": last_error}
		ids.append(String(proposal.get("id", "")))
	var applied_count := 0
	for id in ids:
		if not apply(id, include_deletes):
			var apply_error := last_error
			var rollback := rollback_session_detailed()
			if not bool(rollback.get("ok", false)):
				apply_error += "\n回滚也未完整完成：" + ", ".join(rollback.get("failures", []))
				_fail(apply_error)
			return {"ok": false, "count": 0, "error": apply_error}
		applied_count += 1
	return {"ok": true, "count": applied_count, "error": ""}


func skip(id: String) -> void:
	var index := _proposal_index(id)
	if index < 0:
		return
	var proposal := proposals[index]
	if String(proposal.get("status", "")) == "pending":
		proposal.status = "skipped"
		proposals[index] = proposal
		changed.emit()


func rollback_session() -> int:
	return int(rollback_session_detailed().get("count", 0))


func rollback_session_detailed() -> Dictionary:
	var applied_paths := PackedStringArray()
	for proposal in proposals:
		if ["write_started", "applied"].has(String(proposal.get("status", ""))):
			applied_paths.append(String(proposal.get("path", "")))
	if applied_paths.is_empty():
		if bool(recovery_data.get("scene_needs_restore", false)):
			rollback_incomplete = true
			_persist_recovery()
			return {
				"ok": false,
				"count": 0,
				"failures": PackedStringArray(["场景快照仍待恢复"]),
			}
		rollback_incomplete = false
		recovery_data.clear()
		_clear_recovery_file()
		return {"ok": true, "count": 0, "failures": PackedStringArray()}
	var directory := SNAPSHOT_ROOT.path_join(session_id)
	var dir := DirAccess.open(directory)
	if dir == null:
		rollback_incomplete = true
		_persist_recovery()
		return {
			"ok": false,
			"count": 0,
			"failures": PackedStringArray(["回滚快照目录不存在"]),
		}
	var restored_paths := PackedStringArray()
	var failures := PackedStringArray()
	for name in dir.get_files():
		if not name.ends_with(".json"):
			continue
		var snapshot_result := _read_text(directory.path_join(name), false)
		if not bool(snapshot_result.get("ok", false)):
			failures.append(name + " 无法读取")
			continue
		var json := JSON.new()
		if json.parse(String(snapshot_result.get("content", ""))) != OK or not (json.data is Dictionary):
			failures.append(name + " 已损坏")
			continue
		var snapshot: Dictionary = json.data
		var path := String(snapshot.get("path", ""))
		if not applied_paths.has(path):
			continue
		if not _valid_path(path):
			failures.append(path + " 路径校验失败")
			continue
		var restored := false
		if bool(snapshot.get("existed", false)):
			restored = _write_file(path, String(snapshot.get("content", "")))
		elif not FileAccess.file_exists(path):
			restored = true
		else:
			restored = DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK
		if restored:
			restored_paths.append(path)
		else:
			failures.append(path)
	for path in applied_paths:
		if not restored_paths.has(path) and not failures.has(path):
			failures.append(path + " 缺少快照")
	for i in range(proposals.size()):
		var proposal := proposals[i]
		if (
			["write_started", "applied"].has(String(proposal.get("status", "")))
			and restored_paths.has(String(proposal.get("path", "")))
		):
			proposal.status = "rolled_back"
			proposals[i] = proposal
	rollback_incomplete = not failures.is_empty()
	if rollback_incomplete:
		_persist_recovery()
	else:
		recovery_data.clear()
		_clear_recovery_file()
	changed.emit()
	return {
		"ok": failures.is_empty(),
		"count": restored_paths.size(),
		"failures": failures,
	}


func _fail(message: String) -> void:
	last_error = message
	error.emit(message)


func _valid_path(path: String) -> bool:
	return _valid_project_file(path, PackedStringArray([ALLOWED_EXTENSION]))


func _valid_project_file(path: String, allowed_extensions: PackedStringArray) -> bool:
	var extension_allowed := false
	for extension in allowed_extensions:
		if path.ends_with(extension):
			extension_allowed = true
			break
	if (
		not path.begins_with("res://")
		or not extension_allowed
		or path.contains("..")
		or path.contains("\\")
		or path.trim_prefix("res://").contains(":")
	):
		return false
	var relative := path.trim_prefix("res://")
	if relative.is_empty():
		return false
	for part in relative.split("/", true):
		if part.is_empty() or part == ".":
			return false
	var root := ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	var absolute := ProjectSettings.globalize_path(path).simplify_path()
	if not absolute.begins_with(root + "/"):
		return false
	var current := root
	for part in relative.split("/", false):
		current = current.path_join(part)
		var parent := DirAccess.open(current.get_base_dir())
		if parent != null and parent.is_link(current.get_file()):
			return false
	return true


func _proposal_index(id: String) -> int:
	for i in range(proposals.size()):
		if String(proposals[i].get("id", "")) == id:
			return i
	return -1


func _read_text(path: String, validate_project_path := true) -> Dictionary:
	if validate_project_path and not _valid_path(path):
		return {"ok": false, "content": "", "error": "不安全路径：%s" % path}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {
			"ok": false,
			"content": "",
			"error": "无法读取 %s：%s" % [path, error_string(FileAccess.get_open_error())],
		}
	var length := file.get_length()
	var bytes := file.get_buffer(length)
	file.close()
	if bytes.size() != length:
		return {"ok": false, "content": "", "error": "读取不完整：%s" % path}
	return {"ok": true, "content": bytes.get_string_from_utf8(), "error": ""}


func _write_file(path: String, content: String) -> bool:
	if not _valid_path(path):
		return false
	var absolute := ProjectSettings.globalize_path(path)
	if DirAccess.make_dir_recursive_absolute(absolute.get_base_dir()) != OK:
		return false
	# A directory could have been replaced by a link between validation and mkdir.
	if not _valid_path(path):
		return false
	return _write_absolute_atomic(absolute, content)


func _write_absolute_atomic(absolute: String, content: String) -> bool:
	var token := "%d_%d" % [Time.get_ticks_usec(), randi()]
	var temporary := absolute + ".ai_tmp_" + token
	var backup := absolute + ".ai_backup_" + token
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return false
	var stored := file.store_string(content)
	file.flush()
	var write_error := file.get_error()
	file.close()
	if not stored or write_error != OK:
		DirAccess.remove_absolute(temporary)
		return false
	var verify := _read_text(temporary, false)
	if (
		not bool(verify.get("ok", false))
		or String(verify.get("content", "")).sha256_text() != content.sha256_text()
	):
		DirAccess.remove_absolute(temporary)
		return false
	var existed := FileAccess.file_exists(absolute)
	var original_hash := ""
	if existed:
		var original := _read_text(absolute, false)
		if not bool(original.get("ok", false)):
			DirAccess.remove_absolute(temporary)
			return false
		original_hash = String(original.get("content", "")).sha256_text()
		if DirAccess.copy_absolute(absolute, backup) != OK:
			DirAccess.remove_absolute(temporary)
			return false
	if DirAccess.rename_absolute(temporary, absolute) != OK:
		if existed:
			var current := _read_text(absolute, false)
			var target_intact := (
				bool(current.get("ok", false))
				and String(current.get("content", "")).sha256_text() == original_hash
			)
			if not target_intact and DirAccess.rename_absolute(backup, absolute) != OK:
				# Keep the verified backup beside the target for manual recovery.
				return false
			if target_intact:
				DirAccess.remove_absolute(backup)
		DirAccess.remove_absolute(temporary)
		return false
	var final_verify := _read_text(absolute, false)
	if (
		not bool(final_verify.get("ok", false))
		or String(final_verify.get("content", "")).sha256_text() != content.sha256_text()
	):
		if existed:
			if DirAccess.rename_absolute(backup, absolute) != OK:
				return false
		else:
			DirAccess.remove_absolute(absolute)
		return false
	if existed:
		DirAccess.remove_absolute(backup)
	return true


func _save_snapshot(path: String, existed: bool, content: String) -> bool:
	var directory := SNAPSHOT_ROOT.path_join(session_id)
	var absolute_directory := ProjectSettings.globalize_path(directory)
	if DirAccess.make_dir_recursive_absolute(absolute_directory) != OK:
		return false
	var snapshot_path := directory.path_join("%s.json" % path.sha256_text())
	if FileAccess.file_exists(snapshot_path):
		return true
	var payload := JSON.stringify({"path": path, "existed": existed, "content": content})
	return _write_absolute_atomic(ProjectSettings.globalize_path(snapshot_path), payload)


func _persist_recovery() -> bool:
	var absolute := ProjectSettings.globalize_path(RECOVERY_FILE)
	if DirAccess.make_dir_recursive_absolute(absolute.get_base_dir()) != OK:
		return false
	var payload := JSON.stringify({
		"session_id": session_id,
		"summary": summary,
		"plan": plan,
		"proposals": proposals,
		"node_operations": node_operations,
		"last_error": last_error,
		"recovery_data": recovery_data,
	})
	return _write_absolute_atomic(absolute, payload)


func _load_recovery() -> void:
	if not FileAccess.file_exists(RECOVERY_FILE):
		return
	var read_result := _read_text(RECOVERY_FILE, false)
	if not bool(read_result.get("ok", false)):
		rollback_incomplete = true
		last_error = "检测到损坏的待恢复事务记录。"
		return
	var json := JSON.new()
	if json.parse(String(read_result.get("content", ""))) != OK or not (json.data is Dictionary):
		rollback_incomplete = true
		last_error = "检测到无法解析的待恢复事务记录。"
		return
	var data: Dictionary = json.data
	session_id = String(data.get("session_id", ""))
	summary = String(data.get("summary", "待恢复事务"))
	var recovered_plan: Variant = data.get("plan", [])
	plan = recovered_plan.duplicate(true) if recovered_plan is Array else []
	proposals.clear()
	var recovered_proposals: Variant = data.get("proposals", [])
	if recovered_proposals is Array:
		for raw in recovered_proposals:
			if raw is Dictionary:
				proposals.append((raw as Dictionary).duplicate(true))
	node_operations.clear()
	var recovered_operations: Variant = data.get("node_operations", [])
	if recovered_operations is Array:
		for raw in recovered_operations:
			if raw is Dictionary:
				node_operations.append((raw as Dictionary).duplicate(true))
	last_error = String(data.get("last_error", "上一次事务尚未完整回滚。"))
	var recovered_data: Variant = data.get("recovery_data", {})
	recovery_data = (recovered_data as Dictionary).duplicate(true) if recovered_data is Dictionary else {}
	rollback_incomplete = true


func _clear_recovery_file() -> void:
	if FileAccess.file_exists(RECOVERY_FILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(RECOVERY_FILE))
