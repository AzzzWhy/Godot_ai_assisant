extends SceneTree
## 冒烟测试（纯离线，不发起任何真实网络请求）：
## 验证 AILLMClient 的信号、请求队列、历史维护与 SSE 流式解析。
##
## 运行方式（项目根目录）：
##   godot --headless --path . -s res://tests/smoke_test.gd
## 退出码 0 = 全部通过。
##
## 注意：Godot 4.x 的 lambda 按值捕获局部变量，所以测试里用 Array/Dictionary
## 这类引用类型来累加/记录信号结果。

var _fails := 0
const PROPOSAL_STORE := preload("res://addons/ai_assistant/agent/proposal_store.gd")
const INLINE_PATCH := preload("res://addons/ai_assistant/agent/inline_patch.gd")
const BUILDER := preload("res://addons/ai_assistant/agent/builder_contract.gd")
const WORKBENCH := preload("res://addons/ai_assistant/editor/workbench_main.gd")


func _initialize() -> void:
	_test_no_key_fails_cleanly()
	_test_sse_streaming()
	_test_nonstream_json()
	_test_queue_and_cleanup()
	_test_proposal_contract()
	_test_inline_patch()
	_test_builder_contract()
	_test_transactional_store()
	_test_update_apply_and_rollback()
	_test_transaction_rolls_back_on_conflict()
	_test_symlink_sandbox()
	_test_scene_snapshot()
	_test_recovery_persistence()
	await process_frame
	_test_workbench_builds()
	if _fails == 0:
		print("SMOKE_TEST_OK: 全部通过")
		quit(0)
	else:
		printerr("SMOKE_TEST_FAILED: %d 项失败" % _fails)
		quit(1)


# ---------- 场景 1：未配置 Key 立即失败，且失败后历史被清理 ----------

func _test_no_key_fails_cleanly() -> void:
	var client: AILLMClient = AILLMClient.new()
	get_root().add_child(client)
	var got: Array = []
	client.request_finished.connect(func(success: bool, err: String) -> void:
		got.append(success)
		_check(not success and err.contains("API Key"), "无 Key 应失败并提示 API Key，实际: %s" % err)
	)
	client.chat("你好")
	_check(not got.is_empty(), "无 Key 路径应同步发出 request_finished")
	_check(not got.is_empty() and got[0] == false, "request_finished 应携带 success=false")
	_check(client.get_history().is_empty(), "失败后历史应为空，实际 %d 条" % client.get_history().size())
	_check(not client.is_busy(), "失败后不应处于 busy")
	client.free()


# ---------- 场景 2：SSE 流式解析（直接喂事件，不走网络） ----------

func _test_sse_streaming() -> void:
	var client: AILLMClient = AILLMClient.new()
	get_root().add_child(client)
	client.api_key = "sk-test"
	client.base_url = "http://127.0.0.1:1/v1"  # 不可达端口，阻止任何真实请求
	var streamed: Array = []
	var reasoned: Array = []
	var got_response: Array = []
	var finished: Array = []
	client.stream_chunk.connect(func(t: String) -> void: streamed.append(t))
	client.reasoning_chunk.connect(func(t: String) -> void: reasoned.append(t))
	client.response_received.connect(func(r: Dictionary) -> void: got_response.append(r))
	client.request_finished.connect(func(s: bool, e: String) -> void: finished.append(s))

	client.chat("继续")
	_check(client.is_busy(), "chat 后应处于 busy")
	client._handle_stream_event('data: {"choices":[{"delta":{"reasoning_content":"让我想想"},"finish_reason":null}]}')
	client._handle_stream_event('data: {"choices":[{"delta":{"content":"好的，"},"finish_reason":null}]}')
	client._handle_stream_event('data: {"choices":[{"delta":{"content":"完成。"},"finish_reason":null}]}')
	client._handle_stream_event("data: [DONE]")

	_check("".join(streamed) == "好的，完成。", "流式正文应为「好的，完成。」，实际: '%s'" % "".join(streamed))
	_check("".join(reasoned) == "让我想想", "思考内容应为「让我想想」，实际: '%s'" % "".join(reasoned))
	_check(client.last_response_text == "好的，完成。", "last_response_text 错误: '%s'" % client.last_response_text)
	_check(client.last_reasoning_text == "让我想想", "last_reasoning_text 错误: '%s'" % client.last_reasoning_text)
	_check(not got_response.is_empty() and got_response[0].get("content", "") == "好的，完成。", "response_received 内容错误")
	_check(not finished.is_empty() and finished[0] == true, "完成后应发出 request_finished(success)")
	_check(not client.is_busy(), "结束后不应 busy")

	var h := client.get_history()
	_check(h.size() == 2, "历史应有 user + assistant 共 2 条，实际 %d" % h.size())
	if h.size() == 2:
		_check(String(h[0].get("role", "")) == "user", "第 1 条应为 user")
		_check(String(h[1].get("role", "")) == "assistant", "第 2 条应为 assistant")
		_check(String(h[1].get("reasoning_content", "")) == "让我想想", "assistant 条目应保存思考内容")
	client.free()


# ---------- 场景 3：非流式整包 JSON 解析 ----------

func _test_nonstream_json() -> void:
	var client: AILLMClient = AILLMClient.new()
	get_root().add_child(client)
	client.base_url = "http://127.0.0.1:1/v1"
	client.stream = false
	client.chat("x")
	client._extract_from_json('{"choices":[{"message":{"content":"整包回复","reasoning_content":"想法"}}]}')
	_check(client.last_response_text == "整包回复", "整包解析正文错误: '%s'" % client.last_response_text)
	_check(client.last_reasoning_text == "想法", "整包解析思考错误: '%s'" % client.last_reasoning_text)
	client.free()


# ---------- 场景 4：无 Key 时连发两条 → 两条都失败、队列与历史保持干净 ----------

func _test_queue_and_cleanup() -> void:
	var client: AILLMClient = AILLMClient.new()
	get_root().add_child(client)
	var count: Array = []
	client.request_finished.connect(func(s: bool, e: String) -> void: count.append(s))
	# 无 Key 时两条请求都是同步失败的，无需等待帧
	client.chat("第一条")
	client.chat("第二条")
	_check(count.size() == 2, "两条请求都应结束，实际 %d 次" % count.size())
	_check(client.get_history().is_empty(), "两条失败后历史应为空，实际 %d 条" % client.get_history().size())
	_check(not client.is_busy(), "队列清空后不应 busy")
	client.free()


# ---------- 场景 5：提案 JSON 与路径沙箱 ----------

func _test_proposal_contract() -> void:
	var store: AIProposalStore = PROPOSAL_STORE.new()
	store.begin_session(["更新脚本"])
	_check(store.add_changes([{
		"path": "res://tests/example.gd",
		"action": "create",
		"summary": "测试",
		"content": "extends Node",
	}]) == 1, "合法 .gd 提案应被加入")
	_check(store.proposals.size() == 1, "提案列表应有 1 项")
	_check(store.add_changes([{"path": "res://../outside.gd", "action": "update", "content": "x"}]) == 0, "路径穿越提案必须被拒绝")
	_check(store.add_changes([{"path": "res://folder\\outside.gd", "action": "create", "content": "x"}]) == 0, "反斜杠路径必须被拒绝")
	_check(store.add_changes([{"path": "res://scene.tscn", "action": "update", "content": "x"}]) == 0, "非 .gd 文件提案必须被拒绝")


func _test_inline_patch() -> void:
	var source := "extends Node\nvar score := 1\nfunc ready():\n\tpass\n"
	var ok: Dictionary = INLINE_PATCH.apply_edits(source, [{
		"old_string": "var score := 1",
		"new_string": "var score := 2",
		"summary": "加分",
	}])
	_check(not ok.has("error"), "唯一匹配的替换应成功")
	_check(String(ok.get("text", "")).contains("var score := 2"), "替换后应包含新代码")
	_check(ok.get("hunks", []).size() == 1, "应产生 1 个 hunk")
	var missing: Dictionary = INLINE_PATCH.apply_edits(source, [{"old_string": "not-in-file", "new_string": "x"}])
	_check(missing.has("error"), "找不到原文时应失败")
	var dup_src := "a := 1\na := 1\n"
	var dup: Dictionary = INLINE_PATCH.apply_edits(dup_src, [{"old_string": "a := 1", "new_string": "a := 2"}])
	_check(dup.has("error"), "原文出现多次时应拒绝")
	var parsed: Dictionary = INLINE_PATCH.parse_response("```json\n" + JSON.stringify({
		"summary": "测试",
		"edits": [{"old_string": "var score := 1", "new_string": "var score := 2"}],
	}) + "\n```")
	_check(parsed.has("edits"), "应解析出 edits 数组")


func _test_builder_contract() -> void:
	var response := "```json\n" + JSON.stringify({
		"plan": ["给 Player 写移动脚本"],
		"summary": "完成移动脚本",
		"changes": [{
			"path": "res://player.gd",
			"action": "create",
			"summary": "创建移动脚本",
			"content": "extends CharacterBody2D",
		}],
		"node_operations": [{
			"operation": "attach_script",
			"target": "selected",
			"script_path": "res://player.gd",
		}],
	}) + "\n```"
	var parsed: Dictionary = BUILDER.parse(response)
	var changes: Array = parsed.get("changes", [])
	var operations: Array = parsed.get("node_operations", [])
	_check(changes.size() == 1, "Builder JSON 应解析多文件 changes")
	_check(not changes.is_empty() and String(changes[0].get("path", "")) == "res://player.gd", "Builder 应保留安全路径")
	_check(operations.size() == 1, "Builder JSON 应解析节点操作")
	_check(not operations.is_empty() and String(operations[0].get("operation", "")) == "attach_script", "Builder 应解析 attach_script")
	var unsafe := BUILDER.parse("```json\n" + JSON.stringify({
		"changes": [{"path": "res://../bad.gd", "action": "create", "content": "x"}],
		"node_operations": [],
	}) + "\n```")
	_check(unsafe.has("error"), "Builder 必须拒绝路径穿越")
	var edit_response := BUILDER.parse("```json\n" + JSON.stringify({
		"changes": [{
			"path": "res://player.gd",
			"action": "update",
			"edits": [{"old_string": "var speed := 1", "new_string": "var speed := 2"}],
		}],
		"node_operations": [],
	}) + "\n```")
	_check(not edit_response.has("error"), "Builder update 应接受精确 edits")
	var invalid_node := BUILDER.parse("```json\n" + JSON.stringify({
		"changes": [{"path": "res://player.gd", "action": "create", "content": "extends Node"}],
		"node_operations": [{
			"operation": "attach_script",
			"target": "../Other",
			"script_path": "res://player.gd",
		}],
	}) + "\n```")
	_check(invalid_node.has("error"), "Builder 必须拒绝未锁定节点操作")


func _test_transactional_store() -> void:
	var path := "res://tests/__ai_workbench_smoke.gd"
	var absolute := ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(absolute)
	var store: AIProposalStore = PROPOSAL_STORE.new()
	store.begin_session(["创建临时脚本"], "事务测试")
	var added := store.add_changes([{
		"path": path,
		"action": "create",
		"summary": "临时脚本",
		"content": "extends Node\n",
	}])
	_check(added == 1 and store.has_pending(), "事务 store 应接受安全 create")
	var result := store.apply_all_transactional()
	_check(bool(result.get("ok", false)), "事务应原子应用全部文件")
	_check(FileAccess.file_exists(path), "应用后临时脚本应存在")
	var restored := store.rollback_session()
	_check(restored == 1 and not FileAccess.file_exists(path), "回滚应删除本轮新建脚本")
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(absolute)


func _test_transaction_rolls_back_on_conflict() -> void:
	var created_path := "res://tests/__ai_atomic_created.gd"
	var updated_path := "res://tests/__ai_atomic_updated.gd"
	_remove(created_path)
	_remove(updated_path)
	_write(updated_path, "extends Node\nvar value := 1\n")
	var store: AIProposalStore = PROPOSAL_STORE.new()
	store.begin_session(["验证全部或全部不应用"], "原子回滚测试")
	var added := store.add_changes([
		{
			"path": created_path,
			"action": "create",
			"content": "extends Node\n",
		},
		{
			"path": updated_path,
			"action": "update",
			"content": "extends Node\nvar value := 2\n",
		},
	])
	_check(added == 2, "原子事务应接收两个文件")
	_write(updated_path, "extends Node\nvar value := 99\n")
	var result := store.apply_all_transactional()
	_check(not bool(result.get("ok", true)), "文件冲突应让整个事务失败")
	_check(not FileAccess.file_exists(created_path), "事务失败后应删除已经创建的前序文件")
	_check(
		FileAccess.get_file_as_string(updated_path).contains("99"),
		"事务失败不能覆盖外部修改",
	)
	_remove(created_path)
	_remove(updated_path)


func _test_update_apply_and_rollback() -> void:
	var path := "res://tests/__ai_atomic_update_ok.gd"
	_remove(path)
	_write(path, "extends Node\nvar value := 1\n")
	var store: AIProposalStore = PROPOSAL_STORE.new()
	store.begin_session(["更新已有脚本"], "update 回滚测试")
	_check(store.add_changes([{
		"path": path,
		"action": "update",
		"content": "extends Node\nvar value := 2\n",
	}]) == 1, "事务应接受已有脚本 update")
	var result := store.apply_all_transactional()
	_check(
		bool(result.get("ok", false))
		and FileAccess.get_file_as_string(path).contains("value := 2"),
		"原子写入应更新已有脚本",
	)
	var rollback := store.rollback_session_detailed()
	_check(
		bool(rollback.get("ok", false))
		and FileAccess.get_file_as_string(path).contains("value := 1"),
		"详细回滚应恢复已有脚本",
	)
	_remove(path)


func _test_symlink_sandbox() -> void:
	var dir := DirAccess.open("res://tests")
	if dir == null:
		_check(false, "应能打开 tests 目录验证符号链接沙箱")
		return
	var link_name := "__ai_external_link"
	if dir.is_link(link_name) or dir.dir_exists(link_name):
		dir.remove(link_name)
	var create_error := dir.create_link(ProjectSettings.globalize_path("user://"), link_name)
	if create_error != OK:
		print("  • 当前文件系统不支持创建测试符号链接，已跳过链接逃逸用例")
		return
	var store: AIProposalStore = PROPOSAL_STORE.new()
	store.begin_session()
	_check(store.add_changes([{
		"path": "res://tests/%s/outside.gd" % link_name,
		"action": "create",
		"content": "extends Node",
	}]) == 0, "项目内符号链接不得逃逸路径沙箱")
	dir.remove(link_name)


func _test_scene_snapshot() -> void:
	var path := "res://tests/__ai_scene_snapshot.tscn"
	var original := "[gd_scene format=3]\n\n[node name=\"Root\" type=\"Node\"]\n"
	_remove(path)
	_write(path, original)
	var store: AIProposalStore = PROPOSAL_STORE.new()
	var snapshot := store.capture_scene_snapshot(path)
	_write(path, original.replace("Root", "Changed"))
	var restored := store.restore_scene_snapshot(path, String(snapshot.get("content", "")))
	_check(
		bool(snapshot.get("ok", false))
		and restored
		and FileAccess.get_file_as_string(path) == original,
		"场景快照应能检测并恢复保存失败",
	)
	_remove(path)


func _test_recovery_persistence() -> void:
	if FileAccess.file_exists(PROPOSAL_STORE.RECOVERY_FILE):
		print("  • 检测到真实待恢复事务，已跳过持久化标记测试")
		return
	var path := "res://tests/__ai_recovery_marker.gd"
	_remove(path)
	var store: AIProposalStore = PROPOSAL_STORE.new()
	store.begin_session(["保留待恢复状态"], "恢复标记测试")
	store.add_changes([{
		"path": path,
		"action": "create",
		"content": "extends Node\n",
	}])
	_check(store.arm_recovery(), "事务开始前应持久化恢复记录")
	var applied := store.apply_all_transactional()
	_check(bool(applied.get("ok", false)), "模拟中断前事务应已写入文件")
	var recovered: AIProposalStore = PROPOSAL_STORE.new()
	_check(
		recovered.has_unresolved_transaction()
		and recovered.session_id == store.session_id
		and recovered.proposals.size() == 1,
		"未解决事务应跨插件重载恢复并继续阻止新任务",
	)
	recovered.rollback_session_detailed()
	recovered.discard_draft()
	_remove(path)


func _test_workbench_builds() -> void:
	var screen: AIWorkbenchMain = WORKBENCH.new()
	get_root().add_child(screen)
	_check(screen.controller != null, "AI 工作台应创建统一控制器")
	_check(screen.controller.store != null, "AI 工作台应创建统一提案 store")
	screen._layout_initialized = false
	screen._task_panel_manually_set = false
	screen._update_workspace_layout(880.0)
	_check(not screen._left_card.visible, "窄工作区应自动收起任务栏")
	screen._update_workspace_layout(1280.0)
	_check(
		screen._left_card.visible
		and screen._body_split.split_offset == 260
		and screen._center_split.split_offset == -360,
		"默认窗口应按 Godot Dock 使用约 260/中栏/360",
	)
	screen._update_workspace_layout(880.0)
	screen._task_toggle.button_pressed = true
	screen._on_task_toggle()
	_check(screen._left_card.visible, "窄工作区应允许手动展开任务栏")
	_check(screen._settings_window != null, "应创建设置窗口")
	_check(screen._settings_window.get_child_count() > 0, "设置窗口应包含表单内容")
	_check(screen._url_edit != null and screen._key_edit != null, "设置窗口应包含 Base URL 和 API Key")
	var path := "res://tests/__ai_controller_patch.gd"
	var original := "extends Node\nvar speed := 1\n"
	_remove(path)
	_write(path, original)
	screen.controller.captured_context = {
		"script_path": path,
		"script_source": original,
		"selected_node_path": "",
	}
	screen.controller._build_draft("```json\n" + JSON.stringify({
		"summary": "调整速度",
		"plan": ["修改速度"],
		"changes": [{
			"path": path,
			"action": "update",
			"edits": [{
				"old_string": "var speed := 1",
				"new_string": "var speed := 2",
			}],
		}],
		"node_operations": [],
	}) + "\n```")
	_check(screen.controller.state_key == "review", "控制器应进入统一 review 状态")
	var has_proposal := screen.controller.store.proposals.size() == 1
	_check(has_proposal, "控制器应生成一个内存草稿")
	if has_proposal:
		_check(
			String(screen.controller.store.proposals[0].get("content", "")).contains("speed := 2"),
			"控制器应把精确 edits 转换为内存草稿",
		)
	_check(FileAccess.get_file_as_string(path) == original, "审查前不得写入磁盘")
	screen.controller.discard_draft()
	_remove(path)
	var invalid_path := "res://tests/__ai_invalid_draft.gd"
	_remove(invalid_path)
	screen.controller.store.begin_session(["生成非法脚本"], "语法校验测试")
	screen.controller.store.add_changes([{
		"path": invalid_path,
		"action": "create",
		"content": "extends Node\nfunc broken(\n",
	}])
	screen.controller.state_key = "review"
	var invalid_result := screen.controller.apply_all()
	_check(
		not bool(invalid_result.get("ok", true)) and not FileAccess.file_exists(invalid_path),
		"非法 GDScript 必须自动回滚且不留下文件",
	)
	screen.controller.discard_draft()
	_test_multifile_dependency_validation(screen.controller)
	screen.controller.store.rollback_incomplete = true
	_check(
		not screen.controller.run_chat("不应发送"),
		"未解决回滚必须阻止新的 Chat/Builder 请求",
	)
	screen.controller.discard_draft()
	_check(
		not screen.controller.has_unresolved_transaction(),
		"重试回滚成功后才能清除未解决事务",
	)
	_test_node_script_property_rollback(screen.controller)
	screen.shutdown()
	screen.free()


func _test_multifile_dependency_validation(controller: AIWorkbenchController) -> void:
	var base_path := "res://tests/__ai_dependency_base.gd"
	var child_path := "res://tests/__ai_dependency_child.gd"
	_remove(base_path)
	_remove(child_path)
	controller.store.begin_session(["创建相互依赖的脚本"], "多文件依赖校验")
	controller.store.add_changes([
		{
			"path": base_path,
			"action": "create",
			"content": "extends RefCounted\nfunc value() -> int:\n\treturn 1\n",
		},
		{
			"path": child_path,
			"action": "create",
			"content": "extends \"%s\"\nfunc child_value() -> int:\n\treturn value() + 1\n" % base_path,
		},
	])
	controller.state_key = "review"
	var result := controller.apply_all()
	_check(
		bool(result.get("ok", false))
		and FileAccess.file_exists(base_path)
		and FileAccess.file_exists(child_path),
		"合法多文件依赖应在组合写入后通过校验",
	)
	controller.store.rollback_session_detailed()
	controller.clear_finished()
	_remove(base_path)
	_remove(child_path)


func _test_node_script_property_rollback(controller: AIWorkbenchController) -> void:
	var new_path := "res://tests/__ai_node_script.gd"
	_remove(new_path)
	_write(new_path, "extends Node2D\n@export var speed := 2\n")
	var target := Node2D.new()
	get_root().add_child(target)
	var old_script := GDScript.new()
	old_script.source_code = "extends Node2D\n@export var speed := 1\n"
	_check(old_script.reload(false) == OK, "节点回滚测试原脚本应可解析")
	target.set_script(old_script)
	target.set("speed", 42)
	controller.store.set_node_operations([{
		"operation": "attach_script",
		"target": "selected",
		"script_path": new_path,
	}])
	controller._locked_target_node = weakref(target)
	var captured := controller._capture_node_snapshots()
	var applied := controller._apply_node_operations()
	_check(
		bool(captured.get("ok", false))
		and bool(applied.get("ok", false))
		and int(target.get("speed")) == 42,
		"绑定新脚本时应保留同名导出属性",
	)
	var failures := controller._restore_node_scripts()
	_check(
		failures.is_empty()
		and target.get_script() == old_script
		and int(target.get("speed")) == 42,
		"节点回滚应恢复原脚本和导出属性",
	)
	controller.store.set_node_operations([])
	target.free()
	_remove(new_path)


func _write(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(content)
		file.close()


func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ✓ ", msg)
	else:
		_fails += 1
		printerr("  ✗ ", msg)
