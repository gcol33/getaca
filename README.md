# getaca

*external data your package depends on, pinned to exact bytes*

[![R-CMD-check](https://github.com/gcol33/getaca/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/gcol33/getaca/actions/workflows/R-CMD-check.yaml)
[![Codecov test coverage](https://codecov.io/gh/gcol33/getaca/graph/badge.svg)](https://app.codecov.io/gh/gcol33/getaca)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**One engine that retrieves, verifies, caches and garbage-collects the large data
files your package declares it needs.**

A taxonomic backbone runs to 800 MB, a global climate grid to several GB, a
pretrained model to more. Files that size stay outside the package. Declare one in a
few kilobytes, and retrieving it is one call:

```r
library(getaca)

atlas <- resource(
  "atlas", "2026-06",
  urls   = "https://primary.invalid/atlas-2026-06.zip",
  sha256 = "97f28a53a7912a80c12cc8f26e0c422d9212e067e11479ae61ef0a91b456b53a"
)

reg  <- registry(package = "yourpkg", resources = list(atlas))
path <- getaca("atlas", registry = reg)
```

Write that registry to `inst/getaca/registry.rds` and every later call reaches it
from anywhere, with the package name alone:

```r
path <- getaca("atlas", package = "yourpkg")
```

`getaca` resolves the declaration through an explicit policy, verifies what arrives
against the checksum, records where it came from, and returns an ordinary local
path. The same installed package resolves the same bytes on every machine and in
every rerun.

## What the declaration is for

Downloading a file into a cache directory and checking its hash is a few dozen
lines, and for one file that never moves that is the right amount of code. Two
things come after it, and they are what the declaration carries.

**The data are republished on their own schedule.** A checksum written into your sources
holds until your next release, so a dead mirror or a fresh upstream cut waits for
CRAN. A declaration can name a remote registry you keep: mirrors get repaired,
`2026-09` gets published, and installed copies follow. A version that has been
published still names the bytes it always named, since a registry redefining one is
refused, and the registry can be signed so a user's session can tell your
declaration from anything else that host might one day serve.

**`R CMD check` has no network, and CRAN reads `tools::R_user_dir()` as a cache you
are expected to manage.** Resolution collapses to `offline` under check whatever the
policy says, three helpers cover tests, examples and vignettes, and the retention
sweeps run after every retrieval. That is the part that turns a few dozen lines into
a few hundred, in every package that depends on external data.

So the package ships the declaration and `getaca` does the rest. There is one engine
and many declarations, the way there is one `renv` and many lockfiles.

## Failures that name who can fix them

A retrieval produces the bytes the package was built against, or an error
naming who can act on it. Seven situations get seven answers, each classed so
callers can branch on the cause:

| Condition | Meaning | Who acts |
|---|---|---|
| `getaca_error_unavailable` | no mirror answered | user |
| `getaca_error_offline` | not cached, network not permitted here | user |
| `getaca_error_incomplete` | transfer ended short | user |
| `getaca_error_upstream_changed` | publisher replaced a published version | upstream |
| `getaca_error_cache_corrupt` | local copy drifted from its own record | user |
| `getaca_error_declaration` | every mirror agrees, the registry disagrees | author |
| `getaca_error_composition` | the parts arrived intact and compose to something else | author |

When several independent mirrors return identical bytes and none of them match
the declared checksum, the registry is the likely error, and
`getaca_error_declaration` says so.

Each condition carries an `actor` field, so a declaring package can catch the
ones its users will meet and answer in its own vocabulary:

```r
install_atlas <- function(name = "atlas") {
  path <- tryCatch(
    getaca(name, package = "yourpkg"),
    getaca_error_unavailable = function(e) {
      stop("The atlas is not installed and no network is available.\n",
           "Connect, then run: yourpkg::install_atlas()", call. = FALSE)
    }
  )
  open_atlas(path)
}
```

## Passing `R CMD check` with a 4 GB dependency

Resolution collapses to `offline` under `R CMD check`, whatever policy is set.
Three helpers cover the three contexts CRAN cares about:

```r
# in tests
test_that("the atlas parses", {
  getaca_skip_if_unavailable("atlas", package = "yourpkg")
  expect_s3_class(read_atlas(getaca("atlas", package = "yourpkg")), "atlas")
})

# in examples and vignettes
path <- getaca_optional("atlas", package = "yourpkg")
if (!is.null(path)) summarise_atlas(path)

# anywhere a plain logical is easier
if (getaca_available("atlas", package = "yourpkg")) { }
```

Point `GETACA_CACHE` at a pre-seeded directory and a CI job finds everything
already there. The cache is a plain directory tree, so the usual actions cache
it by key:

```yaml
- uses: actions/cache@v4
  with:
    path: ~/.cache/getaca
    key: getaca-${{ hashFiles('inst/getaca/registry.rds') }}
- run: Rscript -e 'getaca::getaca_prefetch(package = "yourpkg")'
  env:
    GETACA_CACHE: ~/.cache/getaca
```

Keying the cache on the registry file means a new declaration downloads once
and every later job reuses it.

## Records and channels

A **resource record** is immutable: `yourpkg / atlas / 2026-06` names exact bytes
forever. A **channel** maps the logical name onto one record, and channels
move.

| Policy | Resolves through | Use when |
|---|---|---|
| `bundled` | the registry shipped with the package | default; same install, same bytes |
| `current` | author's remote registry, falling back to bundled | mirrors need repair, or data releases outpace CRAN |
| `pinned` | a frozen local snapshot | an analysis must keep resolving what it was written against |
| `offline` | cached and bundled information only | no network permitted |

A remote channel may repair a dead mirror and may publish `2026-09`. `2026-06`
keeps its meaning, and a registry that redefines it is rejected as invalid.

The registry states which record the channel points at. Version strings here
are labels, and `source-2026-06_build-3` has no defensible ordering, so
declaration order cannot stand in for one:

```r
registry(
  package = "yourpkg",
  current = c(atlas = "2026-09"),
  resources = list(
    resource("atlas", "2026-06", urls = "...", sha256 = "..."),
    resource("atlas", "2026-09", urls = "...", sha256 = "...")
  )
)
```

A name offering several versions and naming no head is refused as an invalid
registry. The one mistake this design is exposed to, appending `2026-03` below
`2026-09` and moving every user backwards, becomes an error at `registry()` on
the author's machine.

## Signing what you publish

A remote registry can be signed, so a user's session can tell your declaration
from whatever else the host might one day serve:

```r
public <- registry_keygen("~/.keys/yourpkg.key")   # once, kept out of the repo

registry(package = "yourpkg", remote = "https://host.example/yourpkg.rds",
         keys = public, resources = list(...))

registry_write(reg, "publish/yourpkg.rds")
registry_sign("publish/yourpkg.rds", key = "~/.keys/yourpkg.key")
```

The key travels in the registry your package ships and the declaration comes
from your host, so the two reach a user by different routes. That is what a
signature rests on, and it is why the public key belongs in the installed
package rather than beside the file it vouches for.

The signature covers the declaration, when it was published, and when it stops
being accepted, so an old registry cannot be replayed in place of the current
one. A host that cannot be reached still falls back to the bundled declaration;
a registry that arrives and fails its signature stops instead. Declaring no
keys leaves everything as it was.

## A declaration in full

Everything an author writes, in one file:

```r
# data-raw/registry.R, run at build time
registry_write(
  registry(
    package  = "yourpkg",
    policy   = "current",
    remote   = "https://yourpkg.invalid/getaca-registry.rds",
    current  = c(atlas = "2026-06"),
    resources = list(
      resource("atlas", "2026-06",
               urls = c("https://zenodo.invalid/records/1234567/files/atlas-2026-06.zip",
                        "https://releases.invalid/atlas/2026.06/atlas.zip"),
               sha256 = "9f2c...",
               size   = 4.1e9,
               license = "CC-BY-4.0",
               upstream = list(source_release = "2026-06", build = "3"))
    )
  ),
  "inst/getaca/registry.rds"
)
```

Installing the package copies a few kilobytes. The first real call retrieves,
verifies and caches:

```r
path <- getaca("atlas", package = "yourpkg")
```

Zenodo and GitHub releases both host files this size for free, and listing one of
each is what makes an outage at either survivable. What the rest of the declaration
buys:

- **two mirrors** mean an outage at the first falls through to the second
- **`sha256`** turns a truncated or substituted file into an error at
  retrieval, where it is diagnosable
- **`upstream`** keeps both identities, the publisher's release and the build that
  turned it into the file you ship, so provenance answers which one moved
- **`policy = "current"`** lets a dead mirror be repaired, or `2026-09`
  published, without a CRAN release
- **`current`** states which of the published versions a bare `getaca("atlas")`
  returns

When the publisher issues `2026-09`, the remote registry adds the record and moves
the head. When the publisher replaces `2026-06` in place, the checksum stops
matching, the cached copy is left alone, and the error names the publisher as the
party who changed something.

## What the cached path guarantees

`getaca()` returns a path to a complete file, verified against the declared
checksum, at the resolved version, in a slot `getaca` owns.

Bytes land in `.tmp/`, are sized, hashed, and only then admitted to the cache,
so an interrupted transfer can never appear as a valid cached resource and a
failed transfer never touches a copy that was already good. The temporary file
is named after the declared checksum, so an interrupted download resumes on the
next attempt. Each mirror gets its own temporary file, because a partial
transfer is resumable only against the mirror that produced it.

Bytes then live once, under their own checksum, and a version slot holds a name
for them. Two packages declaring the same file keep one copy and two separate
dependency records, and the second package to ask for it waits for the first
transfer rather than starting its own. Everything the cache owns is read-only,
since shared bytes make one caller's stray write everybody's problem.

Verification asks three questions and keeps the answers apart:

| | when | recorded as |
|---|---|---|
| full re-hash | on download, on `verify = TRUE`, and every `getaca.verify_days` | `verified_at` |
| size check | on ordinary access | `checked_at` |
| use | on ordinary access | `accessed_at` |

"Verified" therefore means the bytes were re-hashed then, rather than that
somebody looked at the file at some point. A mismatch found in shared bytes
reaches every package holding them: the stamp is withdrawn from each slot
naming those bytes, and each re-hashes its own copy on next access.

Two sessions asking for the same 4 GB file wait on a portable directory mutex
keyed on the checksum, and the second observes the first's success. A lock
whose holder died goes stale and is taken over.

## Provenance, and what is cached

```r
getaca_info("atlas", package = "yourpkg")
#> <getaca cache entry> yourpkg/atlas@2026-06
#>   path        ~/.cache/R/getaca/yourpkg/atlas/2026-06/raw/atlas-2026-06.zip
#>   store       hardlink to blobs/sha256/9f/9f2c8d1e5a3b
#>   sha256      9f2c8d1e...
#>   size        4,100,000,000 bytes
#>   license     CC-BY-4.0
#>   built from  source_release: 2026-06
#>   built from  build: 3
#>   resolved by current registry sha256:8b31e0da54cf (published 2026-07-22)
#>   source url  https://zenodo.invalid/records/1234567/files/atlas-2026-06.zip
#>   getaca      0.1.0
#>   fetched     2026-07-26 11:02:13
#>   verified    2026-07-26 11:09:44 (full re-hash)
#>   checked     2026-07-26 15:31:02 (size and mtime)
```

That is a reproducibility appendix, and a bug report that says which mirror
served the bytes and which registry state chose them. The registry digest is
derived from the declaration itself, so it identifies that state exactly.

`getaca_catalogue()` widens it to a data frame covering both halves, every
resource the installed packages declare and every copy the cache holds:

```r
getaca_catalogue()[, c("package", "name", "version", "current", "declared", "cached")]
#>   package  name version current declared cached
#> 1 yourpkg atlas 2026-06    TRUE     TRUE   TRUE
#> 2 yourpkg atlas 2026-03   FALSE    FALSE   TRUE
#> 3 yourpkg  grid 2026-06    TRUE     TRUE  FALSE
```

Row 2 is a copy of a version nothing asks for any more, which is what the
retention sweeps reclaim first. Row 3 is work still to do on this machine.

## Processors

A processor turns one verified path into another: unpacking an archive, or
preparing a package-specific layout. It carries an id, so the processed result
gets its own cache slot and its own provenance.

```r
resource("atlas", "2026-06",
         urls = "https://primary.invalid/atlas-2026-06.zip",
         sha256 = "9f2c...",
         processor = processor("unzip", function(input, output_dir) {
           utils::unzip(input, exdir = output_dir)
           output_dir
         }))
```

Changing what the transformation does means changing the id, which invalidates
previously processed copies. `getaca(..., processed = FALSE)` returns the raw
artefact. `getaca` knows nothing about file formats and never reads data.

## Files that arrive in pieces

A host that caps file size, or a publisher issuing deltas against a base
release, gives you a resource that arrives as a series. Declare the pieces, and
`sha256` describes the artefact they compose:

```r
resource("atlas", "2026-09",
         sha256 = "b104...",
         file   = "atlas.parquet",
         parts  = list(
           part("https://primary.invalid/atlas-base.bin",    sha256 = "91cc..."),
           part("https://primary.invalid/atlas-2026-09.bin", sha256 = "4e77...")
         ))
```

Each part is verified and stored under its own digest, so the base is
transferred once however many versions declare it, and publishing a version
costs your users the delta. The composed result is hashed against the record's
own checksum before anyone sees it, then joins the store exactly as a downloaded
file does.

Parts are concatenated unless the record declares a `combiner()`, which is what
a delta format needs. Either way the artefact is the identity: re-splitting a
file or moving a piece to a new host changes the route, and what a version means
is fixed by the checksum at the end of it.

## Keeping the cache in bounds

CRAN permits `tools::R_user_dir()` on condition that contents are "actively
managed (including removing outdated material)". `getaca` reads that as a
retention policy, and collects after every successful retrieval.

Removal runs cheapest and safest first: broken material, abandoned transfers,
superseded versions past their retention window, least-recently-used entries
once over the size ceiling, and finally bytes that no declaration references any
more. Superseded and not-recently-used age on separate clocks, so an expensive
resource is never dropped merely for being old. Pinned entries, the version the
bundled registry names, and anything under an active lock are never touched.

```r
getaca_clean(dry_run = TRUE)      # what would go, and why
getaca_keep("atlas", package = "yourpkg")  # exempt this one permanently
options(getaca.max_bytes = 50 * 1024^3)  # raise the ceiling
```

## getaca or a companion data package?

| | companion data package | `getaca` |
|---|---|---|
| Size | fits a repository | too large to bundle |
| Release cadence | coupled to code releases | independent of them |
| Shape | naturally R objects | any file, any format |
| Granularity | all of it, always | users take what they need |
| License | redistribution permitted | download permitted, redistribution discouraged |

A companion package can itself use `getaca`, though that is rarely the first
recommendation: it moves the complexity one step along.

## Related work

Several established packages solve neighbouring problems, and one of them may be
the better fit depending on which problem you have.

[**pins**](https://cran.r-project.org/package=pins) publishes "data sets,
models, and other R objects, making it easy to share them across projects and
with your colleagues", across boards including local folders, Posit Connect and
AWS S3. It is built around the person sharing an artefact and the board it
lives on.

[**BiocFileCache**](https://bioconductor.org/packages/BiocFileCache) "creates a
persistent on-disk cache of files that the user can add, update, and retrieve",
for resources that are costly to create or fetched from the web, backed by an
SQLite metadata database.

[**pooch**](https://www.fatiando.org/pooch/) is where Python puts this problem, "a
friend to fetch your data files": a registry of file names and hashes shipped as
package data, a cache folder, one URL per file, and a `version` documented as "the
version string for your project", which names the subfolder the cache uses.

`getaca` is built around a package declaring what it needs. Identity is
`package / name / version`, where the version labels the data rather than the code,
so a channel can move a name onto new bytes between releases. The declaration ships
inside the installed package, and resolution, verification, offline behaviour and
retention are the same for every declaring package because there is one engine.

## Dependencies

`Imports: curl`, plus `stats`, `tools` and `utils` from base R. Recursive
footprint outside base R: **zero packages**. YAML and JSON registries, testthat
helpers and vignettes live in `Suggests` and are gated at call time.

Hashing is SHA-256 in C, in `src/sha256.c`, with no `LinkingTo` and nothing to
configure. Where the CPU has SHA-256 instructions the block compression uses
them, which puts verification at disk speed: 1.43 GB/s on an i9-14900K, so a
4 GB resource is verified in under three seconds.

## What's in the box

- **`getaca()`** retrieve a declared resource, return a local path
- **`resource()`** declare one immutable record
- **`registry()`** collect a package's declarations and name the channel head
- **`registry_write()`** ship them at `inst/getaca/registry.rds`
- **`registry_digest()`**, **`registry_manifest()`** the identity of a
  declaration state, and the text it is taken over
- **`as_registry()`** build one from a YAML or JSON authoring file
- **`part()`**, **`combiner()`** declare a record that arrives as a series, and
  how the series composes
- **`processor()`** declare a post-verification transformation
- **`getaca_info()`** full provenance for a cached resource
- **`getaca_catalogue()`** what is declared, what is current, what is cached
- **`getaca_refresh()`** forget cached registry state within a session
- **`getaca_prefetch()`** warm a cache before going offline
- **`getaca_pin()`** freeze current resolution into a pin file
- **`getaca_keep()`** exempt a resource from collection
- **`getaca_clean()`** run the retention sweeps by hand
- **`getaca_available()`**, **`getaca_optional()`**, **`getaca_skip_if_unavailable()`** check-safe access
- **`getaca_policy()`**, **`getaca_cache_dir()`** settings

## Installation

```r
install.packages("pak")
pak::pak("gcol33/getaca")
```

## Documentation

- [Quick start](https://gillescolling.com/getaca/articles/quickstart.html)
- [Declaring resources](https://gillescolling.com/getaca/articles/declaring.html)
- [Policies and channels](https://gillescolling.com/getaca/articles/policies.html)
- [Surviving R CMD check and CI](https://gillescolling.com/getaca/articles/checks.html)
- [The cache](https://gillescolling.com/getaca/articles/cache.html)
- [Handling failures](https://gillescolling.com/getaca/articles/failures.html)
- [Migrating an existing downloader](https://gillescolling.com/getaca/articles/migrating.html)
- [Choosing between getaca and the alternatives](https://gillescolling.com/getaca/articles/alternatives.html)
- [Function reference](https://gillescolling.com/getaca/reference/index.html)

## Support

> "Software is like sex: it's better when it's free." — Linus Torvalds

I'm a PhD student who builds R packages in my free time because I believe good tools
should be free and open. I started these projects for my own work and figured others
might find them useful too.

If this package saved you some time, buying me a coffee is a nice way to say thanks.
It helps with my coffee addiction.

[![Buy Me A Coffee](https://img.shields.io/badge/-Buy%20me%20a%20coffee-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/gcol33)

## License

MIT (see the LICENSE.md file)

## Citation

```bibtex
@software{getaca,
  author = {Colling, Gilles},
  title = {getaca: Reproducible External Data Dependencies for R Packages},
  year = {2026},
  url = {https://github.com/gcol33/getaca}
}
```
