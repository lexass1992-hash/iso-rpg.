extends Node2D
# Этап 2: монстры и бой.
# Тап по земле: идти. Тап по монстру: подойти и бить. Удержание: идти за пальцем.

const TW := 128.0
const TH := 64.0
const W := 48
const H := 48
const SPEED := 5.5
const HERO_RANGE := 1.5
const HERO_CD := 0.6
const HERO_MAX_HP := 100.0
const MON_COUNT := 28

var astar := AStarGrid2D.new()
var trees: Array[Vector2i] = []
var solid := {}
var hero_g := Vector2(24.0, 24.0)
var hero_hp := HERO_MAX_HP
var hero_cd := 0.0
var hero_slash := 0.0
var hero_dead_t := 0.0
var path: Array[Vector2i] = []
var monsters: Array = []
var attack_target = null
var holding_ground := false
var chase_t := 0.0
var floaters: Array = []

var ground := Node2D.new()
var objects := Node2D.new()
var cam := Camera2D.new()
var hud := Control.new()
var fps_label := Label.new()
var marker_g := Vector2(-1, -1)
var marker_t := 0.0
var rng := RandomNumberGenerator.new()    # карта (фиксированный seed)
var grng := RandomNumberGenerator.new()   # геймплей


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.05, 0.07, 0.04))
	rng.seed = 12345
	grng.randomize()
	_build_world()
	for i in MON_COUNT:
		monsters.append(_make_monster())
	add_child(ground)
	add_child(objects)
	ground.draw.connect(_draw_ground)
	objects.draw.connect(_draw_objects)
	add_child(cam)
	cam.position = to_screen(hero_g)
	cam.position_smoothing_enabled = true
	cam.position_smoothing_speed = 8.0
	var layer := CanvasLayer.new()
	add_child(layer)
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.draw.connect(_draw_hud)
	layer.add_child(hud)
	fps_label.position = Vector2(20, 12)
	layer.add_child(fps_label)
	ground.queue_redraw()


func _build_world() -> void:
	astar.region = Rect2i(0, 0, W, H)
	astar.cell_size = Vector2(1, 1)
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.update()
	var center := Vector2(W / 2, H / 2)
	for i in W:
		for j in H:
			var edge := i == 0 or j == 0 or i == W - 1 or j == H - 1
			var near := Vector2(i, j).distance_to(center) < 4.0
			if edge or (not near and rng.randf() < 0.1):
				var cell := Vector2i(i, j)
				solid[cell] = true
				astar.set_point_solid(cell, true)
				trees.append(cell)


func to_screen(g: Vector2) -> Vector2:
	return Vector2((g.x - g.y) * TW / 2.0, (g.x + g.y) * TH / 2.0)


func to_grid(p: Vector2) -> Vector2:
	var a := p.x / (TW / 2.0)
	var b := p.y / (TH / 2.0)
	return Vector2((a + b) / 2.0, (b - a) / 2.0)


func _cell_of(g: Vector2) -> Vector2i:
	return Vector2i(roundi(g.x), roundi(g.y))


func _path_to(cell: Vector2i) -> bool:
	if cell.x < 0 or cell.y < 0 or cell.x >= W or cell.y >= H or solid.has(cell):
		return false
	var p := astar.get_id_path(_cell_of(hero_g), cell)
	if p.is_empty():
		return false
	path.assign(p)
	if path.size() > 1:
		path.remove_at(0)
	return true


func set_target(world: Vector2) -> void:
	var cell := _cell_of(to_grid(world))
	if _path_to(cell):
		marker_g = Vector2(cell)
		marker_t = 1.0


# ---------- Монстры ----------

func _make_monster() -> Dictionary:
	var cell := Vector2i(W / 2 + 12, H / 2)
	for k in 60:
		var c := Vector2i(grng.randi_range(2, W - 3), grng.randi_range(2, H - 3))
		if not solid.has(c) and Vector2(c).distance_to(hero_g) > 10.0:
			cell = c
			break
	var kind := grng.randi() % 3
	var hp: float = [30.0, 60.0, 20.0][kind]
	return {
		"g": Vector2(cell), "kind": kind, "hp": hp, "maxhp": hp,
		"speed": [3.0, 1.8, 4.0][kind], "dmg": [5.0, 8.0, 3.0][kind],
		"cd": 0.0, "path": [] as Array[Vector2i], "repath": 0.0,
		"hit": 0.0, "alive": true, "dead_t": 0.0,
	}


func _update_monster(m: Dictionary, delta: float) -> void:
	if not m.alive:
		m.dead_t -= delta
		if m.dead_t <= 0.0:
			m.merge(_make_monster(), true)
		return
	m.cd = maxf(0.0, m.cd - delta)
	m.hit = maxf(0.0, m.hit - delta)
	if hero_dead_t > 0.0:
		return
	var dist: float = m.g.distance_to(hero_g)
	if dist <= 1.2:
		m.path.clear()
		if m.cd <= 0.0:
			m.cd = 1.0
			_hurt_hero(grng.randf_range(m.dmg * 0.7, m.dmg * 1.3))
	elif dist < 8.0:
		m.repath -= delta
		if m.repath <= 0.0:
			m.repath = 0.4 + grng.randf() * 0.2
			var p := astar.get_id_path(_cell_of(m.g), _cell_of(hero_g))
			m.path = p
			if m.path.size() > 1:
				m.path.remove_at(0)
		if not m.path.is_empty():
			var tgt := Vector2(m.path[0])
			var d: Vector2 = tgt - m.g
			var step: float = m.speed * delta
			if d.length() <= step:
				m.g = tgt
				m.path.remove_at(0)
			else:
				m.g += d.normalized() * step


func _hurt_hero(dmg: float) -> void:
	hero_hp -= dmg
	_float_text(hero_g, str(int(roundf(dmg))), Color(1.0, 0.3, 0.3))
	if hero_hp <= 0.0:
		hero_hp = 0.0
		hero_dead_t = 3.0
		path.clear()
		attack_target = null
		holding_ground = false


func _hero_attack(m: Dictionary) -> void:
	hero_cd = HERO_CD
	hero_slash = 0.15
	var dmg := roundf(grng.randf_range(8.0, 14.0))
	m.hp -= dmg
	m.hit = 0.12
	_float_text(m.g, str(int(dmg)), Color(1.0, 0.9, 0.3))
	if m.hp <= 0.0:
		m.alive = false
		m.dead_t = 15.0
		attack_target = null


func _float_text(g: Vector2, text: String, col: Color) -> void:
	floaters.append({"p": to_screen(g) + Vector2(0, -80), "text": text, "t": 0.9, "col": col})


func _monster_at(world: Vector2):
	var best = null
	var best_d := 44.0
	for m in monsters:
		if not m.alive:
			continue
		var d: float = (to_screen(m.g) + Vector2(0, -32)).distance_to(world)
		if d < best_d:
			best_d = d
			best = m
	return best


# ---------- Ввод ----------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var m = _monster_at(make_canvas_position_local(event.position))
			if m != null:
				attack_target = m
				holding_ground = false
			else:
				attack_target = null
				holding_ground = true
		else:
			holding_ground = false


# ---------- Цикл ----------

func _process(delta: float) -> void:
	hero_cd = maxf(0.0, hero_cd - delta)
	hero_slash = maxf(0.0, hero_slash - delta)

	if hero_dead_t > 0.0:
		hero_dead_t -= delta
		if hero_dead_t <= 0.0:
			hero_hp = HERO_MAX_HP
			hero_g = Vector2(24.0, 24.0)
			path.clear()
	else:
		if holding_ground:
			set_target(get_global_mouse_position())
		elif attack_target != null and attack_target.alive:
			var dist: float = hero_g.distance_to(attack_target.g)
			if dist <= HERO_RANGE:
				path.clear()
				if hero_cd <= 0.0:
					_hero_attack(attack_target)
			else:
				chase_t -= delta
				if chase_t <= 0.0:
					chase_t = 0.2
					_path_to(_cell_of(attack_target.g))

		if not path.is_empty():
			var tgt := Vector2(path[0])
			var d := tgt - hero_g
			var step := SPEED * delta
			if d.length() <= step:
				hero_g = tgt
				path.remove_at(0)
			else:
				hero_g += d.normalized() * step

	for m in monsters:
		_update_monster(m, delta)

	for f in floaters:
		f.t -= delta
		f.p += Vector2(0, -50) * delta
	floaters = floaters.filter(func(f): return f.t > 0.0)

	cam.position = to_screen(hero_g)
	marker_t = maxf(0.0, marker_t - delta * 1.5)
	fps_label.text = "FPS: %d" % Engine.get_frames_per_second()
	objects.queue_redraw()
	hud.queue_redraw()


# ---------- Отрисовка ----------

func _draw_ground() -> void:
	for i in W:
		for j in H:
			var c := to_screen(Vector2(i, j))
			var shade := 0.0 if (i + j) % 2 == 0 else 0.04
			var col := Color(0.30 + shade, 0.38 + shade, 0.22 + shade)
			ground.draw_colored_polygon(_diamond(c), col)


func _diamond(c: Vector2) -> PackedVector2Array:
	return PackedVector2Array([
		c + Vector2(0, -TH / 2.0), c + Vector2(TW / 2.0, 0),
		c + Vector2(0, TH / 2.0), c + Vector2(-TW / 2.0, 0)])


func _ellipse(c: Vector2, rx: float, ry: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for k in 20:
		var a := TAU * k / 20.0
		pts.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	return pts


func _draw_objects() -> void:
	if marker_t > 0.0:
		var pts := _diamond(to_screen(marker_g))
		pts.append(pts[0])
		objects.draw_polyline(pts, Color(1, 0.9, 0.3, marker_t), 3.0)

	if attack_target != null and attack_target.alive:
		var ring := _ellipse(to_screen(attack_target.g), 34, 14)
		ring.append(ring[0])
		objects.draw_polyline(ring, Color(0.95, 0.15, 0.15), 3.0)

	var hc := _cell_of(hero_g)
	var items: Array = []
	for t in trees:
		if absi(t.x - hc.x) <= 14 and absi(t.y - hc.y) <= 14:
			var rock := (t.x * 7 + t.y * 13) % 5 == 0
			items.append([t.x + t.y, to_screen(Vector2(t)), 2 if rock else 0, null])
	for m in monsters:
		if m.alive and absi(roundi(m.g.x) - hc.x) <= 14 and absi(roundi(m.g.y) - hc.y) <= 14:
			items.append([m.g.x + m.g.y, to_screen(m.g), 3, m])
	if hero_dead_t <= 0.0:
		items.append([hero_g.x + hero_g.y, to_screen(hero_g), 1, null])
	items.sort_custom(func(a, b): return a[0] < b[0])
	for it in items:
		match it[2]:
			0: _draw_tree(it[1])
			1: _draw_hero(it[1])
			2: _draw_rock(it[1])
			3: _draw_monster(it[1], it[3])

	if hero_slash > 0.0 and attack_target != null and hero_dead_t <= 0.0:
		var a := to_screen(hero_g) + Vector2(0, -40)
		var b: Vector2 = to_screen(attack_target.g) + Vector2(0, -35)
		objects.draw_line(a, b, Color(1, 1, 1, 0.9), 6.0)

	for f in floaters:
		var col: Color = f.col
		col.a = clampf(f.t / 0.5, 0.0, 1.0)
		objects.draw_string_outline(ThemeDB.fallback_font, f.p, f.text,
			HORIZONTAL_ALIGNMENT_CENTER, 60, 30, 6, Color(0, 0, 0, col.a))
		objects.draw_string(ThemeDB.fallback_font, f.p, f.text,
			HORIZONTAL_ALIGNMENT_CENTER, 60, 30, col)


func _draw_tree(p: Vector2) -> void:
	objects.draw_colored_polygon(_ellipse(p, 30, 12), Color(0, 0, 0, 0.3))
	objects.draw_rect(Rect2(p + Vector2(-7, -34), Vector2(14, 34)), Color(0.35, 0.22, 0.12))
	objects.draw_circle(p + Vector2(0, -56), 30, Color(0.10, 0.30, 0.12))
	objects.draw_circle(p + Vector2(-12, -44), 20, Color(0.13, 0.36, 0.15))


func _draw_rock(p: Vector2) -> void:
	objects.draw_colored_polygon(_ellipse(p, 32, 13), Color(0, 0, 0, 0.3))
	objects.draw_circle(p + Vector2(0, -16), 24, Color(0.45, 0.45, 0.48))
	objects.draw_circle(p + Vector2(10, -22), 12, Color(0.55, 0.55, 0.58))


func _draw_hero(p: Vector2) -> void:
	objects.draw_colored_polygon(_ellipse(p, 22, 9), Color(0, 0, 0, 0.35))
	objects.draw_rect(Rect2(p + Vector2(-13, -56), Vector2(26, 46)), Color(0.20, 0.35, 0.80))
	objects.draw_circle(p + Vector2(0, -66), 12, Color(0.90, 0.75, 0.60))


func _draw_monster(p: Vector2, m: Dictionary) -> void:
	var kind: int = m.kind
	var cols := [Color(0.82, 0.82, 0.75), Color(0.35, 0.52, 0.30), Color(0.85, 0.22, 0.20)]
	var sc: float = [1.0, 1.25, 0.8][kind]
	var col: Color = Color.WHITE if m.hit > 0.0 else cols[kind]
	objects.draw_colored_polygon(_ellipse(p, 22 * sc, 9 * sc), Color(0, 0, 0, 0.35))
	objects.draw_rect(Rect2(p + Vector2(-13 * sc, -50 * sc), Vector2(26 * sc, 40 * sc)), col)
	objects.draw_circle(p + Vector2(0, -60 * sc), 12 * sc, col)
	objects.draw_circle(p + Vector2(-4 * sc, -62 * sc), 2.5, Color(0.9, 0.1, 0.1))
	objects.draw_circle(p + Vector2(4 * sc, -62 * sc), 2.5, Color(0.9, 0.1, 0.1))
	var bw := 44.0
	var by := -50.0 * sc - 36.0
	var frac: float = clampf(m.hp / m.maxhp, 0.0, 1.0)
	objects.draw_rect(Rect2(p + Vector2(-bw / 2.0, by), Vector2(bw, 6)), Color(0, 0, 0, 0.7))
	objects.draw_rect(Rect2(p + Vector2(-bw / 2.0, by), Vector2(bw * frac, 6)), Color(0.85, 0.15, 0.15))


func _draw_hud() -> void:
	var s := get_viewport_rect().size
	var r := Rect2(40, s.y - 70, 420, 30)
	hud.draw_rect(r, Color(0, 0, 0, 0.6))
	hud.draw_rect(Rect2(r.position, Vector2(r.size.x * clampf(hero_hp / HERO_MAX_HP, 0.0, 1.0), r.size.y)), Color(0.8, 0.1, 0.1))
	hud.draw_string(ThemeDB.fallback_font, r.position + Vector2(10, 22),
		"HP %d / %d" % [ceili(hero_hp), int(HERO_MAX_HP)], HORIZONTAL_ALIGNMENT_LEFT, -1, 20)
	if hero_dead_t > 0.0:
		hud.draw_string(ThemeDB.fallback_font, Vector2(0, s.y / 2.0), "YOU DIED",
			HORIZONTAL_ALIGNMENT_CENTER, s.x, 64, Color(0.9, 0.2, 0.2))
