# How a transfer reports itself

getaca drives its own transfer loop, so what a download reports is a
decision the package makes rather than one libcurl makes for it. A
reporter receives an event for every transfer that begins, for the bytes
that arrive while it runs, and for how it ended, and renders them
however it likes.

## Details

The events carry what getaca knows and a transfer library cannot: the
resource identity, which part of a series is moving, the size the
registry declares for it, and how much of it was already on disk when
the attempt resumed. That is why the declared total is available before
the first byte arrives, and why a series reports `(part 2 of 3)` rather
than three unrelated downloads.

## Events

Each event is a list with a `type` and the fields for that type. A
handler switches on `type` and ignores what it does not use, so a later
release adding an event type leaves an existing reporter working.

- `"begin"`:

  A transfer attempt starts. `id` is the resource, which
  [`format()`](https://rdrr.io/r/base/format.html) renders including the
  part label where there is one. `url` is the mirror. `total` is the
  declared size in bytes, or `NA` when the declaration gives none.
  `offset` is what was already on disk, which is non-zero when an
  interrupted transfer resumes.

- `"bytes"`:

  Bytes have arrived. `bytes` is the cumulative total for this attempt
  including `offset`, so it can be compared against `total` directly.
  Fires often; a reporter that draws is expected to throttle.

- `"end"`:

  The attempt finished. `status` is `"ok"` or `"failed"`, `reason` is
  the failure reason or `NA`, and `bytes` is what arrived.

A reporter never affects the outcome of a retrieval. An error raised
inside one is caught, reported once as a warning, and the reporter is
switched off for the rest of the session's call rather than being
allowed to fail a download that is otherwise fine.

## See also

[`getaca_progress()`](https://gillescolling.com/getaca/reference/getaca_progress.md)
to choose one,
[`reporter()`](https://gillescolling.com/getaca/reference/reporter.md)
to write one.
