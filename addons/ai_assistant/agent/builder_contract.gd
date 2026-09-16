@tool
class_name AIBuilderContract
extends RefCounted
## Structured contract for one Builder run.


static func prompt(request: String, context: Dictionary) -> String:
	return """You are a Godot 4.6 Builder agent. Produce a complete, reviewable implementation for the user's request.
Nothing has been written yet. Never claim that files, nodes, or scenes were already changed.

Return one JSON object inside a ```json block:
{
  "summary": "short Chinese summary",
  "plan": ["short Chinese step"],
  "changes": [
    {
      "path": "res://path/file.gd",
      "action": "create|update",
      "summary": "short Chinese summary",
      "content": "complete final file content (required for create)",
      "edits": [
        {
          "old_string": "exact unique original snippet",
          "new_string": "replacement",
          "summary": "short Chinese summary"
        }
      ]
    }
  ],
  "node_operations": [
    {
      "operation": "attach_script",
      "target": "selected",
      "script_path": "res://path/file.gd",
      "summary": "short Chinese summary"
    }
  ]
}

Rules:
- Return valid JSON only inside the json fence.
- changes may contain multiple files, but only .gd files below res://.
- content is mandatory for create. For update, prefer exact edits; content is also accepted.
- Every old_string must exactly and uniquely match the current file, including whitespace.
- Never propose terminal commands, .tscn edits, deletes, moves, or paths containing "..".
- Only emit attach_script when a selected node exists and should use the generated script.
- Use target="selected"; the host locks the exact node at task start.
- Keep unrelated code unchanged and use Godot 4.6 APIs.

Editor context:
%s

User request:
%s""" % [JSON.stringify(context, "  "), request]


static func parse(response: String) -> Dictionary:
	var payload := response.strip_edges()
	var block := RegEx.new()
	block.compile("```json\\s*([\\s\\S]*?)```")
	var match := block.search(payload)
	if match != null:
		payload = match.get_string(1).strip_edges()
	var json := JSON.new()
	if json.parse(payload) != OK or not (json.data is Dictionary):
		return {"error": "AI 返回的不是可识别的 Builder JSON。"}
	var parsed: Dictionary = json.data
	if parsed.has("error") and not String(parsed.get("error", "")).is_empty():
		return {"error": String(parsed.error)}
	return normalize(parsed)


static func normalize(parsed: Dictionary) -> Dictionary:
	var raw_changes: Variant = parsed.get("changes", [])
	# Backwards compatibility with the first single-file V2 contract.
	if raw_changes is Array and raw_changes.is_empty() and parsed.has("path"):
		raw_changes = [{
			"path": parsed.get("path", ""),
			"action": parsed.get("action", "update"),
			"summary": parsed.get("summary", "AI 脚本改动"),
			"content": parsed.get("content", ""),
			"edits": parsed.get("edits", []),
		}]
	if not (raw_changes is Array) or raw_changes.is_empty():
		return {"error": "Builder 结果没有 changes 数组。"}

	var changes: Array[Dictionary] = []
	for raw in raw_changes:
		if not (raw is Dictionary):
			return {"error": "changes 中存在无效项目。"}
		var item: Dictionary = raw
		var path := String(item.get("path", "")).strip_edges()
		var action := String(item.get("action", "update")).strip_edges().to_lower()
		var content := String(item.get("content", ""))
		var edits: Variant = item.get("edits", [])
		if not safe_script_path(path):
			return {"error": "已拒绝不安全脚本路径：%s" % path}
		if not ["create", "update"].has(action):
			return {"error": "Builder 只允许 create/update：%s" % action}
		if action == "create" and content.is_empty():
			return {"error": "%s 是 create，但缺少完整 content。" % path}
		if action == "update" and content.is_empty() and (not (edits is Array) or edits.is_empty()):
			return {"error": "%s 是 update，但没有 content 或 edits。" % path}
		changes.append({
			"path": path,
			"action": action,
			"summary": String(item.get("summary", "AI 脚本改动")),
			"content": content,
			"edits": edits if edits is Array else [],
		})

	var raw_operations: Variant = parsed.get("node_operations", [])
	if not (raw_operations is Array):
		return {"error": "node_operations 必须是数组。"}
	# Backwards compatibility with attach=true.
	if raw_operations.is_empty() and bool(parsed.get("attach", false)):
		raw_operations = [{
			"operation": "attach_script",
			"target": "selected",
			"script_path": String(changes[0].path),
			"summary": "挂载生成的脚本",
		}]
	var operations: Array[Dictionary] = []
	for raw in raw_operations:
		if not (raw is Dictionary):
			return {"error": "node_operations 中存在无效项目。"}
		var item: Dictionary = raw
		var operation := String(item.get("operation", "")).strip_edges()
		var target := String(item.get("target", "selected")).strip_edges()
		var script_path := String(item.get("script_path", "")).strip_edges()
		if operation != "attach_script" or target != "selected":
			return {"error": "只允许对任务开始时选中的节点执行 attach_script。"}
		if not safe_script_path(script_path):
			return {"error": "节点操作包含不安全脚本路径：%s" % script_path}
		var found := false
		for change in changes:
			if String(change.path) == script_path:
				found = true
				break
		operations.append({
			"operation": operation,
			"target": target,
			"script_path": script_path,
			"summary": String(item.get("summary", "挂载脚本")),
		})
	if operations.size() > 1:
		return {"error": "当前版本每轮只允许给选中节点绑定一个脚本。"}

	var raw_plan: Variant = parsed.get("plan", [])
	var plan: Array = raw_plan if raw_plan is Array else []
	return {
		"summary": String(parsed.get("summary", "Builder 已生成改动")),
		"plan": plan,
		"changes": changes,
		"node_operations": operations,
	}


static func safe_script_path(path: String) -> bool:
	return (
		path.begins_with("res://")
		and path.ends_with(".gd")
		and not path.contains("..")
		and not path.contains("\\")
		and not path.trim_prefix("res://").contains(":")
	)
