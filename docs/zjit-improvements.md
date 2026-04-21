# ZJIT Improvements Log

Tracking ZJIT optimizations developed using the DOOM renderer benchmark.

## 1. Float arithmetic inlining (+, -, *, /)

**Branch:** `zjit-doom-analysis` in ruby/ruby
**Status:** Local, not submitted

### What changed

Added `FloatAdd`, `FloatSub`, `FloatMul`, `FloatDiv` HIR instructions to ZJIT.
These lower to `gen_prepare_leaf_call_with_gc` + direct ccall to `rb_float_plus` etc.,
skipping the full `CCallWithFrame` overhead (frame push/pop, stack spill, locals spill).

Key detail: guards use `types::Flonum` (cheap bitwise tag check) not `types::Float`
(expensive class load from memory). Initial implementation with `types::Float` caused
a 25% regression due to the cost of the class check in the inner loop.

### Files modified

- `zjit/src/hir.rs` -- 4 new Insn variants, effects, display, copy, type inference, verifier
- `zjit/src/codegen.rs` -- 4 gen functions, dispatch entries
- `zjit/src/cruby_methods.rs` -- `try_inline_float_op` helper, 4 inline functions, 4 annotations

### Benchmark results

DOOM renderer, 320x240, 200 frames, Apple Silicon, `--enable-zjit=dev`:

| Viewpoint | Baseline (ms) | Float inline (ms) | Change |
|-----------|--------------|-------------------|--------|
| spawn     | 35.44        | 33.52             | -5.4%  |
| hallway   | 30.89        | 30.17             | -2.3%  |
| corner    | 34.50        | 33.43             | -3.1%  |
| reverse   | 28.91        | 28.04             | -3.0%  |
| **FPS**   | **28.3**     | **29.8**          | **+5.3%** |

Spawn and corner (high floor/ceiling pixel count) gain more than reverse (low pixel count),
confirming the optimization targets the floor/ceiling rendering loop as expected.

### Lesson learned

`GuardType Float` (union of Flonum + HeapFloat) generates a full class check: test for
special constant, compare to Qfalse, load klass from object memory, compare to rb_cFloat.
That is 4 instructions + a memory dereference per guard. With 4 guards per pixel in the
inner loop, this caused 300K+ memory loads per frame and a net 25% regression.

Switching to `GuardType Flonum` uses a cheap bitwise tag check: `(val & 3) == 2`.
No memory access, single branch. Since most Ruby Floats are Flonum on 64-bit platforms,
the guard rarely fails.

---

## 2. Float#to_i inlining

**Branch:** `zjit-doom-analysis` in ruby/ruby
**Status:** Local, not submitted

### What changed

Added `FloatToInt` HIR instruction and `rb_jit_flo_to_i` C helper in `jit.c`
(wrapper for static `flo_to_i`). Truncates Float to Integer via
`gen_prepare_leaf_call_with_gc + ccall`, skipping CCallWithFrame.

### Files modified

- `jit.c` -- new `rb_jit_flo_to_i` helper
- `zjit/bindgen/src/main.rs` -- allowlist entry
- `zjit/src/cruby_bindings.inc.rs` -- function declaration
- `zjit/src/hir.rs` -- FloatToInt instruction
- `zjit/src/codegen.rs` -- gen_float_to_int
- `zjit/src/cruby_methods.rs` -- inline_float_to_i, annotations for to_i and to_int

### Cumulative benchmark results (release build, `--enable-zjit`)

| Runtime | FPS | vs Interpreter |
|---------|-----|----------------|
| Interpreter | 30.8 | 1.00x |
| ZJIT baseline | 40.5 | 1.32x |
| **ZJIT + all optimizations** | **44.5** | **1.44x (+10%)** |
| YJIT | 79.1 | 2.57x |

Dev build results (`--enable-zjit=dev`, with debug assertions):

| Viewpoint | Baseline (ms) | All optimizations (ms) | Change |
|-----------|--------------|----------------------|--------|
| spawn     | 35.44        | 33.13                | -6.5%  |
| hallway   | 30.89        | 29.70                | -3.9%  |
| corner    | 34.50        | 32.33                | -6.3%  |
| reverse   | 28.91        | 27.62                | -4.5%  |

---

## Remaining targets (from zjit-optimization-spec.md)

### Quick wins (next PRs)

| Target | Expected impact | Notes |
|--------|----------------|-------|
| Math.sqrt/sin/cos/atan2 annotations | 1-3% | Pure leaf+no_gc cfuncs. Pattern same as #16721 predicate annotations. |
| Float comparisons (>, >=, <, <=, ==) HIR | ~1-2% | FloatGt/Ge/Lt/Le instructions following FloatAdd pattern (gen_prepare_leaf_call_with_gc). Improves BSP traversal in render_seg, point_on_side. |
| Float#-@ annotation | <1% | Builtin in numeric.rb already leaf, just needs return type. |
| ~~SCREEN_WIDTH constant folding~~ | ~1-2% | **Already done by ZJIT.** PatchPoint StableConstantNames folds to `Fixnum[320] = Const Value(320)`, and `x < SCREEN_WIDTH` becomes `FixnumLt`. |

### Done (already shipped or merged)

- Float arithmetic +, -, *, / -- ruby/ruby#16735 (FloatAdd/Sub/Mul/Div)
- Float#to_i -- ruby/ruby#16735 (FloatToInt)
- Float-Fixnum mixed operands -- ruby/ruby#16735
- Float/Integer predicate annotations -- ruby/ruby#16721 (merged)
- getlocal level=0 EP staleness fix -- ruby/ruby#16736 (merged)

### Needs major ZJIT infrastructure (months of work, ZJIT team)

| Target | Expected impact | Why blocked |
|--------|----------------|-------------|
| Float unboxing / scalar replacement | 15-25% | Needs FP register support in backend (ZJIT is GPR-only), escape analysis pass, scalar replacement pass. |
| Loop-invariant code motion | 5-10% | Needs loop detection (back-edges, natural loops, dominance), invariant analysis pass, motion pass. |
| Array bounds check elimination | 5-10% | Needs range analysis / abstract interpretation. |
| Inlining Float#to_i further (fcvtzs) | 1-3% | Already inlined via ccall. Single-instruction codegen needs FP register support. |
| Integer ops further inlining | 1-2% | Needs verification HIR is already firing FixnumAdd etc. in DOOM hot loop. |
