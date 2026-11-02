# Go

In Go, data-oriented layout pays twice: better cache behavior *and* less garbage-collector work. Slices of pointer-free types are not scanned by the GC, so replacing pointer graphs with indices can cut GC CPU dramatically.

## Contents
1. Typed indices and interning
2. Map → slice
3. Pointers → indices
4. Packing hot data into index bits
5. AoS → SoA
6. Go-specific notes
7. Profiling tools

## 1. Typed indices and interning

```go
type SymbolID uint32

type Interner struct {
    lookup map[string]SymbolID // ingest only
    names  []string
}

func (in *Interner) Intern(s string) SymbolID {
    if id, ok := in.lookup[s]; ok {
        return id
    }
    id := SymbolID(len(in.names))
    in.names = append(in.names, s)
    in.lookup[s] = id
    return id
}
```

Go 1.23+ also has `unique.Make` for canonicalized handles, but dense integer IDs are what enable the array moves below.

## 2. Map → slice

```go
// Before
lastPrice := map[SymbolID]float64{}
// After
lastPrice := make([]float64, len(in.names))
for _, t := range trades {
    lastPrice[t.Symbol] = t.Price
}
```

## 3. Pointers → indices

```go
// Before: every *Node is a GC-tracked heap object
type Node struct {
    Value    int64
    Children []*Node
}

// After: pointer-free slices, invisible to the GC scanner
const None = ^uint32(0)

type Tree struct {
    Value       []int64
    FirstChild  []uint32
    NextSibling []uint32
}
```

## 4. Packing hot data into index bits

```go
// Layout: [ kind: 8 | index: 24 ]
type Ref uint32

const (
    indexBits = 24
    indexMask = 1<<indexBits - 1
)

func MakeRef(k Kind, index uint32) Ref {
    if index > indexMask {
        panic("index overflows 24 bits")
    }
    return Ref(uint32(k)<<indexBits | index)
}
func (r Ref) Kind() Kind    { return Kind(r >> indexBits) }
func (r Ref) Index() uint32 { return uint32(r) & indexMask }
```

## 5. AoS → SoA

```go
// Before
type Quote struct {
    TS       int64
    Bid, Ask float64
    BidSz    uint32
    AskSz    uint32
    Venue    uint16
    Flags    uint16
}

// After
type Quotes struct {
    TS           []int64
    Bid, Ask     []float64
    BidSz, AskSz []uint32
    Venue, Flags []uint16
}

func MidSum(q *Quotes) float64 {
    var s float64
    ask := q.Ask[:len(q.Bid)] // hint for bounds-check elimination
    for i, b := range q.Bid {
        s += (b + ask[i]) * 0.5
    }
    return s
}
```

## 6. Go-specific notes

- Interfaces in hot loops mean dynamic dispatch and often heap escapes; batch by concrete type.
- Check escapes with `go build -gcflags=-m`; values that escape to the heap are GC load.
- `[]*T` vs `[]T`: prefer the latter; it's contiguous and, if `T` is pointer-free, unscanned.
- Order struct fields large-to-small to reduce padding (`fieldalignment` vet analyzer reports it).
- `sync.Pool` is a cache; apply the same scrutiny — first ask why so much is being allocated.
- Strings and slices contain pointers; a `[]string` column is still GC-scanned. Interned IDs avoid that.

## 7. Profiling tools

- Benchmarks: `go test -bench . -benchmem -count 10`, compare with `benchstat`.
- CPU/heap: `pprof` (`go test -cpuprofile`, `-memprofile`, or `net/http/pprof`), `go tool pprof -http`.
- GC: `GODEBUG=gctrace=1`, `go tool trace`.
- Cache: Linux `perf stat` works on Go binaries.

