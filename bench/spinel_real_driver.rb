# Minimal driver: pull in the real renderer + its dep graph, call
# render_frame in a loop, report timing. No CLI / no GC tuning / no
# Net::HTTP. Apples-to-apples with bench/benchmark.rb's render-loop
# subset (the part that actually exercises the renderer).
require_relative '../lib/doom/wad/reader'
require_relative '../lib/doom/wad/palette'
require_relative '../lib/doom/wad/colormap'
require_relative '../lib/doom/wad/flat'
require_relative '../lib/doom/wad/patch'
require_relative '../lib/doom/wad/texture'
require_relative '../lib/doom/wad/sprite'
require_relative '../lib/doom/wad/hud_graphics'
require_relative '../lib/doom/map/data'
require_relative '../lib/doom/game/player_state'
require_relative '../lib/doom/game/sector_actions'
require_relative '../lib/doom/game/animations'
require_relative '../lib/doom/game/sector_effects'
require_relative '../lib/doom/render/renderer'

WAD_PATH = "/Users/hasik/Projects/doom/doom1.wad"
WARMUP   = 5
FRAMES   = 50

wad      = Doom::Wad::Reader.new(WAD_PATH)
palette  = Doom::Wad::Palette.load(wad)
colormap = Doom::Wad::Colormap.load(wad)
flats    = Doom::Wad::Flat.load_all(wad)
textures = Doom::Wad::TextureManager.new(wad)
sprites  = Doom::Wad::SpriteManager.new(wad)
map      = Doom::Map::MapData.load(wad, "E1M1")

renderer = Doom::Render::Renderer.new(wad, map, textures, palette, colormap, flats, sprites)
renderer.skip_background_fill = true

ps = map.player_start
renderer.set_player(ps.x, ps.y, 41, ps.angle)

i = 0
while i < WARMUP
  renderer.render_frame
  i = i + 1
end

t0 = Time.now
i = 0
while i < FRAMES
  renderer.render_frame
  i = i + 1
end
elapsed = Time.now - t0

puts "frames:        #{FRAMES}"
puts "warmup:        #{WARMUP}"
puts "elapsed:       #{(elapsed * 1000).to_i} ms"
puts "ms/frame:      #{(elapsed * 1000 / FRAMES).round(3)}"
puts "fps:           #{(FRAMES / elapsed).round(1)}"

# Framebuffer fingerprint — proves the two runtimes did equivalent
# rendering work (not just looped fast over no-ops). Sums every pixel
# value plus a count of non-zero pixels so an all-zeros output (the
# "spinel skipped everything" failure mode) reads as fingerprint=0/0.
fb = renderer.framebuffer
sum = 0
nonzero = 0
i = 0
while i < fb.length
  v = fb[i]
  sum = sum + v
  if v != 0
    nonzero = nonzero + 1
  end
  i = i + 1
end
puts "fb_sum:        #{sum}"
puts "fb_nonzero:    #{nonzero}"
puts "fb_size:       #{fb.length}"
