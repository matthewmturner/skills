# Rust

## Contents
1. Typed indices and interning
2. Hash map → flat array
3. Pointers → indices (arena)
4. Packing hot data into index bits
5. AoS → SoA
6. Hot/cold split
7. Rust-specific notes
8. Profiling and benchmarking tools

## 1. Typed indices and interning

```rust
#[derive(Copy, Clone, PartialEq, Eq, Hash, Debug)]
pub struct SymbolId(u32);

#[derive(Default)]
pub struct Interner {
    lookup: HashMap<Box<str>, SymbolId>, // only touched at ingest
    names: Vec<Box<str>>,                // id -> name, for display
}

impl Interner {
    pub fn intern(&mut self, s: &str) -> SymbolId {
        if let Some(&id) = self.lookup.get(s) { return id; }
        let id = SymbolId(u32::try_from(self.names.len()).expect("too many symbols"));
        self.names.push(s.into());
        self.lookup.insert(s.into(), id);
        id
    }
    pub fn name(&self, id: SymbolId) -> &str { &self.names[id.0 as usize] }
    pub fn len(&self) -> usize { self.names.len() }
}
```

## 2. Hash map → flat array

```rust
// Before
let mut last_price: HashMap<SymbolId, f64> = HashMap::new();
for t in &trades { last_price.insert(t.symbol, t.price); }

// After (IDs are dense)
let mut last_price = vec![f64::NAN; interner.len()];
for t in &trades { last_price[t.symbol.0 as usize] = t.price; }
```

If a map must survive, prefer `hashbrown`/`std` with a fast hasher (`ahash`, `rustc-hash`/`FxHashMap`) over the default SipHash for trusted keys.

## 3. Pointers → indices (arena)

```rust
// Before: one heap allocation per node, pointer chasing on traversal
struct Node { value: i64, children: Vec<Box<Node>> }

// After: parallel arrays, u32 links (u32::MAX = none)
pub struct Tree {
    value: Vec<i64>,
    first_child: Vec<u32>,
    next_sibling: Vec<u32>,
}
```

Indices are `Copy` and sidestep borrow-checker fights that `Rc<RefCell<_>>` graphs cause. For removal, use a free list or tombstones; if IDs escape the owning structure, add a generation counter (the `slotmap` crate does this) so stale IDs are detectable.

## 4. Packing hot data into index bits

```rust
/// Layout: [ kind: 8 bits | index: 24 bits ]
#[derive(Copy, Clone, PartialEq, Eq)]
pub struct Ref(u32);

impl Ref {
    const INDEX_BITS: u32 = 24;
    const INDEX_MASK: u32 = (1 << Self::INDEX_BITS) - 1;
    pub const MAX_INDEX: u32 = Self::INDEX_MASK;

    pub fn new(kind: Kind, index: u32) -> Self {
        assert!(index <= Self::MAX_INDEX, "index overflows 24 bits");
        Ref(((kind as u32) << Self::INDEX_BITS) | index)
    }
    #[inline] pub fn kind(self) -> Kind { Kind::from_u8((self.0 >> Self::INDEX_BITS) as u8) }
    #[inline] pub fn index(self) -> usize { (self.0 & Self::INDEX_MASK) as usize }
}
```

Add a round-trip test over every `Kind` and the boundary indices.

## 5. AoS → SoA

```rust
// Before: 40-byte records, loop uses 16 bytes of each
struct Quote { ts: i64, bid: f64, ask: f64, bid_sz: u32, ask_sz: u32, venue: u16, flags: u16 }
fn mid_sum(q: &[Quote]) -> f64 { q.iter().map(|q| (q.bid + q.ask) * 0.5).sum() }

// After
struct Quotes { ts: Vec<i64>, bid: Vec<f64>, ask: Vec<f64>, bid_sz: Vec<u32>, ask_sz: Vec<u32>, venue: Vec<u16>, flags: Vec<u16> }
fn mid_sum(q: &Quotes) -> f64 {
    q.bid.iter().zip(&q.ask).map(|(b, a)| (b + a) * 0.5).sum()
}
```

The `soa_derive` crate generates the SoA struct from an AoS definition. With Arrow data, operate on `Float64Array::values()` slices or `arrow::compute` kernels directly instead of building row structs; in DataFusion, stay in `RecordBatch`/`ArrayRef` space.

## 6. Hot/cold split

```rust
struct Hot  { price: Vec<f64>, qty: Vec<u32>, side: Vec<u8> }            // scanned every tick
struct Cold { client_tag: Vec<String>, notes: Vec<Option<String>> }     // read on audit
```

## 7. Rust-specific notes

- Watch for hidden allocation: `clone()` on `String`/`Vec` in loops, `collect()` into temporaries, `format!` in hot paths. Reuse buffers (`clear()` keeps capacity).
- `Vec<Option<u32>>` is 8 bytes per element; a sentinel (`u32::MAX`) or `Option<NonZeroU32>` gets it back to 4.
- Check struct size with `std::mem::size_of` in a test; reorder fields or split if padding is large (Rust reorders by default, `#[repr(C)]` does not).
- Bounds checks rarely matter, but if the profile says they do, iterate with zip/chunks instead of indexing, or hoist an `assert!(i < len)` so LLVM can elide them.
- `Arc` refcount traffic across threads can dominate; pass `&T` or indices instead.
- In async (Tokio) code, look at per-task allocation and channel hops before micro-optimizing compute.

## 8. Profiling and benchmarking tools

- Benchmarks: `criterion` or `divan`; build with `--release` and `debug = true` in the profile for symbols.
- CPU: `perf record -g` + `cargo flamegraph`, `samply`.
- Cache behavior: `perf stat -e cache-misses,cache-references,L1-dcache-load-misses`, `valgrind --tool=cachegrind`.
- Allocation: `dhat` (crate), heaptrack.
- Codegen: `cargo asm` / `cargo show-asm` to confirm vectorization.

