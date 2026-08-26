@tool
extends EditorPlugin
## AI Assistant 插件入口。
## - 在编辑器右侧停靠区添加「AI 助手」聊天面板
## - 自动注册全局单例 AI（autoload），供游戏运行时使用
## - 迁移/注册项目设置默认值

const AUTOLOAD_NAME := "AI"
const AUTOLOAD_PATH := "res://addons/ai_assistant/autoload/ai_assistant.gd"
const DOCK_SCRIPT_PATH := "res://addons/ai_assistant/editor/ai_chat_dock.gd"
const TASK_DOCK_SCRIPT_PATH := "res://addons/ai_assistant/editor/task_dock.gd"
const VCS_DOCK_SCRIPT_PATH := "res://addons/ai_assistant/editor/vcs_panel.gd"
const PLUGIN_ICON_PATH := "res://addons/ai_assistant/icon.svg"

## 运行时（游戏内）使用的 ProjectSettings 默认值
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

## 编辑器（面板）使用的 EditorSettings 默认值
## 注：base_url / model 不在此预写默认值，避免「首开凭空出现一个没填过的地址」的困惑；
## 面板首次打开留空，用占位符提示，保存过什么就显示什么。
const EDITOR_SETTINGS := {
	"ai_assistant/api_key": "",
	"ai_assistant/temperature": 1.0,
	"ai_assistant/max_tokens": 0,
	"ai_assistant/stream": true,
	"ai_assistant/timeout": 60.0,
	"ai_assistant/system_prompt": "你是一个嵌入在 Godot 游戏引擎中的 AI 编程助手。你精通 GDScript、Godot 4.x 引擎 API、游戏设计与 AI 集成。回答尽量简洁，给出可直接运行的代码，默认使用中文。",
	"ai_assistant/managed_autoload": false,
	"ai_assistant/remember_api_key": false,
	"ai_assistant/permission_mode": "review",
}

var _dock: Control = null
var _task_dock: Control = null
var _vcs_dock: Control = null


func _enter_tree() -> void:
	_register_editor_settings()
	_register_runtime_settings()
	_manage_autoload(true)
	# 懒加载面板脚本：即使某个子脚本加载失败，插件本体（设置/单例）仍能工作
	var dock := _build_dock()
	if dock != null:
		add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_BL, dock)
	_task_dock = _build_panel(TASK_DOCK_SCRIPT_PATH, "AI 任务")
	if _task_dock != null:
		add_control_to_bottom_panel(_task_dock, "AI 任务")
	_vcs_dock = _build_panel(VCS_DOCK_SCRIPT_PATH, "版本控制")
	if _vcs_dock != null:
		add_control_to_bottom_panel(_vcs_dock, "版本控制")
	# 菜单入口：即使面板被关闭/隐藏，也能从这里重新打开
	add_tool_menu_item("打开 AI 助手面板", Callable(self, "_reopen_dock"))
	add_tool_menu_item("AI 助手设置…", Callable(self, "_open_dock_settings"))
	add_tool_menu_item("AI 为当前节点创建脚本提案", Callable(self, "_open_node_task"))


func _exit_tree() -> void:
	if has_method("remove_tool_menu_item"):
		remove_tool_menu_item("打开 AI 助手面板")
		remove_tool_menu_item("AI 助手设置…")
		remove_tool_menu_item("AI 为当前节点创建脚本提案")
	if _task_dock != null:
		remove_control_from_bottom_panel(_task_dock)
		_task_dock.queue_free()
		_task_dock = null
	if _vcs_dock != null:
		remove_control_from_bottom_panel(_vcs_dock)
		_vcs_dock.queue_free()
		_vcs_dock = null
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null
	_manage_autoload(false)


## 安全地创建面板实例；子脚本解析失败时返回 null 并给出明确提示
func _build_dock() -> Control:
	if _dock != null and is_instance_valid(_dock):
		return _dock
	var script: Script = load(DOCK_SCRIPT_PATH)
	if script == null:
		push_error("AI 助手：无法加载面板脚本（%s）。请确认使用的 Godot 版本 ≥ 4.0。" % DOCK_SCRIPT_PATH)
		return null
	_dock = script.new()
	if _dock == null:
		push_error("AI 助手：面板脚本实例化失败（%s）。" % DOCK_SCRIPT_PATH)
		return null
	_dock.name = "AI 助手"
	return _dock


func _build_panel(path: String, panel_name: String) -> Control:
	var script: Script = load(path)
	if script == null:
		push_error("AI 助手：无法加载 %s（%s）。" % [panel_name, path])
		return null
	var panel := script.new()
	if panel == null:
		push_error("AI 助手：无法创建 %s。" % panel_name)
		return null
	panel.name = panel_name
	return panel


## 从「项目」菜单重新打开聊天面板（面板被关闭时也有效）
func _reopen_dock() -> void:
	var dock := _build_dock()
	if dock == null:
		return
	if dock.is_inside_tree():
		remove_control_from_docks(dock)
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_BL, dock)
	dock.show()


## 从「项目」菜单直接弹出设置窗口
func _open_dock_settings() -> void:
	_reopen_dock()
	if _dock != null and _dock.has_method("open_settings_dialog"):
		_dock.open_settings_dialog()


func _open_node_task() -> void:
	if _task_dock != null and _task_dock.has_method("open_node_script_task"):
		_task_dock.open_node_script_task(null)


func get_plugin_name() -> String:
	return "AI Assistant"


func get_plugin_icon() -> Texture2D:
	# 运行时 load + 判空，避免首次打开（尚未导入 svg）时 preload 失败导致整个插件被禁用
	var icon := load(PLUGIN_ICON_PATH)
	return icon if icon is Texture2D else null


## ---------- 设置管理 ----------

## 编辑器设置句柄（Godot 4 中 EditorSettings 不是全局单例，需经 EditorInterface 获取）
func _editor_settings() -> EditorSettings:
	return EditorInterface.get_editor_settings()


## 把插件的编辑器设置写入 EditorSettings（持久化到编辑器配置，不含项目密钥风险）
func _register_editor_settings() -> void:
	var es := _editor_settings()
	for key in EDITOR_SETTINGS:
		if not es.has_setting(key):
			es.set_setting(key, EDITOR_SETTINGS[key])


## 把运行时 ProjectSettings 默认值写入项目配置（用户可覆盖）
func _register_runtime_settings() -> void:
	var changed := false
	for key in RUNTIME_SETTINGS:
		if not ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, RUNTIME_SETTINGS[key])
			changed = true
	if changed:
		ProjectSettings.save()
	# 安全检测：API Key 如果写在项目配置里，会随 project.godot 进入导出包/压缩包/仓库
	if not String(ProjectSettings.get_setting("ai_assistant/api_key", "")).is_empty():
		push_warning("AI 助手：检测到 API Key 写入了项目配置（project.godot / 导出包会包含它）！\n"
			+ "推荐：① 用编辑器面板「⚙ 设置」输入（默认仅内存，勾选「记住」才明文存入编辑器配置）；"
			+ "② 游戏运行时用环境变量 AI_API_KEY；③ 若已填，请清空并轮换该 Key。")


## ---------- Autoload 管理 ----------
## 启用时注册 AI 单例；停用时只移除「由本插件注册」的 Autoload，绝不碰用户自己的同名配置。
func _manage_autoload(enable: bool) -> void:
	var key := "autoload/" + AUTOLOAD_NAME
	var expected := "*" + AUTOLOAD_PATH
	var es := _editor_settings()
	if enable:
		if ProjectSettings.has_setting(key):
			return  # 用户项目里已有同名 Autoload，尊重用户配置
		ProjectSettings.set_setting(key, expected)
		ProjectSettings.save()
		es.set_setting("ai_assistant/managed_autoload", true)
	else:
		var managed := false
		if es.has_setting("ai_assistant/managed_autoload"):
			managed = bool(es.get_setting("ai_assistant/managed_autoload"))
		if not managed:
			return
		if ProjectSettings.has_setting(key) and String(ProjectSettings.get_setting(key)) == expected:
			# 与 Godot 编辑器删除 Autoload 的方式保持一致
			ProjectSettings.set_setting(key, "")
			ProjectSettings.save()
		es.set_setting("ai_assistant/managed_autoload", false)
