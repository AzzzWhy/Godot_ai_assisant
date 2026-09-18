@tool
extends RefCounted
## Small, streaming-friendly Markdown subset for the narrow chat rail.
## User/model text is escaped before any trusted BBCode is added. Code uses
## ordinary inline font/background spans so long lines can still word-wrap.

const CODE_OPEN := "[bgcolor=#222b36][color=#c6d5e8][code]"
const CODE_CLOSE := "[/code][/color][/bgcolor]"


static func render(text: String) -> String:
	var output := PackedStringArray()
	var fence_character := ""
	var fence_length := 0
	var code_lines := PackedStringArray()
	for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
		var trimmed := line.strip_edges()
		if not fence_character.is_empty():
			var closing_length := _leading_count(trimmed, fence_character)
			if closing_length >= fence_length and trimmed.substr(closing_length).strip_edges().is_empty():
				output.append(CODE_OPEN + escape_bbcode("\n".join(code_lines)) + CODE_CLOSE)
				code_lines.clear()
				fence_character = ""
			else:
				code_lines.append(line)
			continue
		var opening_character := trimmed.left(1)
		var opening_length := _leading_count(trimmed, opening_character) if opening_character in ["`", "~"] else 0
		if opening_length >= 3:
			fence_character = opening_character
			fence_length = opening_length
			continue
		output.append(_render_line(line))
	# Close the generated spans even while the model is still inside a fence.
	if not fence_character.is_empty():
		output.append(CODE_OPEN + escape_bbcode("\n".join(code_lines)) + CODE_CLOSE)
	return "\n".join(output)


static func escape_bbcode(text: String) -> String:
	# Escaping only opening brackets also preserves literal [lb]/[rb] strings.
	return text.replace("[", "[lb]")


static func _render_line(line: String) -> String:
	var trimmed := line.strip_edges()
	var heading_level := _leading_count(trimmed, "#")
	if heading_level in range(1, 7) and trimmed.substr(heading_level).begins_with(" "):
		var heading_size := 20 if heading_level == 1 else (18 if heading_level == 2 else (16 if heading_level == 3 else 14))
		return "[font_size=%d][b]%s[/b][/font_size]" % [heading_size, _inline(trimmed.substr(heading_level + 1))]
	if trimmed == ">" or trimmed.begins_with("> "):
		return "[color=#8e98a8]│ %s[/color]" % _inline(trimmed.substr(2))
	if trimmed.begins_with("- ") or trimmed.begins_with("* ") or trimmed.begins_with("+ "):
		var indent := line.substr(0, line.find(trimmed))
		return indent + "• " + _inline(trimmed.substr(2))
	# Numbered lists keep their original numbers; no table/indent minimum width.
	return _inline(line)


static func _inline(text: String) -> String:
	var output := PackedStringArray()
	var emphasis: Array[Dictionary] = []
	var position := 0
	while position < text.length():
		var character := text.substr(position, 1)
		if character == "\\" and position + 1 < text.length() and text.substr(position + 1, 1) in ["*", "_", "`", "\\", "[", "]"]:
			output.append(escape_bbcode(text.substr(position + 1, 1)))
			position += 2
			continue
		if character == "`":
			var ticks := 1
			while position + ticks < text.length() and text.substr(position + ticks, 1) == "`":
				ticks += 1
			var delimiter := "`".repeat(ticks)
			var closing := text.find(delimiter, position + ticks)
			if closing == -1:
				# Incomplete inline code must not start interpreting its contents.
				output.append(CODE_OPEN + escape_bbcode(text.substr(position + ticks)) + CODE_CLOSE)
				break
			output.append(CODE_OPEN + escape_bbcode(text.substr(position + ticks, closing - position - ticks)) + CODE_CLOSE)
			position = closing + ticks
			continue
		if character == "*" or character == "_":
			var marker_length := 1
			while marker_length < 3 and position + marker_length < text.length() and text.substr(position + marker_length, 1) == character:
				marker_length += 1
			var marker := character.repeat(marker_length)
			var before := text.substr(position - 1, 1) if position > 0 else ""
			var after := text.substr(position + marker_length, 1)
			var inside_word := character == "_" and _is_word_character(before) and _is_word_character(after)
			if not inside_word:
				if not emphasis.is_empty() and emphasis.back()["marker"] == marker and not before.strip_edges().is_empty():
					var opened: Dictionary = emphasis.pop_back()
					output[int(opened["index"])] = "[b][i]" if marker_length == 3 else ("[b]" if marker_length == 2 else "[i]")
					output.append("[/i][/b]" if marker_length == 3 else ("[/b]" if marker_length == 2 else "[/i]"))
					position += marker_length
					continue
				if not after.strip_edges().is_empty():
					emphasis.append({"marker": marker, "index": output.size()})
			output.append(marker)
			position += marker_length
			continue
		output.append(escape_bbcode(character))
		position += 1
	return "".join(output)


static func _leading_count(text: String, character: String) -> int:
	var count := 0
	while count < text.length() and text.substr(count, 1) == character:
		count += 1
	return count


static func _is_word_character(character: String) -> bool:
	if character.is_empty():
		return false
	var codepoint := character.unicode_at(0)
	return character == "_" or character.to_lower() != character.to_upper() or (codepoint >= 48 and codepoint <= 57) or codepoint >= 128
