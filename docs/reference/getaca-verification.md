# Verification model

Three different questions get three different answers, and the entry
record keeps them apart so that "verified" never quietly means "we
looked at this sometime in the past".

## Details

- full verification:

  Re-hash the bytes. Recorded as `verified_at`. Always performed on
  download.

- cheap check:

  Compare size and modification time against the entry. Recorded as
  `checked_at`. Performed on ordinary access.

- periodic re-verification:

  A full re-hash once the last one is older than `getaca.verify_days`,
  because size and mtime miss some kinds of corruption and all kinds of
  substitution.
