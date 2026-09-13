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

	_dump_steam_peer_api()

	# --- Rendering / feature flags -------------------------------------------
	print("[diag] renderer=", ProjectSettings.get_setting("rendering/renderer/rendering_method", "?"))
	quit()


## 打印 SteamMultiplayerPeer 的真实方法签名。
##
## SteamTransport 是按这些方法名写的，但它只在「扩展不可用」的环境里跑过单测，
## 签名对不对从来没被真实验证过。这里直接把 GDExtension 注册进来的方法表打出来，
## 用真实二进制当权威答案，而不是靠翻文档。
func _dump_steam_peer_api() -> void:
	const PEER := "SteamMultiplayerPeer"
	if not ClassDB.class_exists(PEER):
		print("[diag] ", PEER, " 不存在，跳过方法表")
		return
	print("[diag] --- ", PEER, " 方法表 ---")
	for method in ClassDB.class_get_method_list(PEER, true):
		var args: Array = []
		for argument in method.get("args", []):
			args.append("%s: %s" % [argument.get("name", "?"), argument.get("type", TYPE_NIL)])
		print("[diag]   %s(%s) -> %s" % [
			method.get("name", "?"),
			", ".join(args),
			method.get("return", {}).get("type", TYPE_NIL),
		])
	_dump_steam_relay_api()


## 打印 Steam 单例里和中继 / P2P 网络状态有关的方法。
##
## 为什么需要：Steam 的 P2P 连接依赖「中继网络就绪」，而 initRelayNetworkAccess()
## 是**异步**的 —— 调用返回不代表就绪。连得太早会一直超时，且看不出原因。
## 方法名和签名以真实二进制为准，不靠翻文档猜。
func _dump_steam_relay_api() -> void:
	if not Engine.has_singleton("Steam"):
		return
	var steam: Object = Engine.get_singleton("Steam")
	print("[diag] --- Steam 里与中继 / 网络状态有关的方法 ---")
	var keywords := ["relay", "network", "p2p", "socket", "connection"]
	for method in steam.get_method_list():
		var name := str(method.get("name", ""))
		var lowered := name.to_lower()
		var hit := false
		for keyword in keywords:
			if lowered.contains(keyword):
				hit = true
				break
		if not hit or lowered.contains("get_") and lowered.contains("persona"):
			continue
		var args: Array = []
		for argument in method.get("args", []):
			args.append(str(argument.get("name", "?")))
		print("[diag]   %s(%s)" % [name, ", ".join(args)])
