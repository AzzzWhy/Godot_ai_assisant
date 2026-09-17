@tool
class_name AIInlinePatch
extends RefCounted
## Applies unique search/replace edits and reports line hunks for the script editor.


static func apply_edits(source: String, edits: Array) -> Dictionary:
	var text := source
	var hunks: Array = []
	var added := 0
	var removed := 0
	for raw in edits:
		if not (raw is Dictionary):
			continue
		var item: Dictionary = raw
		var old_string := String(item.get("old_string", ""))
		var new_string := String(item.get("new_string", ""))
		if old_string.is_empty():
			return {"error": "编辑缺少 old_string，无法在脚本中定位。"}
		var count := _count_occurrences(text, old_string)
		if count == 0:
			return {"error": "找不到要替换的原文，请让模型用文件中的精确片段重试。"}
		if count > 1:
			return {"error": "原文在文件中出现了 %d 次，为避免误改已拒绝。请缩小替换范围。" % count}
		var at := text.find(old_string)
		var start_line := text.substr(0, at).count("\n")
		var new_line_count := maxi(1, new_string.split("\n").size())
		var old_line_count := maxi(1, old_string.split("\n").size())
		hunks.append({
			"start": start_line,
			"count": new_line_count,
			"added": new_line_count,
			"removed": old_line_count,
			"summary": String(item.get("summary", "")),
		})
		added += new_line_count
		removed += old_line_count
		text = text.substr(0, at) + new_string + text.substr(at + old_string.length())
	if hunks.is_empty():
		return {"error": "没有可应用的编辑。"}
	return {"text": text, "hunks": hunks, "added": added, "removed": removed}


static func hunks_from_full_replace(original: String, proposed: String) -> Array:
	var old_lines := original.split("\n")
	var new_lines := proposed.split("\n")
	var hunks: Array = []
	var i := 0
	var start := -1
	while i < new_lines.size() or i < old_lines.size():
		var old_line := String(old_lines[i]) if i < old_lines.size() else ""
		var new_line := String(new_lines[i]) if i < new_lines.size() else ""
		var different := i >= old_lines.size() or i >= new_lines.size() or old_line != new_line
		if different:
			if start < 0:
				start = mini(i, new_lines.size() - 1) if not new_lines.is_empty() else 0
		elif start >= 0:
			hunks.append(_hunk(start, i - start))
			start = -1
		i += 1
	if start >= 0:
		hunks.append(_hunk(start, maxi(1, new_lines.size() - start)))
	if hunks.is_empty() and original != proposed and not new_lines.is_empty():
		hunks.append(_hunk(0, new_lines.size()))
	return hunks


static func parse_response(response: String) -> Dictionary:
	var payload := response.strip_edges()
	var block := RegEx.new()
	block.compile("```json\\s*([\\s\\S]*?)```")
	var match := block.search(payload)
	if match != null:
		payload = match.get_string(1).strip_edges()
	var json := JSON.new()
	if json.parse(payload) != OK or not (json.data is Dictionary):
		return {}
	var parsed: Dictionary = json.data
	if parsed.has("error") and not String(parsed.get("error", "")).is_empty():
		return {"error": String(parsed.error)}
	var edits: Variant = parsed.get("edits", [])
	if edits is Array and not edits.is_empty():
		return {"summary": String(parsed.get("summary", "脚本内联改动")), "edits": edits}
	return {}


static func first_script_block(response: String) -> String:
	var re := RegEx.new()
	re.compile("```(?:gdscript|gd)?\\s*\\n([\\s\\S]*?)```")
	var match := re.search(response)
	if match == null:
		return ""
	return match.get_string(1).strip_edges()


static func editing_prompt(request: String, path: String, source: String) -> String:
	return """You are editing one Godot 4.x GDScript in place. Do not claim the file was saved.
Return one JSON object inside a ```json block:
{
  "summary": "short Chinese summary",
  "edits": [{"old_string":"exact original snippet","new_string":"replacement","summary":"short Chinese summary"}]
}
Rules:
- old_string must uniquely match the current file, including whitespace.
- Keep unrelated logic unchanged.
- Only edit this .gd file. No terminal commands.

File: %s
User request:
%s

Current file:
```gdscript
%s
```""" % [path, request, source]


static func _count_occurrences(text: String, needle: String) -> int:
	if needle.is_empty():
		return 0
	var count := 0
	var from := 0
	while true:
		var at := text.find(needle, from)
		if at < 0:
			break
		count += 1
		from = at + needle.length()
	return count


static func _hunk(start: int, count: int) -> Dictionary:
	return {"start": maxi(0, start), "count": maxi(1, count), "added": maxi(1, count), "removed": 0, "summary": ""}
