## Resubmission

This is a resubmission of a new package. Thank you for the review. Each point
is addressed below.

Development continued between the submission of 0.1.0 and the review, so the
corrected package is 0.1.6 rather than a second 0.1.0; `NEWS.md` records what
changed in between.

**"for R" in the title and description.** Removed. The title is now
"Reproducible External Data Dependencies", and the description says "package"
where it said "R package".

**Single quotes.** Removed around SHA-256. Nothing else in the title or
description is quoted: Ed25519 and SHA-256 are algorithm names rather than
software names.

**References.** Added to the Description field: FIPS 180-4 for the hashing in
`src/sha256.c`, and the Ed25519 paper together with RFC 8032 for the signing
in `src/ed25519.c`.

**Writing to the user's home filespace.** Nothing is written by default. The
cache directory is `tools::R_user_dir("getaca", "cache")`, which CRAN policy
permits on condition that the contents are actively managed; the package
implements that management (`?"getaca-gc"`) and documents it in
`vignette("cache")`. `getaca_cache_dir()` reports the path without creating
it, and nothing under it is created until a user calls `getaca()` for a
resource they asked for. The location is overridable through the
`getaca.cache` option or the `GETACA_CACHE` environment variable.

No example, vignette or test writes there. Every example that would write is
inside `\dontrun{}` or commented out; every vignette redirects `getaca.cache`
into `tempdir()` in its setup chunk; every test that touches the cache calls a
helper that points it at a `withr` temp directory. Resolution also collapses
to the `offline` policy under `R CMD check`, so a check run cannot fetch.

**Changing the user's options.** `R/options.R` contains no side-effecting
option change. The only `options()` call is inside `getaca_policy()`, whose
sole documented purpose is to set `getaca.policy` when the user asks it to;
`getaca_progress()` in `R/progress.R` is the same shape for
`getaca.progress`. Both now return the previous value of the option
invisibly, so a caller that has to change one for the duration of a function
can restore it immediately:

```r
old <- getaca_policy("offline")
on.exit(options(getaca.policy = old), add = TRUE)
```

The examples for both demonstrate that restoration and leave the session as
they found it. The vignettes now save and restore the options and environment
variables their setup chunks set. No function changes `par()` or the working
directory; the package draws no graphics and never calls `setwd()`.

**Authors@R.** The six TweetNaCl authors are now listed with `ctb` roles:
Daniel J. Bernstein, Bernard van Gastel, Wesley Janssen, Tanja Lange, Peter
Schwabe and Sjaak Smetsers. `src/ed25519.c` derives its Curve25519 field
arithmetic, point addition, Montgomery ladder and scalar reduction from
TweetNaCl 20140427. `inst/COPYRIGHTS` records the provenance and what the
derived work adds. No `cph` role is added for them because TweetNaCl is
released into the public domain by its authors, so there is no copyright for
them to hold; the `ctb` entries record the authorship.

## R CMD check results

0 errors | 0 warnings | 1 note

The note is "New submission".

## Test environments

* local: Windows 11, R 4.6.0, `R CMD check --as-cran`
* win-builder: R-devel, R-release
* GitHub Actions: macOS release, Windows release, Ubuntu r-devel, release,
  oldrel-1 and oldrel-2

The compiled code is additionally checked on every push in the five r-hub
containers CRAN uses for its own additional issues: clang-asan, gcc-asan,
clang-ubsan, valgrind and rchk. All five are clean.

## URLs in examples and vignettes

Several examples declare resources at hosts under the `.invalid` top-level
domain, which RFC 2606 reserves for exactly this purpose. They are meant not
to resolve: a runnable example must never reach a real host, and the package's
own check-time policy refuses network access regardless.

## Downstream dependencies

None. This is a first release.
