@tool
extends EditorPlugin
## Plugin shell: floating AI workbench window, optional VCS bottom panel, runtime autoload.

const AUTOLOAD_NAME := "AI"
const AUTOLOAD_PATH := "res://addons/ai_assistant/autoload/ai_assistant.gd"
const WORKBENCH_PATH := "res://addons/ai_assistant/editor/workbench_main.gd"
const VCS_PANEL_PATH := "res://addons/ai_assistant/editor/vcs_panel.gd"
const PLUGIN_ICON_PATH := "res://addons/ai_assistant/icon.svg"

const WINDOW_SIZE_SETTING := "ai_assistant/workbench_window_size"
const WINDOW_POSITION_SETTING := "ai_assistant/workbench_window_position"
const WINDOW_SCALE_SETTING := "ai_assistant/workbench_window_scale"
const DEFAULT_WINDOW_SIZE := Vector2i(1280, 720)
const MIN_WINDOW_SIZE := Vector2i(1080, 640)
const LEGACY_WINDOW_SIZE := Vector2i(1120, 720)

const RUNTIME_SETTINGS := {
	"ai_assistant/base_url": "https://api.deepseek.com",
	"ai_assistant/api_key": "",
	"ai_assistant/model": "deepseek-chat",
	"ai_assistant/temperature": 1.0,
	"ai_assistant/max_tokens": 0,
	"ai_assistant/stream": true,
	"ai_assistant/timeout": 60.0,
	"ai_assistant/system_prompt": "",
}

const EDITOR_SETTINGS := {
	"ai_assistant/api_key": "",
	"ai_assistant/temperature": 1.0,
	"ai_assistant/max_tokens": 0,
	"ai_assistant/stream": true,
	"ai_assistant/timeout": 60.0,
	"ai_assistant/system_prompt": "你是 Godot 4.6 编程助手。默认用中文简洁回答。",
	"ai_assistant/remember_api_key": false,
	"ai_assistant/permission_mode": "review",
	"ai_assistant/workbench_window_size": DEFAULT_WINDOW_SIZE,
	"ai_assistant/workbench_window_position": Vector2i(-1, -1),
}

var _workbench: Control
var _workbench_window: Window
var _toolbar_button: Button
var _vcs_panel: Control
var _window_geometry_loaded := false


func _enter_tree() -> void:
	_register_editor_settings()
	_register_runtime_settings()
	_build_workbench_window()
	_toolbar_button = Button.new()
	_toolbar_button.text = "AI 工作台"
	_toolbar_button.tooltip_text = "打开悬浮 AI 工作台"
	_toolbar_button.focus_mode = Control.FOCUS_NONE
	_toolbar_button.pressed.connect(_open_workbench)
	add_control_to_container(CONTAINER_TOOLBAR, _toolbar_button)
	_vcs_panel = _build_control(VCS_PANEL_PATH, "版本控制")
	if _vcs_panel != null:
		add_control_to_bottom_panel(_vcs_panel, "版本控制")
	add_tool_menu_item("打开 AI 工作台", Callable(self, "_open_workbench"))
	add_tool_menu_item("AI 工作台设置…", Callable(self, "_open_settings"))


func _exit_tree() -> void:
	remove_tool_menu_item("打开 AI 工作台")
	remove_tool_menu_item("AI 工作台设置…")
	if _toolbar_button != null:
		remove_control_from_container(CONTAINER_TOOLBAR, _toolbar_button)
		_toolbar_button.queue_free()
		_toolbar_button = null
	_persist_window_geometry()
	if _workbench != null:
		if _workbench.has_method("shutdown"):
			_workbench.call("shutdown")
		_workbench = null
	if _workbench_window != null:
		_workbench_window.queue_free()
		_workbench_window = null
	if _vcs_panel != null:
		remove_control_from_bottom_panel(_vcs_panel)
		_vcs_panel.queue_free()
		_vcs_panel = null


func _enable_plugin() -> void:
	var key := "autoload/" + AUTOLOAD_NAME
	if not ProjectSettings.has_setting(key) or String(ProjectSettings.get_setting(key, "")).is_empty():
		add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)


func _disable_plugin() -> void:
	var key := "autoload/" + AUTOLOAD_NAME
	var expected := "*" + AUTOLOAD_PATH
	if ProjectSettings.has_setting(key) and String(ProjectSettings.get_setting(key, "")) == expected:
		remove_autoload_singleton(AUTOLOAD_NAME)


func _has_main_screen() -> bool:
	return false


func _get_unsaved_status(_for_scene: String) -> String:
	if _workbench != null and _workbench.has_method("has_pending_draft"):
		if bool(_workbench.call("has_pending_draft")):
			return "AI 工作台还有尚未应用的脚本草稿。"
	return ""


func _open_workbench() -> void:
	if _workbench_window == null:
		_build_workbench_window()
	if _workbench_window == null:
		return
	if not _workbench_window.visible:
		var centered := _restore_window_geometry()
		if centered:
			_workbench_window.popup_centered(_workbench_window.size)
		else:
			_workbench_window.popup()
		if _workbench != null and _workbench.has_method("set_active"):
			_workbench.call("set_active", true)
	_workbench_window.grab_focus()


func _open_settings() -> void:
	_open_workbench()
	if _workbench != null and _workbench.has_method("open_settings_dialog"):
		_workbench.call_deferred("open_settings_dialog")


func _build_workbench_window() -> void:
	if _workbench_window != null:
		return
	_workbench = _build_control(WORKBENCH_PATH, "AIWorkbenchContent")
	if _workbench == null:
		return
	_workbench_window = Window.new()
	_workbench_window.name = "AIWorkbenchWindow"
	_workbench_window.title = "AI 工作台"
	var editor_scale := _editor_scale()
	_workbench_window.content_scale_factor = editor_scale
	_workbench_window.size = _fit_on_screen(_scaled_size(DEFAULT_WINDOW_SIZE, editor_scale))
	_workbench_window.min_size = _fit_on_screen(_scaled_size(MIN_WINDOW_SIZE, editor_scale))
	_workbench_window.wrap_controls = true
	_workbench_window.transient = true
	_workbench_window.exclusive = false
	_workbench_window.unresizable = false
	_workbench_window.visible = false
	_workbench_window.close_requested.connect(_on_workbench_close_requested)
	_workbench.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_workbench_window.add_child(_workbench)
	EditorInterface.get_base_control().add_child(_workbench_window)


func _on_workbench_close_requested() -> void:
	_persist_window_geometry()
	if _workbench != null and _workbench.has_method("set_active"):
		_workbench.call("set_active", false)
	if _workbench_window != null:
		_workbench_window.hide()


func _restore_window_geometry() -> bool:
	if _workbench_window == null:
		return true
	var settings := _editor_settings()
	var size_value: Variant = settings.get_setting(WINDOW_SIZE_SETTING) if settings.has_setting(WINDOW_SIZE_SETTING) else DEFAULT_WINDOW_SIZE
	var position_value: Variant = settings.get_setting(WINDOW_POSITION_SETTING) if settings.has_setting(WINDOW_POSITION_SETTING) else Vector2i(-1, -1)
	var window_size := size_value as Vector2i if size_value is Vector2i else DEFAULT_WINDOW_SIZE
	if window_size == LEGACY_WINDOW_SIZE:
		window_size = DEFAULT_WINDOW_SIZE
	var previous_scale := float(settings.get_setting(WINDOW_SCALE_SETTING)) if settings.has_setting(WINDOW_SCALE_SETTING) else 1.0
	var editor_scale := _editor_scale()
	window_size = _scaled_size(window_size, editor_scale / maxf(previous_scale, 0.1))
	var minimum := _workbench_window.min_size
	window_size.x = maxi(window_size.x, minimum.x)
	window_size.y = maxi(window_size.y, minimum.y)
	window_size = _fit_on_screen(window_size)
	_workbench_window.size = window_size
	_window_geometry_loaded = true
	if position_value is Vector2i and (position_value as Vector2i).x >= 0 and (position_value as Vector2i).y >= 0:
		var usable := DisplayServer.screen_get_usable_rect(DisplayServer.SCREEN_OF_MAIN_WINDOW)
		var position := position_value as Vector2i
		if usable.size.x > 0 and usable.size.y > 0:
			position.x = clampi(position.x, usable.position.x, usable.end.x - window_size.x)
			position.y = clampi(position.y, usable.position.y, usable.end.y - window_size.y)
		_workbench_window.position = position
		return false
	return true


func _persist_window_geometry() -> void:
	if _workbench_window == null or not _window_geometry_loaded:
		return
	var settings := _editor_settings()
	settings.set_setting(WINDOW_SIZE_SETTING, _workbench_window.size)
	settings.set_setting(WINDOW_POSITION_SETTING, _workbench_window.position)
	settings.set_setting(WINDOW_SCALE_SETTING, _editor_scale())


func _editor_scale() -> float:
	return maxf(EditorInterface.get_editor_scale(), 1.0)


func _scaled_size(value: Vector2i, factor: float) -> Vector2i:
	return Vector2i(roundi(value.x * factor), roundi(value.y * factor))


func _fit_on_screen(value: Vector2i) -> Vector2i:
	var usable := DisplayServer.screen_get_usable_rect(DisplayServer.SCREEN_OF_MAIN_WINDOW)
	if usable.size.x <= 0 or usable.size.y <= 0:
		return value
	return Vector2i(mini(value.x, maxi(1, usable.size.x - 40)), mini(value.y, maxi(1, usable.size.y - 40)))


func _build_control(path: String, control_name: String) -> Control:
	var script: Script = load(path)
	if script == null:
		push_error("AI 工作台：无法加载 %s（%s）。" % [control_name, path])
		return null
	var control := script.new() as Control
	if control == null:
		push_error("AI 工作台：无法创建 %s。" % control_name)
		return null
	control.name = control_name
	return control


func _editor_settings() -> EditorSettings:
	return EditorInterface.get_editor_settings()


func _register_editor_settings() -> void:
	var settings := _editor_settings()
	for key in EDITOR_SETTINGS:
		if not settings.has_setting(key):
			settings.set_setting(key, EDITOR_SETTINGS[key])


func _register_runtime_settings() -> void:
	var changed := false
	for key in RUNTIME_SETTINGS:
		if not ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, RUNTIME_SETTINGS[key])
			changed = true
	if changed:
		ProjectSettings.save()
	if not String(ProjectSettings.get_setting("ai_assistant/api_key", "")).is_empty():
		push_warning(
			"AI 工作台：检测到 API Key 写入 project.godot。"
			+ "编辑器请用工作台设置；游戏运行时推荐环境变量 AI_API_KEY。",
		)
