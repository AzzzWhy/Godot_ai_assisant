@tool
extends PanelContainer
## One response owns its reasoning, Markdown answer and animation lifecycle.

signal content_changed

const THEME := preload("res://addons/ai_assistant/editor/workbench_dark_theme.gd")
const MARKDOWN := preload("res://addons/ai_assistant/editor/chat_markdown.gd")
const REASONING_HEIGHT := 220.0
const RENDER_INTERVAL := 0.05

var role := "assistant"
var answer_text := ""
var reasoning_text := ""
var animations_enabled := true
var running := false
var reasoning_expanded := true
var _started_ms := 0
var _elapsed := 0.0
var _render_elapsed := 0.0
var _dirty := false
var _revealed := 0.0
var _manual_fold := false
var _finish_state := "idle"
var _column: VBoxContainer
var _reasoning_panel: PanelContainer
var _reasoning_toggle: Button
var _reasoning_scroll: ScrollContainer
var _reasoning_body: RichTextLabel
var _answer: RichTextLabel
var _indicator: Label
var _status: Label
var _fade: Tween
var _fold: Tween


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := THEME.panel(THEME.USER_BG if role == "user" else THEME.BG_INSET, 9)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 10
	style.content_margin_bottom = 12
	style.border_color = Color("#323c49")
	add_theme_stylebox_override("panel", style)
	_column = VBoxContainer.new()
	_column.add_theme_constant_override("separation", 10)
	add_child(_column)
	var header := HBoxContainer.new()
	_column.add_child(header)
	var author := Label.new()
	author.text = "你" if role == "user" else ("系统" if role == "system" else "AI")
	THEME.apply_label(author, role == "system", 12)
	if role == "assistant":
		author.add_theme_color_override("font_color", THEME.ACCENT_EMPHASIS)
	header.add_child(author)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	_status = Label.new()
	THEME.apply_label(_status, true, 11)
	header.add_child(_status)
	_indicator = Label.new()
	_indicator.text = "●"
	THEME.apply_label(_indicator, true, 11)
	_indicator.visible = false
	header.add_child(_indicator)
	_build_reasoning()
	_answer = _rich_text(false)
	_column.add_child(_answer)
	_answer.visible = false
	set_process(false)
	if animations_enabled:
		modulate.a = 0.0
		_fade = create_tween()
		_fade.tween_property(self, "modulate:a", 1.0, 0.18)


func _build_reasoning() -> void:
	_reasoning_panel = PanelContainer.new()
	var style := THEME.panel(Color("#1d2733"), 6)
	style.border_color = Color("#35465a")
	style.border_width_left = 2
	_reasoning_panel.add_theme_stylebox_override("panel", style)
	_reasoning_panel.visible = false
	_column.add_child(_reasoning_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	_reasoning_panel.add_child(box)
	_reasoning_toggle = Button.new()
	_reasoning_toggle.flat = true
	_reasoning_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_reasoning_toggle.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_reasoning_toggle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_reasoning_toggle.add_theme_font_size_override("font_size", 12)
	_reasoning_toggle.add_theme_color_override("font_color", Color("#acbdd0"))
	_reasoning_toggle.tooltip_text = "展开或收起模型返回的思考内容"
	_reasoning_toggle.pressed.connect(func() -> void:
		_manual_fold = true
		set_reasoning_expanded(not reasoning_expanded)
	)
	box.add_child(_reasoning_toggle)
	_reasoning_scroll = ScrollContainer.new()
	_reasoning_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_reasoning_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_reasoning_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_reasoning_scroll.visible = false
	box.add_child(_reasoning_scroll)
	_reasoning_body = _rich_text(true)
	_reasoning_body.resized.connect(_resize_reasoning)
	_reasoning_scroll.add_child(_reasoning_body)


func _rich_text(muted: bool) -> RichTextLabel:
	var body := RichTextLabel.new()
	body.bbcode_enabled = true
	body.fit_content = true
	body.scroll_active = false
	body.selection_enabled = true
	body.context_menu_enabled = true
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Explicit system-font weights keep CJK headings readable instead of using
	# the engine fallback font's heavy synthetic bold. Fall back across platforms.
	for font_kind in ["normal_font", "bold_font", "italics_font", "bold_italics_font"]:
		var font := SystemFont.new()
		font.font_names = PackedStringArray(["Microsoft YaHei UI", "PingFang SC", "Noto Sans CJK SC", "sans-serif"])
		font.font_weight = 600 if font_kind.contains("bold") else 400
		font.font_italic = font_kind.contains("italics")
		body.add_theme_font_override(font_kind, font)
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["Cascadia Code", "Consolas", "Menlo", "Noto Sans Mono", "monospace"])
	body.add_theme_font_override("mono_font", mono)
	body.add_theme_color_override("default_color", Color("#aebdce") if muted else THEME.FG)
	for font_size in ["normal_font_size", "bold_font_size", "italics_font_size", "bold_italics_font_size", "mono_font_size"]:
		body.add_theme_font_size_override(font_size, 13)
	body.add_theme_constant_override("line_separation", 5)
	return body


func begin() -> void:
	running = true
	_started_ms = Time.get_ticks_msec()
	_status.text = "等待模型"
	_indicator.visible = true
	set_process(true)


func append_reasoning(chunk: String) -> void:
	if chunk.is_empty():
		return
	reasoning_text += chunk
	_reasoning_panel.visible = true
	_dirty = true
	set_process(true)
	_update_status()


func append_answer(chunk: String) -> void:
	if chunk.is_empty():
		return
	answer_text += chunk
	_dirty = true
	set_process(true)
	_update_status()


func set_answer(text: String) -> void:
	answer_text = text
	_dirty = true
	# Static user/system messages and non-streaming replies are immediately readable.
	_flush_text()
	_revealed = _answer.get_total_character_count()
	_answer.visible_characters = -1
	_update_status()


func finish(state: String = "idle") -> void:
	_flush_text()
	running = false
	_finish_state = state
	_indicator.visible = false
	_revealed = _answer.get_total_character_count()
	_answer.visible_characters = -1
	_elapsed = (Time.get_ticks_msec() - _started_ms) / 1000.0 if _started_ms > 0 else 0.0
	if not reasoning_text.is_empty() and not _manual_fold:
		set_reasoning_expanded(false)
	_update_status()
	set_process(false)
	content_changed.emit()


func set_animations(enabled: bool) -> void:
	animations_enabled = enabled
	if not enabled:
		if _fade != null and _fade.is_running():
			_fade.kill()
		modulate.a = 1.0
		if _fold != null and _fold.is_running():
			_fold.kill()
		if _answer != null:
			_revealed = _answer.get_total_character_count()
			_answer.visible_characters = -1
		if _indicator != null:
			_indicator.modulate.a = 1.0
		_apply_reasoning_height()


func _process(delta: float) -> void:
	_render_elapsed += delta
	if _dirty and _render_elapsed >= RENDER_INTERVAL:
		_render_elapsed = 0.0
		_flush_text()
	if running:
		_elapsed = (Time.get_ticks_msec() - _started_ms) / 1000.0
		_indicator.modulate.a = 0.4 + 0.6 * (sin(_elapsed * 4.0) + 1.0) * 0.5 if animations_enabled else 1.0
		_update_status()
	if animations_enabled and running:
		var total := _answer.get_total_character_count()
		# Catch up quickly with large chunks; never leave an accumulating text backlog.
		_revealed = minf(total, _revealed + delta * maxf(80.0, (total - _revealed) * 10.0))
		_answer.visible_characters = int(_revealed)
	else:
		_revealed = _answer.get_total_character_count()
		_answer.visible_characters = -1


func _flush_text() -> void:
	if not _dirty:
		return
	_dirty = false
	var follow_reasoning := _reasoning_scroll.scroll_vertical >= _reasoning_scroll.get_v_scroll_bar().max_value - _reasoning_scroll.get_v_scroll_bar().page - 24
	_reasoning_body.text = MARKDOWN.render(reasoning_text)
	_answer.text = MARKDOWN.render(answer_text) if role == "assistant" else MARKDOWN.escape_bbcode(answer_text)
	_answer.visible = not answer_text.is_empty()
	_apply_reasoning_height.call_deferred()
	if follow_reasoning:
		_scroll_reasoning_to_end.call_deferred()
	content_changed.emit()


func set_reasoning_expanded(expanded: bool) -> void:
	reasoning_expanded = expanded
	_update_status()
	if _fold != null and _fold.is_running():
		_fold.kill()
	var height := _reasoning_height() if expanded else 0.0
	if not animations_enabled or not is_inside_tree():
		_apply_reasoning_height()
		return
	_reasoning_scroll.visible = true
	_fold = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_fold.tween_property(_reasoning_scroll, "custom_minimum_size:y", height, 0.18)
	_fold.tween_callback(func() -> void:
		_reasoning_scroll.visible = reasoning_expanded and not reasoning_text.is_empty()
		content_changed.emit()
	)


func _reasoning_height() -> float:
	return minf(REASONING_HEIGHT, maxf(24.0, _reasoning_body.get_content_height() + 8.0))


func _resize_reasoning() -> void:
	_apply_reasoning_height.call_deferred()


func _apply_reasoning_height() -> void:
	if _reasoning_scroll == null or (_fold != null and _fold.is_running()):
		return
	_reasoning_scroll.visible = reasoning_expanded and not reasoning_text.is_empty()
	_reasoning_scroll.custom_minimum_size.y = _reasoning_height() if _reasoning_scroll.visible else 0.0


func _scroll_reasoning_to_end() -> void:
	if reasoning_expanded:
		_reasoning_scroll.scroll_vertical = int(_reasoning_scroll.get_v_scroll_bar().max_value)


func _update_status() -> void:
	if _status == null:
		return
	if running:
		_status.text = ("正在回复" if not answer_text.is_empty() else ("正在思考" if not reasoning_text.is_empty() else "等待模型")) + " · %ds" % int(_elapsed)
	elif role == "assistant":
		_status.text = "已停止" if _finish_state == "cancelled" else ("未完成" if _finish_state == "error" else "回复完成")
	var caption := "思考过程" if running else "思考过程 · %ds" % int(_elapsed)
	_reasoning_toggle.text = ("▾  " if reasoning_expanded else "▸  ") + caption
