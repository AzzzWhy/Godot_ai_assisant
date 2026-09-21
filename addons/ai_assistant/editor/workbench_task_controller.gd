@tool
class_name AIWorkbenchController
extends Node
## Single orchestration point for Chat, Builder, review and transactional apply.

signal state_changed(state_key: String, message: String)
signal message_added(role: String, text: String)
signal stream_text(text: String)
signal reasoning_text(text: String)
signal draft_changed
signal context_changed(context: Dictionary)
signal models_loaded(models: Array, error_message: String)
signal token_usage_threshold_reached(total_tokens: int, threshold: int)
signal response_stalled(elapsed_seconds: int)

const CLIENT_SCRIPT := preload("res://addons/ai_assistant/client/openai_compatible_chat_client.gd")
const BUILDER := preload("res://addons/ai_assistant/agent/builder_response_contract.gd")
const INLINE_PATCH := preload("res://addons/ai_assistant/agent/exact_text_patch.gd")
const STORE_SCRIPT := preload("res://addons/ai_assistant/agent/transactional_proposal_store.gd")
const SESSION_CONFIG := preload("res://addons/ai_assistant/editor/editor_session_config.gd")
const SCENE_CONTEXT := preload("res://addons/ai_assistant/editor/selected_scene_summary.gd")

const IDLE := "idle"
const PLANNING := "planning"
const GENERATING := "generating"
const REVIEW := "review"
const APPLYING := "applying"
const DONE := "done"
const ERROR := "error"
const CANCELLED := "cancelled"
const TOKEN_WARNING_STEP := 10_000_000

var state_key := IDLE
var state_message := "等待任务"
var store: AIProposalStore
var captured_context: Dictionary = {}
var current_context: Dictionary = {}
var last_request := ""

var _client: AILLMClient
var _pending_kind := ""
var _chat_history: Array[Dictionary] = []
var _chat_streamed := false
var _reasoning_received := ""
var _original_node_scripts: Array[Dictionary] = []
var _original_script_sources: Array[Dictionary] = []
var _locked_script: Script
var _locked_scene_root: WeakRef
var _locked_target_node: WeakRef
var _locked_target_script_id := 0
var _locked_target_script_path := ""
var _locked_scene_content := ""
var _locked_scene_hash := ""
var _scene_save_attempted := false
var _latest_scene_snapshot: Dictionary = {}
var _rollback_incomplete := false
var _total_tokens_consumed := 0


func _ready() -> void:
	_client = CLIENT_SCRIPT.new()
	add_child(_client)
	_client.stream_chunk.connect(_on_stream_chunk)
	_client.reasoning_chunk.connect(_on_reasoning_chunk)
	_client.request_finished.connect(_on_request_finished)
	_client.models_loaded.connect(_on_models_loaded)
	_client.token_usage_reported.connect(_on_token_usage_reported)
	_client.response_stalled.connect(_on_response_stalled)
	store = STORE_SCRIPT.new()
	store.changed.connect(func() -> void: draft_changed.emit())
	store.error.connect(func(message: String) -> void:
		if state_key == APPLYING:
			_set_state(ERROR, message)
	)
	if store.has_unresolved_transaction():
		var recovery := store.recovery_data
		if not recovery.is_empty():
			captured_context.scene_path = String(recovery.get("scene_path", ""))
			_locked_scene_content = String(recovery.get("scene_content", ""))
			_locked_scene_hash = String(recovery.get("scene_hash", ""))
			_scene_save_attempted = bool(recovery.get("scene_needs_restore", false))
		_rollback_incomplete = true
		state_key = ERROR
		state_message = (
			store.last_error
			if not store.last_error.is_empty()
			else "检测到上次未完整回滚的事务，请点击「重试回滚」。"
		)
	load_config()


func load_config() -> void:
	if not Engine.is_editor_hint():
		return
	var settings := EditorInterface.get_editor_settings()
	_client.base_url = String(_setting(settings, "ai_assistant/base_url", ""))
	_client.model = String(_setting(settings, "ai_assistant/model", ""))
	_client.temperature = -1.0
	_client.max_tokens = int(_setting(settings, "ai_assistant/max_tokens", 0))
	_client.timeout_seconds = float(_setting(settings, "ai_assistant/timeout", 60.0))
	_total_tokens_consumed = int(_setting(settings, "ai_assistant/total_tokens_consumed", 0))
	_client.stream = bool(_setting(settings, "ai_assistant/stream", true))
	_client.system_prompt = String(_setting(
		settings,
		"ai_assistant/system_prompt",
		"你是 Godot 4.6 编程助手。默认用中文简洁回答。",
	))
	var remember_key := bool(_setting(settings, "ai_assistant/remember_api_key", false))
	_client.api_key = String(_setting(settings, "ai_assistant/api_key", "")) if remember_key else ""
	SESSION_CONFIG.apply_to(_client)


func get_config() -> Dictionary:
	return {
		"base_url": _client.base_url,
		"api_key": _client.api_key,
		"model": _client.model,
		"max_tokens": _client.max_tokens,
		"timeout": _client.timeout_seconds,
		"stream": _client.stream,
		"system_prompt": _client.system_prompt,
	}


func save_config(values: Dictionary, remember_key: bool) -> void:
	if not Engine.is_editor_hint():
		return
	_client.base_url = String(values.get("base_url", "")).strip_edges()
	_client.api_key = String(values.get("api_key", "")).strip_edges()
	_client.model = String(values.get("model", "")).strip_edges()
	_client.temperature = -1.0
	_client.max_tokens = int(values.get("max_tokens", 0))
	_client.timeout_seconds = float(values.get("timeout", 60.0))
	_client.stream = bool(values.get("stream", true))
	_client.system_prompt = String(values.get("system_prompt", ""))
	var settings := EditorInterface.get_editor_settings()
	for key in ["base_url", "model", "max_tokens", "timeout", "stream", "system_prompt"]:
		settings.set_setting("ai_assistant/" + key, values.get(key, get_config().get(key)))
	settings.set_setting("ai_assistant/remember_api_key", remember_key)
	if remember_key and not _client.api_key.is_empty():
		settings.set_setting("ai_assistant/api_key", _client.api_key)
	elif settings.has_setting("ai_assistant/api_key"):
		if settings.has_method("erase"):
			settings.erase("ai_assistant/api_key")
		else:
			settings.set_setting("ai_assistant/api_key", "")
	SESSION_CONFIG.capture(_client)


func fetch_models(api_key_override := "", base_url_override := "") -> void:
	var key := api_key_override.strip_edges()
	var url := base_url_override.strip_edges()
	_client.fetch_models(
		key if not key.is_empty() else _client.api_key,
		url if not url.is_empty() else _client.base_url,
	)


func is_configured() -> bool:
	return (
		not _client.base_url.strip_edges().is_empty()
		and not _client.api_key.strip_edges().is_empty()
		and not _client.model.strip_edges().is_empty()
	)


func is_busy() -> bool:
	return [PLANNING, GENERATING, APPLYING].has(state_key) or _client.is_busy()


func has_pending_draft() -> bool:
	return store != null and (store.has_pending() or has_unresolved_transaction())


func has_unresolved_transaction() -> bool:
	return (
		_rollback_incomplete
		or (store != null and store.has_unresolved_transaction())
		or not _original_node_scripts.is_empty()
		or not _original_script_sources.is_empty()
		or _scene_save_attempted
	)


func capture_context(selected_node: Node = null) -> Dictionary:
	_latest_scene_snapshot = {}
	var context := {
		"project_path": ProjectSettings.globalize_path("res://"),
		"scene_path": "",
		"scene_hash": "",
		"scene_root_instance_id": 0,
		"scene_root_name": "",
		"selected_node_path": "",
		"selected_node_instance_id": 0,
		"selected_node_name": "",
		"selected_node_type": "",
		"selected_node_script_path": "",
		"node_context": "未选择节点。",
		"script_path": "",
		"script_source": "",
		"script_hash": "",
	}
	if not Engine.is_editor_hint():
		current_context = context
		if state_key == IDLE:
			captured_context = context.duplicate(true)
		context_changed.emit(current_context)
		return current_context
	var root := EditorInterface.get_edited_scene_root()
	if root != null:
		context.scene_path = root.scene_file_path
		context.scene_root_instance_id = root.get_instance_id()
		context.scene_root_name = root.name
		if not root.scene_file_path.is_empty():
			var scene_snapshot := store.capture_scene_snapshot(root.scene_file_path)
			if bool(scene_snapshot.get("ok", false)):
				_latest_scene_snapshot = scene_snapshot.duplicate(true)
				context.scene_hash = String(scene_snapshot.get("hash", ""))
	if selected_node != null and is_instance_valid(selected_node):
		context.selected_node_instance_id = selected_node.get_instance_id()
		context.selected_node_name = selected_node.name
		context.selected_node_type = selected_node.get_class()
		context.node_context = SCENE_CONTEXT.from_node(selected_node)
		if root != null and (selected_node == root or root.is_ancestor_of(selected_node)):
			context.selected_node_path = String(root.get_path_to(selected_node))
		var node_script: Variant = selected_node.get_script()
		if node_script is Script and not node_script.resource_path.is_empty():
			context.selected_node_script_path = node_script.resource_path
			context.script_path = node_script.resource_path
			context.script_source = node_script.source_code
			var open_entry := _open_script_entry(node_script.resource_path)
			if not open_entry.is_empty():
				context.script_source = String(open_entry.get("source", ""))
	if String(context.script_path).is_empty():
		var script_editor := EditorInterface.get_script_editor()
		if script_editor != null:
			var current_script: Script = script_editor.get_current_script()
			if current_script != null and current_script.resource_path.ends_with(".gd"):
				context.script_path = current_script.resource_path
				context.script_source = _live_script_text(script_editor, current_script)
	context.script_hash = String(context.script_source).sha256_text()
	current_context = context.duplicate(true)
	if not [PLANNING, GENERATING, REVIEW, APPLYING].has(state_key):
		captured_context = context.duplicate(true)
	context_changed.emit(current_context)
	return current_context


func run_builder(request: String, selected_node: Node = null) -> bool:
	var task := request.strip_edges()
	if task.is_empty():
		_set_state(ERROR, "请先描述要完成的任务。")
		return false
	if is_busy():
		_set_state(ERROR, "已有任务正在进行。")
		return false
	if has_unresolved_transaction():
		_set_state(ERROR, "上一次应用没有完整回滚，请先点击「重试回滚」。")
		return false
	load_config()
	if not is_configured():
		_set_state(ERROR, "请先配置 Base URL、API Key 和模型。")
		return false
	if store.has_pending():
		_set_state(ERROR, "请先应用或撤销当前待审查改动。")
		return false
	if state_key == DONE:
		store.discard_draft()
	last_request = task
	var context := capture_context(selected_node)
	captured_context = context.duplicate(true)
	var root := EditorInterface.get_edited_scene_root()
	_locked_scene_root = weakref(root) if root != null else null
	_locked_target_node = weakref(selected_node) if selected_node != null else null
	_locked_target_script_id = 0
	_locked_target_script_path = ""
	_locked_scene_content = ""
	_locked_scene_hash = ""
	_scene_save_attempted = false
	if bool(_latest_scene_snapshot.get("ok", false)):
		_locked_scene_content = String(_latest_scene_snapshot.get("content", ""))
		_locked_scene_hash = String(_latest_scene_snapshot.get("hash", ""))
	if selected_node != null and selected_node.get_script() is Script:
		var locked_node_script := selected_node.get_script() as Script
		_locked_target_script_id = locked_node_script.get_instance_id()
		_locked_target_script_path = locked_node_script.resource_path
	_locked_script = null
	var context_path := String(context.get("script_path", ""))
	if selected_node != null and selected_node.get_script() is Script:
		var node_script := selected_node.get_script() as Script
		if node_script.resource_path == context_path:
			_locked_script = node_script
	if _locked_script == null:
		var script_editor := EditorInterface.get_script_editor()
		if script_editor != null:
			var current_script := script_editor.get_current_script()
			if current_script != null and current_script.resource_path == context_path:
				_locked_script = current_script
	_pending_kind = "builder"
	_chat_streamed = false
	_reasoning_received = ""
	message_added.emit("user", task)
	_set_state(PLANNING, "正在理解任务和锁定上下文")
	_client.stream = false
	_client.system_prompt = ""
	# Multi-file JSON responses routinely take longer than a short Chat reply.
	if _client.timeout_seconds > 0.0:
		_client.timeout_seconds = maxf(_client.timeout_seconds, 180.0)
		_set_state(GENERATING, "正在生成脚本和节点操作（最长 %d 秒）" % int(_client.timeout_seconds))
	else:
		_set_state(GENERATING, "正在生成脚本和节点操作（无超时上限）")
	_client.send_raw([{"role": "user", "content": BUILDER.prompt(task, context)}])
	return true


func run_chat(message: String) -> bool:
	var text := message.strip_edges()
	if text.is_empty():
		return false
	if is_busy():
		_set_state(ERROR, "已有请求正在进行。")
		return false
	if has_unresolved_transaction():
		_set_state(ERROR, "上一次应用没有完整回滚，请先点击「重试回滚」。")
		return false
	if store.has_pending():
		_set_state(ERROR, "请先应用或撤销 Builder 改动，再切换到 Chat。")
		return false
	load_config()
	if not is_configured():
		_set_state(ERROR, "请先配置 Base URL、API Key 和模型。")
		return false
	_pending_kind = "chat"
	_chat_streamed = false
	_reasoning_received = ""
	_chat_history.append({"role": "user", "content": text})
	message_added.emit("user", text)
	_set_state(GENERATING, "模型正在回复")
	var stream_setting := true
	if Engine.is_editor_hint():
		stream_setting = bool(_setting(
			EditorInterface.get_editor_settings(),
			"ai_assistant/stream",
			true,
		))
	_client.stream = stream_setting
	_client.system_prompt = String(get_config().system_prompt)
	_client.send_raw(_chat_history)
	return true


func cancel() -> void:
	if _client != null and _client.is_busy():
		# cancel() emits request_finished synchronously. Release the request first
		# so its completion cannot appear as an error or append stale output.
		_pending_kind = ""
		_reasoning_received = ""
		_client.cancel()
		_set_state(CANCELLED, "已停止")


func clear_chat_history() -> void:
	_chat_history.clear()
	if _pending_kind != "builder":
		_client.clear_history()


func discard_draft() -> void:
	if state_key == APPLYING:
		return
	if has_unresolved_transaction():
		retry_rollback()
		return
	store.discard_draft()
	_original_node_scripts.clear()
	_original_script_sources.clear()
	_clear_locks()
	_set_state(IDLE, "已撤销本轮草稿")


func retry_rollback() -> Dictionary:
	var message := _rollback_transaction("正在重试回滚")
	if has_unresolved_transaction():
		_set_state(ERROR, message)
		return {"ok": false, "error": message}
	store.discard_draft()
	_clear_locks()
	_set_state(IDLE, "回滚已完成，未解决事务已清除")
	return {"ok": true, "error": ""}


func apply_all() -> Dictionary:
	if state_key != REVIEW or not store.has_pending():
		return {"ok": false, "error": "没有可应用的改动。"}
	var context_error := _validate_locked_context()
	if not context_error.is_empty():
		_set_state(ERROR, context_error)
		return {"ok": false, "error": context_error}
	var snapshot_result := _capture_node_snapshots()
	if not bool(snapshot_result.get("ok", false)):
		var snapshot_error := String(snapshot_result.get("error", "无法保存节点回滚状态。"))
		_set_state(ERROR, snapshot_error)
		return {"ok": false, "error": snapshot_error}
	_rollback_incomplete = false
	var recovery := {
		"scene_path": String(captured_context.get("scene_path", "")),
		"scene_content": _locked_scene_content,
		"scene_hash": _locked_scene_hash,
		"scene_needs_restore": false,
	}
	if not store.arm_recovery(recovery):
		store.disarm_recovery()
		_original_node_scripts.clear()
		var recovery_error := "无法持久化事务恢复记录，已取消应用。"
		_set_state(ERROR, recovery_error)
		return {"ok": false, "error": recovery_error}
	_set_state(APPLYING, "正在写入脚本")
	var file_result := store.apply_all_transactional(false)
	if not bool(file_result.get("ok", false)):
		var file_error := String(file_result.get("error", "脚本写入失败。"))
		_original_node_scripts.clear()
		_rollback_incomplete = store.has_unresolved_transaction()
		_set_state(ERROR, file_error)
		return {"ok": false, "error": file_error}
	var validation_error := _validate_written_scripts()
	if not validation_error.is_empty():
		validation_error = _rollback_transaction(validation_error)
		_set_state(ERROR, validation_error)
		return {"ok": false, "error": validation_error}
	if Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().scan()
	var sync_result := _sync_open_scripts()
	if not bool(sync_result.get("ok", false)):
		var sync_error := String(sync_result.get("error", "脚本编辑器同步失败。"))
		sync_error = _rollback_transaction(sync_error)
		_set_state(ERROR, sync_error)
		return {"ok": false, "error": sync_error}
	var node_result := _apply_node_operations()
	if not bool(node_result.get("ok", false)):
		var node_error := String(node_result.get("error", "节点操作失败。"))
		node_error = _rollback_transaction(node_error)
		_set_state(ERROR, node_error)
		return {"ok": false, "error": node_error}
	if not store.node_operations.is_empty():
		var save_error := _save_scene()
		if not save_error.is_empty():
			save_error = _rollback_transaction(save_error)
			_set_state(ERROR, save_error)
			return {"ok": false, "error": save_error}
	_original_node_scripts.clear()
	_original_script_sources.clear()
	store.disarm_recovery()
	_clear_locks()
	_set_state(DONE, "已应用 %d 个文件和 %d 个节点操作" % [
		int(file_result.get("count", 0)),
		store.node_operations.size(),
	])
	draft_changed.emit()
	return {
		"ok": true,
		"files": int(file_result.get("count", 0)),
		"node_operations": store.node_operations.size(),
	}


func clear_finished() -> void:
	if state_key == DONE or state_key == ERROR or state_key == CANCELLED:
		if has_unresolved_transaction():
			retry_rollback()
			return
		store.discard_draft()
		_clear_locks()
		_set_state(IDLE, "等待任务")


func _on_request_finished(success: bool, error_message: String) -> void:
	var kind := _pending_kind
	if kind.is_empty():
		return
	_pending_kind = ""
	if not success:
		if state_key != CANCELLED:
			_set_state(ERROR, error_message)
		return
	# Non-streamed responses (including Builder) have no reasoning_chunk signal.
	# For streamed responses, emit only any final suffix not already delivered.
	var reasoning := _client.last_reasoning_text
	if reasoning.begins_with(_reasoning_received):
		var remaining := reasoning.substr(_reasoning_received.length())
		_reasoning_received = reasoning
		if not remaining.is_empty():
			reasoning_text.emit(remaining)
	if kind == "chat":
		var answer := _client.last_response_text
		_chat_history.append({"role": "assistant", "content": answer})
		if not _chat_streamed:
			message_added.emit("assistant", answer)
		_set_state(IDLE, "回复完成")
	elif kind == "builder":
		_build_draft(_client.last_response_text)


func _build_draft(response: String) -> void:
	var parsed := BUILDER.parse(response)
	if parsed.has("error"):
		_set_state(ERROR, String(parsed.error))
		message_added.emit("system", String(parsed.error))
		return
	var plan: Array = parsed.get("plan", [])
	store.begin_session(plan, String(parsed.get("summary", "Builder 已生成改动")))
	var changes: Array = parsed.get("changes", [])
	var review_changes: Array = []
	for raw in changes:
		var change: Dictionary = (raw as Dictionary).duplicate(true)
		var path := String(change.get("path", ""))
		if not store.is_safe_path(path):
			store.discard_draft()
			_set_state(ERROR, "Builder 返回了不安全路径：%s" % path)
			return
		var before := ""
		if String(change.get("action", "")) == "update":
			var open_entry := _open_script_entry(path)
			if not open_entry.is_empty():
				before = String(open_entry.get("source", ""))
			elif path == String(captured_context.get("script_path", "")):
				before = String(captured_context.get("script_source", ""))
			else:
				before = FileAccess.get_file_as_string(path)
			var edits: Variant = change.get("edits", [])
			if edits is Array and not edits.is_empty():
				var patched := INLINE_PATCH.apply_edits(before, edits)
				if patched.has("error"):
					store.discard_draft()
					_set_state(ERROR, "%s：%s" % [path, String(patched.error)])
					return
				change.content = String(patched.get("text", ""))
		change.preview_before = before
		review_changes.append(change)
	var added := store.add_changes(review_changes)
	if added != changes.size():
		var reason := store.last_error if not store.last_error.is_empty() else "改动校验未通过。"
		store.discard_draft()
		_set_state(ERROR, reason)
		return
	var operations: Array = parsed.get("node_operations", [])
	if not operations.is_empty() and String(captured_context.get("selected_node_path", "")).is_empty():
		store.discard_draft()
		_set_state(ERROR, "AI 请求挂载脚本，但任务开始时没有锁定节点。")
		return
	var locked_operations: Array = []
	for raw in operations:
		var operation: Dictionary = (raw as Dictionary).duplicate(true)
		var operation_path := String(operation.get("script_path", ""))
		if not store.is_safe_path(operation_path):
			store.discard_draft()
			_set_state(ERROR, "节点操作包含不安全路径：%s" % operation_path)
			return
		var operation_in_changes := false
		for proposed_change in review_changes:
			if String(proposed_change.get("path", "")) == operation_path:
				operation_in_changes = true
				break
		if not operation_in_changes and not FileAccess.file_exists(operation_path):
			store.discard_draft()
			_set_state(ERROR, "待绑定脚本不存在：%s" % operation_path)
			return
		operation.disk_hash = (
			FileAccess.get_file_as_string(operation_path).sha256_text()
			if FileAccess.file_exists(operation_path)
			else ""
		)
		locked_operations.append(operation)
	store.set_node_operations(locked_operations)
	message_added.emit("assistant", String(parsed.get("summary", "已生成待审查改动。")))
	_set_state(REVIEW, "生成完成，请检查结果后应用全部")
	draft_changed.emit()


func _validate_written_scripts() -> String:
	for proposal in store.proposals:
		if String(proposal.get("action", "")) == "delete":
			continue
		var was_printing_errors := Engine.print_error_messages
		Engine.print_error_messages = false
		var script := ResourceLoader.load(
			String(proposal.get("path", "")),
			"Script",
			ResourceLoader.CACHE_MODE_IGNORE_DEEP,
		)
		var reload_error := ERR_PARSE_ERROR
		if script is GDScript:
			reload_error = script.reload(false)
		Engine.print_error_messages = was_printing_errors
		if not (script is GDScript) or reload_error != OK:
			return "脚本校验失败，已自动回滚：%s" % String(proposal.get("path", ""))
	return ""


func _capture_node_snapshots() -> Dictionary:
	_original_node_scripts.clear()
	if store.node_operations.is_empty():
		return {"ok": true}
	var target: Variant = _locked_target_node.get_ref() if _locked_target_node != null else null
	if not (target is Node) or not is_instance_valid(target):
		return {"ok": false, "error": "任务开始时选中的节点已不存在。"}
	var old_script: Variant = target.get_script()
	_original_node_scripts.append({
		"node": target,
		"script": old_script,
		"script_source": old_script.source_code if old_script is Script else "",
		"properties": _capture_script_properties(target),
	})
	return {"ok": true}


func _apply_node_operations() -> Dictionary:
	if store.node_operations.is_empty():
		return {"ok": true}
	var target: Variant = _locked_target_node.get_ref() if _locked_target_node != null else null
	if not (target is Node) or not is_instance_valid(target):
		return {"ok": false, "error": "任务开始时选中的节点已不存在。"}
	var saved_properties: Dictionary = (
		_original_node_scripts[0].get("properties", {})
		if not _original_node_scripts.is_empty()
		else {}
	)
	for operation in store.node_operations:
		if String(operation.get("operation", "")) != "attach_script":
			return {"ok": false, "error": "不支持的节点操作。"}
		var script_path := String(operation.get("script_path", ""))
		var loaded := ResourceLoader.load(
			script_path,
			"Script",
			ResourceLoader.CACHE_MODE_IGNORE_DEEP,
		)
		if not (loaded is Script):
			return {"ok": false, "error": "脚本加载失败，无法绑定节点：%s" % script_path}
		var current: Variant = target.get_script()
		if current is GDScript and current.resource_path == script_path:
			current.source_code = FileAccess.get_file_as_string(script_path)
			var reload_error: Error = current.reload(true)
			if reload_error != OK:
				return {
					"ok": false,
					"error": "更新节点现有脚本失败：%s" % error_string(reload_error),
				}
		else:
			target.set_script(loaded)
			if target.get_script() != loaded:
				return {
					"ok": false,
					"error": "脚本基类与节点类型不兼容：%s" % script_path,
				}
		_restore_compatible_properties(target, saved_properties)
	return {"ok": true}


func _restore_node_scripts() -> PackedStringArray:
	var failures := PackedStringArray()
	var remaining: Array[Dictionary] = []
	for snapshot in _original_node_scripts:
		var failed := false
		var node: Variant = snapshot.get("node")
		if not (node is Node) or not is_instance_valid(node):
			failures.append("目标节点已失效")
			remaining.append(snapshot)
			continue
		var old_script: Variant = snapshot.get("script")
		if old_script is GDScript:
			old_script.source_code = String(snapshot.get("script_source", ""))
			var reload_error: Error = old_script.reload(true)
			if reload_error != OK:
				failures.append("原节点脚本无法重新加载")
				failed = true
		if node.get_script() != old_script:
			node.set_script(old_script)
		if node.get_script() != old_script:
			failures.append("原节点脚本无法恢复")
			remaining.append(snapshot)
			continue
		_restore_compatible_properties(node, snapshot.get("properties", {}))
		if failed:
			remaining.append(snapshot)
	_original_node_scripts = remaining
	return failures


func _capture_script_properties(node: Node) -> Dictionary:
	var properties := {}
	for info in node.get_property_list():
		var usage := int(info.get("usage", 0))
		if (usage & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
			continue
		var property_name := String(info.get("name", ""))
		if property_name.is_empty():
			continue
		properties[property_name] = {
			"value": node.get(property_name),
			"type": int(info.get("type", TYPE_NIL)),
		}
	return properties


func _restore_compatible_properties(node: Node, properties: Dictionary) -> void:
	var accepted := {}
	for info in node.get_property_list():
		var usage := int(info.get("usage", 0))
		if (usage & PROPERTY_USAGE_SCRIPT_VARIABLE) != 0:
			accepted[String(info.get("name", ""))] = int(info.get("type", TYPE_NIL))
	for property_name in properties:
		if not accepted.has(property_name):
			continue
		var snapshot: Dictionary = properties[property_name]
		var old_type := int(snapshot.get("type", TYPE_NIL))
		var new_type := int(accepted[property_name])
		if old_type == new_type or old_type == TYPE_NIL or new_type == TYPE_NIL:
			node.set(property_name, snapshot.get("value"))


func _rollback_transaction(reason: String) -> String:
	var failures := PackedStringArray()
	if _scene_save_attempted:
		var scene_path := String(captured_context.get("scene_path", ""))
		if not store.restore_scene_snapshot(scene_path, _locked_scene_content):
			failures.append("场景文件无法恢复")
		else:
			_scene_save_attempted = false
			var recovery := store.recovery_data.duplicate(true)
			recovery.scene_needs_restore = false
			if not store.update_recovery_data(recovery):
				failures.append("场景恢复记录无法更新")
	var file_rollback := store.rollback_session_detailed()
	if not bool(file_rollback.get("ok", false)):
		var file_failures: Variant = file_rollback.get("failures", PackedStringArray())
		if file_failures is PackedStringArray:
			failures.append_array(file_failures)
		elif file_failures is Array:
			for failure in file_failures:
				failures.append(String(failure))
	# Restore disk dependencies before reloading the scripts attached to live nodes.
	failures.append_array(_restore_script_sources())
	failures.append_array(_restore_node_scripts())
	if Engine.is_editor_hint():
		# A rollback can remove newly created scripts. Refresh the FileSystem dock and
		# resource imports after the transaction, outside the current import callback.
		EditorInterface.get_resource_filesystem().call_deferred("scan")
	if not failures.is_empty():
		_rollback_incomplete = true
		var unresolved_message := reason + "\n回滚未完整完成：" + ", ".join(failures)
		store.mark_unresolved(unresolved_message)
		return unresolved_message
	_rollback_incomplete = false
	return reason


func _sync_open_scripts() -> Dictionary:
	if not Engine.is_editor_hint():
		return {"ok": true}
	_original_script_sources.clear()
	var by_path := {}
	for proposal in store.proposals:
		by_path[String(proposal.get("path", ""))] = String(proposal.get("content", ""))
	for entry in _open_script_entries():
		var path := String(entry.get("path", ""))
		if not by_path.has(path):
			continue
		var script: Script = entry.get("script")
		var code: Variant = entry.get("code")
		var editor_base: Variant = entry.get("editor")
		_original_script_sources.append({
			"script": script,
			"source": String(entry.get("source", "")),
			"code": code,
			"editor": editor_base,
			"was_unsaved": bool(entry.get("unsaved", false)),
		})
		var next_source := String(by_path[path])
		script.source_code = next_source
		if code is CodeEdit and is_instance_valid(code):
			code.text = script.source_code
		if editor_base != null and editor_base.has_method("apply_code"):
			editor_base.call("apply_code")
		var save_error := ResourceSaver.save(script, path)
		if save_error != OK:
			return {
				"ok": false,
				"error": "无法同步已打开脚本：%s" % error_string(save_error),
			}
		if editor_base != null and editor_base.has_method("tag_saved_version"):
			editor_base.call("tag_saved_version")
	return {"ok": true}


func _restore_script_sources() -> PackedStringArray:
	var failures := PackedStringArray()
	var remaining: Array[Dictionary] = []
	for snapshot in _original_script_sources:
		var script: Variant = snapshot.get("script")
		if script is Script:
			script.source_code = String(snapshot.get("source", ""))
			var code: Variant = snapshot.get("code")
			if code is CodeEdit and is_instance_valid(code):
				code.text = script.source_code
			var editor_base: Variant = snapshot.get("editor")
			if editor_base != null and editor_base.has_method("apply_code"):
				editor_base.call("apply_code")
			if (
				not bool(snapshot.get("was_unsaved", false))
				and editor_base != null
				and editor_base.has_method("tag_saved_version")
			):
				editor_base.call("tag_saved_version")
		else:
			failures.append("已打开脚本资源已失效")
			remaining.append(snapshot)
	_original_script_sources = remaining
	return failures


func _open_script_entry(path: String) -> Dictionary:
	if not Engine.is_editor_hint():
		return {}
	for entry in _open_script_entries():
		if String(entry.get("path", "")) == path:
			return entry
	return {}


func _open_script_entries() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	if not Engine.is_editor_hint():
		return entries
	var script_editor := EditorInterface.get_script_editor()
	if script_editor == null:
		return entries
	var scripts: Array = script_editor.get_open_scripts()
	var editors: Array = script_editor.get_open_script_editors()
	var unsaved := PackedStringArray()
	if script_editor.has_method("get_unsaved_files"):
		unsaved = script_editor.call("get_unsaved_files")
	for i in range(scripts.size()):
		if not (scripts[i] is Script):
			continue
		var script := scripts[i] as Script
		if not store.is_safe_path(script.resource_path):
			continue
		var editor_base: Variant = editors[i] if i < editors.size() else null
		var code: Variant = null
		var source := script.source_code
		if editor_base != null and editor_base.has_method("get_base_editor"):
			var base: Variant = editor_base.get_base_editor()
			if base is CodeEdit:
				code = base
				source = code.text
		var is_unsaved := unsaved.has(script.resource_path)
		if not script_editor.has_method("get_unsaved_files") and FileAccess.file_exists(script.resource_path):
			is_unsaved = source != FileAccess.get_file_as_string(script.resource_path)
		entries.append({
			"path": script.resource_path,
			"script": script,
			"editor": editor_base,
			"code": code,
			"source": source,
			"unsaved": is_unsaved,
		})
	return entries


func _validate_locked_context() -> String:
	for proposal in store.proposals:
		if String(proposal.get("status", "")) != "pending":
			continue
		var path := String(proposal.get("path", ""))
		var exists_now := FileAccess.file_exists(path)
		if exists_now != bool(proposal.get("existed", false)):
			return "待审查期间文件状态已变化，请重新生成：%s" % path
		var current := FileAccess.get_file_as_string(path) if exists_now else ""
		if current.sha256_text() != String(proposal.get("disk_hash", proposal.get("source_hash", ""))):
			return "待审查期间文件已被修改，请重新生成：%s" % path
		var open_entry := _open_script_entry(path)
		if (
			not open_entry.is_empty()
			and String(open_entry.get("source", "")).sha256_text()
			!= String(proposal.get("source_hash", ""))
		):
			return "待审查期间脚本标签页已被修改，请重新生成：%s" % path
	var locked_path := String(captured_context.get("script_path", ""))
	if _locked_script != null and is_instance_valid(_locked_script) and not locked_path.is_empty():
		var live_source := _locked_script.source_code
		var locked_entry := _open_script_entry(locked_path)
		if not locked_entry.is_empty():
			live_source = String(locked_entry.get("source", ""))
		if live_source.sha256_text() != String(captured_context.get("script_hash", "")):
			return "待审查期间已打开脚本被修改，请重新生成：%s" % locked_path
	if not store.node_operations.is_empty():
		if not Engine.is_editor_hint():
			return "节点操作只能在 Godot 编辑器中应用。"
		var root := EditorInterface.get_edited_scene_root()
		if root == null:
			return "当前场景已关闭。"
		var locked_root: Variant = _locked_scene_root.get_ref() if _locked_scene_root != null else null
		if locked_root != root or root.get_instance_id() != int(captured_context.get("scene_root_instance_id", 0)):
			return "场景根节点实例已经变化，请重新生成。"
		if root.scene_file_path != String(captured_context.get("scene_path", "")):
			return "当前场景与任务开始时不同，请重新生成。"
		if root.scene_file_path.is_empty():
			return "场景尚未保存。请先保存场景，再重新生成 Builder 任务。"
		if _locked_scene_hash.is_empty():
			return "无法为场景创建安全快照；节点操作当前只支持已保存的 .tscn 场景。"
		var current_scene := store.capture_scene_snapshot(root.scene_file_path)
		if not bool(current_scene.get("ok", false)):
			return String(current_scene.get("error", "无法读取场景文件。"))
		if String(current_scene.get("hash", "")) != _locked_scene_hash:
			return "场景文件在审查期间已被外部修改，请重新加载后再生成。"
		var scene_file := FileAccess.open(root.scene_file_path, FileAccess.READ_WRITE)
		if scene_file == null:
			return "场景文件不可写，无法保证节点事务安全。"
		scene_file.close()
		var node_path := NodePath(String(captured_context.get("selected_node_path", "")))
		var target := root.get_node_or_null(node_path)
		var locked_target: Variant = _locked_target_node.get_ref() if _locked_target_node != null else null
		if target == null or target != locked_target:
			return "任务开始时选中的节点已不存在。"
		if target.get_instance_id() != int(captured_context.get("selected_node_instance_id", 0)):
			return "选中节点实例已经变化，请重新生成。"
		if target.get_class() != String(captured_context.get("selected_node_type", "")):
			return "选中节点类型已经变化，请重新生成。"
		var current_script: Variant = target.get_script()
		if _locked_target_script_id == 0 and current_script != null:
			return "选中节点的脚本绑定已经变化，请重新生成。"
		if _locked_target_script_id != 0:
			if not (current_script is Script):
				return "选中节点的原脚本已被移除，请重新生成。"
			if (
				current_script.get_instance_id() != _locked_target_script_id
				or current_script.resource_path != _locked_target_script_path
			):
				return "选中节点的脚本绑定已经变化，请重新生成。"
		for operation in store.node_operations:
			var operation_path := String(operation.get("script_path", ""))
			if not store.is_safe_path(operation_path):
				return "待绑定脚本路径不安全：%s" % operation_path
			var in_proposals := false
			for proposal in store.proposals:
				if String(proposal.get("path", "")) == operation_path:
					in_proposals = true
					break
			if in_proposals:
				continue
			if not FileAccess.file_exists(operation_path):
				return "待绑定脚本已不存在：%s" % operation_path
			var current_hash := FileAccess.get_file_as_string(operation_path).sha256_text()
			if current_hash != String(operation.get("disk_hash", "")):
				return "待绑定脚本在审查期间已变化：%s" % operation_path
	return ""


func _save_scene() -> String:
	var root := EditorInterface.get_edited_scene_root()
	if root == null or root.scene_file_path.is_empty():
		return "场景尚未保存，无法完成节点绑定事务。请先保存场景后重试。"
	if not EditorInterface.has_method("save_scene"):
		return "当前 Godot 版本不支持从插件保存场景。"
	_scene_save_attempted = true
	var recovery := store.recovery_data.duplicate(true)
	recovery.scene_needs_restore = true
	if not store.update_recovery_data(recovery):
		return "无法更新场景恢复记录，已取消保存。"
	var result: Variant = EditorInterface.save_scene()
	if result is int and int(result) != OK:
		return "场景保存失败：%s" % error_string(int(result))
	return ""


func _live_script_text(script_editor: ScriptEditor, script: Script) -> String:
	var editor := script_editor.get_current_editor()
	if editor != null and editor.has_method("get_base_editor"):
		var base: Variant = editor.get_base_editor()
		if base is CodeEdit:
			return (base as CodeEdit).text
	return script.source_code


func _on_stream_chunk(text: String) -> void:
	if _pending_kind == "chat" and not text.is_empty():
		_chat_streamed = true
		stream_text.emit(text)


func _on_reasoning_chunk(text: String) -> void:
	if _pending_kind.is_empty() or text.is_empty():
		return
	_reasoning_received += text
	reasoning_text.emit(text)


func _on_models_loaded(models: Array, error_message: String) -> void:
	models_loaded.emit(models, error_message)


func _on_token_usage_reported(request_tokens: int) -> void:
	if request_tokens <= 0:
		return
	# 只累计服务端明确返回的 usage，避免用字符数估算造成计费误导。
	var previous := _total_tokens_consumed
	_total_tokens_consumed += request_tokens
	if Engine.is_editor_hint():
		EditorInterface.get_editor_settings().set_setting(
			"ai_assistant/total_tokens_consumed",
			_total_tokens_consumed,
		)
	var previous_step := floori(float(previous) / TOKEN_WARNING_STEP)
	var current_step := floori(float(_total_tokens_consumed) / TOKEN_WARNING_STEP)
	if current_step > previous_step:
		token_usage_threshold_reached.emit(
			_total_tokens_consumed,
			current_step * TOKEN_WARNING_STEP,
		)


func _on_response_stalled(elapsed_seconds: int) -> void:
	response_stalled.emit(elapsed_seconds)


func _set_state(next_state: String, message: String) -> void:
	state_key = next_state
	state_message = message
	state_changed.emit(state_key, state_message)


func _clear_locks() -> void:
	_locked_script = null
	_locked_scene_root = null
	_locked_target_node = null
	_locked_target_script_id = 0
	_locked_target_script_path = ""
	_locked_scene_content = ""
	_locked_scene_hash = ""
	_scene_save_attempted = false
	_rollback_incomplete = false


func _setting(settings: EditorSettings, key: String, fallback: Variant) -> Variant:
	var full_key := key if key.begins_with("ai_assistant/") else "ai_assistant/" + key
	return settings.get_setting(full_key) if settings.has_setting(full_key) else fallback
