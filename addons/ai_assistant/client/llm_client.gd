class_name AILLMClient
extends Node
## 任意 OpenAI 兼容接口的异步 LLM 客户端。
## 兼容：DeepSeek / OpenAI / Moonshot(Kimi) / 通义 / Ollama / vLLM 等。
##
## 特性：
## - 基于 HTTPClient 的低层轮询，支持 SSE 流式输出（无需线程）
## - 自动维护对话历史（system + user + assistant）
## - 单客户端同一时间只处理一个请求，多余请求自动排队
## - 可配置超时、温度、max_tokens；支持 cancel()
## - 对 deepseek-reasoner 的 reasoning_content（思考过程）单独发信号

signal stream_chunk(text: String)
## 流式增量正文（仅在 stream = true 时发出）
signal reasoning_chunk(text: String)
## 流式增量思考内容（deepseek-reasoner 等模型）
signal response_received(response: Dictionary)
## 整段回复完成，response = {"content": String, "reasoning_content": String}
signal request_finished(success: bool, error_message: String)
## 每次请求结束（成功或失败）都发出
signal history_changed(history: Array)
## 对话历史变更（用于持久化 / UI 同步）
signal models_loaded(models: Array, error_message: String)
## 调用 fetch_models() 后的结果：models = 模型 id 列表；error_message 为空表示成功

const DEFAULT_BASE_URL := "https://api.deepseek.com"
const DEFAULT_MODEL := "deepseek-chat"
const CHAT_PATH := "/chat/completions"

## ---------- 配置（可用属性直接修改，或由 Autoload 从 ProjectSettings 读取） ----------
var base_url := DEFAULT_BASE_URL
var api_key := ""
var model := DEFAULT_MODEL
var temperature := 1.0      # 设为 -1 表示不发送该参数
var max_tokens := 0         # 0 = 使用服务端默认值
var stream := true
var timeout_seconds := 60.0
var system_prompt := ""

## 对话历史（OpenAI messages 格式）：[{"role": "user", "content": "..."}, ...]
var history: Array[Dictionary] = []

## 最近一次请求的完整回复
var last_response_text := ""
var last_reasoning_text := ""

var _client: HTTPClient = null
var _endpoint_path := CHAT_PATH
var _buffer := ""
var _utf8_carry := PackedByteArray()  # 跨包截断的 UTF-8 残留字节，避免多字节字符被拆坏
var _stream_mode := false
var _request_sent := false
var _status_code := 0
var _finalized := false
var _busy := false
var _queue: Array[Dictionary] = []
var _started_at_msec := 0
var _last_status: HTTPClient.Status = HTTPClient.STATUS_DISCONNECTED
var _last_user_message: Dictionary = {}
var _last_url := ""  # 最近一次实际请求的完整 URL（用于错误诊断）
var _models_http: HTTPRequest = null
var _fetching_models := false


func is_busy() -> bool:
	return _busy


func get_history() -> Array:
	return history


## 设置系统提示词（会替换当前 system_prompt）
func set_system_prompt(text: String) -> void:
	system_prompt = text
	history_changed.emit(history)


func clear_history() -> void:
	history.clear()
	history_changed.emit(history)


## 从 JSON 反序列化历史记录（用于跨会话恢复）
func load_history(messages: Array) -> void:
	history.clear()
	for m in messages:
		if m is Dictionary and m.has("role") and m.has("content"):
			history.append(m)
	history_changed.emit(history)


## 发送一条用户消息并请求回复（忙时自动排队）
func chat(text: String) -> void:
	var msg := {"role": "user", "content": text}
	history.append(msg)
	_last_user_message = msg
	_queue.append({"job": "chat", "message": msg})
	_pump()


## 不追加历史、直接以指定 messages 发起请求（高级用法）
func send_raw(messages: Array[Dictionary]) -> void:
	history = messages.duplicate(true)
	_last_user_message = {}
	_queue.append({"job": "raw"})
	_pump()


## 取消当前请求（队列中尚未开始的请求仍会执行）
func cancel() -> void:
	if not _busy:
		return
	if _client != null:
		_client.close()
	_last_user_message = {}
	_finalize(false, "请求已取消")


# ------------------------- 模型列表（OpenAI 兼容 GET {base}/models） -------------------------

## 异步拉取当前 Key 可用的模型列表，完成后发出 models_loaded(models, error_message)
## api_key_override：可选，指定本次请求使用的 Key（设置窗口里输入框未保存时用）
func fetch_models(api_key_override := "") -> void:
	if _fetching_models:
		return
	var url := build_models_url()
	if url.is_empty():
		models_loaded.emit([], "Base URL 无效，无法获取模型列表")
		return
	if _models_http == null:
		_models_http = HTTPRequest.new()
		add_child(_models_http)
		_models_http.timeout = timeout_seconds
		_models_http.request_completed.connect(_on_models_completed)
	_fetching_models = true
	var headers := PackedStringArray(["Accept: application/json"])
	var key := (api_key_override if not api_key_override.is_empty() else api_key).strip_edges()
	if not key.is_empty():
		headers.append("Authorization: Bearer " + key)
	var err := _models_http.request(url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		_fetching_models = false
		models_loaded.emit([], "模型列表请求发送失败: %s" % error_string(err))


func _on_models_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_fetching_models = false
	if result != HTTPRequest.RESULT_SUCCESS:
		models_loaded.emit([], "模型列表请求失败（result=%d，请检查网络 / Base URL）" % result)
		return
	if response_code != 200:
		# 尽量解析服务商返回的具体错误原因，便于排查（401 常见于 Key 无效/服务未开通）
		var reason := "HTTP %d" % response_code
		var json := JSON.new()
		if json.parse(body.get_string_from_utf8()) == OK and json.data is Dictionary:
			var err: Variant = json.data.get("error", null)
			if err is Dictionary and err.has("message"):
				reason += ": %s" % String(err.get("message", ""))
		models_loaded.emit([], "模型列表 %s（部分服务商不支持该接口，可手动填模型名）" % reason)
		return
	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		models_loaded.emit([], "模型列表响应解析失败")
		return
	if not (json.data is Dictionary):
		models_loaded.emit([], "模型列表响应结构异常")
		return
	var obj: Dictionary = json.data
	var data: Array = obj.get("data", [])
	var ids: Array = []
	for item in data:
		if item is Dictionary:
			var id: Variant = item.get("id", null)
			if id != null and String(id) != "":
				ids.append(String(id))
	ids.sort()
	models_loaded.emit(ids, "" if not ids.is_empty() else "服务器未返回任何模型（可能不支持该接口）")


# ------------------------- 内部实现 -------------------------

func _pump() -> void:
	if _busy or _queue.is_empty():
		return
	var job: Dictionary = _queue.pop_front()
	_busy = true
	_stream_mode = stream
	_buffer = ""
	_utf8_carry = PackedByteArray()
	_request_sent = false
	_status_code = 0
	_finalized = false
	_last_status = HTTPClient.STATUS_DISCONNECTED
	_started_at_msec = Time.get_ticks_msec()
	last_response_text = ""
	last_reasoning_text = ""
	if api_key.strip_edges().is_empty():
		_finalize(false, "未设置 API Key（api_key 为空）")
		return
	var err := _connect()
	if err != OK:
		_finalize(false, "无法解析 base_url: %s" % base_url)
		return
	# 请求在 _process 中当连接就绪后发送


func _process(_delta: float) -> void:
	if not _busy or _client == null:
		return
	if Time.get_ticks_msec() - _started_at_msec > timeout_seconds * 1000.0:
		_finalize(false, "请求超时（%d 秒）" % int(timeout_seconds))
		return

	var err := _client.poll()
	var status := _client.get_status()
	if _status_code == 0 and status == HTTPClient.STATUS_BODY:
		_status_code = _client.get_response_code()

	if err != OK:
		if status == HTTPClient.STATUS_DISCONNECTED:
			_handle_body_end()
		else:
			_finalize(false, "连接错误: %s" % error_string(err))
		_last_status = status
		return

	status = _client.get_status()
	match status:
		HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_REQUESTING:
			pass
		HTTPClient.STATUS_CONNECTED:
			if not _request_sent:
				_send_request()
		HTTPClient.STATUS_BODY:
			if _status_code == 0:
				_status_code = _client.get_response_code()
			var chunk: PackedByteArray = _client.read_response_body_chunk()
			if chunk.size() > 0:
				_buffer += _decode_chunk(chunk)
				if _stream_mode:
					_consume_stream_events()
		HTTPClient.STATUS_DISCONNECTED:
			_handle_body_end()
		HTTPClient.STATUS_CANT_CONNECT, HTTPClient.STATUS_CANT_RESOLVE, \
		HTTPClient.STATUS_CONNECTION_ERROR, HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
			_finalize(false, "连接失败：无法访问 %s" % base_url)
		_:
			pass

	# keep-alive 场景：BODY 结束回到 CONNECTED
	if _last_status == HTTPClient.STATUS_BODY and status != HTTPClient.STATUS_BODY and not _finalized:
		_handle_body_end()
	_last_status = status


func _connect() -> int:
	var parsed := _parse_base_url()
	if parsed.is_empty():
		return ERR_INVALID_PARAMETER
	_endpoint_path = parsed.base_path + CHAT_PATH + parsed.query
	_last_url = "%s://%s:%d%s" % [parsed.proto, parsed.host, parsed.port, _endpoint_path]

	_client = HTTPClient.new()
	var tls: TLSOptions = null
	if parsed.proto == "https":
		tls = TLSOptions.client()
	return _client.connect_to_host(parsed.host, parsed.port, tls)


## 解析 base_url → {proto, host, port, base_path, query}
## 容错：base_url 可带 /v1 等前缀；即使误填了完整端点 /chat/completions 也会自动去重
func _parse_base_url() -> Dictionary:
	var endpoint := base_url.strip_edges().rstrip("/")
	if endpoint.is_empty():
		return {}
	var proto := "https"
	var host_part := endpoint
	if endpoint.begins_with("https://"):
		host_part = endpoint.substr("https://".length())
	elif endpoint.begins_with("http://"):
		proto = "http"
		host_part = endpoint.substr("http://".length())
	else:
		return {}

	var base_path := ""
	var query := ""
	var slash := host_part.find("/")
	if slash != -1:
		var rest := host_part.substr(slash)
		host_part = host_part.substr(0, slash)
		var q := rest.find("?")
		if q != -1:
			base_path = rest.substr(0, q).rstrip("/")
			query = rest.substr(q)
		else:
			base_path = rest.rstrip("/")
	if base_path.ends_with(CHAT_PATH):
		base_path = base_path.substr(0, base_path.length() - CHAT_PATH.length()).rstrip("/")

	var port := 443 if proto == "https" else 80
	var colon := host_part.find(":")
	if colon != -1:
		port = int(host_part.substr(colon + 1))
		host_part = host_part.substr(0, colon)
	if port <= 0 or port > 65535:
		return {}
	return {"proto": proto, "host": host_part, "port": port, "base_path": base_path, "query": query}


## 拼接模型列表接口地址（OpenAI 兼容的 GET {base}/models）
func build_models_url() -> String:
	var parsed := _parse_base_url()
	if parsed.is_empty():
		return ""
	return "%s://%s:%d%s/models%s" % [parsed.proto, parsed.host, parsed.port, parsed.base_path, parsed.query]


func _send_request() -> void:
	_request_sent = true
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Accept: " + ("text/event-stream" if _stream_mode else "application/json"),
		"Authorization: Bearer " + api_key,
	])
	var body := JSON.stringify(_build_payload())
	var err := _client.request(HTTPClient.METHOD_POST, _endpoint_path, headers, body)
	if err != OK:
		_finalize(false, "发送请求失败: %s" % error_string(err))


func _build_payload() -> Dictionary:
	var messages: Array = []
	if not system_prompt.is_empty():
		messages.append({"role": "system", "content": system_prompt})
	messages.append_array(history)
	var payload := {
		"model": model,
		"messages": messages,
		"stream": _stream_mode,
	}
	if temperature >= 0.0:
		payload["temperature"] = temperature
	if max_tokens > 0:
		payload["max_tokens"] = max_tokens
	return payload


## ---------- 流式（SSE）解析 ----------

## 把新到达的字节块解码为文本；若网络包边界把一个 UTF-8 多字节字符切成两半，
## 则把残缺字节暂存到 _utf8_carry，等下一块补齐后再解码，避免中文乱码。
func _decode_chunk(chunk: PackedByteArray) -> String:
	var bytes := _utf8_carry
	_utf8_carry = PackedByteArray()
	bytes.append_array(chunk)
	var incomplete := _trailing_utf8_len(bytes)
	if incomplete > 0:
		var split := bytes.size() - incomplete
		_utf8_carry = bytes.slice(split)
		bytes = bytes.slice(0, split)
	return bytes.get_string_from_utf8()


## 返回末尾不完整 UTF-8 序列占用的字节数（0 表示可安全整体解码）。
func _trailing_utf8_len(b: PackedByteArray) -> int:
	var n := b.size()
	if n == 0:
		return 0
	var s := n - 1
	# 从末尾向前收集连续的后缀字节（0b10xxxxxx）
	while s > 0 and (b[s] & 0xC0) == 0x80:
		s -= 1
	var lead := b[s]
	var seq := 0
	if lead < 0x80:
		return 0
	elif (lead & 0xE0) == 0xC0:
		seq = 2
	elif (lead & 0xF0) == 0xE0:
		seq = 3
	elif (lead & 0xF8) == 0xF0:
		seq = 4
	else:
		return 0  # 非法字节，交给解码器按替换符处理
	var got := n - s
	return got if got < seq else 0


func _consume_stream_events() -> void:
	while true:
		var idx := _buffer.find("\n\n")
		var sep_len := 2
		var idx_crlf := _buffer.find("\r\n\r\n")
		if idx_crlf != -1 and (idx == -1 or idx_crlf < idx):
			idx = idx_crlf
			sep_len = 4
		if idx == -1:
			break
		var event := _buffer.substr(0, idx)
		_buffer = _buffer.substr(idx + sep_len)
		_handle_stream_event(event)


func _handle_stream_event(event: String) -> void:
	var lines := event.split("\n")
	var data := ""
	for line in lines:
		if line.begins_with("data:"):
			if not data.is_empty():
				data += "\n"
			data += line.substr("data:".length()).strip_edges()
	if data.is_empty():
		return
	if data == "[DONE]":
		_finalize(true)
		return
	var json := JSON.new()
	if json.parse(data) != OK:
		push_warning("AI 流式数据解析失败: %s" % data)
		return
	if not (json.data is Dictionary):
		push_warning("AI 流式数据不是 JSON 对象: %s" % data)
		return
	var obj: Dictionary = json.data
	var choices: Array = obj.get("choices", [])
	if choices.is_empty():
		return
	var choice: Dictionary = choices[0]
	var delta: Dictionary = choice.get("delta", {})
	var reasoning: Variant = delta.get("reasoning_content", null)
	if reasoning != null and String(reasoning) != "":
		last_reasoning_text += String(reasoning)
		reasoning_chunk.emit(String(reasoning))
	var content: Variant = delta.get("content", null)
	if content != null and String(content) != "":
		last_response_text += String(content)
		stream_chunk.emit(String(content))
	if choice.get("finish_reason") != null:
		_finalize(true)


## ---------- 收尾 ----------

func _handle_body_end() -> void:
	if _finalized:
		return
	if _status_code == 0 and _client != null:
		_status_code = _client.get_response_code()
	if _status_code == 0 and _buffer.is_empty():
		_finalize(false, "连接被关闭，未收到响应")
		return
	if _status_code != 0 and (_status_code < 200 or _status_code >= 300):
		_fail_with_server_error()
		return
	if _stream_mode:
		# 连接已结束：先 flush 掉可能残留的「缺少结尾空行」的最后一段
		_consume_stream_events()
		var rest := _buffer.strip_edges()
		if not rest.is_empty():
			_handle_stream_event(rest)
			_buffer = ""
		if _finalized:
			return
		# 个别服务端即使请求了 stream 也会整体返回 JSON，兜底解析
		if last_response_text.is_empty() and not _buffer.is_empty():
			_extract_from_json(_buffer)
		_finalize(true)
		return
	_extract_from_json(_buffer)
	_finalize(true)


func _extract_from_json(raw: String) -> void:
	var json := JSON.new()
	if json.parse(raw) != OK:
		push_warning("无法解析响应 JSON")
		return
	if not (json.data is Dictionary):
		push_warning("AI 响应不是预期的 JSON 对象结构")
		return
	var obj: Dictionary = json.data
	var choices: Array = obj.get("choices", [])
	if choices.is_empty():
		return
	var choice: Dictionary = choices[0]
	var msg: Dictionary = choice.get("message", {})
	var reasoning: Variant = msg.get("reasoning_content", null)
	if reasoning != null:
		last_reasoning_text = String(reasoning)
	var content: Variant = msg.get("content", null)
	if content != null:
		last_response_text = String(content)


func _fail_with_server_error() -> void:
	var msg := "HTTP %d" % _status_code
	var json := JSON.new()
	if json.parse(_buffer) == OK and json.data is Dictionary:
		var err: Variant = json.data.get("error", null)
		if err is Dictionary:
			var m: Variant = err.get("message", null)
			if m != null and String(m) != "":
				msg = "HTTP %d: %s" % [_status_code, String(m)]
	if _status_code == 401:
		msg = "API Key 无效或未授权（HTTP 401）" + ("\n" + msg if not msg.begins_with("HTTP 401") else "")
	elif _status_code == 402:
		msg = "账户余额不足或额度用尽（HTTP 402）" + ("\n" + msg if not msg.begins_with("HTTP 402") else "")
	elif _status_code == 429:
		msg = "请求过于频繁或余额不足（HTTP 429）" + ("\n" + msg if not msg.begins_with("HTTP 429") else "")
	if not _last_url.is_empty():
		msg += "\n请求 URL: %s" % _last_url
	_finalize(false, msg)


func _finalize(success: bool, error_message := "") -> void:
	if _finalized:
		return
	_finalized = true
	if _client != null:
		_client.close()
		_client = null
	_busy = false

	if success and not last_response_text.is_empty():
		var entry := {"role": "assistant", "content": last_response_text}
		if not last_reasoning_text.is_empty():
			entry["reasoning_content"] = last_reasoning_text
		# 插到本次请求对应的用户消息之后（排队时历史顺序依然正确）
		var idx := history.rfind(_last_user_message)
		if idx != -1:
			history.insert(idx + 1, entry)
		else:
			history.append(entry)
		response_received.emit({
			"content": last_response_text,
			"reasoning_content": last_reasoning_text,
		})
	elif not success:
		# 失败时移除本次请求追加的用户消息，保持历史干净
		var idx := history.rfind(_last_user_message)
		if idx != -1:
			history.remove_at(idx)

	_last_user_message = {}
	request_finished.emit(success, error_message)
	history_changed.emit(history)
	_pump()