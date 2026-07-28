# Declaring Resources

For package authors: what to declare, where to put it, and which policy
to choose. The reader here is someone whose package needs a file that is
too large, too fast-moving, or too awkwardly licensed to sit in `data/`.

Everything a declaring package owes `getaca` is one serialised object at
`inst/getaca/registry.rds`. There is no `Depends`, no `.onLoad()` hook,
no registration call, and no runtime coupling beyond calling
[`getaca()`](https://gillescolling.com/getaca/reference/getaca.md) when
a resource is actually needed.

## Records and channels

Two things that must not be conflated.

A **resource record** is immutable. `yourpkg / backbone / 2026-06` names
exact bytes, permanently. If the publisher reissues that file with
different contents, that is an upstream mutation and `getaca` refuses
it.

A **channel** maps a logical name onto a record, and channels move.
Where the channel is read from is the resolution policy.

| Policy | Reads the channel from | Use when |
|----|----|----|
| `bundled` | the registry inside the installed package | default |
| `current` | the author’s remote registry, falling back to bundled | data releases outpace your CRAN releases |
| `pinned` | a frozen local snapshot | an analysis must stay put |
| `offline` | nothing; cache and bundled information only | no network permitted |

`bundled` is the default because a dependency that resolves differently
on different days is not a dependency. See
`dev_notes/adr-001-registry-resolution.md` in the source for the
reasoning, and
[`vignette("policies")`](https://gillescolling.com/getaca/articles/policies.md)
for the operational detail.

## Anatomy of a record

``` r

rec <- resource(
  name        = "backbone",
  version     = "2026-06",
  urls        = c("https://zenodo.invalid/records/1234567/files/backbone-2026-06.zip",
                  "https://mirror.invalid/backbone-2026-06.zip"),
  sha256      = strrep("9f", 32),
  size        = 797e6,
  license     = "CC-BY-4.0",
  description = "Reference backbone, June 2026 release"
)
rec
#> <getaca resource record>
#>   name      backbone
#>   version   2026-06
#>   sha256    9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f
#>   size      7.97e+08
#>   license   CC-BY-4.0
#>   urls      https://zenodo.invalid/records/1234567/files/backbone-2026-06.zip
#>              https://mirror.invalid/backbone-2026-06.zip
```

**`name`** becomes a directory name, so it is restricted to
`[A-Za-z0-9._-]`. It is scoped by your package, so a short name is fine
and `"backbone"` will never collide with another package’s `"backbone"`.

**`version`** is a label under the same character restriction. `getaca`
never orders version strings, which is what lets you use whatever your
upstream actually publishes: `2026-06`, `v14.2`, `2026-06_build-3`. Pick
a scheme and keep it; the only rule the package enforces is that a
label, once published, keeps meaning the same bytes.

**`urls`** are tried in order. All must be `https://`. More than one is
worth the trouble: an outage at your primary becomes a slower first call
rather than a support issue.

**`sha256`** is the point of the whole design. It is the digest of the
file as served, which is not always the digest of the file you built: if
your host recompresses, or you upload a re-zipped copy, compute the hash
after the upload by downloading it back.
[`registry_draft()`](https://gillescolling.com/getaca/reference/registry_draft.md),
below, does exactly that.

**`size`** in bytes is optional and cheap. A transfer that ends short is
detected before a multi-gigabyte hash runs, and reported as a truncation
rather than as a checksum mismatch, which points the user at a retry
instead of at the publisher.

**`license`** travels into every provenance record, so a downstream
result can report what terms its inputs came under.

**`description`** is one line for humans reading
[`getaca_catalogue()`](https://gillescolling.com/getaca/reference/getaca_catalogue.md)
output.

**`file`** is optional and names the cached file. The default is the
file name in the first URL, which is right until the URL ends in
`download?id=7`, and which a record composed from parts has to state for
itself.

Malformed records are refused where they are written, with the problem
named:

``` r

resource("backbone", "2026-06",
         urls = "http://insecure.invalid/backbone.zip",
         sha256 = strrep("9f", 32))
#> Error:
#> ! Invalid getaca registry.
#>   - resource 'backbone': all URLs must use https
#> 
#> Fix: the declaring package needs a correction. Report it to its maintainer.
```

``` r

resource("backbone", "2026-06",
         urls = "https://ok.invalid/backbone.zip",
         sha256 = "not-a-digest")
#> Error:
#> ! Invalid getaca registry.
#>   - resource 'backbone': `sha256` must be 64 lowercase hex characters
#> 
#> Fix: the declaring package needs a correction. Report it to its maintainer.
```

## Drafting from where the data is

Typing a record by hand is fine for everything except the checksum,
which has to come from the bytes.
[`registry_draft()`](https://gillescolling.com/getaca/reference/registry_draft.md)
takes the locations, retrieves each file once, hashes it locally and
returns a registry:

``` r

reg <- registry_draft(
  c(backbone = "https://zenodo.org/records/1234567/files/backbone-2026-06.zip"),
  package = "yourpkg",
  version = "2026-06"
)
```

A location is a plain URL, or an identifier for an archive holding
several files. Which one it is, and which archive, is read off the
string:

``` r

registry_draft("10.5281/zenodo.4924875", package = "yourpkg")
registry_draft("10.6084/m9.figshare.14763051.v1", package = "yourpkg")
registry_draft("10.11588/data/TKCFEF", package = "yourpkg")
```

Zenodo and figshare register their own DOI prefixes, so those are
recognised from the string with no lookup. A Dataverse instance is
self-hosted under its own prefix, so a bare DOI is resolved through
`doi.org` to find which host to ask. Each archive supplies what it
knows: the licence, the version, and a DOI for the artefact. Zenodo
mints a record id per version and that becomes the version label;
figshare and Dataverse carry their own version numbers. For a plain URL
there is nothing to infer, so `version =` is required.

Checksums the archive reports are read past. All three publish md5, and
all three publish it from the host that serves the file, so it says
nothing the transfer has not already said. What ends up in the record is
a SHA-256 computed here, from the bytes that arrived.

A draft is a starting point. Resources are named after their files,
which is rarely the name you want a user to type, and `description` is
empty. Both are ordinary
[`resource()`](https://gillescolling.com/getaca/reference/resource.md)
arguments: edit the returned registry, or write the
[`registry_draft()`](https://gillescolling.com/getaca/reference/registry_draft.md)
call into `data-raw/` and edit around it. Give a name in the call where
a location is one file:

``` r

reg <- registry_draft(
  list(backbone = c("https://zenodo.org/records/1234567/files/backbone-2026-06.zip",
               "https://mirror.invalid/backbone-2026-06.zip")),
  package = "yourpkg",
  version = "2026-06"
)
registry_write(reg, "inst/getaca/registry.rds")
```

A list element is the mirrors of one resource. The first is retrieved
and hashed; the rest are recorded and walked at fetch time like any
other mirror list.

Drafting a large record downloads it. Pass `keep = TRUE` to leave the
bytes in the cache, so the first
[`getaca()`](https://gillescolling.com/getaca/reference/getaca.md) call
for the drafted resource finds them already there.

## Assembling the registry

``` r

reg <- registry(
  package   = "yourpkg",
  resources = list(rec)
)
reg
#> <getaca registry> yourpkg  (policy "bundled")
#>   digest: sha256:2306bcc9fb14
#>   - backbone@2026-06  9f9f9f9f9f9f  [CC-BY-4.0]
```

The digest on the second line identifies this registry state. It is
derived from the declaration itself, so there is no number to keep in
step: change a checksum, add a mirror or move a channel head and the
digest follows. It is recorded in the provenance of everything resolved
through this registry, so a bug report can name the exact declaration
that chose the bytes.

``` r

registry_digest(reg)
#> [1] "sha256:2306bcc9fb140caf3b95ccd11d7c09dbd724d65403b67d81739e6567c2e1d2aa"
```

[`registry_manifest()`](https://gillescolling.com/getaca/reference/registry_manifest.md)
shows the text that digest is taken over, which is what makes two
registries diffable when they disagree:

``` r

registry_manifest(reg)
#> getaca-manifest 1
#> package yourpkg
#> resource backbone 2026-06
#>   sha256 9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f
#>   size 797000000
#>   license CC-BY-4.0
#>   url https://zenodo.invalid/records/1234567/files/backbone-2026-06.zip
#>   url https://mirror.invalid/backbone-2026-06.zip
```

Write it into the source tree from a `data-raw/` script, so the registry
is generated rather than hand-maintained:

``` r

# data-raw/registry.R
registry_write(reg, "inst/getaca/registry.rds")
```

Add `^data-raw$` to `.Rbuildignore` and the script stays out of the
built package while the object it produces ships.

Reading it back is symmetric, and validates:

``` r

path <- file.path(tempdir(), "registry.rds")
registry_write(reg, path)
identical(registry_digest(registry_read(path)), registry_digest(reg))
#> [1] TRUE
```

Writing stamps `created`, because publishing a state is what dates it.
That date is what orders two states in time, which a digest cannot do: a
digest says whether two registries are the same, and `created` says
which came first. It sits outside the digest, so writing an unchanged
registry out again leaves its identity alone. Pass a fixed `created`
when a build has to be byte-reproducible.

``` r

registry_read(path)$created
#> [1] "2026-07-29 00:48:24 CEST"
```

## Naming the channel head

A registry that offers one version per name has nothing to decide. One
that offers several has to say which one a bare request returns:

``` r

reg2 <- registry(
  package = "yourpkg",
  current = c(backbone = "2026-09"),
  resources = list(
    resource("backbone", "2026-06",
             urls = "https://host.invalid/backbone-2026-06.zip",
             sha256 = strrep("9f", 32), license = "CC-BY-4.0"),
    resource("backbone", "2026-09",
             urls = "https://host.invalid/backbone-2026-09.zip",
             sha256 = strrep("ab", 32), license = "CC-BY-4.0")
  )
)
reg2
#> <getaca registry> yourpkg  (policy "bundled")
#>   digest: sha256:b1a5245a079d
#>   - backbone@2026-06  9f9f9f9f9f9f  [CC-BY-4.0]
#>   - backbone@2026-09  abababababab  [CC-BY-4.0]  (current)
```

The head is marked when the registry prints, and appears as a column in
the catalogue:

``` r

getaca_catalogue(registry = reg2)[, c("name", "version", "current", "declared")]
#>       name version current declared
#> 1 backbone 2026-06   FALSE     TRUE
#> 2 backbone 2026-09    TRUE     TRUE
```

Leaving it out is an error rather than a default, because the failure it
prevents is silent. A registry appending `2026-03` after `2026-09` under
a declaration-order rule moves every user backwards without any of them
noticing:

``` r

registry(
  package = "yourpkg",
  resources = list(
    resource("backbone", "2026-09",
             urls = "https://host.invalid/a",
             sha256 = strrep("ab", 32)),
    resource("backbone", "2026-03",
             urls = "https://host.invalid/b",
             sha256 = strrep("cd", 32))
  )
)
#> Error:
#> ! Invalid getaca registry for package 'yourpkg'.
#>   - resource 'backbone' declares 2 versions (2026-09, 2026-03) but the registry names no current one; add current = c("backbone" = "2026-03")
#> 
#> Fix: the declaring package needs a correction. Report it to its maintainer.
```

The head names a version, so moving it is one edit and the old record
stays resolvable by `getaca(..., version = "2026-06")` for as long as
you keep declaring it. Dropping a record from the registry does not
delete anyone’s cached copy; it marks it undeclared, which is what makes
it eligible for the superseded sweep after the retention window.

## Choosing `current`

Set it once, in the registry, if your data genuinely release on their
own schedule:

``` r

remote_reg <- registry(
  package = "yourpkg",
  policy  = "current",
  remote  = "https://yourpkg.invalid/getaca-registry.rds",
  resources = list(
    resource("backbone", "2026-06",
             urls   = "https://primary.invalid/backbone-2026-06.zip",
             sha256 = strrep("9f", 32),
             license = "CC-BY-4.0")
  )
)
```

The remote file is a static artefact on GitHub Pages, r-universe or
institutional hosting. An unreachable one falls back to the bundled
registry with a message, which is what CRAN requires when an Internet
resource is unavailable, so the hosting bar is low enough that a `docs/`
directory clears it.

What the remote channel may do:

- repair or add mirrors for a record that already exists

- publish new versions, and move the channel head onto one

What it may not do: change the checksum attached to a version that
already exists. That is rejected as an invalid registry, attributed to
you rather than to the publisher, because a remote file that can
silently redefine published bytes would undo the guarantee the whole
design exists to provide.

Publishing a remote registry is the same call with a different
destination:

``` r

# In a release script, after adding the new record
registry_write(reg2, "docs/getaca-registry.rds")   # served by GitHub Pages
```

Users on `bundled` are unaffected until they reinstall; users on
`current` pick it up on their next session, or immediately after
[`getaca_refresh()`](https://gillescolling.com/getaca/reference/getaca_refresh.md).

## Derived artefacts

Publishing a prepared database rather than the raw upstream release is
often the better deal for users, who then skip the expensive
preprocessing. Record both identities so provenance keeps them:

``` r

resource(
  name    = "backbone-db",
  version = "source-2026-06_build-3",
  urls    = "https://example.invalid/backbone-db-3.duckdb",
  sha256  = strrep("ab", 32),
  license = "CC-BY-4.0",
  upstream = list(
    source_release    = "2026-06",
    build = "3"
  )
)
#> <getaca resource record>
#>   name      backbone-db
#>   version   source-2026-06_build-3
#>   sha256    abababababababababababababababababababababababababababababababab
#>   size      unknown
#>   license   CC-BY-4.0
#>   urls      https://example.invalid/backbone-db-3.duckdb
#>   built from
#>     source_release: 2026-06
#>     build: 3
```

`upstream` is a free-form named list. Every entry is printed by
[`getaca_info()`](https://gillescolling.com/getaca/reference/getaca_info.md)
and kept in the cache index, so a user asking “which upstream release is
this, and which build turned it into a database” gets both answers from
one call. Two things move independently here: upstream can publish
`2026-09`, and you can fix a build bug against `2026-06`. Version labels
like `source-2026-06_build-3` keep both visible in the identity itself.

`getaca` does not care whether bytes are an official release or
something you built. It retrieves and verifies what you declared; your
package owns their scientific meaning.

## Files that arrive in parts

Two situations call for a record whose bytes arrive in pieces. Your host
caps the size of a single file, so a 6 GB database goes up as chunks. Or
upstream publishes a base release and then issues deltas against it,
because each delta is a hundredth of the size of the thing it updates.

Declare the pieces with
[`part()`](https://gillescolling.com/getaca/reference/part.md) and the
artefact they compose with `sha256`, as usual:

``` r

series <- resource(
  name    = "backbone",
  version = "2026-09",
  sha256  = strrep("b1", 32),
  size    = 812e6,
  file    = "backbone.parquet",
  license = "CC-BY-4.0",
  parts   = list(
    part("https://zenodo.invalid/records/456/files/backbone-base.bin",
         sha256 = strrep("91", 32), size = 797e6),
    part("https://zenodo.invalid/records/456/files/backbone-2026-06.bin",
         sha256 = strrep("4e", 32), size = 9.1e6),
    part("https://zenodo.invalid/records/456/files/backbone-2026-09.bin",
         sha256 = strrep("77", 32), size = 5.4e6)
  )
)
series
#> <getaca resource record>
#>   name      backbone
#>   version   2026-09
#>   sha256    b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1
#>   size      8.12e+08
#>   license   CC-BY-4.0
#>   file      backbone.parquet
#>   composed  3 parts via 'concat'
#>     919191919191  7.97e+08  https://zenodo.invalid/records/456/files/backbone-base.bin
#>     4e4e4e4e4e4e  9,100,000  https://zenodo.invalid/records/456/files/backbone-2026-06.bin
#>     777777777777  5,400,000  https://zenodo.invalid/records/456/files/backbone-2026-09.bin
```

A record names locations for the whole file or the parts it is composed
from, so `urls` and `parts` are alternatives and declaring both is
refused. Each part is fetched through the same mirror walk, verified
against its own checksum, and stored under its own digest. The pieces
are then combined, the result is hashed against the record’s `sha256`,
and it joins the store exactly as a downloaded file does. Everything
after that point is identical: the same blob, the same cached path, the
same periodic re-verification, the same
[`getaca_info()`](https://gillescolling.com/getaca/reference/getaca_info.md).

Storing each part under its own digest is what makes the next version
cheap. The base above is one blob, and every version declaring it points
at that blob, so `2026-12` costs your users the new delta rather than
812 MB. The trade is disk: the parts stay for as long as some cached
version still names them, which is what keeps the saving available.

**`sha256` still describes the artefact**, which is the rule everything
else follows from. A version means the bytes its checksum names and
nothing about the route to them, so re-splitting a file at different
boundaries, adding a mirror for one piece, or moving the series to a new
host are all changes of route. Your users are held to the artefact
either way, and a series that does not produce it is reported against
the declaration:

``` r

getaca("backbone", package = "yourpkg")
#> Error: The parts declared for yourpkg/backbone@2026-09 do not produce the declared bytes.
#>   3 parts, each matching its own checksum, combined by 'concat'
#>   declared SHA-256: b1b1b1...
#>   composed SHA-256: 2c40f9...
#>
#> Every part arrived intact, so this is not a transfer problem.
```

### Combining by something other than concatenation

Parts are concatenated in declaration order, which is what a file split
for an upload limit needs. A delta format needs
[`combiner()`](https://gillescolling.com/getaca/reference/combiner.md),
since applying a patch is knowledge about a file format and `getaca` has
none:

``` r

apply_deltas <- combiner("bsdiff", function(parts, output) {
  current <- parts[1]
  for (delta in parts[-1]) {
    current <- bspatch(current, delta, tempfile())
  }
  file.copy(current, output)
})
apply_deltas
#> <getaca combiner> bsdiff
```

The function receives the verified part paths in declaration order and
the file to write. Attach it with `combiner = apply_deltas`. Like a
processor, it carries an id, and the manifest records that id rather
than the closure. Unlike a processor, what it produced is checked
against the record’s own `sha256` before anyone sees it, so an id is all
the manifest needs: the checksum is what says the result is right.

Order matters more here than it does for mirrors. Mirrors are tried in
the order given and any one of them ends the walk; parts are combined in
the order given, so two orderings of one series are two different
artefacts, and reordering a series changes the registry digest.

So the two situations this section opened with are the same declaration
with a different combiner. A file split for an upload limit is
[`part()`](https://gillescolling.com/getaca/reference/part.md) and the
default. A base with deltas against it is
[`part()`](https://gillescolling.com/getaca/reference/part.md) and a
[`combiner()`](https://gillescolling.com/getaca/reference/combiner.md)
that knows the delta format.

### A series that keeps growing

For a base with deltas, each version declares the whole series from the
base onwards: `2026-12` is the base and three deltas. Your users still
transfer only the new delta, since the earlier pieces are already blobs
in their store, and the combiner reapplies the chain from the base each
time. That is local work rather than transfer, and for most formats it
is the cheaper of the two by a wide margin.

When the chain gets long enough that reapplying it stops being cheap,
publish the composed artefact of each version alongside its deltas and
anchor the next version on it:

``` r

resource(
  name    = "backbone",
  version = "2026-12",
  sha256  = strrep("c2", 32),
  file    = "backbone.parquet",
  parts   = list(
    # The artefact of 2026-09, at its published checksum.
    part("https://zenodo.invalid/records/456/files/backbone-2026-09.parquet",
         sha256 = strrep("b1", 32)),
    part("https://zenodo.invalid/records/789/files/backbone-2026-12.bin",
         sha256 = strrep("d3", 32))
  ),
  combiner = apply_deltas
)
```

Nothing new is needed for this, and it costs nothing extra to the users
it does not help. A machine holding `2026-09` already has those bytes
under that digest, finds them in the store, and applies one delta. A
machine holding nothing downloads the previous artefact whole and
applies one delta. Which happens is decided by what is in the store, and
the record reads the same either way.

## Processors

A processor turns one verified path into another. It carries a stable
id, so the derived result gets its own cache slot and its own provenance
rather than being confused with the archive it came from.

Most declarations of an archive want the same transformation, so it is
shipped.
[`unpack()`](https://gillescolling.com/getaca/reference/unpack.md) reads
the format from the cached file’s name:

``` r

archive <- resource(
  name      = "backbone",
  version   = "2026-06",
  urls      = "https://host.invalid/backbone-2026-06.zip",
  sha256    = strrep("9f", 32),
  license   = "CC-BY-4.0",
  processor = unpack()
)
archive
#> <getaca resource record>
#>   name      backbone
#>   version   2026-06
#>   sha256    9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f
#>   size      unknown
#>   license   CC-BY-4.0
#>   urls      https://host.invalid/backbone-2026-06.zip
#>   processor unpack
```

It covers `.zip`, the tarballs under any compression (`.tar`, `.tar.gz`,
`.tgz`, `.tar.bz2`, `.tbz2`, `.tar.xz`, `.txz`) and a single compressed
file (`.gz`, `.bz2`, `.xz`), which is decompressed under its own name
with the extension dropped. Name the format for a file whose name does
not carry one:

``` r

unpack("gzip")$id
#> [1] "unpack-gzip"
```

A large archive holding one subtree you need takes `members`, which
names a file, or a directory and everything under it:

``` r

unpack(members = "tables")$id
#> [1] "unpack-d98a034f"
```

The id encodes the settings for a reason. It is what the cache slot and
the registry manifest are keyed on, so two records asking for different
subsets of one archive must not resolve to one slot. A name that matches
nothing in the archive is an error rather than an empty result, since
getaca hashes the archive and never looks at what came out of it: an
empty slot would pass every later check.

### Writing your own

Anything else is a function of two arguments:

``` r

index <- processor("index-v1", function(input, output_dir) {
  out <- file.path(output_dir, "backbone.tsv")
  write.table(read.csv(input), out, sep = "\t", row.names = FALSE)
  out
})
index$id
#> [1] "index-v1"
```

The function receives the verified input path and a staging directory,
and returns a path inside that directory. `getaca` renames the staging
directory into place once the function returns, so a processor that
fails part-way leaves no half-built result. A returned path outside the
output directory is an error, since the cache would then hold an entry
pointing somewhere it does not own.

Changing what the transformation does means changing the id.
`"index-v1"` to `"index-v2"` invalidates previously processed copies
without touching the raw artefact they were built from, so users re-run
the transformation rather than re-downloading gigabytes.
`getaca(..., processed = FALSE)` returns the raw artefact for anyone who
wants it.

Keep processors cheap and pure. They run inside the per-resource lock,
so a processor that takes ten minutes blocks a second session for ten
minutes. If the transformation is expensive enough to matter, publishing
the derived artefact as its own record is usually the better trade.

## Authoring in YAML

The stored form is an R object, so no parser is ever a hard dependency.
YAML and JSON are accepted at authoring time and gated at call time:

``` r

reg <- as_registry("data-raw/resources.yml", package = "yourpkg")
registry_write(reg, "inst/getaca/registry.rds")
```

``` yaml
backbone:
  version: "2026-06"
  urls:
    - https://primary.invalid/backbone-2026-06.zip

    - https://mirror.invalid/backbone-2026-06.zip
  sha256: "9f9f..."
  size: 797000000
  license: CC-BY-4.0
  description: Reference backbone, June 2026

grid:
  version: "2026-06"
  url: https://primary.invalid/grid-2026-06.zip
  sha256: "ab12..."
  license: CC-BY-4.0
```

Either `urls` or `url` is accepted, and either `license` or `licence`,
since a YAML file is input rather than API. The model has one spelling
for each.

The authoring format keys on resource name, so it describes one version
per name. A registry that offers several versions of a name is built in
R, where the list is a list and `current` sits beside it. Arguments
passed to
[`as_registry()`](https://gillescolling.com/getaca/reference/as_registry.md)
reach
[`registry()`](https://gillescolling.com/getaca/reference/registry.md):

``` r

as_registry("data-raw/resources.yml", package = "yourpkg",
            policy = "current",
            remote = "https://yourpkg.invalid/getaca-registry.rds")
```

JSON works the same way through `jsonlite`. Both are `Suggests`, and
asking for one you have not installed produces an install instruction
rather than a missing-object error.

## Handing errors to your users

Every failure is classed, and carries an `actor` field naming who can
act. Catch the ones your users will meet and say something
domain-specific:

``` r

install_backbone <- function(name = "backbone") {
  path <- tryCatch(
    getaca(name, package = "yourpkg"),
    getaca_error_unavailable = function(e) {
      stop("The backbone is not installed and cannot be downloaded ",
           "because no network connection is available.\n",
           "Connect to the internet and run:\n",
           "  yourpkg::install_backbone(\"backbone\")", call. = FALSE)
    }
  )
  open_backbone(path)
}
```

`getaca_error_offline` is a subclass of `getaca_error_unavailable`, so
the handler above catches both, and a narrower handler can separate
them.

Two conditions name you rather than your user.
`getaca_error_invalid_registry` means the declaration is malformed or
internally inconsistent, and `getaca_error_declaration` means several
independent mirrors agreed with each other and disagreed with your
checksum. Neither is worth catching in your own package: they are bug
reports, and the default message already says so.
[`vignette("failures")`](https://gillescolling.com/getaca/articles/failures.md)
covers the full set.

## Hosting

Immutable hosting makes all of this easier, and Zenodo gives it away: a
versioned DOI resolves to bytes that cannot change under you. Deposit
the data, pin the version DOI’s file URL, and the upstream-mutation case
stops being possible for the copy you control.

GitHub Releases work as a second mirror. Release assets are stable once
uploaded, they are served from a CDN, and the tag names a version in a
way that reads well beside the record’s own label.

An archive is consulted when a registry is written and never when a user
fetches.
[`registry_draft()`](https://gillescolling.com/getaca/reference/registry_draft.md)
is the whole of it, and what it produces is a list of `https://`
locations, which are what ship. A Zenodo file URL is derivable from the
record anyway: `10.5281/zenodo.1234567` and a file name give
`https://zenodo.org/records/1234567/files/<name>`, which is a `urls`
entry like any other. Record the identifier itself in `doi =`, where it
is cited from rather than fetched from:

``` r

resource(
  "backbone", "2026-06",
  urls = "https://zenodo.org/records/1234567/files/backbone-2026-06.zip",
  doi = "10.5281/zenodo.1234567",
  sha256 = "...", license = "CC-BY-4.0"
)
```

The DOI travels into provenance and appears in
[`getaca_info()`](https://gillescolling.com/getaca/reference/getaca_info.md)
and
[`getaca_catalogue()`](https://gillescolling.com/getaca/reference/getaca_catalogue.md),
so an analysis can report the identifier for the exact bytes it read.

## Data behind a registration

Some archives serve their files only to a registered account. A
declaration says which credential a host requires; it never carries one.
[`bearer()`](https://gillescolling.com/getaca/reference/getaca-auth.md)
and
[`basic()`](https://gillescolling.com/getaca/reference/getaca-auth.md)
name environment variables, and
[`auth_host()`](https://gillescolling.com/getaca/reference/getaca-auth.md)
binds a scheme to the host it applies to:

``` r

registry(
  package = "canopy",
  auth = list(
    auth_host("data.ornldaac.earthdata.nasa.gov",
              bearer("EARTHDATA_TOKEN"),
              register = "https://urs.earthdata.nasa.gov/users/new")
  ),
  resources = list(
    resource("gedi-l4a", "2026-06",
             urls = "https://data.ornldaac.earthdata.nasa.gov/gedi/l4a-2026-06.h5",
             sha256 = "...", license = "CC-BY-4.0")
  )
)
```

The credential is read from the environment at the moment of the
request. It is never stored, never written to the cache, never recorded
in provenance and never printed. It travels as an `Authorization`
header, which libcurl withholds from a redirect to another host, and
these archives redirect to object storage routinely. A token carried in
a query string would have neither protection and would appear in every
error message listing the URLs that were tried, so one is not accepted.

A credential belongs to a host rather than to a file, so the declaration
is matched by host: a record listing an authenticated mirror beside a
public one presents the credential to the first and not to the second,
and a record that falls through to the public mirror simply succeeds.
Hosts match exactly, without wildcards.

Credentials are read from the registry the package *ships*, never from a
remote one, for the reason signing keys are. A declaration arriving over
the network that could name the hosts a credential is sent to would be
able to nominate its own.

Say plainly in your documentation which variable a user sets and where
they register.
[`getaca_credentials()`](https://gillescolling.com/getaca/reference/getaca_credentials.md)
reports both, and whether the variable is set, without touching the
network:

``` r

getaca_credentials(package = "canopy")
```

The reproducibility promise narrows for these resources, from every
machine getting the same bytes to every machine holding the credential
getting the same bytes. Weigh that against a public mirror before
declaring one.

## Testing your declaration

The registry is an ordinary object, so the parts worth testing are
testable without a network:

``` r

test_that("the shipped registry is valid and names a head", {
  reg <- registry_for("yourpkg")
  expect_s3_class(reg, "getaca_registry")
  expect_equal(resolve_resource("backbone", registry = reg)$id$version, "2026-06")
})

test_that("the backbone parses when it is available", {
  getaca_skip_if_unavailable("backbone", package = "yourpkg")
  expect_s3_class(read_backbone(getaca("backbone", package = "yourpkg")), "backbone")
})
```

The first runs everywhere, including on CRAN, because it never leaves
the installed package. The second skips cleanly when the resource is
absent and names how to prefetch it.

Registries are read once per session and cached, so a test that installs
a registry into a temporary library needs
[`getaca_refresh()`](https://gillescolling.com/getaca/reference/getaca_refresh.md)
to make the next lookup take effect.

## Before you ship

`inst/getaca/registry.rds` written by
[`registry_write()`](https://gillescolling.com/getaca/reference/registry_write.md)
from a `data-raw/` script

every checksum computed from the file as served, not from a local copy
you built

`size` recorded, so truncation is caught before a full re-hash

at least one mirror, ideally on a host you control

`current` set for any name that declares more than one version

[`registry_digest()`](https://gillescolling.com/getaca/reference/registry_digest.md)
changed since the last release, if the declaration did

`license` on every record

tests use
[`getaca_skip_if_unavailable()`](https://gillescolling.com/getaca/reference/getaca-checks.md)

examples use
[`getaca_optional()`](https://gillescolling.com/getaca/reference/getaca-checks.md),
or `\donttest{}` for large resources

`R CMD check` passes with no network available
