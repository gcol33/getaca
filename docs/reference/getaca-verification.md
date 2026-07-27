# Verification model

Three different questions get three different answers, and the entry
record keeps them apart so that "verified" never quietly means "we
looked at this sometime in the past".

## Details

- full verification:

  Re-hash the bytes the caller is handed. Recorded as `verified_at`.
  Always performed on download.

- cheap check:

  Compare size and modification time against the entry. Recorded as
  `checked_at`. Performed on ordinary access.

- periodic re-verification:

  A full re-hash once the last one is older than `getaca.verify_days`,
  because size and mtime miss some kinds of corruption and all kinds of
  substitution.

All three ask whether the bytes are still the bytes. A cache hit is
checked for one thing first: that the declaration still names the same
bytes it named when they were fetched. Bytes matching a superseded
declaration are not what was asked for, however intact they are.

A mismatch is a verdict on bytes rather than on the slot that found it.
Where those bytes are ones the store shares, the verdict withdraws
`verified_at` from every other slot naming that digest, so each
re-hashes against its own copy on next access instead of continuing on a
stamp this failure has already contradicted.
