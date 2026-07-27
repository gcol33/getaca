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

## Third-party code

`src/ed25519.c` derives its Curve25519 field arithmetic, point addition,
Montgomery ladder and scalar reduction from TweetNaCl 20140427, which its
authors released into the public domain. `inst/COPYRIGHTS` records the
provenance, the authors and what the derived work adds. No copyright holder
is added to `Authors@R` because the source carries no copyright to hold; if
you would prefer the TweetNaCl authors listed as contributors, I am happy to
add them.

## URLs in examples and vignettes

Several examples declare resources at hosts under the `.invalid` top-level
domain, which RFC 2606 reserves for exactly this purpose. They are meant not
to resolve: a runnable example must never reach a real host, and the package's
own check-time policy refuses network access regardless.

## Downstream dependencies

None. This is a first release.
