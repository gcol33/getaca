## Update: getaca 0.2.0

This is an update of a package on CRAN (0.1.6, published 2026-09-01). It
changes how long transfers and locks behave; `NEWS.md` has the list.

## R CMD check results

0 errors | 0 warnings | 0 notes

## Test environments

* local: Windows 11, R-devel (2026-11-17 r90926 ucrt), `R CMD check --as-cran`
  of the submitted tarball: Status OK
* local: Windows 11, R 4.6.0, `R CMD check --as-cran`
* local: Ubuntu under WSL, R 4.3.3, install and tests
* win-builder: not available on 2026-11-23. The tarball uploaded to R-devel
  and R-release at 18:22 was still in the upload directory at 19:53, together
  with every other package uploaded since 17:19, so the R-devel check on
  Windows was run locally instead.
* CRAN incoming pretest of the submitted tarball (2026-11-23,
  `incoming_pretest/getaca_0.2.0_20261123_195715`): Windows R-devel
  (2026-11-17 r90926) Status OK, Debian R-devel (2026-11-21 r90959) Status OK
* GitHub Actions: macOS release, Windows release, Ubuntu r-devel, release,
  oldrel-1 and oldrel-2

## Compiled code

This version adds two C files. `src/process.c` asks the operating system
whether a process id is running. `src/heartbeat.c` starts one thread, which
exists only while the package holds a lock on a cache entry: it updates the
modification time of that lock's file and calls no R API. The thread is joined
when the lock is released and in `R_unload_getaca()`. `src/Makevars` exists
for `-pthread` in `PKG_LIBS`.

The compiled code is checked on every push in the five r-hub containers used
for CRAN's additional issues: clang-asan, gcc-asan, clang-ubsan, valgrind and
rchk. All five are clean for this version.

## Cores and processes

Tests and examples transfer nothing over the network. One test forks a single
child through `parallel::mcparallel()`, on platforms other than Windows, so at
most two processes run at once.

## User filespace

Unchanged from 0.1.6: nothing is written by default, the cache is
`tools::R_user_dir("getaca", "cache")` and is actively managed by the package
(`?"getaca-gc"`), and resolution collapses to the `offline` policy under
`R CMD check`.

## Downstream dependencies

None on CRAN.
