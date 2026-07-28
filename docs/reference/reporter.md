# Write a progress reporter

A reporter turns transfer events into whatever you want a transfer to
look like: a bar, a log line, a row in a database, an update to a Shiny
session. It carries an `id` so that what is reporting is visible when
one is set.

## Usage

``` r
reporter(id, fn)
```

## Arguments

- id:

  Short stable identifier, for example `"bar"` or `"shiny"`.

- fn:

  A function of one argument, the event. Its return value is ignored.

## Value

An object of class `getaca_reporter`.

## Details

See
[getaca-progress](https://gillescolling.com/getaca/reference/getaca-progress.md)
for the events and their fields.

## See also

[`getaca_progress()`](https://gillescolling.com/getaca/reference/getaca_progress.md)

## Examples

``` r
# Only the totals, once each transfer is done.
reporter("totals", function(event) {
  if (identical(event$type, "end")) {
    cat(format(event$id), event$status, event$bytes, "\n")
  }
})
```
