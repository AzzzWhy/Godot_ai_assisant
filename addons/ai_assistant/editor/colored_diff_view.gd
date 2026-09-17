@tool
class_name AIDiffView
extends RichTextLabel

func render_diff(diff: String) -> void:
	clear()
	bbcode_enabled = true
	for line in diff.split("\n"):
		var color := "d1d5db"
		if line.begins_with("+++") or line.begins_with("---") or line.begins_with("index "):
			color = "94a3b8"
		elif line.begins_with("@@"):
			color = "60a5fa"
		elif line.begins_with("+"):
			color = "86efac"
		elif line.begins_with("-"):
			color = "fca5a5"
		append_text("[color=#%s]%s[/color]\n" % [color, _escape_bbcode(line)])


func _escape_bbcode(text: String) -> String:
	return (
		text
		.replace("[", "\u0001")
		.replace("]", "\u0002")
		.replace("\u0001", "[lb]")
		.replace("\u0002", "[rb]")
	)
