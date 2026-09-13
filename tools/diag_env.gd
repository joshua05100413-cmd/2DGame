extends SceneTree
## Diagnostic: report what the engine sees at startup.
## Used to verify the GodotSteam GDExtension loads and the multiplayer
## transport prerequisites (ENet) are available.
##
##   godot --headless --path . --script res://tools/diag_env.gd

func _initialize() -> void:
	print("[diag] Godot ", Engine.get_version_info()["string"])
	print("[diag] display=", DisplayServer.get_name())

	# --- GodotSteam extension ------------------------------------------------
	print("[diag] has 'Steam' singleton in ClassDB: ", ClassDB.class_exists("Steam"))
	var has_engine_singleton := Engine.has_singleton("Steam")
	print("[diag] Engine.has_singleton('Steam'): ", has_engine_singleton)
	if has_engine_singleton:
		var steam := Engine.get_singleton("Steam")
		print("[diag] Steam object=", steam)
		# Only touch its API if the extension really registered.
		var version_info: Dictionary = steam.getSteamVersion() if steam.has_method("getSteamVersion") else {}
		print("[diag] Steam version=", version_info)

	print("[diag] ENetMultiplayerPeer available: ", ClassDB.class_exists("ENetMultiplayerPeer"))
	print("[diag] MultiplayerAPI available: ", ClassDB.class_exists("MultiplayerAPI"))
	print("[diag] MultiplayerSpawner available: ", ClassDB.class_exists("MultiplayerSpawner"))
	print("[diag] MultiplayerSynchronizer available: ", ClassDB.class_exists("MultiplayerSynchronizer"))
	print("[diag] WebSocketPeer available: ", ClassDB.class_exists("WebSocketPeer"))

	# --- Rendering / feature flags -------------------------------------------
	print("[diag] renderer=", ProjectSettings.get_setting("rendering/renderer/rendering_method", "?"))
	quit()
