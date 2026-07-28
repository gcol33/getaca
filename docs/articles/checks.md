# Surviving R CMD check and CI

CRAN policy on packages that use Internet resources is one sentence, and
it is the sentence this article exists to satisfy:

> Packages which use Internet resources should fail gracefully with an
> informative message if the resource is not available or has changed
> (and not give a check warning nor error).

A four-gigabyte dependency makes that harder than it sounds. The file
cannot ship in the package, the check machine has no network and no
cache, and “gracefully” has to hold in tests, in examples and in
vignettes, which fail in three different ways.

The three failure modes are worth naming, because the fix differs. A
test that calls a missing resource throws, and the check reports a
failing test. An example that throws stops the check with an error in
`R CMD check` output, which is the form CRAN rejects most readily. A
vignette that throws fails the build step, and the package does not
install at all. None of the three is recoverable by a message, so each
needs a guard placed before the call rather than a handler wrapped
around it.

The rest of this article is those guards, the workflow files that make
CI exercise the real path, and the recipe for reproducing a check farm
locally before submitting.

## The check clamp

Under `R CMD check`, resolution collapses to `offline` whatever the
policy is set to. Nothing has to be configured for this: `getaca` reads
the environment variables the check process sets.

``` r

getaca_policy()
#> [1] "offline"
```

This vignette reports `offline` because it sets `GETACA_OFFLINE` in its
setup chunk, which forces the same clamp outside a check run. The check
itself is detected from `_R_CHECK_PACKAGE_NAME_` and the other variables
the check process exports, so a declaring package needs no configuration
to be safe there.

The clamp is released by `NOT_CRAN=true`, which
[`devtools::test()`](https://devtools.r-lib.org/reference/test.html) and
`devtools::check(env_vars = c(NOT_CRAN = "true"))` set for you. That is
the switch that lets your own CI run the same tests against real
resources while a CRAN machine never leaves the box.

Setting `GETACA_OFFLINE` to `1`, `true` or `yes` is how you reproduce a
check machine’s behaviour on your own laptop before submitting.

## The three helpers

They answer three different questions, and they are not three front
doors onto the same download.

| Helper | Question | Returns | Touches the network |
|----|----|----|----|
| [`getaca_available()`](https://gillescolling.com/getaca/reference/getaca-checks.md) | Is this usable right now? | `TRUE` / `FALSE` | never |
| [`getaca_optional()`](https://gillescolling.com/getaca/reference/getaca-checks.md) | Give me the path if you have it | path or `NULL` | under a network policy |
| [`getaca_skip_if_unavailable()`](https://gillescolling.com/getaca/reference/getaca-checks.md) | Should this test run? | invisible `NULL`, or skips | never |

### In tests

``` r

test_that("the backbone parses", {
  getaca_skip_if_unavailable("backbone", package = "yourpkg")

  path <- getaca("backbone", package = "yourpkg")
  expect_s3_class(read_backbone(path), "backbone")
})
```

The skip message names the missing resource, the package that declared
it, and the call that would fetch it:

    external resource 'backbone' (declared by yourpkg) is not cached;
    prefetch with getaca_prefetch("backbone", package = "yourpkg")

That matters more than it looks. A skipped test on someone else’s CI is
a question, and a skip reason that answers it is the difference between
a bug report and a
[`getaca_prefetch()`](https://gillescolling.com/getaca/reference/getaca_prefetch.md)
call.

[`getaca_skip_if_unavailable()`](https://gillescolling.com/getaca/reference/getaca-checks.md)
needs `testthat`, which it asks for at call time, so `getaca` does not
depend on a test framework in order to help tests.

### In examples

``` r

#' @examples
#' path <- getaca_optional("backbone", package = "yourpkg")
#' if (!is.null(path)) {
#'   summarise_backbone(path)
#' }
```

[`getaca_optional()`](https://gillescolling.com/getaca/reference/getaca-checks.md)
catches every `getaca_error` and returns `NULL` with a message, so an
example runs to completion on a machine that has nothing. This vignette
is built with the network switched off, which is the same path a check
machine takes:

``` r

path <- getaca_optional("backbone", registry = reg)
#> getaca: 'backbone' is not available here, so this output is abbreviated.
#> yourpkg/backbone@2026-06 is not cached and cannot be downloaded (offline mode is in effect).
#> 
#> Action: on a connected machine run getaca_prefetch("backbone", package = "yourpkg"),
#> or point GETACA_CACHE at a cache that already holds it.
#> 
#> Fix: this is expected during checks. Use getaca_skip_if_unavailable()
#> in tests and getaca_optional() in examples.
is.null(path)
#> [1] TRUE
```

For a resource large enough that fetching it is unreasonable even where
the network exists, `\donttest{}` is the honest wrapper.
[`getaca_optional()`](https://gillescolling.com/getaca/reference/getaca-checks.md)
handles absence; `\donttest{}` handles expense. They stack:

``` r

#' @examples
#' \donttest{
#' path <- getaca_optional("backbone", package = "yourpkg")
#' if (!is.null(path)) summarise_backbone(path)
#' }
```

### In vignettes

A vignette is built during `R CMD check`, so it faces the same
constraint as an example, with the extra problem that its output is what
users read. Three shapes work, in descending order of preference.

**Bundle a small fixture.** A vignette that demonstrates the API on a
100 KB extract in `inst/extdata` runs everywhere, always produces the
same output, and never depends on a download. This is the right answer
whenever the point being made does not need the full resource.

Most of the time it does not. A vignette showing how an input is
matched, how a result is shaped, or what an argument changes needs
twenty rows, not six million. Cut the extract once, commit it, and
generate it from a `data-raw/` script so it can be regenerated when the
upstream schema moves:

``` r

# data-raw/make-fixture.R
full  <- read_backbone(getaca::getaca("backbone", package = "yourpkg"))
small <- head(full[full$group %in% c("a", "b"), ], 200)
saveRDS(small, "inst/extdata/backbone-extract.rds", version = 3)
```

``` r

# in the vignette
backbone <- readRDS(system.file("extdata", "backbone-extract.rds",
                                package = "yourpkg"))
```

The extract carries the same schema as the real thing, so every code
path the vignette demonstrates is a path that runs against the full
resource too. What it does not carry is coverage, which is why the
vignette says what it is using.

**Guard the section.** When the full resource genuinely is the point:


    ``` r
    summarise_backbone(getaca::getaca("backbone", package = "yourpkg"))
    ```

The chunk is skipped where the resource is absent, and the vignette
still builds. Pair it with a short line of prose saying what would have
appeared, so a reader of the CRAN-built version is not left with a gap.

**Precompute.** For a figure that takes twenty minutes, generate it in a
`data-raw/` script, commit the result, and have the vignette read the
committed artefact. The `R.rsp` static vignette engine formalises this.

### Anywhere a logical reads better

``` r

getaca_available("backbone", registry = reg)
#> [1] FALSE
```

[`getaca_available()`](https://gillescolling.com/getaca/reference/getaca-checks.md)
performs the cheap integrity check as well as the existence test, so it
returns `FALSE` for a cached copy that has been truncated or replaced.
It never re-hashes and never downloads, which is what makes it safe in a
condition evaluated often.

It also swallows resolution errors and returns `FALSE`, so a package
that is not installed, or a name that is not declared, produces `FALSE`
rather than an error:

``` r

getaca_available("nothing-here", package = "getaca")
#> [1] FALSE
```

## Seeding a cache

[`getaca_prefetch()`](https://gillescolling.com/getaca/reference/getaca_prefetch.md)
downloads and verifies without returning anything, which is what you
want in a setup step:

``` r

getaca_prefetch("backbone", package = "yourpkg")   # one resource
getaca_prefetch(package = "yourpkg")               # everything yourpkg declares
getaca_prefetch(c("backbone", "grid"), package = "yourpkg")
```

Where the cache lives is set by `GETACA_CACHE`, which is the single knob
a CI job needs:

``` r

Sys.setenv(GETACA_CACHE = "/mnt/shared/getaca")
```

The cache is an ordinary directory tree with no database and no absolute
paths recorded inside it, so copying it between machines works, and so
does restoring it from a CI cache action.

## GitHub Actions

The standard `r-lib/actions` check workflow needs two additions: a cache
step and a prefetch step.

``` yaml
- uses: actions/cache@v4
  with:
    path: ~/getaca-cache
    key: getaca-${{ runner.os }}-${{ hashFiles('inst/getaca/registry.rds') }}

- name: Prefetch declared resources
  run: Rscript -e 'getaca::getaca_prefetch(package = "yourpkg")'
  env:
    GETACA_CACHE: ~/getaca-cache

- uses: r-lib/actions/check-r-package@v2
  env:
    GETACA_CACHE: ~/getaca-cache
    NOT_CRAN: true
```

Keying the cache on `inst/getaca/registry.rds` is the part worth
copying. The registry file changes exactly when a declaration changes,
so a new version downloads once and every subsequent job on that key
restores it. Keying on the lockfile or the commit SHA instead
re-downloads far more often than the data actually move.

`NOT_CRAN: true` on the check step releases the clamp, so the tests that
[`getaca_skip_if_unavailable()`](https://gillescolling.com/getaca/reference/getaca-checks.md)
guards actually run against the seeded cache. Drop it and the job checks
that your skips work, which is a weaker thing to check.

For a matrix build, add the OS to the key and let each runner keep its
own copy. Sharing one cache across operating systems saves nothing,
because the restore is per-runner anyway.

### A separate job for the expensive path

When the resource is large enough that fetching it on every push is
unreasonable, split it:

``` yaml
on:
  schedule: [{cron: "0 4 * * 1"}]
  workflow_dispatch:

jobs:
  full:
    steps:
      - uses: actions/cache@v4
        with:
          path: ~/getaca-cache
          key: getaca-full-${{ hashFiles('inst/getaca/registry.rds') }}
      - run: Rscript -e 'getaca::getaca_prefetch(package = "yourpkg")'
        env: {GETACA_CACHE: ~/getaca-cache}
      - uses: r-lib/actions/check-r-package@v2
        env: {GETACA_CACHE: ~/getaca-cache, NOT_CRAN: true}
```

Every push then runs the fast checks with skips, and a weekly job runs
the same tests against real data. A failure in the weekly job is a
signal about the data, which is usually what you want to know separately
from a signal about the code.

## Testing that the guards work

A guard that never fires is a guard nobody has tested. Two things are
worth asserting directly.

That the skip happens when the resource is absent:

``` r

test_that("the backbone test skips cleanly on a bare machine", {
  withr::local_envvar(c(GETACA_OFFLINE = "true"))
  withr::local_options(list(getaca.cache = withr::local_tempdir()))

  expect_false(getaca_available("backbone", package = "yourpkg"))
})
```

And that the code path a guarded call protects still behaves when the
resource is present, which is what the weekly CI job is for.

The failure this catches is subtle: a helper that resolves a resource at
load time, or in a default argument, runs before any guard in the test
body. Moving the call inside the function it belongs to is usually the
whole fix.

Resolution itself is testable everywhere, because it never leaves the
installed package:

``` r

test_that("the shipped registry resolves the version we think it does", {
  reg <- registry_for("yourpkg")
  expect_equal(resolve_resource("backbone", registry = reg)$id$version, "2026-06")
})
```

That test runs on CRAN, catches a registry regenerated with the head
pointing at the wrong record, and costs nothing.

## Reproducing a check machine locally

Before submitting, run the check the way CRAN will:

``` r

withr::with_envvar(
  c(GETACA_CACHE = tempfile(), NOT_CRAN = ""),
  devtools::check()
)
```

An empty temporary cache plus an unset `NOT_CRAN` gives you a machine
that has never seen your resources and refuses to fetch them. If the
check passes there, it passes on a check farm.

The failure this catches is an example or vignette that works on your
machine because the resource happens to be cached, and produces an error
on a machine where it is not. It is the single most common way a package
with external data gets rejected, and it is invisible to every check run
on a developer’s own laptop.

Run it once more with the resources present, so both halves are covered:

``` r

withr::with_envvar(
  c(GETACA_CACHE = "~/getaca-cache", NOT_CRAN = "true"),
  devtools::check()
)
```

The first run proves the package survives their machine. The second
proves it does something useful on yours.

### When the check farm disagrees with your CI

A package can pass everywhere you control and fail on a CRAN machine.
Three causes account for most of it when external data are involved.

**A leftover cache.** Your CI restored a cache the check farm does not
have. The empty-cache run above is the test for this.

**A different clamp.** `NOT_CRAN` set in a `.Renviron`, a `Makevars`, or
a CI default releases the clamp without your noticing, and everything
downloads. Check `Sys.getenv("NOT_CRAN")` in the failing environment
before looking anywhere else.

**Timing.** A check farm runs with limits on total check time. A test
that downloads even a modest file can pass locally and time out there.
Under the clamp nothing downloads, which removes the problem, but a
package that released the clamp in its own tests has to keep an eye on
it.

The CRAN incoming checks run `--as-cran`, which enables tests the
default `R CMD check` does not. `devtools::check(cran = TRUE)` matches
it locally.

## What a check run actually does

Every path through `getaca` under the clamp ends in one of three places,
and none of them is a network call:

``` r

err <- tryCatch(getaca("backbone", registry = reg), getaca_error = function(e) e)
cat(conditionMessage(err))
#> yourpkg/backbone@2026-06 is not cached and cannot be downloaded (offline mode is in effect).
#> 
#> Action: on a connected machine run getaca_prefetch("backbone", package = "yourpkg"),
#> or point GETACA_CACHE at a cache that already holds it.
#> 
#> Fix: this is expected during checks. Use getaca_skip_if_unavailable()
#> in tests and getaca_optional() in examples.
```

The message is written for the person reading a check log, so it names
the prefetch call and the environment variable rather than describing
the internal state that produced it.

``` r

class(err)
#> [1] "getaca_error_offline"     "getaca_error_unavailable"
#> [3] "getaca_error"             "error"                   
#> [5] "condition"
```

`getaca_error_offline` inherits from `getaca_error_unavailable`, so a
package that handles the general “cannot get it” case handles the check
case for free, and a package that wants to distinguish them can.

## What to say in DESCRIPTION

A package that downloads data on first use should say so where a user
reads before installing. The `Description` field is the place:

    Description: Analyses data against a large reference backbone. The backbone
        is downloaded on first use and cached under tools::R_user_dir(), and
        can be fetched ahead of time with install_backbone().

Two things this earns. A reviewer sees the behaviour declared rather
than discovering it, and a user on a metered connection is not surprised
by a gigabyte. Naming the prefetch function also gives the answer to the
question the sentence provokes.

`getaca` goes in `Imports`, since the declaration is useless without it,
and the recursive footprint it adds is `curl` with nothing beneath it.
`getaca` carries compiled code, so a source install compiles one C file;
it declares no `LinkingTo`, so nothing has to be built before it.

## CRAN checklist

no test, example or vignette downloads anything when `NOT_CRAN` is unset

tests guarded with
[`getaca_skip_if_unavailable()`](https://gillescolling.com/getaca/reference/getaca-checks.md),
so skips carry a reason

examples use
[`getaca_optional()`](https://gillescolling.com/getaca/reference/getaca-checks.md),
wrapped in `\donttest{}` when the resource is large

vignettes use a bundled fixture, or gate chunks on
[`getaca_available()`](https://gillescolling.com/getaca/reference/getaca-checks.md)

[`devtools::check()`](https://devtools.r-lib.org/reference/check.html)
passes against an empty `GETACA_CACHE`

the declaring package’s own `Description` mentions that data are
downloaded on first use

## Where to go next

- [`vignette("cache")`](https://gillescolling.com/getaca/articles/cache.md)
  for what the cache holds and how it is managed

- [`vignette("failures")`](https://gillescolling.com/getaca/articles/failures.md)
  for the conditions a guarded call can raise

- [`vignette("policies")`](https://gillescolling.com/getaca/articles/policies.md)
  for the clamp’s place among the settings layers
