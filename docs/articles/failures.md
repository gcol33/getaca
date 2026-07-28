# Handling Failures

A plain downloader reports six different situations the same way:
something went wrong with a URL. `getaca` separates them, because the
six have three different people who can act on them and four different
things to do.

Every failure is a classed condition carrying an `actor` field naming
who can act. Callers branch on the class rather than on message text.

| Condition | Cause | Actor | Action |
|----|----|----|----|
| `getaca_error_unavailable` | no mirror answered | user | connect, or prefetch elsewhere |
| `getaca_error_offline` | not cached, network not permitted here | user | prefetch, or point `GETACA_CACHE` at a seeded cache |
| `getaca_error_incomplete` | every mirror ended short | user | retry |
| `getaca_error_upstream_changed` | published bytes were replaced | upstream | the declaring package needs a new record |
| `getaca_error_cache_corrupt` | local copy drifted from its own record | user | clean and refetch |
| `getaca_error_invalid_registry` | the declaration is wrong | author | report to the declaring package |
| `getaca_error_declaration` | every mirror agrees, the registry disagrees | author | report to the declaring package |
| `getaca_error_composition` | the parts arrived intact and compose to something else | author | report to the declaring package |

All eight inherit from `getaca_error`, which inherits from `error`, so a
handler for `getaca_error` catches everything the package raises and
nothing else.

## The general shape

``` r

err <- tryCatch(getaca("wfo", registry = reg), getaca_error = function(e) e)
class(err)
#> [1] "getaca_error_offline"     "getaca_error_unavailable"
#> [3] "getaca_error"             "error"                   
#> [5] "condition"
```

``` r

err$actor
#> [1] "user"
```

``` r

cat(conditionMessage(err))
#> taxify/wfo@2026-06 is not cached and cannot be downloaded (offline mode is in effect).
#> 
#> Action: on a connected machine run getaca_prefetch("wfo", package = "taxify"),
#> or point GETACA_CACHE at a cache that already holds it.
#> 
#> Fix: this is expected during checks. Use getaca_skip_if_unavailable()
#> in tests and getaca_optional() in examples.
```

Three parts to every message: what happened, what to do about it, and a
closing line derived from the actor. The `Fix:` line is what tells a
user whether the next step is theirs, and the `Action:` lines above it
are what they type.

Beyond `actor`, each condition carries the data that produced it, so a
handler can reason about the situation rather than parse the message:

``` r

names(err)
#> [1] "message" "call"    "actor"   "id"
```

`err$id` is the `getaca_id`, so `format(err$id)` gives
`package/name@version` for a log line.

## `getaca_error_unavailable`

No mirror could be reached. Every URL is listed with the reason it
failed, so a user can tell a proxy problem from a host that is down from
a path that 404s.

``` r

getaca("wfo", package = "taxify")
#> Error: Cannot reach any source for taxify/wfo@2026-06.
#>   https://primary.invalid/wfo-2026-06.zip: HTTP 503
#>   https://mirror.invalid/wfo-2026-06.zip: Could not resolve host
#>
#> Actions: connect to a network; or run getaca_prefetch() on a connected
#> machine and copy the cache directory; or set the resource optional here
#> with getaca_available() before calling.
#>
#> Fix: see the actions listed above.
```

The condition carries `urls` and `reasons` as parallel vectors, which is
enough to build a domain-specific message:

``` r

tryCatch(
  getaca("wfo", package = "taxify"),
  getaca_error_unavailable = function(e) {
    stop(sprintf(
      "Could not download the WFO backbone from %d source(s).\nTried:\n%s",
      length(e$urls), paste0("  ", e$urls, " (", e$reasons, ")", collapse = "\n")
    ), call. = FALSE)
  }
)
```

## `getaca_error_offline`

A subclass of `getaca_error_unavailable`, raised when the resource is
not cached and the policy in force forbids reaching for it. Under
`R CMD check` this is the only failure a resource-dependent code path
can produce, because the clamp forces `offline` before any transport is
attempted.

``` r

cat(conditionMessage(err))
#> taxify/wfo@2026-06 is not cached and cannot be downloaded (offline mode is in effect).
#> 
#> Action: on a connected machine run getaca_prefetch("wfo", package = "taxify"),
#> or point GETACA_CACHE at a cache that already holds it.
#> 
#> Fix: this is expected during checks. Use getaca_skip_if_unavailable()
#> in tests and getaca_optional() in examples.
```

The subclass relationship is what lets a package write one handler and
get both:

``` r

inherits(err, "getaca_error_unavailable")
#> [1] TRUE
```

Separating them is worth doing when the two need different words. “You
are offline” is wrong advice for a machine that is online but running a
check, and “the server is down” is wrong advice for a machine with no
network at all.

``` r

tryCatch(
  getaca("wfo", package = "taxify"),
  getaca_error_offline = function(e) {
    message("Running without network access. Prefetch first:\n",
            "  getaca_prefetch(\"wfo\", package = \"taxify\")")
    NULL
  },
  getaca_error_unavailable = function(e) {
    message("The download sources are not responding. Try again later.")
    NULL
  }
)
```

Handlers are matched in order, so the narrower one has to come first.

## `getaca_error_incomplete`

Every mirror that failed did so by ending short of the declared size.
That is a different situation from a host being down, and the action is
different: retry, because a partial transfer resumes rather than
restarting.

``` r

getaca("wfo", package = "taxify")
#> Error: Transfer of taxify/wfo@2026-06 ended early.
#>   expected 797000000 bytes, received 412300000 bytes
#>
#> Action: retry. Any previously cached copy was left untouched.
#>
#> Fix: see the actions listed above.
```

The size check runs before hashing, so a truncated four-gigabyte
transfer fails in milliseconds rather than after a full digest. It only
runs when the record declares a `size`, which is one reason to declare
one.

Where some mirrors ended short and others could not be reached at all,
the broader `getaca_error_unavailable` is raised instead, with each
mirror’s reason listed. Retrying helps one kind of failure and not the
other, so claiming the whole thing was a truncation would be wrong.

## `getaca_error_upstream_changed`

A complete transfer whose digest does not match the declaration. The
publisher appears to have replaced the file without issuing a new
version.

``` r

getaca("wfo", package = "taxify")
#> Error: The remote file no longer matches taxify/wfo@2026-06.
#>   declared SHA-256: 9f9f9f...
#>   observed SHA-256: 3c1a77...
#>   source: https://primary.invalid/wfo-2026-06.zip
#>
#> The publisher appears to have replaced the contents without issuing a
#> new version. getaca will not accept the substitution, and any copy
#> already verified in the cache has been left untouched.
#>
#> Fix: the publisher changed the file. The declaring package needs a new
#> registry entry.
```

Two properties of this failure are the point of the package. The new
bytes are not accepted, so nothing downstream silently starts computing
on a different dataset. And a copy already in the cache is untouched, so
a machine that has the correct file keeps working while the situation is
sorted out.

As a user, there is nothing to do here except report it. As the
declaring author, the response is to work out which of four things
happened: a corrupted transfer that will not reproduce, a genuine
upstream recut that deserves a new version record, an upstream mistake
worth reporting to the publisher, or a wrong checksum in your own
registry.

## `getaca_error_declaration`

Several independent mirrors returned identical bytes, and none matched
the declared checksum. When every mirror agrees with the others and
disagrees with the registry, the registry is the likely error.

``` r

getaca("wfo", package = "taxify")
#> Error: The declared checksum for taxify/wfo@2026-06 looks wrong.
#>   2 independent sources agreed on SHA-256 3c1a77...
#>   the registry declares 9f9f9f...
#>
#> When every mirror agrees with the others and disagrees with the
#> registry, the registry is the likely error.
#>
#> Fix: the declaring package needs a correction. Report it to its maintainer.
```

This is the condition that distinguishes an author’s mistake from a
publisher’s. One mirror disagreeing is an upstream mutation; two mirrors
agreeing with each other and not with you is a typo, a checksum computed
before an upload recompressed the file, or a record copied from the
wrong row.

It requires more than one mirror to be diagnosable at all, which is a
practical argument for declaring two.

## `getaca_error_composition`

Every declared
[`part()`](https://gillescolling.com/getaca/reference/part.md) arrived
and matched its own checksum, and combining them produced something
other than the artefact the record names.

``` r

getaca("wfo", package = "taxify")
#> Error: The parts declared for taxify/wfo@2026-09 do not produce the declared bytes.
#>   3 parts, each matching its own checksum, combined by 'concat'
#>   declared SHA-256: b1b1b1...
#>   composed SHA-256: 2c40f9...
#>
#> Every part arrived intact, so this is not a transfer problem. Either the
#> series is not the one this version is made of, or it is put together by
#> something other than what the registry names.
#>
#> Fix: the declaring package needs a correction. Report it to its maintainer.
```

This is `getaca_error_declaration` one level up. There, the transport
was sound and the checksum was wrong; here every checksum in the series
was right and what they add up to was wrong. A part that goes missing or
arrives changed raises the ordinary transfer conditions instead, naming
which part of the series it was:

``` r

#> Error: Cannot reach any source for taxify/wfo@2026-09 (part 2 of 3).
```

As an author, reach for this after re-splitting a file, reordering a
series, or changing what a
[`combiner()`](https://gillescolling.com/getaca/reference/combiner.md)
does without changing its id. Nothing reaches the cache, so a user
hitting it is not left with a half-composed artefact.

## `getaca_error_cache_corrupt`

The cached copy no longer matches its own entry record. Raised by the
cheap size check on ordinary access, and by the scheduled or forced
re-hash.

``` r

getaca("wfo", package = "taxify")
#> Error: The cached copy of taxify/wfo@2026-06 is damaged.
#>   path: ~/.cache/R/getaca/taxify/wfo/2026-06/raw/wfo-2026-06.zip
#>   declared SHA-256: 9f9f9f...
#>   observed SHA-256: 71b0c2...
#>
#> Action: getaca_clean("wfo", package = "taxify"), then retry.
#>
#> Fix: see the actions listed above.
```

Silent repair was considered and rejected. Refetching without saying
anything would hide a disk developing bad sectors, a sync client
rewriting files, and a colleague who opened something in the cache
directory and saved it. The message names the clean-up call, so the
repair is one line and the user knows it happened.

``` r

tryCatch(
  getaca("wfo", package = "taxify"),
  getaca_error_cache_corrupt = function(e) {
    warning("Cached WFO backbone was damaged; refetching.", call. = FALSE)
    getaca_clean("wfo", package = "taxify")
    getaca("wfo", package = "taxify")
  }
)
```

That handler is reasonable in a package that knows its users would want
the repair. Doing it inside `getaca` for everyone would make the failure
invisible.

## `getaca_error_invalid_registry`

The declaration is malformed or internally inconsistent. Raised at
[`registry()`](https://gillescolling.com/getaca/reference/registry.md)
and
[`resource()`](https://gillescolling.com/getaca/reference/resource.md)
where possible, which puts it on the author’s machine rather than a
user’s:

``` r

registry("taxify", list(
  resource("wfo", "2026-09", urls = "https://host.invalid/a",
           sha256 = strrep("ab", 32)),
  resource("wfo", "2026-03", urls = "https://host.invalid/b",
           sha256 = strrep("cd", 32))
))
#> Error:
#> ! Invalid getaca registry for package 'taxify'.
#>   - resource 'wfo' declares 2 versions (2026-09, 2026-03) but the registry names no current one; add current = c("wfo" = "2026-03")
#> 
#> Fix: the declaring package needs a correction. Report it to its maintainer.
```

Every problem found is listed, rather than the first one:

``` r

resource("wfo", "2026-06", urls = "ftp://host.invalid/a", sha256 = "abc")
#> Error:
#> ! Invalid getaca registry.
#>   - resource 'wfo': all URLs must use https
#>   - resource 'wfo': `sha256` must be 64 lowercase hex characters
#> 
#> Fix: the declaring package needs a correction. Report it to its maintainer.
```

The same condition covers the runtime cases: a package that ships no
registry, a name the registry does not declare, a remote registry
declaring a different package, and a pin file that redefines a published
version.

``` r

resolve_resource("no-such-resource", registry = reg)
#> Error:
#> ! Invalid getaca registry for package 'taxify'.
#>   - package 'taxify' declares no resource named 'no-such-resource' (has: wfo)
#> 
#> Fix: the declaring package needs a correction. Report it to its maintainer.
```

The message names what is on offer, which is usually enough to spot a
typo without opening the registry.

``` r

resolve_resource("wfo", package = "stats")
#> Error:
#> ! Invalid getaca registry for package 'stats'.
#>   - package 'stats' ships no getaca registry at inst/getaca/registry.rds
#> 
#> Fix: the declaring package needs a correction. Report it to its maintainer.
```

That one names the conventional path, so a user who expected a package
to declare resources can see immediately that it does not.

## Writing a handler in a declaring package

The pattern that works is to catch the user-actionable conditions and
speak your own domain, and to let the author-actionable and
upstream-actionable ones through unchanged. A user cannot act on either,
and the default messages already say who can.

``` r

install_backbone <- function(name = "wfo") {
  tryCatch(
    open_backbone(getaca(name, package = "taxify")),

    getaca_error_offline = function(e) {
      stop("The ", name, " backbone is not installed and this session cannot ",
           "download it.\n",
           "On a connected machine run:\n",
           "  taxify::install_backbone(\"", name, "\")\n",
           "or point GETACA_CACHE at a directory that already holds it.",
           call. = FALSE)
    },

    getaca_error_unavailable = function(e) {
      stop("The ", name, " backbone could not be downloaded from any of its ",
           length(e$urls), " sources.\n",
           "This is usually temporary. Try again, or use a different backbone:\n",
           "  taxify(names, backbone = \"col\")", call. = FALSE)
    },

    getaca_error_cache_corrupt = function(e) {
      stop("The cached ", name, " backbone is damaged.\n",
           "Repair it with:\n",
           "  getaca::getaca_clean(\"", name, "\", package = \"taxify\")",
           call. = FALSE)
    }
  )
}
```

Three things this gets right. It names your function rather than
[`getaca()`](https://gillescolling.com/getaca/reference/getaca.md), so
the user’s next step is in your vocabulary. It suggests a domain-level
alternative for the transient case. And it leaves
`getaca_error_upstream_changed` and `getaca_error_declaration` alone,
which means a user who hits one gets a message that tells them to report
it, and a report that contains the checksums you need.

## Testing your handlers

Conditions can be constructed by making a resolution fail, which needs
no network:

``` r

offline_error <- tryCatch(
  getaca("wfo", registry = reg, policy = "offline"),
  getaca_error = function(e) e
)
class(offline_error)[1]
#> [1] "getaca_error_offline"
```

``` r

test_that("a missing backbone gets a taxify-flavoured message", {
  withr::local_envvar(c(GETACA_OFFLINE = "true"))
  withr::local_options(list(getaca.cache = withr::local_tempdir()))

  expect_error(install_backbone("wfo"), "On a connected machine run")
})
```

Forcing `GETACA_OFFLINE` with an empty cache is the cheapest way to
exercise the path a user without the resource takes, and it is
deterministic on every machine.

For the conditions that need a transfer, the honest test is against a
real resource on CI with `NOT_CRAN=true`, guarded by
[`getaca_skip_if_unavailable()`](https://gillescolling.com/getaca/reference/getaca-checks.md).
See
[`vignette("checks")`](https://gillescolling.com/getaca/articles/checks.md).

## Where to go next

- [`vignette("checks")`](https://gillescolling.com/getaca/articles/checks.md)
  for behaving during checks and in CI

- [`vignette("cache")`](https://gillescolling.com/getaca/articles/cache.md)
  for what `getaca_error_cache_corrupt` is protecting

- [`vignette("declaring")`](https://gillescolling.com/getaca/articles/declaring.md)
  for the two conditions that name you
