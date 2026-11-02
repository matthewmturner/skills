---
name: perf-optimization
description: Guides performance optimization work using data-oriented design — flat arrays over hash tables, indices over pointers, bit-packing hot data, structure-of-arrays layouts, and redesign over caching. Use this skill whenever the user asks to make code faster, reduce latency or memory, optimize a hot path, profile something, fix a slow query/loop/allocation pattern, or review code for performance, in any language — even if they don't say "optimize" (e.g. "this is slow", "why is this taking so long", "can we cut allocations here", "flamegraph shows X"). Also use when the user proposes adding a cache to fix slowness.
---

# Performance Optimization (Data-Oriented)

These principles are language-agnostic. Once you know what language the code is in, read the matching file in `references/` for idioms, code sketches, and profiling tools:

| Language | Reference |
|---|---|
| Rust | `references/rust.md` |
| Go | `references/go.md` |
| C | `references/c.md` |

If the language isn't listed, apply the principles directly and pick the closest reference for inspiration (manual-memory or systems languages → C or Rust; garbage-collected → Go). If a codebase mixes languages, read the reference for the language the hot path is in.

## The core belief

Most slow code is slow because of how its data is laid out and touched, not because of a missing micro-optimization or a missing cache. CPUs are fast at streaming through contiguous memory and slow at chasing pointers, hashing, and missing cache lines. The highest-leverage move is usually to reshape the data so the hot path does less work over less memory, in order.

Four questions drive the work. Ask them of every hot path, in roughly this order.

## 1. How do we rewrite this to better leverage data-oriented design?

Start from the data, not the code. Before touching anything, answer:

- What is the hot loop actually reading and writing? Which fields, how many bytes per item, in what order?
- How many items are there typically, and at the tail?
- What fraction of each loaded cache line is actually used?

Then reshape: group data by how it's accessed, not by what "object" it conceptually belongs to. Prefer batched transforms over a whole collection to per-object methods called one at a time. Separate hot fields from cold fields. Make the common case branch-free and the rare case a separate path.

## 2. Can we replace hash tables with flat arrays, pointers with indices, and pack hot data into index bits?

Three escalating moves:

**Hash table → flat array.** If keys are (or can be made) dense small integers, an array indexed by key beats any hash map: no hashing, no probing, predictable memory. When keys are strings or sparse IDs, intern them once at the boundary into dense 32-bit IDs, then use arrays everywhere inside. A hash map that survives should be justified (truly sparse, unbounded key space), not the default.

**Pointer → index.** Replace pointers/references between nodes with 32-bit indices into a backing array (an arena). Indices are half the size of a 64-bit pointer, trivially serializable and relocatable, keep the backing storage contiguous, and in garbage-collected languages remove work from the collector. Give each index a distinct type so indices into different arrays can't be mixed up.

**Pack hot data into the upper bits.** If an index only needs ~24 bits of range, the remaining bits can carry what you check most often — a type tag, a flag, a small enum — so the common check needs no memory load at all. Define the bit layout in one place with named constants and accessors; never scatter raw shifts and masks through the code. Assert the range limit, and test that values round-trip.

## 3. Caching is cope for a slow design

Default posture: do not add caches, and treat existing caches as suspects to delete. A cache is usually evidence that the underlying computation or data layout is wrong, and it brings real costs — invalidation bugs, memory bloat, cold-start cliffs, nondeterministic latency, and a second source of truth. Instead, redesign so the work is cheap enough not to need one.

When you find a cache:
1. Benchmark with it.
2. Remove it and benchmark again.
3. If it was load-bearing, ask *why* the uncached path is slow and fix that (layout, algorithm, redundant work, allocation).
4. Re-measure. The goal is uncached performance at or beyond cached performance.

Be honest when step 3 doesn't get there. A cache in front of something genuinely outside your control — network round trips, disk, a remote service — is a different thing from a cache papering over your own slow code. If you believe a cache should stay, say so explicitly with the numbers; don't silently keep it, and don't silently delete it either.

## 4. Should this be a structure of arrays instead of an array of structures?

Array-of-structures (one array of records, each with all fields) loads every field whenever you touch one. If the hot loop reads two of ten fields, most of each cache line is wasted.

Structure-of-arrays (one array per field) lets the loop stream only the columns it needs, packs without padding, and vectorizes far more readily.

Pick SoA when hot loops touch a subset of fields over many items. Keep AoS when code nearly always reads all fields of one item together (random access to whole records). Hybrids are fine: a hot SoA core plus a cold side-table keyed by the same index. Columnar formats (Arrow, Parquet, dataframes) are already SoA — work with their columns directly rather than materializing rows.

## Working method

Optimization without measurement is guessing. Every change follows this loop:

1. **Baseline.** Establish a reproducible benchmark on realistic data sizes before changing anything. Record the numbers that matter (throughput, p50/p99 latency, allocations, peak memory).
2. **Profile.** Find where time actually goes, with a sampling profiler and, for layout questions, cache-miss counters. Don't optimize what isn't hot. The language reference lists tools.
3. **Hypothesize in data terms.** "This loop misses cache because each node is a separate heap allocation" — not "this function is slow."
4. **Change one thing.** Apply one of the four moves above.
5. **Measure again.** Same benchmark, same machine. Keep the change only if it wins meaningfully; revert otherwise. Run enough iterations to trust the delta over the noise.
6. **Verify correctness.** Layout changes are easy to get subtly wrong (off-by-one indices, bit-packing overflow, stale indices after removal). Existing tests must pass; add tests for the new invariants.

## How to report

When proposing or finishing optimization work, present:

- **What was hot** (from the profile, with numbers).
- **The data-layout diagnosis** — what was being loaded, chased, or hashed that didn't need to be.
- **The change**, framed by which of the four moves it applies.
- **Before/after numbers** from the same benchmark.
- **Trade-offs** — added complexity, invariants others must now respect, any regressions on non-hot paths, and any cache you kept and why.

Prefer a few large structural wins over a long list of micro-tweaks. If the profile shows the code is already layout-sound and the time is in genuinely necessary work, say so rather than inventing changes.

