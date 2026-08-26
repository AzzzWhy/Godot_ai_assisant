@tool
class_name AIProposalParser
extends RefCounted
## Parses the small JSON contract used by V2 planning responses.

static func planning_prompt(request: String, context: String) -> String:
	return """You are preparing a Godot script change proposal. Do not claim changes were applied.
Return one JSON object inside a ```json block using this schema:
{
  "plan": ["short step"],
  "changes": [{"path":"res://path/file.gd", "action":"create|update|delete", "summary":"short Chinese summary", "content":"complete file content"}]
}
Rules: only propose .gd files below res://; use complete content for create/update; delete has no content.

User request:
%s

Selected Godot context:
%s""" % [request, context]


static func parse(response: String) -> Dictionary:
	var payload := response.strip_edges()
	var block := RegEx.new()
	block.compile("```json\\s*([\\s\\S]*?)```")
	var match := block.search(payload)
	if match != null:
		payload = match.get_string(1).strip_edges()
	var json := JSON.new()
	if json.parse(payload) != OK or not (json.data is Dictionary):
		return {"error": "AI 返回的不是可识别的提案 JSON。请要求它按 JSON 提案格式重试。"}
	var parsed: Dictionary = json.data
	var changes: Variant = parsed.get("changes", [])
	if not (changes is Array):
		return {"error": "提案缺少 changes 数组。"}
	return {"plan": parsed.get("plan", []), "changes": changes}
