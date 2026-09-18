extends SceneTree
## Offline Markdown rendering checks, including incomplete streaming frames.

const MARKDOWN := preload("res://addons/ai_assistant/editor/chat_markdown.gd")
var _failures := 0


func _initialize() -> void:
	_check(MARKDOWN.render("**加粗** / *强调* / `player_name`").contains("[b]加粗[/b] / [i]强调[/i]"), "Inline emphasis is rendered")
	_check(MARKDOWN.render("***一起***").contains("[b][i]一起[/i][/b]"), "Combined emphasis is balanced")
	_check(_plain("# 标题\n- 项目\n1. 第一步\n> 引用") == "标题\n• 项目\n1. 第一步\n│ 引用", "Headers, lists and quotes preserve readable text")
	_check(_plain("player_name and some_variable_name") == "player_name and some_variable_name", "Identifier underscores remain literal")
	_check(_plain("\\*普通文字\\*") == "*普通文字*", "Markdown escapes remain literal")
	var hostile := "[url=https://example.invalid]link[/url] [img]res://secret[/img] [lb] [rb]"
	_check(_plain(hostile) == hostile, "Raw BBCode is displayed literally")
	_check(_plain("`" + hostile + "`") == hostile, "Inline code cannot inject BBCode")
	_check(_plain("```gdscript\n" + hostile + "\n```") == hostile, "Fenced code cannot inject BBCode")
	_check(_plain("```gdscript\nvar text = \"**literal**\"\n``\n```\n**正常**") == "var text = \"**literal**\"\n``\n正常", "A short closing fence stays literal and closed code allows subsequent Markdown")
	_check(_plain("~~~\n*literal*\n~~~") == "*literal*", "Tilde fences are supported")
	var stream := "## 回复\n**准备**\n```gdscript\nvar names = [\"[b]literal[/b]\"]\n```\n完成。"
	for length in range(stream.length() + 1):
		var frame := MARKDOWN.render(stream.left(length))
		_check(frame.count("[code]") == frame.count("[/code]"), "Code tags close in every partial frame %d" % length)
		_check(frame.count("[b]") == frame.count("[/b]"), "Bold tags close in every partial frame %d" % length)
		_check(frame.count("[i]") == frame.count("[/i]"), "Italic tags close in every partial frame %d" % length)
	_check(_plain("`unfinished [b]**code**") == "unfinished [b]**code**", "Incomplete inline code stays literal")
	await process_frame
	await _test_narrow_layout()
	if _failures == 0:
		print("CHAT_MARKDOWN_TEST_OK")
	quit(0 if _failures == 0 else 1)


func _test_narrow_layout() -> void:
	var column := VBoxContainer.new()
	column.size = Vector2(300, 100)
	get_root().add_child(column)
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.text = MARKDOWN.render("```gdscript\nvar long_resource = preload(\"res://" + "very_long_asset_path_".repeat(20) + ".tscn\")\n```")
	column.add_child(label)
	await process_frame
	await process_frame
	_check(label.get_combined_minimum_size().x <= 300, "Long code does not force the chat rail wider")
	_check(label.get_content_height() > 30, "Long code wraps onto multiple lines")
	column.queue_free()
	await process_frame


func _plain(markdown: String) -> String:
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.text = MARKDOWN.render(markdown)
	var result := label.get_parsed_text()
	label.free()
	return result


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		printerr("CHAT_MARKDOWN_TEST_FAILED: " + message)
