# Declare a package's external resources

A registry is one package's declaration of what it needs. It carries no
download logic: getaca is the single engine, and every package supplies
only its own list of resource records.

## Usage

``` r
registry(
  package,
  resources,
  remote = NULL,
  policy = c("bundled", "current", "pinned", "offline"),
  current = NULL,
  keys = NULL
)
```

## Arguments

- package:

  Name of the declaring package. Becomes part of every resource identity
  and scopes the cache, so two packages declaring the same resource name
  never collide.

- resources:

  A list of
  [`resource()`](https://gillescolling.com/getaca/reference/resource.md)
  records, or a single record.

- remote:

  Optional URL of an author-controlled registry file. Consulted only
  under the `"current"` policy. It may repair or add mirrors and may
  introduce new versions. It may never change the bytes a published
  version refers to.

- policy:

  Default resolution policy for this package. One of `"bundled"`,
  `"current"`, `"pinned"`, `"offline"`. See
  [`getaca_policy()`](https://gillescolling.com/getaca/reference/getaca_policy.md).

- current:

  Named character vector giving the channel head: the version a bare
  request for each resource name resolves to, as `c(wfo = "2026-09")`.
  Required for any name declaring more than one version, and optional
  for the rest, since a name with one version has only one answer.

- keys:

  Public keys, from
  [`registry_keygen()`](https://gillescolling.com/getaca/reference/registry_keygen.md),
  that may sign this package's remote registry. Declaring any of them
  makes a signature mandatory under the `"current"` policy: an unsigned
  or unverifiable remote registry is then refused rather than used. The
  keys trusted are the ones in the registry the *package ships*, which
  reaches a user by a different route than the remote does, and that is
  what a signature rests on. See
  [getaca-signing](https://gillescolling.com/getaca/reference/getaca-signing.md).

## Value

An object of class `getaca_registry`.

## Details

Ship the result at `inst/getaca/registry.rds` via
[`registry_write()`](https://gillescolling.com/getaca/reference/registry_write.md).
getaca discovers it with
[`system.file()`](https://rdrr.io/r/base/system.file.html), so no
registration call and no load hook are required.

## Identity

A registry state is identified by
[`registry_digest()`](https://gillescolling.com/getaca/reference/registry_digest.md),
derived from the declaration itself, and recorded in the provenance of
every resource it resolves. There is no revision number to keep in step:
a digest cannot be typed wrong, and two states that differ cannot claim
to be the same one.
[`registry_write()`](https://gillescolling.com/getaca/reference/registry_write.md)
stamps `created`, which is what orders two states in time, and a bundled
registry additionally has the version of the package that ships it.

## Channel heads

A registry declares records; a channel points at one of them. When a
resource name carries several versions, which of them `getaca("name")`
returns is a decision, so the registry states it in `current` rather
than leaving it to declaration order. A registry that declares two
versions of a name without naming a head is refused, which is what stops
a version appended in the wrong place from silently moving every user
backwards.

## Examples

``` r
registry(
  package = "mypackage",
  resources = list(
    resource("reference-data", "2.1",
             urls = "https://example.org/ref-2.1.zip",
             sha256 = strrep("b", 64))
  )
)

# Two versions on offer, one of them the channel head:
registry(
  package = "mypackage",
  current = c("reference-data" = "2.1"),
  resources = list(
    resource("reference-data", "2.0",
             urls = "https://example.org/ref-2.0.zip",
             sha256 = strrep("a", 64)),
    resource("reference-data", "2.1",
             urls = "https://example.org/ref-2.1.zip",
             sha256 = strrep("b", 64))
  )
)
```
