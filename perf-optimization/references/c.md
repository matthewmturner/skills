# C

## Contents
1. Typed indices and interning
2. Hash table → flat array
3. Pointers → indices (arena)
4. Packing hot data into index bits
5. AoS → SoA
6. Hot/cold split
7. C-specific notes
8. Profiling and benchmarking tools

## 1. Typed indices and interning

Wrap indices in single-member structs so the compiler rejects mixing them up, at zero runtime cost:

```c
typedef struct { uint32_t v; } SymbolId;
typedef struct { uint32_t v; } NodeId;
```

Intern strings once at ingest. Any open-addressing table works for the lookup side; the key point is that the ID is the dense position in `names`:

```c
typedef struct {
    StrMap   lookup;   /* string -> uint32_t, ingest only */
    char   **names;    /* id -> name */
    uint32_t len, cap;
} Interner;

SymbolId intern(Interner *in, const char *s) {
    uint32_t id;
    if (strmap_get(&in->lookup, s, &id)) return (SymbolId){id};
    if (in->len == in->cap) grow(in);              /* realloc names, doubling */
    id = in->len++;
    in->names[id] = strdup(s);
    strmap_put(&in->lookup, in->names[id], id);
    return (SymbolId){id};
}
```

## 2. Hash table → flat array

```c
/* Before: hash lookup per trade */
/* hashmap_put(&last_price, t->symbol, t->price); */

/* After: dense IDs index a plain array */
double *last_price = malloc(in.len * sizeof *last_price);
for (uint32_t i = 0; i < in.len; i++) last_price[i] = NAN;
for (size_t i = 0; i < n_trades; i++)
    last_price[trades[i].symbol.v] = trades[i].price;
```

If a table must survive, use open addressing with linear probing and a power-of-two capacity, not chained buckets of malloc'd nodes.

## 3. Pointers → indices (arena)

```c
/* Before: one malloc per node, pointer chasing on traversal */
typedef struct Node { int64_t value; struct Node *first_child, *next_sibling; } Node;

/* After: parallel arrays with uint32_t links */
#define NONE UINT32_MAX
typedef struct {
    int64_t  *value;
    uint32_t *first_child;
    uint32_t *next_sibling;
    uint32_t  len, cap;
} Tree;
```

Indices stay valid when the arrays are `realloc`'d; pointers into them do not, which removes a whole class of use-after-realloc bugs. For removal, keep a free list threaded through `next_sibling`, and add a generation counter if IDs leave the owning structure.

## 4. Packing hot data into index bits

Don't use bitfields for this: their layout is implementation-defined. Use explicit masks behind inline accessors.

```c
/* Layout: [ kind: 8 | index: 24 ] */
typedef struct { uint32_t bits; } Ref;

enum { REF_INDEX_BITS = 24 };
#define REF_INDEX_MASK ((UINT32_C(1) << REF_INDEX_BITS) - 1)

static inline Ref ref_make(uint8_t kind, uint32_t index) {
    assert(index <= REF_INDEX_MASK);
    return (Ref){ ((uint32_t)kind << REF_INDEX_BITS) | index };
}
static inline uint8_t  ref_kind(Ref r)  { return (uint8_t)(r.bits >> REF_INDEX_BITS); }
static inline uint32_t ref_index(Ref r) { return r.bits & REF_INDEX_MASK; }

_Static_assert(sizeof(Ref) == 4, "Ref must stay 4 bytes");
```

`assert` vanishes under `NDEBUG`, so also validate at ingest if real data can exceed the range.

## 5. AoS → SoA

```c
/* Before: 40-byte records, the loop uses 16 bytes of each */
typedef struct { int64_t ts; double bid, ask; uint32_t bid_sz, ask_sz; uint16_t venue, flags; } Quote;

/* After */
typedef struct {
    int64_t  *ts;
    double   *bid, *ask;
    uint32_t *bid_sz, *ask_sz;
    uint16_t *venue, *flags;
    size_t    len;
} Quotes;

double mid_sum(const double *restrict bid, const double *restrict ask, size_t n) {
    double s = 0;
    for (size_t i = 0; i < n; i++) s += (bid[i] + ask[i]) * 0.5;
    return s;
}
```

`restrict` tells the compiler the columns don't alias, which is often what unlocks vectorization. (Floating-point reductions only vectorize with `-ffast-math` or `-fassociative-math`, or with manual multiple accumulators.)

## 6. Hot/cold split

```c
typedef struct { double *price; uint32_t *qty; uint8_t *side; } OrdersHot;   /* scanned every tick */
typedef struct { char **client_tag; char **notes; } OrdersCold;             /* read on audit */
/* same index into both */
```

## 7. C-specific notes

- Many small `malloc`s are a layout problem as much as a speed problem; use a bump/arena allocator per batch or request and free it in one shot.
- Function pointers per element (hand-rolled vtables) defeat batching; group items by kind and run a tight loop per kind.
- Linked lists and tree nodes allocated individually are the classic pointer-chasing case; prefer arrays plus indices.
- Check struct sizes with `_Static_assert(sizeof(...) == N, ...)` and order fields large-to-small to minimize padding.
- Pad per-thread counters to 64 bytes (`_Alignas(64)`) to avoid false sharing.
- Confirm vectorization with `-fopt-info-vec` (GCC) or `-Rpass=loop-vectorize` (Clang).

## 8. Profiling and benchmarking tools

- Benchmarks: a small harness using `clock_gettime(CLOCK_MONOTONIC)` with warmup and many iterations, or `hyperfine` for whole-program runs.
- CPU: `perf record -g` with flamegraphs, Tracy for instrumented frames.
- Cache: `perf stat -e cache-misses,cache-references,L1-dcache-load-misses`, `valgrind --tool=cachegrind`, `perf c2c` for false sharing.
- Allocation: heaptrack, `valgrind --tool=massif`.
- Codegen: Compiler Explorer (godbolt), `objdump -d`.

