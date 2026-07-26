# Active cache management

CRAN policy permits a package to use
[`tools::R_user_dir()`](https://rdrr.io/r/tools/userdir.html) "provided
that by default sizes are kept as small as possible and the contents are
actively managed (including removing outdated material)". Actively
managed means the package has a retention policy, not that it ships a
function users might discover. getaca therefore collects conservatively
after every successful retrieval, and `getaca_clean()` exists for the
deliberate case.

## Usage

``` r
getaca_clean(
  name = NULL,
  package = NULL,
  what = c("broken", "temp", "superseded", "lru", "unreferenced"),
  dry_run = FALSE
)
```

## Arguments

- name:

  Restrict to one resource name.

- package:

  Restrict to one declaring package. `NULL` means all.

- what:

  Which sweeps to run. Any of `"broken"`, `"temp"`, `"superseded"`,
  `"lru"`, `"unreferenced"`.

- dry_run:

  Report what would be removed without removing it.

## Value

A data frame of affected entries, invisibly when acting.

## Details

Removal order, cheapest and safest first:

1.  broken and incomplete material

2.  abandoned temporary transfers

3.  superseded unpinned versions, once past the retention period

4.  least recently used unpinned resources, only when over the size
    ceiling

5.  bytes in the store that no declaration references any more

"Superseded" and "not recently used" are different states and age on
different clocks, so an expensive resource is not deleted merely for
being old.

A version slot holds a name for bytes the store owns, so the sweeps
above remove names. Bytes go once the last name for them does, which is
why the store sweep runs last.

Never removed: pinned entries, the version the bundled registry
currently names, and anything under an active lock.

## Examples

``` r
getaca_clean(dry_run = TRUE)
```
