extends SceneTree
## Offline provider-response tests; no HTTP requests or project writes.
## godot --headless --path . -s res://tests/reasoning_controller_test.gd

const CLIENT := preload("res://addons/ai_assistant/client/openai_compatible_chat_client.gd")

class ControllerHarness extends "res://addons/ai_assistant/editor/workbench_task_controller.gd":
	var built_response := ""

	func _build_draft(response: String) -> void:
		built_response = response
		_set_state(REVIEW, "草稿已生成")


var _fails := 0


func _initialize() -> void:
	_test_non_streamed_chat()
	_test_streamed_chat()
	_test_builder_reasoning()
	_test_unstreamed_suffix()
	_test_cancel_and_late_events()
	_test_plain_response()
	if _fails == 0:
		print("REASONING_CONTROLLER_TEST_OK")
	else:
		printerr("REASONING_CONTROLLER_TEST_FAILED: %d" % _fails)
	quit(0 if _fails == 0 else 1)


func _make_controller(kind: String, events: Array) -> ControllerHarness:
	# Keep this harness outside the tree: _ready() would load editor settings
	# and a real recovery store, neither of which is involved in response delivery.
	var controller := ControllerHarness.new()
	controller._client = CLIENT.new()
	controller.add_child(controller._client)
	controller._client.stream_chunk.connect(controller._on_stream_chunk)
	controller._client.reasoning_chunk.connect(controller._on_reasoning_chunk)
	controller._client.request_finished.connect(controller._on_request_finished)
	controller._client._busy = true
	controller._pending_kind = kind
	controller.state_key = controller.GENERATING
	controller._chat_history.append({"role": "user", "content": "测试请求"})
	controller.reasoning_text.connect(func(text: String) -> void:
		events.append(["reasoning", text])
	)
	controller.stream_text.connect(func(text: String) -> void:
		events.append(["stream", text])
	)
	controller.message_added.connect(func(role: String, text: String) -> void:
		events.append([role, text])
	)
	controller.state_changed.connect(func(state: String, _message: String) -> void:
		events.append(["state", state])
	)
	return controller


func _complete_json(controller: ControllerHarness, content: String, reasoning: String) -> void:
	controller._client._extract_from_json(JSON.stringify({
		"choices": [{
			"message": {"content": content, "reasoning_content": reasoning},
			"finish_reason": "stop",
		}],
	}))
	controller._client._finalize(true)


func _send_delta(controller: ControllerHarness, delta: Dictionary, finish: String = "") -> void:
	controller._client._handle_stream_event("data: " + JSON.stringify({
		"choices": [{"delta": delta, "finish_reason": finish if not finish.is_empty() else null}],
	}))


func _test_non_streamed_chat() -> void:
	var events: Array = []
	var controller := _make_controller("chat", events)
	_complete_json(controller, "最终回答", "先分析现有节点。")
	_check(events == [
		["reasoning", "先分析现有节点。"],
		["assistant", "最终回答"],
		["state", "idle"],
	], "JSON Chat should deliver reasoning before the answer and completion")
	_check(controller._chat_history == [
		{"role": "user", "content": "测试请求"},
		{"role": "assistant", "content": "最终回答"},
	], "displaying reasoning should preserve normal Chat history")
	controller.free()


func _test_streamed_chat() -> void:
	var events: Array = []
	var controller := _make_controller("chat", events)
	_send_delta(controller, {"reasoning_content": "第一步。"})
	_send_delta(controller, {"reasoning_content": "第二步。"})
	_send_delta(controller, {"content": "答案"}, "stop")
	_check(events == [
		["reasoning", "第一步。"],
		["reasoning", "第二步。"],
		["stream", "答案"],
		["state", "idle"],
	], "SSE reasoning and answer must not be duplicated on completion")
	_check(controller._chat_history.back().content == "答案", "streaming should retain the final answer in history")
	controller.free()


func _test_builder_reasoning() -> void:
	var events: Array = []
	var controller := _make_controller("builder", events)
	var response := '{"changes": []}'
	_complete_json(controller, response, "检查资源后生成脚本。")
	_check(events == [
		["reasoning", "检查资源后生成脚本。"],
		["state", "review"],
	], "Builder should expose JSON reasoning before showing its draft")
	_check(controller.built_response == response, "Builder must receive the original response unchanged")
	controller.free()


func _test_unstreamed_suffix() -> void:
	var events: Array = []
	var controller := _make_controller("chat", events)
	_send_delta(controller, {"reasoning_content": "已收到。"})
	_complete_json(controller, "答案", "已收到。最后一段。")
	_check(events.slice(0, 2) == [
		["reasoning", "已收到。"],
		["reasoning", "最后一段。"],
	], "a completed reasoning buffer should add only an undelivered suffix")
	controller.free()


func _test_cancel_and_late_events() -> void:
	var events: Array = []
	var controller := _make_controller("chat", events)
	_send_delta(controller, {"reasoning_content": "已开始。"})
	controller.cancel()
	controller._client.reasoning_chunk.emit("过期内容")
	controller._client.stream_chunk.emit("过期答案")
	controller._client.request_finished.emit(false, "过期错误")
	controller._client.request_finished.emit(true, "")
	_check(events == [
		["reasoning", "已开始。"],
		["state", "cancelled"],
	], "cancel must not flicker into error or accept late output/completions")
	_check(controller._chat_history.size() == 1, "cancelled output must not enter Chat history")
	controller.free()


func _test_plain_response() -> void:
	var events: Array = []
	var controller := _make_controller("chat", events)
	_complete_json(controller, "直接回答", "")
	_check(events == [["assistant", "直接回答"], ["state", "idle"]], "providers without reasoning should not emit invented thinking text")
	controller.free()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
	else:
		_fails += 1
		printerr("FAIL: ", message)
