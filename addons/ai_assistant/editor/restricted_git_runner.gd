@tool
class_name AIGitBridge
extends Node
## Executes only a short allowlist of fixed git subcommands for this project.

signal completed(result: Dictionary)

var _thread: Thread
var _busy := false
var _project_root := ""


func is_busy() -> bool:
	return _busy


func run(args: PackedStringArray) -> void:
	if _busy:
		return
	_busy = true
	_project_root = ProjectSettings.globalize_path("res://")
	_thread = Thread.new()
	var err := _thread.start(_execute.bind(args))
	if err != OK:
		_busy = false
		completed.emit({"ok": false, "code": err, "output": "无法启动 Git 任务：%s" % error_string(err)})


func _execute(args: PackedStringArray) -> void:
	var output: Array = []
	var safe_args := PackedStringArray(["-C", _project_root])
	safe_args.append_array(args)
	var code := OS.execute("git", safe_args, output, true)
	call_deferred("_finish", code, "\n".join(PackedStringArray(output)))


func _finish(code: int, output: String) -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	_busy = false
	completed.emit({"ok": code == 0, "code": code, "output": output})
