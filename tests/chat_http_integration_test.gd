extends SceneTree
## 端到端集成测试（需要 tests/chat_api_mock_server.py 在 127.0.0.1:8765 运行）：
## 走真实 HTTP 路径验证：流式 SSE、非流式 JSON、401 错误处理、队列。
##
## 运行方式：
##   python3 tests/chat_api_mock_server.py &   # 或后台任务
##   godot --headless --path . -s res://tests/chat_http_integration_test.gd

const BASE := "http://127.0.0.1:8765/v1"

var _fails := 0


func _initialize() -> void:
	_run()


func _run() -> void:
	await _test_streaming()
	await _test_non_streaming()
	await _test_401_error()
	await _test_models_list()
	if _fails == 0:
		print("INTEGRATION_TEST_OK: 全部通过")
		quit(0)
	else:
		printerr("INTEGRATION_TEST_FAILED: %d 项失败" % _fails)
		quit(1)


## 场景 4：GET {base}/models 拉取模型列表（异步，经 HTTPRequest）
func _test_models_list() -> void:
	var client := _make_client(BASE)
	var got: Array = []
	client.models_loaded.connect(func(m: Array, e: String) -> void: got.append([m, e]))
	client.fetch_models()
	var waited := 0
	while got.is_empty() and waited < 300:
		await process_frame
		waited += 1
	_check(not got.is_empty(), "models_loaded 应触发")
	if not got.is_empty():
		var models: Array = got[0][0]
		var err := String(got[0][1])
		_check(err.is_empty(), "模型列表不应报错，实际: %s" % err)
		_check(models.has("mock-model-a") and models.has("mock-model-b"), "应返回 mock 模型列表，实际: %s" % str(models))
	_check(build_models_url_ok(client), "build_models_url 应拼出 {base}/models")
	client.free()


func build_models_url_ok(client: AILLMClient) -> bool:
	return client.build_models_url() == BASE + "/models"


func _test_streaming() -> void:
	var client := _make_client(BASE)
	var streamed: Array = []
	var finished: Array = []
	client.stream_chunk.connect(func(t: String) -> void: streamed.append(t))
	client.request_finished.connect(func(s: bool, e: String) -> void: finished.append([s, e]))
	client.chat("hi")
	var waited := 0
	while finished.is_empty() and waited < 300:
		await process_frame
		waited += 1
	var full := "".join(streamed)
	_check(full == "你好，世界！", "流式正文应为「你好，世界！」，实际: '%s'" % full)
	_check(not finished.is_empty(), "流式请求应结束")
	if not finished.is_empty():
		_check(finished[0][0], "流式请求应成功，错误: %s" % str(finished[0][1]))
	_check(client.last_response_text == "你好，世界！", "last_response_text 错误: '%s'" % client.last_response_text)
	_check(client.get_history().size() == 2, "流式后历史应为 2 条，实际 %d" % client.get_history().size())
	client.free()


func _test_non_streaming() -> void:
	var client := _make_client(BASE + "/chat/completions?mode=json")
	client.stream = false
	var finished: Array = []
	client.request_finished.connect(func(s: bool, e: String) -> void: finished.append([s, e]))
	client.chat("hi")
	var waited := 0
	while finished.is_empty() and waited < 300:
		await process_frame
		waited += 1
	_check(not finished.is_empty(), "非流式请求应结束")
	if not finished.is_empty():
		_check(finished[0][0], "非流式请求应成功，错误: %s" % str(finished[0][1]))
	_check(client.last_response_text == "非流式回复 42", "非流式正文错误: '%s'" % client.last_response_text)
	client.free()


func _test_401_error() -> void:
	var client := _make_client(BASE + "/chat/completions?mode=401")
	var finished: Array = []
	client.request_finished.connect(func(s: bool, e: String) -> void: finished.append([s, e]))
	client.chat("hi")
	var waited := 0
	while finished.is_empty() and waited < 300:
		await process_frame
		waited += 1
	_check(not finished.is_empty(), "401 请求应结束")
	if not finished.is_empty():
		_check(finished[0][0] == false, "401 应失败")
		_check(String(finished[0][1]).contains("401"), "错误信息应包含 401，实际: %s" % str(finished[0][1]))
	_check(client.get_history().is_empty(), "401 失败后历史应为空，实际 %d 条" % client.get_history().size())
	client.free()


func _make_client(url: String) -> AILLMClient:
	var c: AILLMClient = AILLMClient.new()
	get_root().add_child(c)
	c.base_url = url
	c.api_key = "sk-local"
	c.timeout_seconds = 10
	return c


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ✓ ", msg)
	else:
		_fails += 1
		printerr("  ✗ ", msg)