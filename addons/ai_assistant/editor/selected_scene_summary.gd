@tool
class_name AISceneContext
extends RefCounted

static func from_node(node: Node) -> String:
	if node == null:
		return "未选择场景节点。"
	var lines := PackedStringArray([
		"节点类型: %s" % node.get_class(),
		"节点名: %s" % node.name,
		"节点路径: %s" % String(node.get_path()),
		"场景文件: %s" % (node.scene_file_path if not node.scene_file_path.is_empty() else "未保存场景"),
		"父节点: %s" % (node.get_parent().get_class() if node.get_parent() != null else "无"),
		"已有脚本: %s" % (node.get_script().resource_path if node.get_script() != null else "无"),
	])
	var children := PackedStringArray()
	for child in node.get_children():
		children.append("%s (%s)" % [child.name, child.get_class()])
	lines.append("直接子节点: " + (", ".join(children) if not children.is_empty() else "无"))
	var signals := PackedStringArray()
	for info in node.get_signal_list():
		var name := String(info.get("name", ""))
		if not name.is_empty() and not name.begins_with("tree_"):
			signals.append(name)
	lines.append("信号: " + (", ".join(signals) if not signals.is_empty() else "无"))
	return "\n".join(lines)
