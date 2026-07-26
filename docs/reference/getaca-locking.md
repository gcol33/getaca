# Per-resource locking

Two sessions asking for the same multi-gigabyte file must not both
download it, and must never mistake each other's in-flight temporary
file for a finished resource. Locking is foundational rather than an
optimisation, so it is present from the first version.

## Details

The lock is a directory.
[`dir.create()`](https://rdrr.io/r/base/files2.html) is atomic on both
POSIX and Windows, which makes it a portable mutex without a compiled
dependency. A waiter either observes that the holder finished
successfully, or takes over once the lock goes stale.

The key is the declared checksum rather than the identity triple,
because what a waiter is waiting for is a transfer of particular bytes.
Two packages declaring the same file wait on each other, and the second
finds the blob the first admitted instead of downloading it again.
