# The Cache

The cache is where a declared resource becomes a local path. This
article covers the layout, what makes a cached copy trustworthy, how two
sessions avoid downloading the same file twice, and the retention policy
CRAN requires of a package that writes to a user directory.

None of it is private. The cache is an ordinary directory tree, and that
is a deliberate property: copying it to an offline machine, restoring it
from a CI cache action, or looking at it with a file browser all work.

## Where it lives

``` r

getaca_cache_dir()
#> [1] "C:\\Users\\GILLES~1\\AppData\\Local\\Temp\\Rtmpei2GGx/getaca-cache-vignette"
```

That is the sandbox this vignette runs in. The default is
`tools::R_user_dir("getaca", "cache")`, the location CRAN permits for
cached downloads. Two overrides take precedence, in this order:

``` r

options(getaca.cache = "/mnt/fast/getaca")   # this session
Sys.setenv(GETACA_CACHE = "/mnt/fast/getaca") # this process and its children
```

The environment variable is the one to reach for in CI and in job
scripts, because it survives into the R processes a build step spawns.
Asking for the directory does not create it; the first successful
retrieval does.

## Layout

    <cache>/
      blobs/sha256/<aa>/<sha256>     verified bytes, named by their own checksum
      .locks/                        one per checksum, held during a transfer
      .tmp/                          in-flight downloads, never visible as cache
      <package>/
        index.rds                    provenance for this package only
        <name>/<version>/
          raw/<file>                 this slot's name for a blob
          proc-<processor-id>/       processed result, own provenance

Everything a package declares is scoped by declaring package, then
resource name, then version. That falls out of identity being the triple
`package / name / version`, and it buys two things. Two packages
declaring a resource called `"wfo"` never share a slot, so one package’s
registry update cannot affect another’s cached data. And a version can
never be overwritten by another version, so holding two releases side by
side is the normal state rather than a special case.

The bytes underneath are shared. A file lives once, at `blobs/sha256/`,
under its own checksum, and the version slot holds a name for it: a
hardlink where the filesystem allows one, a symlink or a copy where it
does not. Two packages declaring the same 4 GB file therefore keep one
copy and two independent dependency records. They also transfer it once,
because the lock is keyed on the checksum, so the second session waits
for the first and then finds the bytes already there.

Everything the cache owns is read-only. A caller writing to a returned
path would otherwise damage every package that shares those bytes, so
the write fails at the point of the mistake instead. A caller that needs
a writable layout declares a
[`processor()`](https://gillescolling.com/getaca/reference/processor.md),
which gets its own slot.

The store keeps no metadata of its own. Whether a blob is still needed
is answered by reading the package indexes, so there is no reference
count that a crash, a restored backup or a hand-deleted directory could
leave disagreeing with them.

The processed result of a processor sits beside the raw artefact rather
than replacing it, under a directory named for the processor id.
Changing the transformation means changing the id, which invalidates the
derived tree without touching the download it came from.

`index.rds` is one small file per package holding the provenance
records. It is written to a sibling temporary file and renamed, so a
reader never observes a half-written index. A metadata database was
considered and left out: the volume is tiny, and an atomic per-package
file removes a dependency and a class of locking problems.

## What a cached copy has to prove

Three different questions, three answers, and the entry record keeps
them apart so that “verified” never quietly means “we looked at this
sometime”.

|  | what it does | when it runs | recorded as |
|----|----|----|----|
| full verification | re-hashes the bytes | on download, on `verify = TRUE`, and once the last one is older than `getaca.verify_days` | `verified_at` |
| cheap check | compares size against the entry | on every ordinary access | `checked_at` |
| access | none | on every ordinary access | `accessed_at` |

The cheap check catches truncation, replacement by a different-sized
file, and most accidental edits, for the cost of a
[`file.info()`](https://rdrr.io/r/base/file.info.html) call on a
four-gigabyte file. A same-size substitution passes it, which is the
case the scheduled re-hash exists to catch.

``` r

getaca("wfo", package = "taxify")                 # cheap check
getaca("wfo", package = "taxify", verify = TRUE)  # full re-hash first
options(getaca.verify_days = 30)                  # re-hash more often
```

A cached copy that fails either check raises
`getaca_error_cache_corrupt` rather than being silently refetched, and
the message names the clean-up call. Silent repair would hide a disk
going bad, and hide a colleague who edited a file in the cache
directory.

The failure is a verdict on bytes rather than on the slot that found it.
Bytes live once and every package declaring them holds its own record,
so a mismatch in the shared copy withdraws `verified_at` from every
other slot naming it and each re-hashes on next access. A slot holding
its own copy, which is what a filesystem refusing links leaves, and a
processed tree derived from the bytes are answerable only for
themselves.

The fourth timestamp is `fetched_at`, which never moves. Together the
four answer questions that collapsing them would destroy: a resource
fetched in January, re-hashed in April and read this morning reports
exactly that.

## Provenance

``` r

getaca_info("wfo", package = "taxify")
#> <getaca cache entry> taxify/wfo@2026-06
#>   path        ~/.cache/R/getaca/taxify/wfo/2026-06/raw/wfo-2026-06.zip
#>   sha256      9f9f9f...
#>   size        797,000,000 bytes
#>   license     CC-BY-4.0
#>   built from  wfo_release: 2026-06
#>   resolved by current registry sha256:8b31e0da54cf (published 2026-07-22)
#>   source url  https://host.invalid/wfo-2026-06.zip
#>   getaca      0.0.0.9000
#>   fetched     2026-07-26 11:02:13
#>   verified    2026-07-26 11:09:44 (full re-hash)
#>   checked     2026-07-26 15:31:02 (size and mtime)
```

An uncached resource gives `NULL`, which is what makes the call safe in
a report covering a machine that holds some of the set:

``` r

is.null(getaca_info("wfo", registry = reg))
#> [1] TRUE
```

[`getaca_catalogue()`](https://gillescolling.com/getaca/reference/getaca_catalogue.md)
is the same information across everything, plus the declarations that
have never been downloaded:

``` r

getaca_catalogue(registry = reg)[, c("package", "name", "version",
                                     "current", "declared", "cached")]
#>   package name version current declared cached
#> 1  taxify  wfo 2026-06    TRUE     TRUE  FALSE
```

With no arguments it covers every installed package that ships a
registry together with every package holding cached resources, which is
the report worth pasting into an issue:

``` r

str(getaca_catalogue(), max.level = 1)
#> 'data.frame':    0 obs. of  16 variables:
#>  $ package        : chr 
#>  $ name           : chr 
#>  $ version        : chr 
#>  $ current        : logi 
#>  $ processor      : chr 
#>  $ link           : chr 
#>  $ declared       : logi 
#>  $ cached         : logi 
#>  $ size           : num 
#>  $ license        : chr 
#>  $ source         : chr 
#>  $ registry_digest: chr 
#>  $ verified_at    : 'POSIXct' num 
#>  $ accessed_at    : 'POSIXct' num 
#>  $ pinned         : logi 
#>  $ path           : chr
```

The columns worth knowing: `size` in bytes, `license`, `source` and
`registry_digest` naming the policy and the registry state that resolved
it, the three timestamps, `pinned`, and `path`.

## Two sessions, one download

Two R sessions asking for the same four-gigabyte file must not both
fetch it, and must never mistake each other’s in-flight temporary file
for a finished resource.

The lock is a directory under `.locks/`, named for the declared
checksum. [`dir.create()`](https://rdrr.io/r/base/files2.html) is atomic
on both POSIX and Windows, which makes a directory a portable mutex with
no compiled dependency and no lockfile library.

Keying it on the checksum rather than on the resource triple means the
two sessions need not be asking on behalf of the same package. Two
packages declaring the same file are waiting for the same transfer, and
the one that waits finds the bytes in the store when it wakes.

What a second session does:

1.  tries to create the lock directory, and fails

2.  checks whether the lock is stale, by the age of the holder file
    inside it

3.  waits, polling, until the holder releases

4.  re-reads the cache index, finds the first session’s entry, and
    returns that path

Step 4 is the point. The waiter reads the entry the first session wrote
and returns that path, so the second transfer never starts. The cache
check is repeated after the lock is acquired precisely because the
situation may have changed while waiting.

A lock whose holder died leaves a directory behind. It goes stale after
`getaca.lock_stale_seconds`, defaulting to 1800, after which the next
session removes it and takes over. A session that waits longer than its
timeout gets an error naming the lock path and the
[`unlink()`](https://rdrr.io/r/base/unlink.html) call that clears it, so
a genuinely wedged lock is a one-line fix rather than a support thread.

``` r

options(getaca.lock_stale_seconds = 600)
```

Set it lower for short downloads on a shared machine, higher when a
single transfer legitimately runs for an hour.

## How bytes get in

Transfers land in `.tmp/`, are sized, hashed, and only then moved into
place. An interrupted transfer can never appear as a valid cached
resource, and a failed transfer never touches a copy that was already
good.

The temporary file is named after the declared checksum and the mirror
that produced it. Naming it after the checksum makes an interrupted
download resumable on the next attempt, which matters when the resource
is measured in gigabytes. Giving each mirror its own file matters for a
subtler reason: a partial transfer is resumable only against the host
that produced it, so sharing one file across mirrors would let a failed
attempt at the first be resumed onto by the second, and the resulting
corruption is indistinguishable from the publisher having changed the
bytes.

A resumed transfer that completes but does not verify indicts the
partial file rather than the publisher, so the same mirror is asked once
more from empty before any conclusion is drawn about upstream. Without
that, one stale temporary file makes a resource permanently unfetchable
and blames the wrong party for it.

Verified bytes are then admitted to the store under their own checksum,
and the version slot is given a name for them. Admission is a rename,
since `.tmp/` and `blobs/` share the cache root and therefore share a
filesystem. Bytes already in the store are already named by their
checksum, so admitting the same file a second time is a no-op and the
temporary copy is dropped.

## Retention

CRAN permits
[`tools::R_user_dir()`](https://rdrr.io/r/tools/userdir.html) on
condition that contents are “actively managed (including removing
outdated material)”. `getaca` reads that as a retention policy rather
than a function users might discover, so collection runs automatically
after every successful retrieval.

Five sweeps, cheapest and safest first:

| Sweep | Removes | Clock |
|----|----|----|
| `broken` | entries whose path is missing or fails the cheap check | none |
| `temp` | abandoned transfers in `.tmp/` | 7 days by mtime |
| `superseded` | unpinned versions the registry no longer names | `getaca.supersede_days`, default 30 |
| `lru` | least recently used unpinned entries | only above `getaca.max_bytes`, default 20 GB |
| `unreferenced` | bytes in the store that no entry names any more | none |

The first four sweeps remove names. `unreferenced` runs last and removes
the bytes those names were for, once the last one is gone. A blob under
an active lock is left alone: it belongs to a session that has admitted
it and has not yet written its entry.

The size ceiling measures what the cache occupies, so shared bytes count
once. Two packages declaring the same 4 GB file count 4 GB against
`getaca.max_bytes`, and evicting one of them frees nothing until the
other goes too.

Superseded and not-recently-used age on separate clocks on purpose. An
expensive resource that is still the current version is never dropped
merely for being old; it is dropped only when the cache is over its
ceiling, and then only after everything already useless has gone.

Three things are never removed: pinned entries, the version the registry
currently names, and anything under an active lock.

The automatic pass after a retrieval runs only `broken` and `temp`, the
two sweeps that can only ever remove material which is already useless.
Reclaiming a superseded four-gigabyte version is a decision, so it
happens on a schedule rather than as a side effect of a download.

## Cleaning by hand

``` r

getaca_clean(dry_run = TRUE)
#> [1] package  resource reason   bytes    path    
#> <0 rows> (or 0-length row.names)
```

An empty result on a fresh cache. On a working one, each row names the
package, the resource, the reason and the bytes it would reclaim, which
is the report to read before running it for real.

``` r

getaca_clean(dry_run = TRUE)
#>   package        resource                         reason      bytes
#> 1  taxify taxify/wfo@2026-03 superseded version past retent... 7.97e+08
#> 2    <NA>               <NA>              abandoned transfer 1.20e+07

getaca_clean()                               # run every sweep
getaca_clean(what = "temp")                  # just the abandoned transfers
getaca_clean(package = "taxify")             # one package
getaca_clean("wfo", package = "taxify")      # one resource name
```

Keeping something the sweeps would otherwise take:

``` r

getaca_keep("wfo", package = "taxify")                  # pin it
getaca_keep("wfo", package = "taxify", pinned = FALSE)  # release the pin
```

A pinned entry is exempt from the superseded and LRU sweeps permanently.
It is still subject to the `broken` sweep, because an entry whose bytes
are gone is not worth protecting.

## Settings

Every setting is readable from an option or an environment variable,
with the option taking precedence.

| Option | Environment variable | Default | Controls |
|----|----|----|----|
| `getaca.cache` | `GETACA_CACHE` | `R_user_dir()` | where everything lives |
| `getaca.policy` | `GETACA_POLICY` | registry default | which channel resolves |
| `getaca.verify_days` | `GETACA_VERIFY_DAYS` | 90 | scheduled re-hash interval |
| `getaca.supersede_days` | `GETACA_SUPERSEDE_DAYS` | 30 | retention for undeclared versions |
| `getaca.max_bytes` | `GETACA_MAX_BYTES` | 20 GB | ceiling above which LRU runs |
| `getaca.timeout` | `GETACA_TIMEOUT` | 3600 | transfer timeout in seconds |
| `getaca.lock_stale_seconds` | `GETACA_LOCK_STALE_SECONDS` | 1800 | when a lock is abandoned |
| `getaca.pin_file` |  | `getaca.pins.rds` in the working directory | where pins are read from |

The defaults suit a laptop holding a couple of large reference datasets.
Two are worth revisiting on a shared machine: raise `getaca.max_bytes`
when the cache lives on a volume sized for it, and lower
`getaca.lock_stale_seconds` when transfers are short and a wedged lock
costs more than a rare duplicate download.

``` r

options(
  getaca.cache        = "/mnt/data/getaca",
  getaca.max_bytes    = 200 * 1024^3,
  getaca.verify_days  = 30
)
```

## Moving a cache

Copy the directory. There are no absolute paths recorded inside it, so a
cache built on one machine works on another:

``` r

# on a connected machine
Sys.setenv(GETACA_CACHE = "/tmp/seed")
getaca_prefetch(package = "taxify")

# then, on the machine that has no network
Sys.setenv(GETACA_CACHE = "/opt/getaca")
getaca_catalogue()   # everything already there
```

The same property is what makes CI caching work: the archive an actions
cache restores is the cache, with nothing to rebuild.

## Where to go next

- [`vignette("checks")`](https://gillescolling.com/getaca/articles/checks.md)
  for seeding a cache in CI

- [`vignette("failures")`](https://gillescolling.com/getaca/articles/failures.md)
  for `getaca_error_cache_corrupt` and its neighbours

- [`vignette("policies")`](https://gillescolling.com/getaca/articles/policies.md)
  for what decides which version lands in the cache
