extends RefCounted
class_name TransportFactory
## Creates network transports and reports which ones are usable.
##
## Backends are resolved by name so the lobby UI can list them and so a build
## without the Steam extension still runs (it simply offers ENet only).

enum Backend {
	ENET,  ## Built-in; always available.
	STEAM, ## Requires a Godot 4.4-compatible GodotSteam GDExtension.
}


## Create a transport instance for [param backend].
## Returns null when the backend's dependency is missing; call
## [method unavailable_reason] for a user-facing explanation.
static func create(backend: int) -> NetworkTransport:
	match backend:
		Backend.ENET:
			return ENetTransport.new()
		Backend.STEAM:
			if not SteamTransport.is_available():
				return null
			return SteamTransport.new()
	push_error("TransportFactory: unknown backend %d" % backend)
	return null


## True when [param backend] can actually be used in this build/runtime.
static func is_available(backend: int) -> bool:
	match backend:
		Backend.ENET:
			return true
		Backend.STEAM:
			return SteamTransport.is_available()
	return false


## User-facing explanation of why [param backend] is unavailable, or "" if it is.
static func unavailable_reason(backend: int) -> String:
	match backend:
		Backend.ENET:
			return ""
		Backend.STEAM:
			return SteamTransport.probe_reason()
	return "未知的后端。"


## Backend display name for UI.
static func backend_name(backend: int) -> String:
	match backend:
		Backend.ENET:
			return "ENet（IP 直连）"
		Backend.STEAM:
			return "Steam P2P"
	return "未知"


## Every backend, in the order the lobby should list them.
static func all_backends() -> Array:
	return [Backend.ENET, Backend.STEAM]
