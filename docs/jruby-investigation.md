# JRuby Performance Investigation

## Summary

JRuby 10.1 on OpenJDK 24 achieves **42 FPS** after full warmup (~150 frames) -- 21% slower than CRuby interpreter (52 FPS) and 3x slower than YJIT (126 FPS). The root cause is **heap allocation of numeric temporaries**.

## Warmup Curve

| Frames | Avg (ms) | FPS | Phase |
|--------|----------|-----|-------|
| 1-50 | 176 | 5.7 | JVM interpreter, cold start |
| 51-100 | 148 | 6.8 | Still interpreting |
| 101-150 | 82 | 12.2 | C2 JIT compiling hot methods |
| 151-200 | 26 | 38.9 | JIT compiled, stabilizing |
| 200-1000 | ~24 | ~42 | Fully converged |

JRuby needs ~150 frames (4x more than CRuby's 30-frame warmup) for the JVM C2 compiler to optimize the hot path. Additional warmup beyond 200 frames shows diminishing returns.

## Root Cause: Numeric Boxing

Every Ruby numeric operation on JRuby allocates a new Java heap object:

```java
// JRuby: Float multiplication
public IRubyObject op_mul(ThreadContext context, IRubyObject other) {
    return asFloat(context, value * ((RubyNumeric) other).asDouble(context));
    //     ^^^^^^^^ allocates new RubyFloat on Java heap
}

// asFloat → newFloat → new RubyFloat(runtime, value)
```

CRuby avoids this with tagged pointers: small integers (Fixnum) and most floats (Flonum) are encoded directly in the 64-bit `VALUE` word using tag bits. No heap allocation, no GC pressure.

### Per-Pixel Allocation Count

The DOOM span loop does ~11 heap allocations per pixel on JRuby:

| Operation | JRuby | CRuby |
|-----------|-------|-------|
| `pd * arr[x]` | `new RubyFloat` | 0 (Flonum) |
| `rd * cos[x]` | `new RubyFloat` | 0 |
| `1056.0 + ...` | `new RubyFloat` | 0 |
| `rd * sin[x]` | `new RubyFloat` | 0 |
| `3616.0 - ...` | `new RubyFloat` | 0 |
| `.to_i` | `new RubyFixnum` | 0 (Fixnum) |
| `& 63` | `new RubyFixnum` | 0 |
| `ty * 64` | `new RubyFixnum` | 0 |
| `+ tx` | `new RubyFixnum` | 0 |
| `off + x` | `new RubyFixnum` | 0 |
| `x += 1` | `new RubyFixnum*` | 0 |

*Fixnum cache (-256..255) avoids allocation for x=0..255, but allocates for x=256..319.

At 320x120 pixels/frame: **~422,400 heap objects per frame**, producing 144MB of garbage per 100 frames and constant GC pressure.

## Micro-Benchmark Comparison (1M iterations)

| Operation | JRuby 10.1 | CRuby Interp | CRuby YJIT |
|-----------|-----------|-------------|------------|
| Float multiply | **24.6ms** | 45.2ms | 33.4ms |
| Array#[] | 62.2ms | **46.5ms** | **32.2ms** |
| Float#to_i | 50.5ms | **45.0ms** | **33.8ms** |
| Integer#& | **19.4ms** | 35.6ms | 28.0ms |
| Array#[]= | 43.9ms | **31.1ms** | **34.8ms** |
| **Span loop** | **36,898ms** | **2,603ms** | **1,024ms** |

JRuby is actually FASTER for isolated Float multiply and Integer AND (JVM's FPU and ALU are excellent). But Array access is 34% slower (deep call chain: `aref` → `entry` → `elt` → `eltOk` → `eltInternal` → `values[begin+offset]`), and the combined span loop is **36x slower than YJIT** due to cumulative allocation pressure.

## Array Access Call Chain

```
aref(context, arg0)                    // method dispatch
  → instanceof RubyFixnum check        // type check
  → entry(fixnum.getValue())           // unbox to long
    → offset < 0 check                 // negative index
    → elt(offset)
      → offset < 0 || >= realLength    // bounds check
      → eltOk(offset)
        → try { eltInternal((int)offset) }  // try/catch AIOOBE
          → values[begin + offset]          // actual Java array access
```

6 method calls + 3 checks + 1 try/catch for a single array read. CRuby does this in a single inline C function.

## Why JVM JIT Can't Fix This

The JVM C2 compiler should theoretically optimize away the allocations via escape analysis. In practice:

1. **Deep class hierarchy**: `RubyFloat` extends `RubyNumeric` extends `RubyObject` extends `RubyBasicObject` implements `IRubyObject`. C2 can't prove the allocated object doesn't escape through the `IRubyObject` interface.

2. **ThreadContext threading**: Every operation receives `ThreadContext context` which the JIT must assume could capture the result.

3. **Polymorphic dispatch**: `op_mul(IRubyObject other)` uses a `switch` on `getMetaClass().getClassIndex()`, making the call site megamorphic from C2's perspective.

## Why TruffleRuby Is 4x Faster

TruffleRuby (166 FPS) uses the same JVM but achieves 4x JRuby's speed because:

1. **Truffle framework**: Gives GraalVM deep knowledge of Ruby value flow. GraalVM can prove Float temporaries don't escape the loop and keep them as JVM `double` in registers.

2. **Partial evaluation**: Truffle's AST interpreter is partially evaluated by Graal, producing specialized machine code that operates on unboxed values.

3. **No IRubyObject boxing**: After Graal's escape analysis, the `RubyFloat` wrapper never materializes on the heap. Zero allocations per frame.

## Possible JRuby Improvements

1. **Primitive specialization**: JRuby could detect numeric-heavy loops and generate bytecode that operates on unboxed `double`/`long` directly, only boxing when needed at method boundaries.

2. **Fixnum cache expansion**: Increasing `FIXNUM_CACHE_RANGE` to 4096 would eliminate Fixnum allocations for the DOOM loop's index computations.

3. **Inline array access**: The 6-method-call chain for `Array#[]` could be flattened for the common Fixnum-index case.

4. **Float caching**: A small LRU cache of common Float values (similar to Fixnum's cache) could reduce allocations.
