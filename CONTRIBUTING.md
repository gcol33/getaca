# Contributing to getaca

Thanks for considering a contribution. Please read the
[Code of Conduct](CODE_OF_CONDUCT.md) first.

## Installation

```bash
git clone https://github.com/gcol33/getaca.git
cd getaca
```

```r
install.packages(c("devtools", "roxygen2", "testthat", "withr"))
devtools::load_all()
```

## Testing

```r
devtools::test()
devtools::check()
```

Tests never touch the network and never touch the real cache. Every test that
needs a cache calls `local_cache()`, which points `getaca.cache` at a
temporary directory for the duration. If you add a test that reaches a real
URL, it belongs behind `skip_on_cran()` and `skip_if_offline()`, and it should
be the exception.

Fixtures use `writeBin()` rather than `writeLines()`, because line-ending
translation on Windows changes file sizes and several tests turn on exact
sizes.

## Project organisation

```
R/
  resource.R        immutable resource records
  registry.R        package-scoped declarations, discovery, authoring formats
  resolve.R         bundled / current / pinned / offline resolution
  cache.R           layout, index, entry records
  lock.R            per-resource directory mutex
  download.R        mirrors, resume, atomic promotion
  verify.R          full, cheap and scheduled verification
  fetch.R           getaca(), provenance, prefetch
  gc.R              retention policy and sweeps
  check-helpers.R   available / optional / skip
  conditions.R      the failure taxonomy
  options.R         policy and settings
dev_notes/          design record and architecture decisions
```

`dev_notes/` holds the design document and the ADRs. Decisions belong there or
in a commit message, not in code comments.

## What to know before changing behaviour

Three invariants are load-bearing. Changing any of them is a design decision,
not a bug fix, and belongs in an ADR.

1. **A published `name@version` names fixed bytes.** No code path may accept a
   different checksum for an existing version.
2. **A returned path is verified, complete, and owned by getaca.** Nothing may
   return a path to a partial or unverified file.
3. **Resolution collapses to offline under `R CMD check`.** No policy, option
   or argument may reach the network during a check.

## Dependencies

`Imports` is a hard budget: `curl`, and `stats`, `tools` and `utils` from base
R. A pull request adding an `Imports` entry needs the recursive footprint
(`tools::package_dependencies(recursive = TRUE)`) and the line of code that
requires it. Optional features go in `Suggests` and are gated with
`need_suggested()`.

Hashing goes through `sha256_file()` and `tools::sha256sum(bytes = )`. That
function is what sets the R 4.6.0 floor.

## Workflow

1. Branch from `main`.
2. Make the change, with tests.
3. `devtools::document()` then `devtools::test()` then `devtools::check()`.
4. Open a pull request describing what changed and why.

## Style

Follow the surrounding code: base R, no pipes in package code, explicit
`package::function()` for anything outside base. Comments explain domain
reasoning, never history or process.

## Reporting bugs

Open an issue with a reproducible example. For a retrieval problem, include
`getaca_info()` output for the resource and your `getaca_policy()`, with
checksums and URLs redacted if they are not public.

By contributing you agree that your contributions are licensed under the MIT
License.
