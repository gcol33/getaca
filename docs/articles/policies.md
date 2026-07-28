# Policies and Channels

A resolution policy answers one question: which registry state does a
name resolve through? Everything downstream of that answer deals in
immutable records, so the policy is the only place where “the same call
on two days” can legitimately produce different bytes.

This article covers the four policies, what a remote channel is allowed
to change, how pinning freezes an analysis, and how the three settings
layers combine.

## The two halves the design keeps apart

A **resource record** names exact bytes and never changes:

``` r

rec <- resource("wfo", "2026-06",
                urls = "https://host.invalid/wfo-2026-06.zip",
                sha256 = strrep("9f", 32), license = "CC-BY-4.0")
format(rec)
#> [1] "wfo@2026-06  9f9f9f9f9f9f  [CC-BY-4.0]"
```

A **channel** maps the logical name `"wfo"` onto one record, and
channels move. Three places a channel can be read from, so three ways
the same name can resolve:

| Policy | Channel comes from | Same bytes forever? |
|----|----|----|
| `bundled` | the registry inside the installed package | yes, for that install |
| `current` | the author’s remote registry, bundled as fallback | no, by design |
| `pinned` | a frozen local snapshot | yes, until you re-pin |
| `offline` | the bundled registry, network never touched | yes, for that install |

`bundled` and `offline` read the same channel. They differ in what
happens when the resource is absent from the cache: `bundled` downloads
it, `offline` raises `getaca_error_offline` and says how to prefetch.

## `bundled`

The default, and the one that makes a data dependency behave like a code
dependency. The registry that shipped inside the installed package is
the whole answer; nothing is fetched to decide what a name means.

``` r

reg <- registry(
  package = "taxify",
  resources = list(rec)
)

res <- resolve_resource("wfo", registry = reg, policy = "bundled")
res$id
#> <getaca resource> taxify/wfo@2026-06
res$source
#> [1] "bundled"
res$digest
#> [1] "sha256:4fe8f0972e025b5d327334fa655a498ee825d164f4cd971d83150de85c15cc87"
```

`source` and `digest` are recorded in the cache entry, so a provenance
report can state which declaration chose the bytes and which policy read
it. The digest comes from the channel that answered, so under `current`
it names the remote state rather than the registry the call was handed.

Reinstalling the package is what moves this channel. That is the
property worth having: two machines running the same installed version
resolve the same record, and an analysis is reproducible from the
package version alone.

## `current`

For data that release on their own schedule. The author publishes a
static registry file somewhere they control, and `getaca` consults it
before resolving:

``` r

remote_reg <- registry(
  package = "taxify",
  policy  = "current",
  remote  = "https://taxify.invalid/getaca-registry.rds",
  resources = list(rec)
)
remote_reg
#> <getaca registry> taxify  (policy "current")
#>   digest: sha256:760085b87983
#>   remote: https://taxify.invalid/getaca-registry.rds
#>   - wfo@2026-06  9f9f9f9f9f9f  [CC-BY-4.0]
```

The remote is a file, not a service. Publishing it is a
[`registry_write()`](https://gillescolling.com/getaca/reference/registry_write.md)
into a directory that GitHub Pages, r-universe or an institutional web
server already serves.

An unreachable remote produces a message and the bundled registry, which
is what CRAN policy requires of a package that uses Internet resources:

``` r

resolve_resource("wfo", registry = remote_reg, policy = "current")
#> getaca: could not reach the remote registry for 'taxify'; using the bundled
#> registry.
```

An unreadable remote behaves the same way. A file that arrives but does
not parse as a registry, or parses but fails validation, produces a
message and the bundled fallback rather than a hard failure. A remote
that declares a different package is refused outright, since that is a
misconfiguration rather than an outage.

The remote registry is fetched once per session and cached, so a script
making a hundred calls performs one fetch.
[`getaca_refresh()`](https://gillescolling.com/getaca/reference/getaca_refresh.md)
forgets it, which is how you pick up a registry you published five
minutes ago without restarting.

``` r

getaca_refresh()
```

That also forgets registries discovered from installed packages, so it
is what you call after installing a new version of a declaring package
mid-session. Cached *resources* are untouched; this forgets
declarations, not data.

### What a remote channel may change

Two things:

- **mirrors**, for records that already exist. A dead host is repaired
  by publishing a registry whose record for `2026-06` lists a new URL.
- **records**, by adding new ones and moving the head onto them.

One thing it may not change: the checksum attached to a version that
already exists. That is refused, and the error names the declaring
package as the party at fault rather than the publisher. The same rule
holds for a pin file, which is the branch that can be shown here without
a network:

``` r

rewritten <- file.path(tempdir(), "rewritten.rds")
saveRDS(
  list(taxify = registry("taxify", list(
    resource("wfo", "2026-06", urls = "https://host.invalid/wfo-2026-06.zip",
             sha256 = strrep("ab", 32), license = "CC-BY-4.0")
  ))),
  rewritten
)
options(getaca.pin_file = rewritten)
```

``` r

resolve_resource("wfo", registry = reg, policy = "pinned")
#> Error:
#> ! Invalid getaca registry for package 'taxify'.
#>   - the pin file redefines published version wfo@2026-06
#>   - A version identifies exact bytes. Publish a new version instead.
#> 
#> Fix: the declaring package needs a correction. Report it to its maintainer.
```

Without that rule, one edited file would be enough to change what a
published version means, and the guarantee the design exists to provide
would go with it. A publisher who genuinely recut a file gets a new
version label, which is a record users can see and choose.

### Moving the head

Publishing `2026-09` and moving the channel head onto it is one
registry:

``` r

ahead <- registry(
  package = "taxify",
  current = c(wfo = "2026-09"),
  resources = list(
    resource("wfo", "2026-06", urls = "https://host.invalid/wfo-2026-06.zip",
             sha256 = strrep("9f", 32), license = "CC-BY-4.0"),
    resource("wfo", "2026-09", urls = "https://host.invalid/wfo-2026-09.zip",
             sha256 = strrep("ab", 32), license = "CC-BY-4.0")
  )
)

resolve_resource("wfo", registry = ahead)$id
#> <getaca resource> taxify/wfo@2026-09
resolve_resource("wfo", registry = ahead, version = "2026-06")$id
#> <getaca resource> taxify/wfo@2026-06
```

Users on `current` follow the head on their next session. Users on
`bundled` stay where their installed package put them. Users who named a
version keep that version under every policy, which is the escape hatch
an analysis needs.

### Signing a remote channel

The rules above bound what a remote registry can do. They say nothing
about who wrote it, and a registry sits on a host that can change hands.
Signing answers that, and it works because of where the key lives: the
public key travels inside the registry your package *ships*, which a
user installs from CRAN, while the remote registry comes from your own
host. Someone who takes the host does not thereby have the key.

Make a key once, and keep the secret half outside the package source
tree:

``` r

secret <- file.path(tempdir(), "taxify-signing.key")
public <- registry_keygen(secret)
substr(public, 1, 24)
#> [1] "ed25519:43bf13d7cff5565c"
```

Declare the public half in the registry the package ships:

``` r

signed <- registry(
  package = "taxify",
  remote = "https://host.invalid/taxify.rds",
  keys = public,
  resources = list(
    resource("wfo", "2026-06", urls = "https://host.invalid/wfo-2026-06.zip",
             sha256 = strrep("9f", 32), license = "CC-BY-4.0")
  )
)
```

Then write and sign whatever you publish. Sign after writing: writing is
what stamps the publication time, and the signature binds it.

``` r

path <- file.path(tempdir(), "taxify.rds")
registry_write(signed, path)
registry_sign(path, key = secret)

cat(readLines(paste0(path, ".sig"))[1:4], sep = "\n")
#> getaca-signature 1
#> digest sha256:fb8abf3469e5e5a53b57ac439e097c247ec95d320653868347f05ac307caa45b
#> created 2026-07-28T15:54:26Z
#> expires 2026-10-26T15:54:26Z
```

Upload the `.sig` beside the registry; getaca fetches it from the
registry’s own URL with `.sig` appended.
[`registry_verify()`](https://gillescolling.com/getaca/reference/registry_verify.md)
runs the same check a user’s session will, which is worth doing before
publishing:

``` r

registry_verify(path)
```

Editing the registry after signing breaks the link, which is the whole
point:

``` r

moved <- signed
moved$resources[[1]]$urls <- "https://elsewhere.invalid/wfo-2026-06.zip"
saveRDS(moved, path, version = 3)
registry_verify(path)
#> Error:
#> ! The registry for 'taxify' could not be established as authentic.
#>   the signature covers sha256:fb8abf3469e5 but this registry is sha256:9e95117674d9
#> 
#> This package declares signing keys, so a remote registry that cannot be
#> checked against one is refused rather than used. The bundled declaration
#> the package ships is unaffected and still resolves.
#> 
#> Action: getaca_policy("bundled") resolves through it for this session.
#> 
#> Fix: the declaring package needs a correction. Report it to its maintainer.
```

Three consequences worth knowing before you declare a key:

- **It is a commitment.** Once your shipped registry names a key, an
  unsigned or unverifiable remote is refused rather than used. Users are
  not stranded, since the bundled declaration still resolves, but the
  remote channel stops working until the signature does.
- **A signature expires.**
  [`registry_sign()`](https://gillescolling.com/getaca/reference/registry_sign.md)
  dates it 90 days out by default. Re-signing an unchanged registry
  extends it, and is the routine maintenance this feature asks of you.
  `expires = NA` opts out and leaves nothing bounding how long a stale
  declaration can be served in your name.
- **Rotating a key needs a release.** The keys getaca trusts are the
  ones in the installed package, so publish the new key beside the old
  one, keep signing with the old, release, and retire the old key once
  that release is out.

A package that declares no keys behaves exactly as it always did, and
never fetches a signature at all.

## `pinned`

A pin file records, for each named package, the registry state in force
at the moment you pinned. Under the `pinned` policy that snapshot is
what resolution reads, so an analysis keeps resolving what it was
written against even after the package is reinstalled and the remote
registry has moved on.

``` r

pins <- file.path(tempdir(), "getaca.pins.rds")
saveRDS(list(taxify = registry("taxify", list(rec))), pins)
options(getaca.pin_file = pins)
```

``` r

moved_on <- registry(
  package = "taxify",
  current = c(wfo = "2026-09"),
  resources = list(
    rec,
    resource("wfo", "2026-09", urls = "https://host.invalid/wfo-2026-09.zip",
             sha256 = strrep("ab", 32), license = "CC-BY-4.0")
  )
)

resolve_resource("wfo", registry = moved_on)$id
#> <getaca resource> taxify/wfo@2026-09
resolve_resource("wfo", registry = moved_on, policy = "pinned")$id
#> <getaca resource> taxify/wfo@2026-06
```

The installed registry has moved to `2026-09`; the pin holds the
analysis at `2026-06`.

In practice the pin file is written rather than hand-built:

``` r

getaca_pin(c("taxify", "otherpkg"))
```

That writes `getaca.pins.rds` in the working directory by default, which
puts it beside `renv.lock` in a project. Under `current`,
[`getaca_pin()`](https://gillescolling.com/getaca/reference/getaca_pin.md)
records the remote state rather than the bundled one, so pinning
captures what you are actually resolving through at that moment. Point
it somewhere else with the `path` argument, and tell a session where to
look with the `getaca.pin_file` option.

A pin file is subject to the same immutability rule as a remote
registry. A snapshot that disagrees with the installed registry about
what `2026-06` means is refused rather than trusted, so a stale or
edited pin cannot quietly serve different bytes.

Pinning a package that ships no registry warns and skips it, so pinning
a project’s whole dependency list does not fail on the ones that need
nothing:

``` r

getaca_pin("stats", path = file.path(tempdir(), "pins.rds"))
#> Warning: package 'stats' ships no getaca registry; skipped
```

### Pins and `renv`

They answer adjacent questions. `renv` records which package versions an
analysis used; a `getaca` pin records which data versions those packages
resolved to. Together they pin both halves. Neither subsumes the other,
because a package version does not determine a data version once the
package is on `current`, and a data version says nothing about the code
that read it.

Commit both files. Restoring is `renv::restore()` followed by
[`getaca_prefetch()`](https://gillescolling.com/getaca/reference/getaca_prefetch.md)
on a connected machine, after which the analysis runs offline.

## `offline`

Never reaches for the network. Cached copies and bundled declarations
only.

``` r

err <- tryCatch(getaca("wfo", registry = reg, policy = "offline"),
                getaca_error = function(e) e)
class(err)[1]
#> [1] "getaca_error_offline"
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

This is the policy a check run gets, whatever is set elsewhere, and it
is worth setting deliberately in two other situations: an air-gapped
machine, where the message is more useful than a transfer timeout, and a
shared analysis where you want a missing input to fail loudly rather
than pull four gigabytes onto someone’s laptop.

## How the policy in force is decided

Four layers, most specific first:

1.  the `policy` argument to
    [`getaca()`](https://gillescolling.com/getaca/reference/getaca.md)
    or
    [`resolve_resource()`](https://gillescolling.com/getaca/reference/resolve_resource.md)

2.  the `getaca.policy` option, set by
    [`getaca_policy()`](https://gillescolling.com/getaca/reference/getaca_policy.md)

3.  the `GETACA_POLICY` environment variable

4.  the declaring registry’s own `policy` field, defaulting to `bundled`

Two overrides sit above all of them and force `offline`:

- `R CMD check`, detected from the check environment variables

- `GETACA_OFFLINE` set to `1`, `true` or `yes`

``` r

getaca_policy()
#> [1] "offline"
```

The check clamp is released by `NOT_CRAN=true`, which is how a package’s
own CI runs tests against real resources while a CRAN machine never
does.

``` r

getaca_policy("current")                                   # this session
getaca("wfo", package = "taxify", policy = "bundled")      # this call
Sys.setenv(GETACA_POLICY = "pinned")                       # this process
```

Setting the policy per call is the form worth reaching for in package
code. A function that must not vary its answer can pass
`policy = "bundled"` explicitly and stop caring what the user’s session
is set to.

## Choosing a default as an author

The registry’s `policy` field is your recommendation, and users can
override it. Three questions decide it.

**Do the data release independently of your package?** If a new backbone
appears twice a year and your CRAN releases are annual, `current` is
what keeps users on data you consider correct without a release cycle in
between. If the data are static, `bundled` costs nothing and removes a
moving part.

**Can you host a registry file reliably enough?** Reliably here is a low
bar, since an outage falls back to bundled with a message. GitHub Pages
is sufficient. If you have nowhere to put a file you control, `bundled`
is the honest choice.

**Would a user be surprised?** A package whose results shift because a
backbone moved needs that to be visible. `current` is right when the
declaring package surfaces the resolved version in its own output, and
questionable when it does not.

`bundled` is the default for a reason. Under it a data dependency
behaves the way a package dependency behaves: the installed version
determines the answer. Each of the others relaxes that in one direction,
and the direction is the reason to pick it.

## What is recorded

Whichever policy resolved a resource is kept in its cache entry,
alongside the digest of the registry state that supplied the record:

``` r

getaca_info("wfo", package = "taxify")
#> <getaca cache entry> taxify/wfo@2026-06
#>   ...
#>   resolved by current registry sha256:8b31e0da54cf (published 2026-07-22)
#>   source url  https://host.invalid/wfo-2026-06.zip
```

[`getaca_catalogue()`](https://gillescolling.com/getaca/reference/getaca_catalogue.md)
reports the same two fields as `source` and `registry_digest` columns
across every cached resource, so “which of these came from a remote
channel” is one filter rather than an audit.

## Where to go next

- [`vignette("declaring")`](https://gillescolling.com/getaca/articles/declaring.md)
  for publishing a remote registry and moving a head

- [`vignette("checks")`](https://gillescolling.com/getaca/articles/checks.md)
  for the check clamp, `NOT_CRAN` and CI

- [`vignette("failures")`](https://gillescolling.com/getaca/articles/failures.md)
  for the conditions each policy can raise
