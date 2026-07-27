# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`getaca` is an R package: one engine that retrieves, verifies, caches and garbage-collects
the large external data files other packages *declare* they need. Declaring packages ship
`inst/getaca/registry.rds` and contain no download logic of their own.

## Commands

Dev loop scripts live in `dev_notes/` and are the intended entry points (never
`Rscript -e '...'` inline on Windows). Run from the package root:

```bash
Rscript dev_notes/dev.R          # document() then test()
Rscript dev_notes/build.R        # roxygenise(clean) + load_all + test
Rscript dev_notes/doc.R          # roxygen only
Rscript dev_notes/chk.R          # devtools::check(cran = TRUE, --as-cran)
Rscript dev_notes/cov.R          # covr, with every uncovered line printed
Rscript dev_notes/vignettes.R    # knit each vignette in isolation
Rscript dev_notes/site.R         # pkgdown into docs/ via ~/.R/build_pkgdown.R
```

`build.R`, `check.R`, `coverage.R` and `site.R` hardcode `C:/GillesC/Documents/dev/getaca`;
the others are path-free and want the package root as cwd.

One file, one test:

```r
devtools::load_all(); testthat::test_file("tests/testthat/test-resolve.R")
devtools::test(filter = "resolve")           # matches test-resolve.R
```

Regenerate the network fixture (see Testing below):

```bash
Rscript tests/testthat/fixtures/make-remote-registry.R
```

CI runs `R-CMD-check` on a six-row matrix (macOS release, Windows release, Ubuntu
r-devel, release, `oldrel-1` and `oldrel-2`) and a separate coverage job that sets
`NOT_CRAN: true`, which is the only place the live-network tests execute. The
`oldrel` rows are what hold the `Depends: R (>= 4.0.0)` floor honest, since the only
R installed locally is far above it.

A third workflow, `sanitizers.yaml`, runs the tests inside the five R-hub containers
CRAN's own incoming checks use: `clang-asan`, `gcc-asan`, `clang-ubsan`, `valgrind`
and `rchk`. `R CMD check` does not look for a bad memory access or an undefined
shift, and `test-digest.R` and `test-ed25519.R` only catch a wrong answer, so this
is the only place the C is held to anything but its output. Each container ships an
`r-check` script that greps its own diagnostics out of the check log; `rchk` only
prints, so the workflow greps that one itself. It also runs weekly, since R-devel
moves underneath the containers whether or not the package does.

## Architecture

One retrieval path, `getaca()` in `R/fetch.R`:

```
resolve_resource()   name -> immutable record, via the channel the policy selects
get_entry()          cached and intact? validate_cached() and return
                     policy == "offline" -> err_offline(), no network, ever
acquire_lock()       directory mutex keyed on the checksum; re-check after waiting
blob_exists()/adopt()  already in the store, or a slot copy that hashes right?
fetch_to_temp()      mirrors in order, into .tmp/, resumable per mirror
admit() + place()    bytes into blobs/, a named view into the version slot
apply_processor()    optional, into its own slot with its own provenance
put_entry()          provenance row; then gc_opportunistic()
```

Bytes live once, under their own digest, and a version slot holds a *view* of them:

```
<cache>/blobs/sha256/<aa>/<sha256>      the only place bytes live, read-only
        <package>/<name>/<version>/raw/<file>   a link into blobs/
```

Two packages declaring the same file keep one copy and two dependency records. The
store holds no metadata: liveness is reachability over the package indexes
(`live_blobs()`), never a reference count. See `dev_notes/adr-003-content-addressed-store.md`.

Two separations carry most of the design:

**Record vs channel.** A `resource()` record is immutable: `package/name@version` names
exact bytes forever. A *channel* (`registry$current`, the remote registry, a pin file) maps
a bare name onto one record and may move. `resolve_resource()` walks the channel; everything
downstream deals only in records. `assert_immutable()` in `R/resolve.R` is what refuses a
remote registry or pin file that redefines a published version.

**Adjudication vs transport.** `fetch_to_temp(transport = try_one)`, `remote_channel(fetch =
fetch_registry)`, `assert_signed(fetch = fetch_registry)`, `move_file(rename = file.rename)`
and `materialise(link = link_file)` all take the I/O as an argument. `signature_problem()`
goes further and takes no I/O at all: it is handed a parsed signature, a registry, a key set
and a clock, so every way a signature can fail is reachable without a file or a network. Which mirror to trust, which registry state wins, what a failed
rename means and what happens on a filesystem that refuses links are all testable without a
network or a second volume; only `test-network.R` moves real bytes.

| file | owns |
|---|---|
| `R/resource.R` | `resource()`, `resource_id()`, `processor()`, record validation |
| `R/registry.R` | `registry()` + validation, read/write, `registry_for()`, `as_registry()`, `getaca_refresh()` |
| `R/manifest.R` | canonical text form and `registry_digest()` |
| `R/resolve.R` | policy dispatch, remote channel, pin file, immutability assertion, signature gate |
| `R/signature.R` | Ed25519 key and signature files, `registry_sign()`, `registry_verify()`, the verification adjudication |
| `R/fetch.R` | `getaca()`, processor application, `getaca_info()`, `getaca_catalogue()`, prefetch |
| `R/download.R` | mirror loop, resume, HTTP failure classification, promotion |
| `R/store.R` | the content-addressed store: admit, materialise, seal, remove, reachability |
| `R/cache.R` | layout, per-package `index.rds`, entry records |
| `R/verify.R` | full re-hash, cheap size check, periodic re-verification |
| `R/gc.R` | the five retention sweeps |
| `R/lock.R` | portable directory mutex |
| `R/conditions.R` | the failure taxonomy |
| `R/options.R` | policy precedence, cache dir, retention settings |

## Invariants

Changing any of these is a design decision that belongs in a `dev_notes/adr-*.md`, not a bug fix.

1. A published `name@version` names fixed bytes. No path may accept a different checksum for
   an existing version. Two guards, because a declaration can move on either side of a fetch:
   `assert_immutable()` holds an incoming registry or pin file to what the bundled declaration
   and the cache already say, and `validate_cached()` refuses a cache hit whose declaration has
   moved since the bytes arrived. What counts as published includes anything already fetched,
   so a version that only ever existed in a remote registry is covered too.
2. A returned path is complete, verified, read-only, and in a slot getaca owns. Bytes reach
   the store only through `admit()`, after sizing and hashing in `.tmp/`.
3. Resolution collapses to `offline` under `R CMD check`. `in_r_check()` is checked inside
   `effective_policy()`, so no argument or option can route around it.
4. The keys that may vouch for a remote registry are the ones in the registry the *package
   ships*, never the ones in the registry that arrived. A declaration nominating the keys
   allowed to sign it would vouch for itself. `assert_signed()` in `R/resolve.R` reads
   `bundled$keys` for that reason, and a rotation therefore needs a release. See
   `dev_notes/adr-006-signed-registries.md`.
5. Unreachable and unverifiable are different failures. A remote that cannot be reached falls
   back to bundled with a message; a remote that arrives and fails its signature raises
   `getaca_error_signature`. A registry arriving without its signature is the second, since
   one host serves both, and treating it as an outage would let whoever serves it decide
   whether the check runs.

Policy precedence, in `effective_policy()`: check clamp / `GETACA_OFFLINE` → option
`getaca.policy` → env `GETACA_POLICY` → the registry's own `policy` → `"bundled"`. All other
settings go through `getaca_setting()`, which reads `getOption("getaca.<name>")` then
`GETACA_<NAME>`.

## Identity and versioning

- Resource identity is the triple `package / name / version`. Cache paths, lock names and
  index keys are all built from it; index keys append `#<processor-id>` for processed slots.
- Registry identity is `registry_digest()` = SHA-256 of `registry_manifest()`, a sorted,
  escaped, line-oriented rendering. Hashing the R object is not an option: a `processor()`
  holds a closure, which digests differently per machine.
- `created`, `policy` and `description` are deliberately outside the manifest. Editing any of
  them must not change a digest already recorded in someone's provenance.
- Three version counters move independently: `REGISTRY_SCHEMA` (`R/registry.R`) for the
  stored form, `MANIFEST_FORMAT` (`R/manifest.R`) for the rendering, and `SIGNATURE_FORMAT`
  (`R/signature.R`) for the detached signature file. A newer schema or signature format is
  refused; an older schema is read. Changing manifest rendering invalidates every digest ever
  recorded, so it needs the format bump and an ADR. Adding a field that renders nothing when
  absent does not, which is how signing keys joined the manifest at format 1.
- A resource name declaring more than one version must name a head in `current =`. A headless
  multi-version name is refused at `registry()`, on the author's machine.

## Failures

Every error is `getaca_error` plus a subclass, and carries `actor` (`"user"`, `"author"`,
`"upstream"`) so callers branch on cause, not message text. The interesting case is
`getaca_error_declaration`: when several mirrors agree with each other and disagree with the
registry, the registry is blamed rather than the network. Keep that discrimination intact
when touching the mirror loop in `R/download.R`.

## Testing conventions

- `local_cache()` points `getaca.cache` at a temp dir; every test that touches the cache calls
  it. Nothing may write to the real `R_user_dir`.
- `local_fetchable()` releases the check clamp, and any test that drives a fetch calls it
  first. Invariant 3 collapses resolution to `offline` under `R CMD check`, so without it a
  test reaching `getaca()` through an injected transport gets `err_offline()` rather than the
  behaviour it is asserting. `NOT_CRAN` is the only lever, by design. It is deliberately not
  folded into `local_cache()`: releasing the clamp is something a test states, never something
  it inherits from having asked for a cache, and a test asserting that the clamp *holds* sets
  the variables it needs itself. In `test-network.R` the release belongs to `online_only()`
  and must stay after its `skip_on_cran()`, which reads the same variable.
  A plain `R CMD check` with `NOT_CRAN` unset is what CRAN runs and what catches a test that
  forgot; `r-lib/actions` and `devtools::test()` both set it, so neither will.
- `local_registries()` clears the two session caches (`registry_cache` in `R/registry.R`,
  `remote_cache` in `R/resolve.R`) before and after. Any test resolving through a package or
  a remote needs it.
- `online_only()` skips on CRAN and offline, and sets `NOT_CRAN=true` to release the check
  clamp for the duration. It probes `raw.githubusercontent.com`, the host the fixtures are
  actually served from.
- Fixtures use `writeBin()`, not `writeLines()`: line-ending translation on Windows changes
  file sizes, and several tests assert exact sizes.
- Cached files are read-only, so a test that simulates corruption calls `corrupt()` and one
  that removes a cached path calls `getaca:::remove_path()`. A bare `writeBin()` or `unlink()`
  on a cache path fails silently on Windows.
- `test-network.R` fetches `tests/testthat/fixtures/remote-registry.rds` from the `main`
  branch on GitHub. Regenerating that fixture only takes effect once it is pushed, and it
  hardcodes `created` so an unchanged fixture regenerates byte-identically.

## Conventions

- `Imports` is a hard budget: `curl`, plus `stats`/`tools`/`utils` from base R. Zero non-base
  transitive deps. Optional formats and helpers go in `Suggests`, gated with `need_suggested()`.
- All hashing goes through `sha256_file()` (paths) and `sha256_bytes()` (raw vectors) in
  `R/verify.R`, both of which `.Call` into `src/sha256.c`. No `LinkingTo`, no Rcpp, no
  `configure`: the x86 SHA-NI path is a `target` attribute selected by CPUID at load, and the
  ARMv8 path compiles only where the compiler already targets the extension. A change to any
  compression path must keep `test-digest.R` green, which holds each runnable path against the
  FIPS 180-4 vectors, against every other path, and against `tools::sha256sum()` on R >= 4.6.0.
- Signing uses `src/ed25519.c` and `src/sha512.c` on the same terms: plain C behind `.Call`,
  reached through the thin wrappers at the top of `R/signature.R`. The field arithmetic is
  TweetNaCl-derived and public domain (`inst/COPYRIGHTS`); the detached entry points, the
  canonical-scalar check and the OS random source are not. `src/Makevars.win` exists only for
  `-lbcrypt`. `test-ed25519.R` holds all of it against RFC 8032 and FIPS 180-4 rather than
  against itself.
- `Depends: R (>= 4.0.0)`, set by `tools::R_user_dir()`. Nothing in `R/` needs more.
- Base R, no pipes, explicit `package::function()` for anything outside base.
- Comments explain domain reasoning only. Design decisions and history belong in
  `dev_notes/design.md`, `dev_notes/adr-*.md`, `dev_notes/open-questions.md`, or the commit
  message.
- `docs/` is committed pkgdown output; regenerate it with `dev_notes/site.R` rather than
  editing by hand.
