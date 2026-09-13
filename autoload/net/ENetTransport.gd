extends NetworkTransport
class_name ENetTransport
## ENet transport: host listens on a UDP port, clients connect by IP.
##
## This is the default backend. It needs no third-party dependency, which makes
## it the one that always works for local testing.

## How long a client waits for the handshake before giving up.
const CONNECT_TIMEOUT_SEC := 5.0

var _peer: ENetMultiplayerPeer = null
var _connect_timer: float = -1.0
## Set while host()/join() is in flight, so poll() knows what it is waiting for.
var _pending: int = State.STOPPED


func _init() -> void:
	backend_name = "ENet"


func host(max_clients: int, port: int) -> int:
	close()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, max_clients)
	if err != OK:
		last_error = "无法监听端口 %d（错误码 %d）。端口可能已被占用。" % [port, err]
		_set_state(State.FAILED)
		return err

	_peer = peer
	last_error = ""
	_install_peer(peer)
	_set_state(State.HOSTING)
	return OK


func join(address: String, port: int) -> int:
	close()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		last_error = "无法连接 %s:%d（错误码 %d）。" % [address, port, err]
		_set_state(State.FAILED)
		return err

	_peer = peer
	last_error = ""
	_install_peer(peer)
	_set_state(State.STARTING)
	_pending = State.CONNECTED
	_connect_timer = CONNECT_TIMEOUT_SEC
	return OK


func close() -> void:
	_connect_timer = -1.0
	_pending = State.STOPPED
	_peer = null
	_install_peer(null)
	_set_state(State.STOPPED)


func is_server() -> bool:
	return _peer != null and _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED \
		and get_unique_id() == get_server_id()


func get_server_id() -> int:
	return 1


func get_peer_ids() -> PackedInt32Array:
	var ids := PackedInt32Array()
	if _peer == null or _peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return ids
	ids.append(get_server_id())
	var api := _multiplayer()
	if api != null:
		ids.append_array(api.get_peers())
	return ids


func get_unique_id() -> int:
	if _peer == null:
		return 0
	return _peer.get_unique_id()


## ENet exposes no single "failed" event, so we poll the connection status and
## enforce a handshake timeout instead.
func poll() -> void:
	if _peer == null:
		return

	# Emit peer join/leave before the status switch so the authority's roster is
	# up to date in the same frame a peer becomes visible.
	_sync_peer_events()

	var status := _peer.get_connection_status()
	match status:
		MultiplayerPeer.CONNECTION_CONNECTING:
			if _connect_timer > 0.0:
				_connect_timer -= _poll_delta()
				if _connect_timer <= 0.0:
					last_error = "连接超时。请确认主机已开房、IP 正确、防火墙放行 UDP 端口。"
					close()
					_set_state(State.FAILED)
		MultiplayerPeer.CONNECTION_CONNECTED:
			_connect_timer = -1.0
			if _pending == State.CONNECTED:
				_pending = State.STOPPED
				_set_state(State.CONNECTED)
		MultiplayerPeer.CONNECTION_DISCONNECTED:
			# A disconnected peer while we were a client means the host went away.
			var was_client := _pending == State.CONNECTED or state == State.CONNECTED
			_connect_timer = -1.0
			_pending = State.STOPPED
			_peer = null
			_install_peer(null)
			_set_state(State.STOPPED)
			if was_client:
				closed.emit()


## Frame delta helper; poll() has no delta parameter because NetworkManager
## already ticks every frame and transports only need coarse timing.
func _poll_delta() -> float:
	return 1.0 / maxf(Engine.physics_ticks_per_second, 1.0)
