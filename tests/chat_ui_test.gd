extends SceneTree
## Offline UI lifecycle tests. --preview keeps a clearly labelled demo open.

const WORKBENCH := preload("res://addons/ai_assistant/editor/ai_workbench_ui.gd")
var _failures := 0


func _initialize() -> void:
	await process_frame
	var screen := WORKBENCH.new()
	root.size = Vector2i(1280, 800)
	root.add_child(screen)
	screen._set_mode(false)
	await process_frame
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
