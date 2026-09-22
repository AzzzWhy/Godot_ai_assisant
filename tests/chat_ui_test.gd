extends SceneTree
## Offline UI lifecycle tests. --preview keeps a clearly labelled demo open.

const WORKBENCH := preload("res://addons/ai_assistant/editor/ai_workbench_ui.gd")
const CLIENT := preload("res://addons/ai_assistant/client/openai_compatible_chat_client.gd")
var _failures := 0


func _initialize() -> void:
	await process_frame
	var screen := WORKBENCH.new()
	root.size = Vector2i(1280, 800)
	root.add_child(screen)
	screen._set_mode(false)
	await process_frame
	# Settings remain usable at the minimum supported size.
	screen._settings_window.size = Vector2i(360, 360)
	screen._settings_window.show()
	await process_frame
	await process_frame
	_check(
		screen._settings_footer.position.y + screen._settings_footer.size.y <= screen._settings_window.size.y,
		"Settings footer remains visible in a small window",
	)
	_check(
		screen._url_edit.size.x <= screen._settings_body_scroll.size.x + 1,
		"Settings fields do not overflow a narrow window",
	)
	var temperature_visible := false
	for label in screen._settings_body_scroll.find_children("*", "Label", true, false):
		if label.text == "温度":
			temperature_visible = true
	_check(not temperature_visible, "Temperature is removed from workbench settings")
	_check(
		screen._max_tokens_unlimited != null and screen._timeout_unlimited != null,
		"Token and response-time settings expose unlimited choices",
	)
	screen._timeout_unlimited.button_pressed = true
	_check(not screen._timeout.editable, "Unlimited response time disables the numeric limit")
	screen._timeout_unlimited.button_pressed = false
	_check(screen._timeout.editable, "Finite response time enables the numeric limit")
	var limit_client: AILLMClient = CLIENT.new()
	limit_client.temperature = -1.0
	limit_client.max_tokens = 0
	limit_client._stream_mode = true
	var unlimited_payload := limit_client._build_payload()
	_check(
		not unlimited_payload.has("temperature") and not unlimited_payload.has("max_tokens"),
		"Unlimited payload omits temperature and max_tokens constraints",
	)
	_check(
		bool(unlimited_payload.get("stream_options", {}).get("include_usage", false)),
		"Streaming requests ask compatible providers to return token usage",
	)
	limit_client._capture_usage({"usage": {"prompt_tokens": 40, "completion_tokens": 2}})
	_check(limit_client._request_usage_total == 42, "Provider token usage is captured")
	var stalled_seconds: Array[int] = []
	limit_client.response_stalled.connect(
		func(seconds: int) -> void: stalled_seconds.append(seconds)
	)
	limit_client._last_activity_at_msec = 1
	limit_client._notify_if_stalled(300001)
	limit_client._notify_if_stalled(600001)
	_check(stalled_seconds == [300], "A stalled request warns once after 300 seconds")
	limit_client.free()
	screen._url_edit.text = ""
	screen._key_edit.text = ""
	screen._update_model_query_state()
	_check(screen._models_refresh.disabled, "Model query requires URL and API key")
	screen._url_edit.text = "ws.example.com/v1"
	screen._key_edit.text = "short"
	screen._update_model_query_state()
	_check(
		screen._models_refresh.disabled and screen._models_status.text.contains("http"),
		"Incomplete connection data has a concise local validation message",
	)
	screen._url_edit.text = "https://example.com/v1"
	screen._key_edit.text = "sk-test-key"
	screen._update_model_query_state()
	_check(not screen._models_refresh.disabled, "Complete connection data enables model query")
	_check(
		screen._compact_model_error("模型列表 HTTP 401: You didn't provide an API key. Very long provider details")
		== "API Key 无效或未发送（HTTP 401）。",
		"Provider errors are compacted for the layout",
	)
	screen._build_quick_start_window()
	_check(screen._quick_start_window != null, "Quick-start guide window is built")
	_check(
		screen._quick_start_body.text.contains("保存场景")
		and screen._quick_start_body.text.contains("Builder")
		and screen._quick_start_body.text.contains("应用全部")
		and screen._quick_start_body.text.contains("绑定到当前选中的节点"),
		"Quick-start guide covers the essential workflow",
	)
	_check(
		screen._quick_start_hide_check != null
		and screen._quick_start_hide_check.text == "不再提示",
		"Quick-start guide exposes a persistent dismissal choice",
	)
	screen._quick_start_window.size = Vector2i(360, 360)
	screen._quick_start_window.show()
	await process_frame
	await process_frame
	_check(
		screen._quick_start_footer.position.y + screen._quick_start_footer.size.y
		<= screen._quick_start_window.size.y,
		"Quick-start footer remains visible in a small window",
	)
	screen._quick_start_window.hide()
	if "--preview-settings" in OS.get_cmdline_user_args():
		root.title = "设置窗口响应式预览（本地测试）"
		screen._settings_window.title = "AI 工作台设置 · 窄窗口测试"
		screen._settings_window.size = Vector2i(380, 430)
		screen._settings_window.show()
		return
	screen._settings_window.hide()
	screen._on_message_added("user", "如何给角色添加左右移动？")
	screen._on_state_changed("generating", "模型正在回复")
	var first: Variant = screen._active_response
	screen._on_reasoning_text("## 检查方案\n- 确认节点使用 **CharacterBody2D**。\n- 使用 `Input.get_axis()` 读取输入。\n")
	screen._on_stream_text("## 角色移动\n把下面脚本挂到 **CharacterBody2D**：\n```gdscript\nextends CharacterBody2D\n\nfunc _physics_process(delta):\n    velocity.x = Input.get_axis(\"ui_left\", \"ui_right\") * 240\n    move_and_slide()\n```\n> 碰撞形状需要在场景中另行设置。")
	await create_timer(0.2).timeout
	_check(first.reasoning_text.contains("检查方案"), "Reasoning is attached to the active answer")
	_check(first._reasoning_panel.visible and first._reasoning_scroll.visible, "Incoming reasoning expands")
	_check(first._answer.get_parsed_text().contains("extends CharacterBody2D"), "Streamed answer renders code")
	_check(first._indicator.visible and first.is_processing(), "Running answer animates")
	screen._on_state_changed("idle", "回复完成")
	await create_timer(0.25).timeout
	_check(screen._active_response == null and not first.is_processing(), "Completion stops animation and releases active card")
	_check(not first._reasoning_scroll.visible, "Completed reasoning collapses automatically")
	first.set_reasoning_expanded(true)
	await create_timer(0.25).timeout
	_check(first._reasoning_scroll.visible, "Completed reasoning can be expanded again")
	screen._on_message_added("user", "第二轮只测试停止。")
	screen._on_state_changed("generating", "等待模型")
	var second: Variant = screen._active_response
	screen._on_reasoning_text("正在检查输入配置。")
	screen._on_state_changed("cancelled", "已停止")
	_check(second != first and first.answer_text.contains("角色移动"), "Consecutive turns stay separate")
	_check(not second.running and second._status.text == "已停止", "Cancellation ends activity")
	screen._on_message_added("user", "普通模型的回复。")
	screen._on_state_changed("generating", "等待模型")
	var plain: Variant = screen._active_response
	screen._on_message_added("assistant", "没有思考字段，也能正常回复。")
	screen._on_state_changed("idle", "回复完成")
	_check(not plain._reasoning_panel.visible, "No reasoning field means no invented reasoning")
	screen._on_motion_toggled(false)
	_check(first.modulate.a == 1 and not first.animations_enabled, "Motion can be disabled")
	root.size = Vector2i(940, 680)
	await process_frame
	await process_frame
	_check(first.size.x <= screen._chat_scroll.size.x, "Cards fit the narrow chat rail")
	first.set_reasoning_expanded(true)
	first.append_reasoning("\n" + "长思考内容不会撑开整个窗口。\n".repeat(100))
	first._flush_text()
	await process_frame
	await process_frame
	_check(first._reasoning_scroll.size.y <= 221, "Long reasoning has a bounded scroll area")
	if "--preview" in OS.get_cmdline_user_args():
		root.title = "AI 对话效果预览（本地模拟数据）"
		root.size = Vector2i(1280, 800)
		screen._clear_chat()
		screen._on_message_added("user", "为 CharacterBody2D 写一个左右移动脚本。")
		screen._on_state_changed("generating", "本地模拟 · 不会请求模型")
		screen._on_reasoning_text("## 实现思路\n先确认角色类型，再用 **输入轴** 更新水平速度。\n\n- 保留重力与碰撞处理。\n- 使用 `move_and_slide()` 移动。")
		screen._on_stream_text("## 移动脚本\n将脚本挂在 **CharacterBody2D** 上。\n\n```gdscript\nextends CharacterBody2D\n\n@export var speed := 240.0\n\nfunc _physics_process(delta):\n    velocity.x = Input.get_axis(\"ui_left\", \"ui_right\") * speed\n    move_and_slide()\n```\n\n> 左右方向键控制移动。")
		screen._motion_toggle.button_pressed = true
		return
	screen._clear_chat()
	await process_frame
	_check(screen._chat_messages.get_child_count() == 1, "Clear removes completed turns and keeps its notice")
	screen.shutdown()
	screen.queue_free()
	await process_frame
	print("CHAT_UI_TEST_OK" if _failures == 0 else "CHAT_UI_TEST_FAILED: %d" % _failures)
	quit(0 if _failures == 0 else 1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		printerr("CHAT_UI_TEST_FAILED: " + message)
