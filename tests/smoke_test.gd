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


func _initialize() -> void:
	_test_no_key_fails_cleanly()
	_test_sse_streaming()
	_test_nonstream_json()
	_test_queue_and_cleanup()
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


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ✓ ", msg)
	else:
		_fails += 1
		printerr("  ✗ ", msg)