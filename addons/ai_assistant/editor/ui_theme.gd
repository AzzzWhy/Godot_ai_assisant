@tool
class_name AITheme
extends RefCounted
## Godot 4 editor-like dark docks: base_color ~ (0.2, 0.23, 0.31), accent #478cbf.

const BG := Color("#1d2229")
const BG_MUTED := Color("#252b34")
const BG_INSET := Color("#151920")
const BG_CARD := Color("#2a3340")
const FG := Color("#dee4ed")
const FG_MUTED := Color("#8e98a8")
const ACCENT := Color("#478cbf")
const ACCENT_EMPHASIS := Color("#57a3d8")
const SUCCESS := Color("#3fb950")
const SUCCESS_EMPHASIS := Color("#3b8c4a")
const DANGER := Color("#e35d5d")
const ATTENTION := Color("#d29922")
const BORDER := Color("#3d4554")
const USER_BG := Color("#243044")
const AI_BG := Color("#252b34")
const CHIP_BG := Color("#323b4a")


static func panel(bg: Color = BG_CARD, radius := 3) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.set_corner_radius_all(radius)
	box.set_border_width_all(1)
	box.border_color = BORDER
	box.content_margin_left = 8
	box.content_margin_right = 8
	box.content_margin_top = 6
	box.content_margin_bottom = 6
	return box


static func button(kind := "default") -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.set_corner_radius_all(3)
	box.content_margin_left = 10
	box.content_margin_right = 10
	box.content_margin_top = 4
	box.content_margin_bottom = 4
	match kind:
		"primary":
			box.bg_color = SUCCESS_EMPHASIS
			box.border_color = SUCCESS_EMPHASIS
		"danger":
			box.bg_color = Color("#3d1618")
			box.border_color = Color("#da3633")
		"ghost":
			box.bg_color = Color(0, 0, 0, 0)
			box.border_color = BORDER
		"selected":
			box.bg_color = Color("#1f6feb33")
			box.border_color = ACCENT_EMPHASIS
		_:
			box.bg_color = CHIP_BG
			box.border_color = BORDER
	box.set_border_width_all(1)
	return box


static func input_box() -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = BG_INSET
	box.set_corner_radius_all(3)
	box.set_border_width_all(1)
	box.border_color = BORDER
	box.content_margin_left = 10
	box.content_margin_right = 10
	box.content_margin_top = 8
	box.content_margin_bottom = 8
	return box


static func apply_button(btn: Button, kind := "default") -> void:
	btn.add_theme_stylebox_override("normal", button(kind))
	var hover := button(kind)
	hover.bg_color = hover.bg_color.lightened(0.08)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", button("selected" if kind != "primary" else "primary"))
	btn.add_theme_color_override("font_color", FG if kind != "ghost" else FG_MUTED)
	btn.add_theme_color_override("font_hover_color", FG)
	btn.add_theme_font_size_override("font_size", 13)


static func apply_label(label: Label, muted := false, size := 13) -> void:
	label.add_theme_color_override("font_color", FG_MUTED if muted else FG)
	label.add_theme_font_size_override("font_size", size)


static func apply_line_edit(edit: Control) -> void:
	edit.add_theme_stylebox_override("normal", input_box())
	edit.add_theme_stylebox_override("focus", input_box())
	edit.add_theme_color_override("font_color", FG)
	edit.add_theme_color_override("font_placeholder_color", FG_MUTED)


static func chip(text: String) -> PanelContainer:
	var wrap := PanelContainer.new()
	wrap.add_theme_stylebox_override("panel", panel(CHIP_BG, 12))
	var label := Label.new()
	label.text = text
	apply_label(label, true, 12)
	wrap.add_child(label)
	return wrap
