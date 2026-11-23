# Per-resource locking

Two sessions asking for the same multi-gigabyte file must not both
download it, and must never mistake each other's in-flight temporary
file for a finished resource. Locking is foundational rather than an
optimisation, so it is present from the first version.

## Details

The lock is a directory.
[`dir.create()`](https://rdrr.io/r/base/files2.html) is atomic on both
POSIX and Windows, and on the network filesystems a shared cache tends
to live on, which makes it a mutex that works wherever the cache does.

The key is the declared checksum rather than the identity triple,
because what a waiter is waiting for is a transfer of particular bytes.
Two packages declaring the same file wait on each other, and the second
finds the blob the first admitted instead of downloading it again.

## Whether a holder is still there

A lock records the process that took it, the machine that process runs
on and when the process started. A waiter on the same machine asks the
operating system whether that process is still running, so a lock is
held for exactly as long as its holder lives: a transfer of any length
keeps it, and a session that crashed loses it at once.

A waiter on another machine, which a cache on a shared filesystem makes
possible, cannot ask that question. There the holder shows it is alive
by touching its lock on a timer, from a second thread, for as long as it
holds the lock: under a transfer, a
[`combiner()`](https://gillescolling.com/getaca/reference/combiner.md)
and a
[`processor()`](https://gillescolling.com/getaca/reference/processor.md)
alike. The lock is abandoned once it has gone untouched for
`getaca.lock_stale_seconds`, which is how long a crash on another
machine takes to be noticed.

A waiter waits for as long as the holder is alive, since the alternative
is a second transfer of the same bytes. `getaca.lock_wait_seconds`
bounds the wait where that is wanted.
