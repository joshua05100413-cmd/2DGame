extends SceneTree
## Headless smoke-test driver for this project.
##
## WHY THIS EXISTS
##   Godot needs a writable user:// directory (shader cache, logs, config). Under
##   the DSH file sandbox the default location
##   (%APPDATA%\Godot\app_userdata\<project>) is NOT writable and Godot dies with
##   "signal 11" right after:
##       ERROR: Could not create directory: 'user://logs'
##   tools/verify.ps1 works around that by pointing APPDATA inside the workspace,
##   and points --log-file at a path it can then parse for errors.
##
## WHAT IT DOES
##   Boots the real main scene, drives it for N physics frames, then quits.
##   This file is the *driver* only: error auditing happens in tools/verify.ps1,
##   which reads the generated log (GDScript cannot intercept push_error()).
##
## USAGE
##   godot --headless --path . --script res://tools/headless_verify.gd -- --frames=300

const DEFAULT_FRAMES := 300

var _frames_target := DEFAULT_FRAMES
var _frames_done := 0
var _scene_ok := false


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_frames_target = _read_frame_arg(args)
	print("[verify] Godot ", Engine.get_version_info()["string"],
		" | display=", DisplayServer.get_name(),
		" | frames=", _frames_target)
	print("[verify] project=", ProjectSettings.globalize_path("res://"))
	print("[verify] user_dir=", OS.get_user_data_dir())
	_load_main_scene()

	# Deliberate self-test: proves tools/verify.ps1 really fails on errors
	# instead of reporting a false PASS. Emitted as a plain print (not
	# push_error, which aborts _initialize and can kill the run before the log
	# is flushed) but formatted so the harness error pattern matches it.
	if args.has("--fail-test"):
		print("SCRIPT ERROR: [verify] intentional failure (--fail-test)")


func _read_frame_arg(args: PackedStringArray) -> int:
	for arg in args:
		if arg.begins_with("--frames="):
			return int(arg.trim_prefix("--frames="))
	return DEFAULT_FRAMES


# SceneTree calls this every frame; return true to quit.
func _process(_delta: float) -> bool:
	_frames_done += 1
	if _frames_done >= _frames_target:
		print("[verify] ran ", _frames_done, " frames; scene_ok=", _scene_ok)
		return true
	return false


func _load_main_scene() -> void:
	var main_scene: String = ProjectSettings.get_setting("application/run/main_scene", "")
	if main_scene.is_empty():
		push_error("[verify] no main scene configured")
		return
	var packed := load(main_scene) as PackedScene
	if packed == null:
		push_error("[verify] failed to load main scene: " + main_scene)
		return
	var instance := packed.instantiate()
	if instance == null:
		push_error("[verify] failed to instantiate main scene: " + main_scene)
		return
	root.add_child(instance)
	_scene_ok = true
	print("[verify] main scene loaded: ", main_scene)
