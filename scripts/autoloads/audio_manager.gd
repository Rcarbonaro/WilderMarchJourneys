extends Node

const SFX_POOL_SIZE := 8
const MENU_MUSIC: AudioStream = preload("res://assets/audio/music/main_theme.mp3")

var _sfx_players: Array[AudioStreamPlayer] = []
var _next_sfx_index: int = 0
var _music_player: AudioStreamPlayer = null

var _playlist: Array = []
var _playlist_shuffle: bool = false
var _playlist_index: int = -1   # -1 = single-track mode, not a playlist

func _ready() -> void:
	var sfx_bus: String = "SFX" if AudioServer.get_bus_index("SFX") != -1 else "Master"   # ADDED
	for i in range(SFX_POOL_SIZE):
		var p := AudioStreamPlayer.new()
		p.bus = sfx_bus   # ADDED
		add_child(p)
		_sfx_players.append(p)
	_music_player = AudioStreamPlayer.new()
	_music_player.bus = "Music" if AudioServer.get_bus_index("Music") != -1 else "Master"
	print("🐛 music player bus: ", _music_player.bus)   # ADDED temporarily
	add_child(_music_player)
	_music_player.finished.connect(_on_music_finished)

func play_sfx(stream: AudioStream, volume_db: float = 0.0) -> void:
	if stream == null:
		return
	var player := _sfx_players[_next_sfx_index]
	_next_sfx_index = (_next_sfx_index + 1) % _sfx_players.size()
	player.stream = stream
	player.volume_db = volume_db
	player.play()


func play_music(stream: AudioStream, fade_seconds: float = 0.6) -> void:
	# Single-track mode (loops itself via _on_music_finished if its import
	# setting doesn't already have Loop enabled).
	if stream == null:
		return
	_playlist = []          # ADDED — leaving playlist mode
	_playlist_index = -1    # ADDED
	if _music_player.stream == stream and _music_player.playing:
		return   # Already playing this exact track — don't restart/refade.
	_crossfade_to(stream, fade_seconds)


func play_music_playlist(tracks: Array, shuffle: bool = true, fade_seconds: float = 0.6) -> void:
	# Cycles through 'tracks' one at a time, advancing whenever the current
	# one finishes, looping back to the start once every track has played.
	# If 'shuffle' is true, the order is randomized each time the whole list
	# wraps around (not just once at the start), so it doesn't repeat the
	# same sequence every cycle.
	if tracks.is_empty():
		return
	if _playlist == tracks and _music_player.playing:
		return   # This exact playlist is already running — don't restart it.

	_playlist = tracks.duplicate()
	_playlist_shuffle = shuffle
	if shuffle:
		_playlist.shuffle()
	_playlist_index = 0
	_crossfade_to(_playlist[_playlist_index], fade_seconds)


func _on_music_finished() -> void:
	if _playlist_index >= 0 and not _playlist.is_empty():
		# Playlist mode — advance to the next track.
		_playlist_index += 1
		if _playlist_index >= _playlist.size():
			_playlist_index = 0
			if _playlist_shuffle:
				_playlist.shuffle()
		_crossfade_to(_playlist[_playlist_index], 1.0)
	else:
		# Single-track mode fallback loop — only matters if the stream's own
		# import settings don't already have Loop checked.
		if is_instance_valid(_music_player) and _music_player.stream != null:
			_music_player.play()


const FADE_OUT_DURATION := 3.0   # how long the old track takes to go silent
const FADE_IN_DURATION  := 3.0   # how long the new track takes to reach full volume

func _crossfade_to(stream: AudioStream, _fade_seconds: float = 0.0) -> void:
	# _fade_seconds is intentionally ignored now -- FADE_OUT_DURATION and
	# FADE_IN_DURATION above are the single source of truth for timing, so
	# every caller (play_music, play_music_playlist, play_next_in_playlist,
	# _on_music_finished) behaves identically without needing to pass a
	# number through each one.
	var tween := create_tween()

	if _music_player.playing:
		tween.tween_property(_music_player, "volume_db", -40.0, FADE_OUT_DURATION)\
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
		tween.tween_callback(func():
			_music_player.stop()
			_music_player.stream = stream
			_music_player.volume_db = -40.0
			_music_player.play()
		)
	else:
		tween.tween_callback(func():
			_music_player.stream = stream
			_music_player.volume_db = -40.0
			_music_player.play()
		)

	tween.tween_property(_music_player, "volume_db", 0.0, FADE_IN_DURATION)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)

func stop_music(fade_seconds: float = 0.6) -> void:
	_playlist = []
	_playlist_index = -1
	if not _music_player.playing:
		return
	var tween := create_tween()
	tween.tween_property(_music_player, "volume_db", -40.0, fade_seconds)
	tween.tween_callback(func(): _music_player.stop())


func play_menu_music() -> void:
	play_music(MENU_MUSIC)

func play_next_in_playlist(tracks: Array, fade_seconds: float = 0.6) -> void:
	# Like play_music_playlist(), but instead of always starting over at
	# track 0, it ADVANCES to the next track in the list — wrapping back to
	# the start after the last one. Meant for "the forest ambient rotation
	# across separate battles": each new battle_scene calling this with the
	# SAME track list picks up one track further than last time, instead of
	# restarting or reshuffling, so the player doesn't hear the same track
	# over and over.
	if tracks.is_empty():
		return

	if _playlist != tracks:
		# First time seeing this exact list (or a different one) — start at
		# the first track, no advancing needed yet.
		_playlist = tracks.duplicate()
		_playlist_shuffle = false
		_playlist_index = 0
	else:
		# Same list as last time this was called — move forward one, and
		# wrap back to the beginning after the last track.
		_playlist_index = (_playlist_index + 1) % _playlist.size()

	_crossfade_to(_playlist[_playlist_index], fade_seconds)

# ── UI SFX (button hover/press) ───────────────────────────────────────────────
const UI_HOVER_SFX: AudioStream = preload("res://assets/audio/sfx/ui_hover.wav")
const UI_PRESS_SFX: AudioStream = preload("res://assets/audio/sfx/ui_click.wav")
# Swap these two paths to whatever your actual hover/press SFX files are.

func play_ui_hover() -> void:
	play_sfx(UI_HOVER_SFX)


func play_ui_press() -> void:
	play_sfx(UI_PRESS_SFX)


func wire_button_sfx(button: BaseButton) -> void:
	# Connects a SINGLE button's hover/press to the shared UI SFX. Safe to
	# call more than once on the same button -- the is_connected() checks
	# prevent duplicate connections (which would otherwise double up the
	# sound every time this runs again).
	if button == null:
		return
	if not button.mouse_entered.is_connected(play_ui_hover):
		button.mouse_entered.connect(play_ui_hover)
	if not button.pressed.is_connected(play_ui_press):
		button.pressed.connect(play_ui_press)


func wire_all_buttons_in(root: Node) -> void:
	# Recursively finds EVERY Button (and button-like control -- CheckButton,
	# etc., since they all extend BaseButton) under 'root' and wires it.
	# Call this once per scene, after its buttons already exist (e.g. at the
	# END of that scene's _ready()) -- new buttons added later in the same
	# scene (a dynamically built ability bar, a popup, etc.) need their own
	# wire_button_sfx() call, or you can re-run wire_all_buttons_in() again
	# after building them, since re-wiring an already-wired button is a safe
	# no-op.
	if root is BaseButton:
		wire_button_sfx(root)
	for child in root.get_children():
		wire_all_buttons_in(child)
