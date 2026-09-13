extends SceneTree
## 全项目无头编译/资源检查。
##
## 为什么需要它
##   tools/headless_verify.gd 只启动「主场景」。它没碰到的东西（自动加载、
##   没被引用的脚本、大厅 UI、网络层）坏掉了也不会被发现。而解析错误只会
##   由 Godot 打印到日志里，所以这个驱动把项目里每个脚本/场景都强制 load()
##   一遍，交给 tools/verify_net.bat 去审计日志中的 Parse Error / SCRIPT ERROR。
##
## 为什么要写文件
##   本沙箱里 Godot 的 stdout 有时会整段丢失（尤其进程崩溃时）。所以结果
##   既打印也**逐行 flush 落盘**，崩溃时还能看到最后一个正在检查的资源。
##
## 用法
##   godot --headless --path . --script res://tools/compile_check.gd
##   ... -- --out=D:/somewhere/report.txt

const SCAN_EXTENSIONS := [".gd", ".tscn", ".tres", ".gdshader"]
## Godot 3 时代的着色器扩展名。Godot 4 没有对应的 ResourceFormatLoader，
## 强行 load() 会以 "No loader found" 返回 null，所以只报告、不加载。
const LEGACY_EXTENSIONS := [".shader"]
## 不必扫描的目录（引擎缓存 / 版本库 / 生成数据）。
const SKIP_DIRS := [".godot", ".git", "_userdata"]

var _checked := 0
var _failed := 0
var _legacy: Array[String] = []
var _failures: Array[String] = []
var _log: FileAccess = null
var _pending := false


func _initialize() -> void:
	_log = _open_log()
	_report("[compile] Godot " + str(Engine.get_version_info()["string"]))
	_report("[compile] project=" + ProjectSettings.globalize_path("res://"))
	# 扫描推迟到第一帧 _process：_initialize() 发生在 autoload 注册之前，
	# 此时加载引用了 autoload 标识符的脚本（LevelServer、PlayerServer、Town…）
	# 会因为 "Identifier not found" 而误报失败。
	_pending = true


func _process(_delta: float) -> bool:
	if not _pending:
		return true
	_pending = false
	_scan("res://")
	_report("[compile] checked %d resource(s); failures=%d" % [_checked, _failed])
	for failure in _failures:
		_report("[compile] FAIL " + failure)
	for path in _legacy:
		_report("[compile] LEGACY (Godot 3 extension, not loadable in 4.x) " + path)
	if _log != null:
		_log.flush()
		_log.close()
	if _failed > 0:
		# 普通 print 不能终止进程，所以用日志审计识别的模式显式标记失败。
		print("SCRIPT ERROR: [compile] %d resource(s) failed to load" % _failed)
	quit(1 if _failed > 0 else 0)
	return true


func _open_log() -> FileAccess:
	var path := "user://compile_check.log"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			path = arg.trim_prefix("--out=")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("[compile] cannot open report file: " + path)
	return file


func _report(line: String) -> void:
	print(line)
	if _log != null:
		_log.store_line(line)
		_log.flush()


func _scan(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_error("[compile] cannot open directory: " + dir_path)
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry.begins_with(".") and entry != ".":
			entry = dir.get_next()
			continue
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			if not SKIP_DIRS.has(entry):
				_scan(full)
		else:
			_check(entry, full)
		entry = dir.get_next()
	dir.list_dir_end()


func _check(file_name: String, full_path: String) -> void:
	# .import / .uid 是元数据，不是可加载资源。
	if file_name.ends_with(".import") or file_name.ends_with(".uid"):
		return
	var matched := false
	for ext in SCAN_EXTENSIONS:
		if file_name.ends_with(ext):
			matched = true
			break
	if not matched:
		for ext in LEGACY_EXTENSIONS:
			if file_name.ends_with(ext):
				_note_legacy(full_path)
				return
		return

	_checked += 1
	# 先记录再加载：如果加载过程让引擎崩溃，日志里最后一行就是罪魁祸首。
	_report("[compile] loading " + full_path)
	var res: Resource = ResourceLoader.load(full_path)
	if res == null:
		_failed += 1
		_failures.append(full_path + " (load returned null)")
		return
	# 解析失败的脚本会以「无法实例化」的 GDScript 资源形式返回。
	if res is GDScript and not (res as GDScript).can_instantiate():
		_failed += 1
		_failures.append(full_path + " (GDScript cannot instantiate)")


## Godot 3 遗留扩展名：只登记，不 load（4.x 没有对应加载器）。
func _note_legacy(full_path: String) -> void:
	_legacy.append(full_path)
