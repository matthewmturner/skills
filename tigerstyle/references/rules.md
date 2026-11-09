# TigerStyle Rule Checklist

Condensed from [TIGER_STYLE.md](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md).
Each rule has a short ID for findings. Each rule has a "Look for" list of concrete review signals.

## Safety (S)

Source: NASA Power of Ten, extended by TigerBeetle.

### S1 assert — Assertion density and quality

Assertions detect programmer errors. Operating errors are expected and must be handled.
Assertion failures are not expected. The only correct response to corrupt state is to crash.
Assertions turn correctness bugs into liveness bugs and multiply fuzzing power.

- Average at least **two assertions per function**.
- Assert arguments, return values, preconditions, postconditions, and invariants.
- **Split compound assertions:** `assert(a); assert(b);` over `assert(a && b);`.
- Use `if (a) assert(b)` to assert an implication.
- A blatantly true assertion can replace a comment when the condition is critical and surprising.
- Assertions are a safety net, not a replacement for understanding. Do not trust the fuzzer alone.

Look for:
- Functions that take an index, length, or ID and use it without a check.
- `assert(x && y)` or `debug_assert!(a && b)`.
- Assertions that are compiled out in release builds on critical paths, without a reason.
- Assertions used to validate external input. That is an operating error. Handle it.
- Error returns used for a state that is a programmer bug. That should assert.

### S2 pair — Pair assertions, positive and negative space

- For each property, assert it on at least two different code paths. Example: assert validity
  before a write to disk and again after a read from disk.
- Assert the **positive space** (what you expect) and the **negative space** (what you do not
  expect). Bugs live at the valid/invalid boundary.
- Tests must cover valid data, invalid data, and the transition from valid to invalid.

Look for:
- Serialization without a matching check at deserialization.
- An `if` with no `else` where the negative case must be handled or asserted.
- Tests that cover only the happy path.

### S3 bounds — Put a limit on everything

- Every loop and every queue has a fixed upper bound.
- A loop that must not terminate (an event loop) asserts that.
- Retries, buffers, batch sizes, connection pools, recursion depth, and message sizes have
  explicit maximums.

Look for:
- `while (true)`, `loop {}`, `for {}`, `while queue:` with no counter or limit.
- Unbounded channels, `Vec`/`list`/`slice` appends driven by external input.
- Retry loops without a max attempt count or deadline.
- Reads of a length prefix from the network without a maximum.

### S4 recursion — No recursion

All executions that should be bounded must be bounded. Recursion hides the bound.

Look for:
- Direct or mutual recursion, especially over trees, JSON, or user-controlled depth.
- Fix: an explicit stack with a fixed capacity, or iteration.

### S5 alloc — Static allocation

All memory is allocated at startup. No allocation, free, or reallocation after init.
Side effect: designs that consider all memory up front are simpler and faster.

Look for:
- Allocation in the request path, the hot loop, or per event.
- Growable containers without a capacity reserved at init.
- Proportional reading: in GC languages or non-critical code, flag allocation in hot paths
  and unbounded growth. Do not flag every allocation.

### S6 types — Explicitly-sized types

Use `u32`, `i64`, and similar. Avoid architecture-dependent `usize`/`int`/`size_t` for stored
or serialized values.

Look for:
- `usize`, `int`, `long`, `size_t` in wire formats, on-disk structs, or IDs.
- Implicit narrowing or widening casts without a check.

### S7 scope — Smallest scope, fewest variables

Look for:
- Variables declared far above their use.
- Many live variables in one block.
- A check far from the use (place-of-check to place-of-use gap, POCPOU).

### S8 fnlen — 70-line function limit

- Hard limit of 70 lines per function.
- Good shape is an inverted hourglass: few parameters, simple return type, dense body.
- **Push `if`s up and `for`s down.** Keep control flow in the parent. Helpers are non-branchy.
- Centralize state change in the parent. Helpers compute; the parent applies. Keep leaves pure.

Look for:
- Functions over 70 lines.
- Helpers that both branch and mutate shared state.
- A split that moved lines but not responsibility.

### S9 warnings — Strictest compiler warnings

Look for:
- Disabled lints, `#[allow(...)]`, `// nolint`, `@ts-ignore`, `# type: ignore`, `-Wno-*`
  without a "why" comment.
- Missing strict settings in build config (`-Wall -Wextra -Werror`, `clippy::pedantic`,
  `strict: true`, `mypy --strict`).

### S10 pace — Run at your own pace

Do not act directly in reaction to external events. Queue, then process in batches on your
own schedule. This keeps control flow in your hands and bounds work per time period.

Look for:
- Work done inside a network callback or signal handler.
- Per-event fsync, per-message DB write, per-request context switch.

### S11 control — Simple, explicit control flow

- Split compound conditions into nested `if/else`.
- Split long `else if` chains into `else { if { } }` trees when cases interact.
- Every `if` should ask: does it need an `else` that handles or asserts the negative space?
- State invariants positively: `if (index < count)` over `if (index >= count)`.
- Use only a minimum of excellent abstractions. Abstractions are never zero cost.

Look for:
- `if a && !b || c` style conditions.
- Negated guards that obscure the invariant.
- Indirection layers (interfaces, generics, DI, macros) with one implementation.

### S12 errors — Handle all errors

92% of catastrophic failures in distributed systems come from wrong handling of non-fatal
errors (Yuan et al., OSDI 2014).

Look for:
- Swallowed errors: `_ = f()`, `catch {}`, `except: pass`, `.ok()`, `unwrap_or_default()` on
  a meaningful failure, empty `catch` blocks, ignored `err`.
- Error paths with no test.
- Log-and-continue where the state is now invalid.

### S13 why — Always say why

Look for:
- Non-obvious constants, magic numbers, odd orderings, or workarounds with no comment.
- Commit messages that state what but not why. A PR description is not in `git blame`.

### S14 defaults — Pass options explicitly

Do not rely on library defaults at the call site. A default can change in a later version.

Look for:
- Calls with consequential defaults left implicit: timeouts, TLS verify, fsync mode,
  isolation level, buffer sizes, retry policy, encoding, rounding mode.

## Performance (P)

### P1 design — Performance at design time

The 1000x wins come at design time, when you cannot profile. Use mechanical sympathy.

Look for:
- A new data path with no stated expected size, rate, or latency.
- An algorithm with worse complexity than the problem needs.

### P2 envelope — Back-of-the-envelope sketch

Sketch the four resources (network, disk, memory, CPU) and their two characteristics
(bandwidth, latency). Aim to be roughly right.

Look for:
- Missing sketch for a change to a hot path, storage format, or protocol.
- Write the sketch yourself in the review when the author did not.

### P3 slowest — Optimize the slowest resource first

Order: network, disk, memory, CPU, adjusted for frequency. A cache miss repeated a million
times can cost more than one fsync.

### P4 planes — Separate control plane and data plane

Batching on the data plane allows heavy assertions on the control plane with no throughput loss.

### P5 batch — Amortize by batching

Look for:
- N+1 queries, per-item syscalls, per-item network round trips, per-item locks.
- Small writes that can be coalesced.

### P6 sprinter — Predictable work for the CPU

Give the CPU large, predictable chunks. Avoid branchy, pointer-chasing inner loops.

### P7 explicit — Do not depend on the optimizer

Extract hot loops into standalone functions with primitive arguments, no `self`. The compiler
does not need to prove field caching, and the reader sees redundant work.

## Developer Experience (D)

### D1 names — Nouns and verbs just right

- `snake_case` for functions, variables, and files (or the language's convention if it differs).
- No abbreviations, except primitive integers in sort or matrix code.
- Proper acronym case: `VSRState`, not `VsrState` (follow language convention when it conflicts).
- Long-form flags in scripts: `--force`, not `-f`.
- Do not overload a name with two context-dependent meanings.
- Prefer nouns: `pipeline` over `preparing`. Nouns compose: `pipeline_max`.
- Infuse meaning: `arena` and `gpa` over `allocator`.

### D2 units — Units and qualifiers last

`latency_ms_max`, not `max_latency_ms`. Most significant word first.

Look for:
- Durations, sizes, and counts with no unit in the name.
- Qualifier-first names: `max_*`, `min_*`, `num_*`.

### D3 symmetry — Equal-length related names

`source`/`target` over `src`/`dest`, so `source_offset` and `target_offset` line up.

### D4 callbacks — Helper and callback naming and order

- Prefix helpers with the caller name: `read_sector()` and `read_sector_callback()`.
- Callbacks go last in the parameter list.

### D5 order — Order for the reader

- Important things first. `main` first.
- Structs: fields, then types, then methods.

### D6 args — Named arguments when they can be mixed up

A function that takes two arguments of the same primitive type must use an options struct,
keyword arguments, or distinct types. Name nullable arguments so that `null` at the call site
is clear.

### D7 comments — Comments are sentences

Capital letter, full stop, space after the comment marker. Explain why and how. Tests have a
header that states goal and method.

### D8 alias — No duplicate state, no aliases

Do not copy a variable or keep two sources of truth. Caches are a common example.

### D9 byref — Pass large arguments by const reference

Arguments over 16 bytes that must not be copied go by const pointer or reference.

### D10 inplace — In-place init for large structs

Initialize large structs through an out pointer. This gives pointer stability and avoids stack
copies. In-place init is viral to the container.

### D11 signature — Simpler return types

`void` > `bool` > `u64` > `?u64` > `!u64`. Each step adds branches at every call site.

### D12 suspend — Run to completion

A function with precondition assertions must not suspend (`await`, yield) between the check
and the use. Otherwise the assertion is misleading.

### D13 bleed — Buffer bleeds

A buffer not fully written, with padding not zeroed, leaks data and breaks determinism.

Look for:
- Buffers sent or persisted with uninitialized tail bytes or struct padding.

### D14 resources — Group allocation and release

Use blank lines to group an acquire with its `defer`/`finally`/RAII release so leaks are visible.

### D15 offbyone — Index, count, size

`index`, `count`, and `size` are distinct types. index + 1 = count. count * unit = size.
Show division intent: exact, floor, or ceil.

Look for:
- Mixed `i`, `len`, `n`, `size` with no unit in the name.
- Plain `/` where rounding direction matters.

### D16 format — Style by the numbers

- Run the language formatter.
- 4-space indent (or the language standard).
- Hard limit of 100 columns.
- Braces on every `if` unless it fits on one line.

## Dependencies and Tooling (T)

### T1 deps — Zero dependencies

Every dependency adds supply chain, safety, performance, and install cost. Infrastructure
amplifies that cost.

Look for:
- New dependencies in the diff (`Cargo.toml`, `go.mod`, `package.json`, `pyproject.toml`,
  `requirements*.txt`, `build.zig.zon`, `CMakeLists.txt`, vendored code).
- Ask: can 50 lines of local code replace it? What does it pull in transitively?

### T2 tools — Small standard toolbox

Prefer the primary language for scripts over shell. New tools have a higher cost than they
appear to have.

Look for:
- New shell scripts, new build tools, new linters, or new languages added to the repo.

## Zero Technical Debt (Z)

### Z1 debt — Do it right the first time

Showstoppers do not pass: memcpy latency spikes, exponential algorithms, unbounded resources.

Look for:
- `TODO`, `FIXME`, `HACK`, or "follow-up" notes on a safety or performance issue in the diff.
