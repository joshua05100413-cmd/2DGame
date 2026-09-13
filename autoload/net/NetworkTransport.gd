extends RefCounted
class_name NetworkTransport
## Pluggable network transport interface.
##
## The game logic never talks to ENet or Steam directly: it goes through
## NetworkManager, which drives one of these. That keeps the Steam backend a
## drop-in replacement instead of a rewrite.
##
## Contract for implementors:
##   * host() / join() / close() configure the underlying MultiplayerPeer and
##     install it on the scene tree via [method _install_peer].
##   * ready_changed / peer_joined / peer_left / closed are emitted so
##     NetworkManager can keep its own peer bookkeeping.
##   * report starting/stopping through [method _set_state] so callers can show
##     progress and errors without knowing the backend.

enum State {
	STOPPED,   ## No peer installed; single-player / menu.
	STARTING,  ## host() or join() is in flight.
	HOSTING,   ## Acting as the authority.
	CONNECTED, ## Connected to a host as a client.
	FAILED,    ## Last attempt failed; see [member last_error].
}

## Emitted whenever [member state] changes.
signal state_changed(new_state: int)
## Emitted once the peer is installed and usable.
signal ready_changed(is_ready: bool)
## Emitted on the authority when a peer finishes connecting.
signal peer_joined(peer_id: int)
## Emitted on the authority when a peer disconnects.
signal peer_left(peer_id: int)
## Emitted on clients when the connection to the host is gone.
signal closed()

## Human-readable backend name, used by the lobby UI.
var backend_name: String = "unknown"
## True once the underlying peer is installed and usable.
var is_ready: bool = false
var state: int = State.STOPPED
## Last error message, for surfacing in the UI. Empty when nothing failed.
var last_error: String = ""
## Optional MultiplayerAPI override.
##
## Godot allows several independent MultiplayerAPI instances inside one process
## (see SceneTree.set_multiplayer). Tests use that to run a host and a client in
## the same headless process; normal gameplay leaves this null and the tree's
## default API is used.
var _api: MultiplayerAPI = null
## Peer ids observed during the previous poll, used to emit join/leave events.
var _known_peers: Dictionary = {}


## Start listening for clients. Returns [constant OK] or an error code.
func host(_max_clients: int, _port: int) -> int:
	push_error("NetworkTransport.host() is not implemented by " + backend_name)
	return ERR_UNCONFIGURED


## Connect to a host. Returns [constant OK] or an error code.
func join(_address: String, _port: int) -> int:
	push_error("NetworkTransport.join() is not implemented by " + backend_name)
	return ERR_UNCONFIGURED


## Tear the connection down and return to single-player.
func close() -> void:
	push_error("NetworkTransport.close() is not implemented by " + backend_name)


## True when this peer is the authority for the session.
func is_server() -> bool:
	return false


## Id of the authority peer (always 1 for ENet).
func get_server_id() -> int:
	return 1


## Ids of every connected peer, authority included. Empty when not ready.
func get_peer_ids() -> PackedInt32Array:
	var ids := PackedInt32Array()
	var api := _multiplayer()
	if api == null or api.multiplayer_peer == null:
		return ids
	ids.append(get_server_id())
	ids.append_array(api.get_peers())
	return ids


## The local peer id, or 0 when not connected.
func get_unique_id() -> int:
	var api := _multiplayer()
	if api == null or api.multiplayer_peer == null:
		return 0
	return api.get_unique_id()


## Poll for incoming events. Called by NetworkManager each frame.
func poll() -> void:
	pass


# --- helpers for implementors -------------------------------------------------

## Route this transport through a specific MultiplayerAPI instead of the tree's
## default one. Used by the headless tests to run host and client side by side.
func set_multiplayer_api(api: MultiplayerAPI) -> void:
	_api = api


## The MultiplayerAPI this transport drives: the injected one when set,
## otherwise the scene tree's default API. Null before the tree exists.
func _multiplayer() -> MultiplayerAPI:
	if _api != null:
		return _api
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	# NOTE: SceneTree itself has no `multiplayer` property (only Node does),
	# so read it from the tree root. Using `tree.multiplayer` here silently
	# produced "Invalid access to property 'multiplayer'" on every host()/join().
	return tree.root.multiplayer


## Install (or clear) the peer on the target API and update ready state.
func _install_peer(peer: MultiplayerPeer) -> void:
	var api := _multiplayer()
	if api == null:
		push_error("NetworkTransport: no MultiplayerAPI, cannot install peer")
		return
	api.multiplayer_peer = peer
	is_ready = peer != null
	_known_peers.clear()
	ready_changed.emit(is_ready)


## Diff the connected peer set against the previous frame and emit
## [signal peer_joined] / [signal peer_left] accordingly.
##
## WHY THIS EXISTS
##   MultiplayerAPI exposes peer_connected/peer_disconnected signals, but only
##   for the *local* peer set and with slightly different semantics per backend.
##   Diffing get_peers() works identically for ENet and Steam and keeps this
##   logic in one place, so subclasses only need to call it from poll().
func _sync_peer_events() -> void:
	var api := _multiplayer()
	if api == null or api.multiplayer_peer == null:
		_known_peers.clear()
		return

	var current := {}
	for peer_id in api.get_peers():
		current[peer_id] = true

	for peer_id in current:
		if not _known_peers.has(peer_id):
			peer_joined.emit(peer_id)
	for peer_id in _known_peers:
		if not current.has(peer_id):
			peer_left.emit(peer_id)
	_known_peers = current


## Record the current state and notify listeners.
func _set_state(new_state: int) -> void:
	if state == new_state:
		return
	state = new_state
	state_changed.emit(state)
