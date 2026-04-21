#!/usr/bin/env ruby
# frozen_string_literal: true

# Array Access Experiment
#
# The LICM experiment showed that 62% of ZJIT time (45% for YJIT) is array
# access overhead. This benchmark drills into WHAT makes array access slow:
#
#   1. Type guard (is it an Array?)
#   2. Bounds check (is index in range?)
#   3. Element type check (is element a Float/Integer?)
#   4. Method dispatch (Array#[] lookup)
#
# We test by comparing:
#   a. Normal Array#[]
#   b. Array#[] with frozen array
#   c. Array#fetch (explicit bounds check)
#   d. String#getbyte (C-level array, no Ruby dispatch)
#   e. Fiddle pointer (raw memory, no checks at all)
#   f. Pre-packed into a single flat array (fewer objects)

require 'benchmark'

N = 320                # Array size (screen width)
ROWS = 120             # Rows per frame
PASSES = 500           # Full screen passes
TOTAL = N * ROWS * PASSES

puts "Array Access Patterns -- DOOM Hot Loop Analysis"
puts "=" * 60
puts "Array size: #{N}, #{ROWS} rows, #{PASSES} passes"
puts "Total accesses: #{TOTAL / 1_000_000}M"
puts "Ruby: #{RUBY_DESCRIPTION}"
puts

# Build test data
src_float = Array.new(N) { |i| Math.cos(i * 0.01) }
src_int = Array.new(N) { |i| i % 256 }
src_frozen = src_float.dup.freeze

# Pack floats into a string buffer (simulates C array)
require 'fiddle'
float_buf = src_float.pack('d*')
float_ptr = Fiddle::Pointer.to_ptr(float_buf)

# Warmup
3.times do
  ROWS.times do |row|
    x = 0
    dummy = 0.0
    while x < N
      dummy += src_float[x]
      x += 1
    end
  end
end

GC.start
GC.compact if GC.respond_to?(:compact)

results = {}

# ============================================================
# Test 1: Normal Array#[] (Float elements)
# This is what the DOOM loop does for column_cos[x], column_sin[x], etc.
# ============================================================
GC.start
t = Benchmark.realtime do
  dummy = 0.0
  arr = src_float
  PASSES.times do
    ROWS.times do
      x = 0
      while x < N
        dummy += arr[x]
        x += 1
      end
    end
  end
  _ = dummy
end
results[:normal_float] = t

# ============================================================
# Test 2: Frozen Array#[] (Float elements)
# Does freezing help the JIT eliminate mutability checks?
# ============================================================
GC.start
t = Benchmark.realtime do
  dummy = 0.0
  arr = src_frozen
  PASSES.times do
    ROWS.times do
      x = 0
      while x < N
        dummy += arr[x]
        x += 1
      end
    end
  end
  _ = dummy
end
results[:frozen_float] = t

# ============================================================
# Test 3: Normal Array#[] (Integer elements)
# Is Float element unboxing a factor?
# ============================================================
GC.start
t = Benchmark.realtime do
  dummy = 0
  arr = src_int
  PASSES.times do
    ROWS.times do
      x = 0
      while x < N
        dummy += arr[x]
        x += 1
      end
    end
  end
  _ = dummy
end
results[:normal_int] = t

# ============================================================
# Test 4: String#getbyte (C-level byte array)
# String bytes are stored as a C array -- no Ruby object per element,
# no bounds check in the fast path, no type guard on elements.
# ============================================================
GC.start
byte_str = src_int.pack('C*')
t = Benchmark.realtime do
  dummy = 0
  str = byte_str
  PASSES.times do
    ROWS.times do
      x = 0
      while x < N
        dummy += str.getbyte(x)
        x += 1
      end
    end
  end
  _ = dummy
end
results[:string_getbyte] = t

# ============================================================
# Test 5: Fiddle pointer (raw memory read)
# Absolute minimum: read a double from a pointer offset.
# No type check, no bounds check, no Ruby dispatch.
# ============================================================
GC.start
t = Benchmark.realtime do
  dummy = 0.0
  ptr = float_ptr
  PASSES.times do
    ROWS.times do
      x = 0
      while x < N
        dummy += ptr[x * 8, 8].unpack1('d')
        x += 1
      end
    end
  end
  _ = dummy
end
results[:fiddle_unpack] = t

# ============================================================
# Test 6: Three arrays vs one interleaved array
# DOOM accesses column_distscale[x], column_cos[x], column_sin[x]
# for the same x. Is 3 array accesses worse than 1?
# ============================================================
arr_a = Array.new(N) { |i| Math.cos(i * 0.01) }
arr_b = Array.new(N) { |i| Math.sin(i * 0.01) }
arr_c = Array.new(N) { |i| 1.0 / Math.cos(Math.atan2(i - N/2, 160.0)) }

# Interleaved: [a0, b0, c0, a1, b1, c1, ...]
interleaved = Array.new(N * 3)
N.times { |i| interleaved[i*3] = arr_a[i]; interleaved[i*3+1] = arr_b[i]; interleaved[i*3+2] = arr_c[i] }

GC.start
t_separate = Benchmark.realtime do
  dummy = 0.0
  PASSES.times do
    ROWS.times do
      x = 0
      while x < N
        dummy += arr_a[x] + arr_b[x] + arr_c[x]
        x += 1
      end
    end
  end
  _ = dummy
end
results[:three_arrays] = t_separate

GC.start
t_interleaved = Benchmark.realtime do
  dummy = 0.0
  arr = interleaved
  PASSES.times do
    ROWS.times do
      x = 0
      while x < N
        i = x * 3
        dummy += arr[i] + arr[i+1] + arr[i+2]
        x += 1
      end
    end
  end
  _ = dummy
end
results[:interleaved] = t_interleaved

# ============================================================
# Test 7: Array#[] with computed index (like flat_pixels[tex_y * 64 + tex_x])
# Tests whether complex index expressions add overhead
# ============================================================
big_arr = Array.new(4096) { |i| i % 256 }
GC.start
t = Benchmark.realtime do
  dummy = 0
  arr = big_arr
  PASSES.times do
    ROWS.times do |row|
      x = 0
      while x < N
        idx = (row & 63) * 64 + (x & 63)
        dummy += arr[idx]
        x += 1
      end
    end
  end
  _ = dummy
end
results[:computed_index] = t

# ============================================================
# Test 8: Array#[]= (write, like framebuffer[offset + x] = value)
# Is writing slower than reading?
# ============================================================
write_arr = Array.new(N * ROWS, 0)
GC.start
t = Benchmark.realtime do
  arr = write_arr
  PASSES.times do
    ROWS.times do |row|
      offset = row * N
      x = 0
      while x < N
        arr[offset + x] = x
        x += 1
      end
    end
  end
end
results[:array_write] = t

# ============================================================
# Results
# ============================================================
puts "Results (lower = faster)"
puts "-" * 60

baseline = results[:normal_float]
labels = {
  normal_float:   "Array#[] Float",
  frozen_float:   "Array#[] Float (frozen)",
  normal_int:     "Array#[] Integer",
  string_getbyte: "String#getbyte",
  fiddle_unpack:  "Fiddle ptr unpack",
  three_arrays:   "3x Array#[] per pixel",
  interleaved:    "1x Array#[] interleaved",
  computed_index: "Array#[] computed index",
  array_write:    "Array#[]= write",
}

labels.each do |key, label|
  r = results[key]
  ratio = baseline / r
  ops_per_sec = (TOTAL / r / 1_000_000).round(1)
  printf "  %-28s %6.2fs  %5.2fx  %6.1fM ops/s\n", label, r, ratio, ops_per_sec
end

puts
puts "Analysis:"
puts "  Type guard cost:     #{((1 - results[:normal_int].to_f / results[:normal_float]) * 100).round(1)}% (Int vs Float elements)"
puts "  Freeze benefit:      #{((1 - results[:frozen_float].to_f / results[:normal_float]) * 100).round(1)}% (frozen vs mutable)"
puts "  3 arrays vs 1:       #{((1 - results[:interleaved].to_f / results[:three_arrays]) * 100).round(1)}% (interleaved wins by)"
puts "  Read vs write:       #{(results[:array_write] / results[:normal_int]).round(2)}x (write / int-read ratio)"
puts "  Ruby vs C-level:     #{(results[:normal_int] / results[:string_getbyte]).round(2)}x (Array#[] vs String#getbyte)"
