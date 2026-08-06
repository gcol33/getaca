# Resolution policy and settings

`getaca_policy()` reports or sets the resolution policy for the current
session. The policy decides which registry state a name resolves
through, and is recorded in provenance so a result can always be traced
back to it.

## Usage

``` r
getaca_policy(policy = NULL)
```

## Arguments

- policy:

  One of `"bundled"`, `"current"`, `"pinned"`, `"offline"`, or `NULL` to
  query without setting.

## Value

When querying, the policy in effect. When setting, the previous value of
the `getaca.policy` option invisibly, `NULL` if it was unset.

## Policies

- `"bundled"`:

  Always use the registry shipped with the declaring package. The same
  installed package resolves the same bytes forever. This is the
  default.

- `"current"`:

  Consult the author-controlled remote registry, falling back to bundled
  when it cannot be reached. Lets an author repair a dead mirror or
  publish a new version without a CRAN release.

- `"pinned"`:

  Resolve through a frozen local snapshot, so an analysis keeps
  resolving what it resolved on the day it was written.

- `"offline"`:

  Never touch the network. Cached and bundled information only.

During `R CMD check` resolution always collapses to `"offline"`,
whatever is set here.

Setting the policy sets the `getaca.policy` option and nothing else, and
returns what that option held before, so a caller that has to change it
can put it back:

    old <- getaca_policy("offline")
    on.exit(options(getaca.policy = old), add = TRUE)

## Examples

``` r
getaca_policy()

# Setting it is reversible, because the previous value comes back.
old <- getaca_policy("offline")
getaca_policy()
options(getaca.policy = old)
```
