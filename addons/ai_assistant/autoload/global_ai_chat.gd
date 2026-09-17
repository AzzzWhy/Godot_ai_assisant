extends "res://addons/ai_assistant/client/openai_compatible_chat_client.gd"
## 全局 AI 单例（Autoload 名称：AI）。
##
## 插件启用时自动注册；也可手动在「项目设置 -> 全局」Autoload 中注册本文件。
## 用法示例（任意场景的 GDScript）：
##   AI.system_prompt = "你是游戏 NPC…"
##   AI.chat("你好")                     # 触发流式信号
##   AI.stream_chunk.connect(...)        # 增量文本
##   AI.request_finished.connect(...)    # 单次请求结束
##   var r := await AI.request_finished  # 或直接 await 拿到 [success, message]
##
## 配置优先级：环境变量 > ProjectSettings(ai_assistant/*) > 代码默认值。
## 环境变量：AI_API_KEY / AI_BASE_URL / AI_MODEL

func _ready() -> void:
	sync_settings()


## 从 ProjectSettings / 环境变量刷新配置（可在运行时再次调用以热更新）
func sync_settings() -> void:
	base_url = _env_or("AI_BASE_URL", ProjectSettings.get_setting("ai_assistant/base_url", base_url)).strip_edges()
	api_key = _env_or("AI_API_KEY", ProjectSettings.get_setting("ai_assistant/api_key", "")).strip_edges()
	model = _env_or("AI_MODEL", ProjectSettings.get_setting("ai_assistant/model", model)).strip_edges()
	temperature = float(ProjectSettings.get_setting("ai_assistant/temperature", temperature))
	max_tokens = int(ProjectSettings.get_setting("ai_assistant/max_tokens", max_tokens))
	timeout_seconds = float(ProjectSettings.get_setting("ai_assistant/timeout", timeout_seconds))
	stream = bool(ProjectSettings.get_setting("ai_assistant/stream", stream))
	var sp: String = ProjectSettings.get_setting("ai_assistant/system_prompt", "")
	if not sp.is_empty():
		system_prompt = sp


func _env_or(name: String, fallback: Variant) -> String:
	var v := OS.get_environment(name)
	if not v.is_empty():
		return v
	return str(fallback)