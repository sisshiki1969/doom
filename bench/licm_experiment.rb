#!/usr/bin/env ruby
# frozen_string_literal: true

# LICM (Loop-Invariant Code Motion) Experiment
#
# Compares the DOOM floor/ceiling hot loop in several forms:
#   1. Current code (as-is from renderer.rb)
#   2. "Manual LICM" -- pre-extract all array .data pointers, eliminate redundant checks
#   3. Minimal loop -- just the math, no array wrappers
#
# This measures the POTENTIAL speedup from LICM in a JIT compiler.

require 'benchmark'

SCREEN_WIDTH = 320
HALF_HEIGHT = 120
ITERATIONS = 500  # Number of full-screen passes

# Simulate the data structures
column_distscale = Array.new(SCREEN_WIDTH) { |x| 1.0 / Math.cos(Math.atan2(x - SCREEN_WIDTH/2, 160.0)) }
column_cos = Array.new(SCREEN_WIDTH) { |x| Math.cos(x * 0.01) }
column_sin = Array.new(SCREEN_WIDTH) { |x| Math.sin(x * 0.01) }
flat_pixels = Array.new(4096) { rand(256) }  # 64x64 texture
colormap = Array.new(256) { |i| i }           # Identity colormap
framebuffer = Array.new(SCREEN_WIDTH * 240, 0)

player_x = 1056.0
neg_player_y = 3616.0

# Pre-compute perp_dist for each row (as the real code does)
y_slope = Array.new(HALF_HEIGHT + 1) { |dy| dy > 0 ? 100.0 * 160.0 / dy : 0.0 }

puts "DOOM Floor Rendering Hot Loop -- LICM Experiment"
puts "=" * 60
puts "#{SCREEN_WIDTH}x#{HALF_HEIGHT} pixels per pass, #{ITERATIONS} passes"
puts "Total pixels: #{SCREEN_WIDTH * HALF_HEIGHT * ITERATIONS}"
puts "Ruby: #{RUBY_DESCRIPTION}"
puts

# Warmup
3.times do
  HALF_HEIGHT.times do |row|
    perp_dist = y_slope[row + 1]
    next if perp_dist <= 0
    x = 0
    while x < SCREEN_WIDTH
      ray_dist = perp_dist * column_distscale[x]
      tex_x = (player_x + ray_dist * column_cos[x]).to_i & 63
      tex_y = (neg_player_y - ray_dist * column_sin[x]).to_i & 63
      color = flat_pixels[tex_y * 64 + tex_x]
      framebuffer[row * SCREEN_WIDTH + x] = colormap[color]
      x += 1
    end
  end
end

GC.start
GC.compact if GC.respond_to?(:compact)

results = {}

# ============================================================
# Variant 1: Current code (matches renderer.rb)
# The JIT sees: array access with type guards on every iteration
# ============================================================
gc_before = GC.stat[:total_allocated_objects]
t = Benchmark.realtime do
  ITERATIONS.times do
    HALF_HEIGHT.times do |row|
      perp_dist = y_slope[row + 1]
      next if perp_dist <= 0
      cmap = colormap
      row_offset = row * SCREEN_WIDTH
      x = 0
      while x < SCREEN_WIDTH
        ray_dist = perp_dist * column_distscale[x]
        tex_x = (player_x + ray_dist * column_cos[x]).to_i & 63
        tex_y = (neg_player_y - ray_dist * column_sin[x]).to_i & 63
        color = flat_pixels[tex_y * 64 + tex_x]
        framebuffer[row_offset + x] = cmap[color]
        x += 1
      end
    end
  end
end
gc_after = GC.stat[:total_allocated_objects]
results[:current] = { time: t, allocs: gc_after - gc_before }

GC.start

# ============================================================
# Variant 2: Inlined .to_i via Integer()
# Tests whether .to_i dispatch is a real cost
# ============================================================
gc_before = GC.stat[:total_allocated_objects]
t = Benchmark.realtime do
  ITERATIONS.times do
    HALF_HEIGHT.times do |row|
      perp_dist = y_slope[row + 1]
      next if perp_dist <= 0
      cmap = colormap
      row_offset = row * SCREEN_WIDTH
      x = 0
      while x < SCREEN_WIDTH
        ray_dist = perp_dist * column_distscale[x]
        # Use bit-or-0 trick instead of .to_i (avoids method dispatch)
        tx = (player_x + ray_dist * column_cos[x])
        ty = (neg_player_y - ray_dist * column_sin[x])
        tex_x = (tx >= 0 ? tx.floor : tx.ceil) & 63
        tex_y = (ty >= 0 ? ty.floor : ty.ceil) & 63
        color = flat_pixels[tex_y * 64 + tex_x]
        framebuffer[row_offset + x] = cmap[color]
        x += 1
      end
    end
  end
end
gc_after = GC.stat[:total_allocated_objects]
results[:floor_ceil] = { time: t, allocs: gc_after - gc_before }

GC.start

# ============================================================
# Variant 3: Pre-multiply perp_dist into distscale (hoists one multiply)
# Simulates LICM hoisting perp_dist out of the inner loop
# ============================================================
gc_before = GC.stat[:total_allocated_objects]
t = Benchmark.realtime do
  # Pre-allocate a row buffer
  row_distscale = Array.new(SCREEN_WIDTH, 0.0)

  ITERATIONS.times do
    HALF_HEIGHT.times do |row|
      perp_dist = y_slope[row + 1]
      next if perp_dist <= 0
      cmap = colormap
      row_offset = row * SCREEN_WIDTH

      # "LICM": pre-compute perp_dist * distscale for all columns
      # A JIT with LICM could hoist `perp_dist *` out of the inner loop
      # since perp_dist doesn't change within the x loop
      x = 0
      while x < SCREEN_WIDTH
        row_distscale[x] = perp_dist * column_distscale[x]
        x += 1
      end

      x = 0
      while x < SCREEN_WIDTH
        ray_dist = row_distscale[x]
        tex_x = (player_x + ray_dist * column_cos[x]).to_i & 63
        tex_y = (neg_player_y - ray_dist * column_sin[x]).to_i & 63
        color = flat_pixels[tex_y * 64 + tex_x]
        framebuffer[row_offset + x] = cmap[color]
        x += 1
      end
    end
  end
end
gc_after = GC.stat[:total_allocated_objects]
results[:pre_multiply] = { time: t, allocs: gc_after - gc_before }

GC.start

# ============================================================
# Variant 4: Reduce array lookups -- cache cos/sin values
# Tests the cost of repeated Array#[] dispatch
# ============================================================
gc_before = GC.stat[:total_allocated_objects]
t = Benchmark.realtime do
  ITERATIONS.times do
    HALF_HEIGHT.times do |row|
      perp_dist = y_slope[row + 1]
      next if perp_dist <= 0
      cmap = colormap
      row_offset = row * SCREEN_WIDTH
      x = 0
      while x < SCREEN_WIDTH
        ds = column_distscale[x]
        cs = column_cos[x]
        sn = column_sin[x]
        ray_dist = perp_dist * ds
        tex_x = (player_x + ray_dist * cs).to_i & 63
        tex_y = (neg_player_y - ray_dist * sn).to_i & 63
        color = flat_pixels[tex_y * 64 + tex_x]
        framebuffer[row_offset + x] = cmap[color]
        x += 1
      end
    end
  end
end
gc_after = GC.stat[:total_allocated_objects]
results[:cached_lookups] = { time: t, allocs: gc_after - gc_before }

GC.start

# ============================================================
# Variant 5: Combined -- all manual LICM-like optimizations
# ============================================================
gc_before = GC.stat[:total_allocated_objects]
t = Benchmark.realtime do
  # Pre-combine cos/sin/distscale into a single struct-of-arrays
  col_data = Array.new(SCREEN_WIDTH * 3, 0.0)
  SCREEN_WIDTH.times do |x|
    col_data[x * 3]     = column_distscale[x]
    col_data[x * 3 + 1] = column_cos[x]
    col_data[x * 3 + 2] = column_sin[x]
  end

  ITERATIONS.times do
    HALF_HEIGHT.times do |row|
      perp_dist = y_slope[row + 1]
      next if perp_dist <= 0
      cmap = colormap
      row_offset = row * SCREEN_WIDTH
      px = player_x
      npy = neg_player_y
      x = 0
      while x < SCREEN_WIDTH
        i = x * 3
        ray_dist = perp_dist * col_data[i]
        tex_x = (px + ray_dist * col_data[i + 1]).to_i & 63
        tex_y = (npy - ray_dist * col_data[i + 2]).to_i & 63
        color = flat_pixels[tex_y * 64 + tex_x]
        framebuffer[row_offset + x] = cmap[color]
        x += 1
      end
    end
  end
end
gc_after = GC.stat[:total_allocated_objects]
results[:combined] = { time: t, allocs: gc_after - gc_before }

GC.start

# ============================================================
# Variant 6: Pure math baseline -- no array lookups at all
# Shows the theoretical floor (just Float arithmetic)
# ============================================================
gc_before = GC.stat[:total_allocated_objects]
t = Benchmark.realtime do
  dummy = 0
  ITERATIONS.times do
    HALF_HEIGHT.times do |row|
      perp_dist = y_slope[row + 1]
      next if perp_dist <= 0
      x = 0
      while x < SCREEN_WIDTH
        ray_dist = perp_dist * 1.003
        tex_x = (1056.0 + ray_dist * 0.999).to_i & 63
        tex_y = (3616.0 - ray_dist * 0.001).to_i & 63
        dummy = tex_y * 64 + tex_x
        x += 1
      end
    end
  end
  _ = dummy  # prevent dead code elimination
end
gc_after = GC.stat[:total_allocated_objects]
results[:pure_math] = { time: t, allocs: gc_after - gc_before }

# ============================================================
# Results
# ============================================================
puts "Results"
puts "-" * 60

baseline = results[:current][:time]
labels = {
  current:       "1. Current code (as-is)",
  floor_ceil:    "2. .floor/.ceil vs .to_i",
  pre_multiply:  "3. Pre-multiply perp_dist",
  cached_lookups:"4. Cache array lookups",
  combined:      "5. Combined optimizations",
  pure_math:     "6. Pure math (no arrays)",
}

labels.each do |key, label|
  r = results[key]
  ratio = baseline / r[:time]
  pixels_per_sec = (SCREEN_WIDTH * HALF_HEIGHT * ITERATIONS / r[:time] / 1_000_000).round(1)
  allocs_per_pass = r[:allocs].to_f / ITERATIONS
  printf "%-35s %7.2fs  %5.2fx  %5.1fM px/s  %6.0f allocs/pass\n",
         label, r[:time], ratio, pixels_per_sec, allocs_per_pass
end

puts
puts "Key findings:"
v1 = results[:current][:time]
v4 = results[:cached_lookups][:time]
v5 = results[:combined][:time]
v6 = results[:pure_math][:time]
puts "  Array access overhead: #{((1 - v6/v1) * 100).round(1)}% of time is array lookups + guards"
puts "  LICM potential:        #{((1 - v5/v1) * 100).round(1)}% speedup from manual LICM"
puts "  Theoretical ceiling:   #{(v1/v6).round(2)}x if arrays were free"
