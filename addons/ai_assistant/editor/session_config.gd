@tool
class_name AIEditorSession
extends RefCounted
## In-memory editor credentials shared by plugin panels. Never persisted by this helper.

static var api_key := ""
static var base_url := ""
static var model := ""
static var temperature := 1.0
static var max_tokens := 0
static var timeout_seconds := 60.0


static func capture(client: AILLMClient) -> void:
	api_key = client.api_key
	base_url = client.base_url
	model = client.model
	temperature = client.temperature
	max_tokens = client.max_tokens
	timeout_seconds = client.timeout_seconds


static func apply_to(client: AILLMClient) -> void:
	if not api_key.is_empty():
		client.api_key = api_key
	if not base_url.is_empty():
		client.base_url = base_url
	if not model.is_empty():
		client.model = model
	client.temperature = temperature
	client.max_tokens = max_tokens
	client.timeout_seconds = timeout_seconds
