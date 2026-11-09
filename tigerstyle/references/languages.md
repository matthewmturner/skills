# Language Translations and Mechanical Checks

Use `rg`. Scope each command to the changed files for a PR, or to the source root for a repo.
Exclude vendored, generated, and test-fixture directories.

Set the file list for a PR:

```bash
gh pr diff <n> --name-only > files.txt     # or: git diff --name-only <base>...HEAD > files.txt
```

Put `files.txt` in a scratch directory. The commands below read it through `xargs`,
so they work in bash, zsh, and fish.

## Language-Neutral Checks

### Lines over 100 columns

```bash
xargs rg -n --pcre2 '^.{101,}$' < files.txt
```

For a PR, count only added lines:

```bash
gh pr diff <n> | rg '^\+[^+]' | awk 'length($0) > 101' | wc -l
```

### TODO / FIXME in added code

```bash
gh pr diff <n> | rg -n '^\+.*\b(TODO|FIXME|HACK|XXX)\b'
```

### New dependencies

```bash
gh pr diff <n> --name-only | rg '(^|/)(Cargo\.toml|go\.mod|package\.json|pyproject\.toml|requirements.*\.txt|build\.zig\.zon|CMakeLists\.txt)$'
```

Then read the diff of each matched file for added entries.

### Function length

Function length needs a parser. Use the tool for the language below when it is installed.
Do not install a tool. If none is available, read the changed functions and estimate.
State in the output that the count is an estimate.

## Per-Language Table

| Rule | Zig | Rust | Go | C / C++ | TypeScript / JS | Python |
|---|---|---|---|---|---|---|
| S1 assert | `assert`, `comptime assert` | `assert!`, `debug_assert!`, `const _: () = assert!(..)` | `if !cond { panic(..) }` | `assert`, `static_assert` | `assert` / `node:assert`, `console.assert` is weak | `assert` (stripped by `-O`; flag for critical checks) |
| S3 bounds | `while (true)` | `loop {}`, unbounded `mpsc::channel()` | `for {}`, unbuffered goroutine fan-out | `while (1)`, `for (;;)` | `while (true)`, unbounded arrays from input | `while True:` |
| S5 alloc | allocator calls after `init` | `Vec::new`/`push`, `Box::new`, `String` in hot path; prefer `with_capacity` at init | `make`/`append` in hot path, escape to heap | `malloc`/`new` after init | object/array literals in hot loops | list/dict growth in hot loops |
| S6 types | avoid `usize` in data | avoid `usize` in wire/disk types | avoid `int` in wire/disk types | `uint32_t` over `int`/`size_t` in data | `number` for 64-bit IDs is a defect (use `bigint`) | `struct` formats with explicit widths |
| S9 warnings | — | `#![deny(warnings)]`, `clippy::pedantic`; flag `#[allow]` | `go vet`, `staticcheck`; flag `//nolint` | `-Wall -Wextra -Werror`; flag `#pragma` disables | `strict: true`; flag `@ts-ignore`, `any` | `mypy --strict`, `ruff`; flag `# type: ignore`, `# noqa` |
| S12 errors | `catch {}`, `_ = try` | `let _ =`, `.ok()`, `unwrap()` on I/O | `_ = f()`, `if err != nil { log; }` and continue | unchecked return codes | empty `catch`, floating promises | `except: pass`, bare `except` |
| D6 args | options struct | struct or newtype | struct | struct | object param | keyword-only args (`*`) |
| D9 byref | `*const T` | `&T` | pointer for large structs | `const T *` | n/a | n/a |
| D12 suspend | `suspend` | `.await` between check and use | channel op between check and use | n/a | `await` between check and use | `await` between check and use |
| D16 format | `zig fmt` | `rustfmt` | `gofmt` | `clang-format` | `prettier` / `biome` | `ruff format` / `black` |

Naming (D1) follows the language convention when it conflicts with TigerStyle (for example
Go `camelCase`, TS `camelCase`). Apply the intent: no abbreviations, units last, nouns, symmetry.

## Per-Language Commands

### Zig

```bash
xargs rg -c '\bassert\(' < files.txt                                  # assertions per file
xargs rg -n 'while \(true\)' < files.txt                              # unbounded loops
xargs rg -n '\busize\b' < files.txt                                   # arch-sized ints
xargs rg -n '\.(alloc|create|realloc|dupe)\(' < files.txt             # allocation sites
xargs rg -n 'catch \{\s*\}|catch unreachable' < files.txt             # swallowed errors
```

### Rust

```bash
xargs rg -c '\b(debug_)?assert(_eq|_ne)?!' < files.txt
xargs rg -n '^\s*loop\s*\{' < files.txt
xargs rg -n '\busize\b' < files.txt
xargs rg -n 'Vec::new\(\)|vec!\[|Box::new|String::new|\.to_string\(\)|\.clone\(\)' < files.txt
xargs rg -n 'let _ =|\.ok\(\);|\.unwrap\(\)|\.expect\(' < files.txt
xargs rg -n '#\[allow\(' < files.txt
xargs rg -n 'unbounded_channel|mpsc::channel\(\)' < files.txt
```

Function length with `tree-sitter` or `rust-analyzer` if present. Otherwise:

```bash
xargs awk '/^\s*(pub )?(async )?fn /{name=$0; start=FNR} /^\s*\}$/ && start {if (FNR-start>70) print FILENAME":"start": "FNR-start" lines: "name; start=0}' < files.txt
```

This heuristic misses nested closures. Confirm each hit by reading.

### Go

```bash
xargs rg -c 'panic\(' < files.txt
xargs rg -n '^\s*for\s*\{' < files.txt
xargs rg -n '_\s*=\s*\w+\(|_\s*,\s*_\s*=' < files.txt
xargs rg -n 'if err != nil \{\s*$' -A2 < files.txt | rg -n 'log\.' # log-and-continue candidates
xargs rg -n '//\s*nolint' < files.txt
xargs rg -n 'make\(chan [^,]+\)' < files.txt                      # unbuffered or unbounded channel use
```

If `gocyclo` or `funlen` (via `golangci-lint`) is installed, use them for function length.

### C / C++

```bash
xargs rg -c '\b(assert|static_assert)\s*\(' < files.txt
xargs rg -n 'while\s*\(\s*1\s*\)|for\s*\(\s*;\s*;\s*\)' < files.txt
xargs rg -n '\b(malloc|calloc|realloc|free|new|delete)\b' < files.txt
xargs rg -n '#pragma\s+(GCC|clang)\s+diagnostic\s+ignored' < files.txt
```

Use `lizard` for function length and complexity if installed.

### TypeScript / JavaScript

```bash
xargs rg -c '\bassert(\.\w+)?\(|invariant\(' < files.txt
xargs rg -n 'while\s*\(\s*true\s*\)' < files.txt
xargs rg -n 'catch\s*(\(\w*\))?\s*\{\s*\}' < files.txt
xargs rg -n '@ts-ignore|@ts-expect-error|:\s*any\b|as any' < files.txt
xargs rg -n '^\s*(?!await|return)\w+\.then\(' --pcre2 < files.txt    # floating promises (heuristic)
```

Use `eslint` with `max-lines-per-function` if the repo already has eslint.

### Python

```bash
xargs rg -c '^\s*assert\b' < files.txt
xargs rg -n 'while\s+True\s*:' < files.txt
xargs rg -n 'except\s*(Exception)?\s*:\s*$' -A1 < files.txt | rg 'pass'
xargs rg -n '#\s*(type:\s*ignore|noqa)' < files.txt
xargs rg -n '^\s*def \w+\(.*\b(\w+)\s*=\s*(\[\]|\{\})' < files.txt     # mutable defaults
```

Use `radon cc` or `ruff --select C901,PLR0915` for function length and complexity if installed.

## Assertion Density

Compute: assertions in changed functions divided by changed functions. A file-level ratio
(assertion lines / function count) is an acceptable approximation. State which one you used.
