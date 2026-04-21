# ZJIT Optimization: EP Load Hoisting for Loop-Invariant Locals

## Problem

When a Ruby block accesses outer-scope local variables inside a loop, ZJIT reloads each variable from the environment pointer (EP) on every iteration. Each reload produces `GetEP` + `LoadField` (returns `BasicObject`) + `GuardType ArrayExact`, none of which are eliminated across iterations.

In DOOM Ruby's hot loop (53% of frame time), this creates **36 redundant instructions per pixel** (6 arrays x 6 instructions each) that could be hoisted to the loop preheader.

## Reproduction

```ruby
def doom_loop
  cos = Array.new(320) { |x| Math.cos(x * 0.01) }
  sin = Array.new(320) { |x| Math.sin(x * 0.01) }
  dst = Array.new(320) { |x| 1.0 }
  tex = Array.new(4096) { rand(256) }
  fb  = Array.new(76800, 0)
  cmap = Array.new(256) { |i| i }

  120.times do |row|
    pd = 100.0 * 160.0 / (row + 1)
    off = row * 320
    x = 0
    while x < 320
      rd = pd * dst[x]
      tx = (1056.0 + rd * cos[x]).to_i & 63
      ty = (3616.0 - rd * sin[x]).to_i & 63
      c = tex[ty * 64 + tx]
      fb[off + x] = cmap[c]
      x += 1
    end
  end
end
50.times { doom_loop }
```

Run with `ruby --zjit-dump-hir` to see the HIR.

## Current HIR (loop body, bb4)

Each array access generates this sequence:

```
v110:CPtr = GetEP 1                              # load enclosing scope EP
v111:BasicObject = LoadField v110, :dst@-0x30     # read local variable
v249:ArrayExact = GuardType v111, ArrayExact       # prove it's an Array
v251:CInt64 = UnboxFixnum v101                     # unbox index
v252:CInt64 = ArrayLength v249                     # load array length
v253:CInt64 = GuardLess v251, v252                 # upper bounds check
v254:CInt64 = AdjustBounds v253, v252              # handle negative indices
v255:CInt64[0] = Const CInt64(0)
v256:CInt64 = GuardGreaterEq v254, v255            # lower bounds check
v257:BasicObject = ArrayAref v249, v256            # actual element load
```

This repeats 6 times per iteration (dst, cos, sin, tex, cmap, fb). Lines 1-3 are identical every time because the locals don't change.

## Why it's safe to hoist

1. **`NoEPEscape` invariant holds** -- PatchPoints for `NoEPEscape(block in doom_loop)` are emitted in bb4. This means no external code can modify the EP locals.

2. **No `StoreField` to EP in bb4** -- the loop body never reassigns `cos`, `sin`, `dst`, `tex`, `fb`, or `cmap`. They are read-only within the while loop.

3. **`GetEP` is deterministic** -- for a given frame, `GetEP 1` always returns the same pointer. The enclosing frame doesn't move.

4. **The locals are assigned before the loop** -- they're set in bb3 (the loop preheader equivalent) via `Array.new` calls.

## Proposed fix

### Option A: Cross-block load-store optimization

Extend `optimize_load_store` to propagate `compile_time_heap` from dominating blocks (same approach as the guard propagation we prototyped). When bb4 sees `LoadField v110, :dst@-0x30`, it would find the same load cached from bb3 or a previous iteration and reuse it.

This eliminates the redundant `GetEP` + `LoadField` but the `GuardType ArrayExact` would still need the guard propagation patch to be eliminated.

### Option B: Full LICM pass (recommended)

Add a loop-invariant code motion pass that:

1. Uses `LoopInfo` (already exists) to identify loop headers and loop bodies
2. For each instruction in a loop body, checks if all operands are defined outside the loop
3. If the instruction has no side effects within the loop (or only reads from invariant memory), moves it to the loop preheader

For our case, the sequence `GetEP 1` + `LoadField :dst@-0x30` + `GuardType ArrayExact` would all be hoisted because:
- `GetEP 1` operands: level (constant) -- loop-invariant
- `LoadField` operands: EP result (hoisted), offset (constant) -- loop-invariant, reads memory but EP doesn't change (NoEPEscape)
- `GuardType` operands: LoadField result (hoisted), type (constant) -- loop-invariant

The `ArrayLength` could also be hoisted if we prove the array isn't resized in the loop (no `Array#push`, `Array#[]=` at out-of-bounds index, etc.).

### Where to insert the pass

In `Function::optimize()` (hir.rs line ~5830), after `fold_constants` and before `eliminate_dead_code`:

```rust
run_pass!(type_specialize);
run_pass!(inline);
run_pass!(optimize_getivar);
run_pass!(optimize_c_calls);
run_pass!(convert_no_profile_sends);
run_pass!(optimize_load_store);
run_pass!(fold_constants);
run_pass!(hoist_loop_invariants);  // <-- NEW
run_pass!(clean_cfg);
run_pass!(remove_redundant_patch_points);
run_pass!(remove_duplicate_check_interrupts);
run_pass!(eliminate_dead_code);
```

## Expected impact

### Per-iteration instruction count

| Instructions per pixel | Current | With hoisting | Reduction |
|----------------------|---------|---------------|-----------|
| GetEP | 6 | 0 | -6 |
| LoadField (EP locals) | 6 | 0 | -6 |
| GuardType ArrayExact | 6 | 0 | -6 |
| ArrayLength | 6 | 0 (if hoisted) | -6 |
| GuardLess (bounds) | 6 | 6 (index varies) | 0 |
| GuardGreaterEq | 6 | 6 | 0 |
| ArrayAref | 6 | 6 | 0 |
| GuardType Flonum/Fixnum | 6 | 6 | 0 |
| Other (Float ops, etc.) | ~8 | ~8 | 0 |
| **Total** | **~56** | **~32** | **-24 (43%)** |

### Benchmark estimates

At 320 pixels/row, 120 rows, 80 FPS:
- Current: 56 * 320 * 120 = 2,150,400 instructions/frame
- Hoisted: 32 * 320 * 120 + 24 * 120 = 1,231,680 instructions/frame (+ 2,880 hoisted)
- Reduction: 43% fewer instructions in the hot path

Expected DOOM FPS improvement: 10-20% (from ~46 to ~52-55 FPS).

## Existing infrastructure

ZJIT already has all the building blocks:

- `LoopInfo` -- identifies loop headers, back edges, natural loops (hir.rs ~line 8811)
- `Dominators` -- immediate dominator computation (hir.rs ~line 8624)
- `ControlFlowInfo` -- predecessors/successors (hir.rs)
- `Effect` system -- tracks which instructions read/write memory
- `NoEPEscape` invariant -- proves EP locals aren't modified externally
- `optimize_load_store` -- load deduplication within blocks (pattern to follow)

## Relationship to other optimizations

| Optimization | Status | Guards eliminated per pixel |
|-------------|--------|---------------------------|
| PR #16766 (Flonum return type) | Open PR | 1 (accumulator) |
| EP load hoisting (this spec) | Not started | 24 (EP loads + type guards + lengths) |
| Array element type specialization | Not started | 6 (Flonum/Fixnum on elements) |
| Bounds check elimination | Not started | 12 (upper + lower, provably in-range) |
| **Total** | | **43 out of 56 (77%)** |

## Benchmark instructions

```bash
cd /path/to/ruby
# Build with ZJIT
./configure --enable-zjit && make -j$(nproc)

# DOOM benchmark (clone github.com/khasinski/doom, needs doom1.wad)
./ruby --zjit bench/benchmark.rb --run

# Micro-benchmark
./ruby --zjit -e '
require "benchmark"
def array_loop(n)
  arr = Array.new(1000) { |i| i.to_f }
  sum = 0.0
  n.times { i = 0; while i < 1000; sum += arr[i]; i += 1; end }
  sum
end
Benchmark.bm { |x| x.report { array_loop(10000) } }
'

# Dump HIR to verify hoisting
./ruby --zjit-dump-hir your_test.rb 2>&1 | grep "GetEP\|LoadField\|GuardType"
# Before: GetEP+LoadField+GuardType in loop body (bb4)
# After: GetEP+LoadField+GuardType in preheader only (bb3)
```

## Contact

Investigation done with DOOM Ruby (github.com/khasinski/doom) as the benchmark.
For questions: github.com/khasinski/doom/issues
