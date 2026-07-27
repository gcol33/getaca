# A cached copy is bytes plus the declaration they were verified against. When
# the declaration moves and the version label does not, the two disagree about
# what that version means, and a cache hit must not settle the disagreement by
# staying quiet.

# A processed slot, without depending on an archive format for one.
copying_processor <- function() {
  processor("copy", function(path, dir) {
    out <- file.path(dir, "processed.csv")
    file.copy(path, out)
    out
  })
}

test_that("a cache hit under a changed declaration is refused, not returned", {
  cache <- local_cache()
  src <- withr::local_tempdir()
  f <- seed_file(src, contents = "the bytes 1.0 originally named")
  seed_cache(demo_registry(f$sha256), f)

  # Same package, same name, same version, different bytes. This is what a
  # package upgrade shipping a corrected checksum looks like to a user whose
  # cache is already warm.
  moved <- demo_registry(strrep("b", 64))

  expect_error(getaca("res", registry = moved),
               class = "getaca_error_redeclared")
  expect_error(getaca("res", registry = moved), "demopkg/res@1.0")
})

test_that("the refusal blames the author and says how to accept the new bytes", {
  cache <- local_cache()
  src <- withr::local_tempdir()
  f <- seed_file(src)
  seed_cache(demo_registry(f$sha256), f)

  cond <- tryCatch(getaca("res", registry = demo_registry(strrep("b", 64))),
                   getaca_error = function(e) e)
  expect_equal(cond$actor, "author")
  expect_equal(cond$cached, f$sha256)
  expect_equal(cond$declared, strrep("b", 64))
  expect_match(conditionMessage(cond),
               "getaca_clean\\(\"res\", package = \"demopkg\"\\)")
})

test_that("verify = TRUE compares against the declaration, not the entry's memory", {
  cache <- local_cache()
  src <- withr::local_tempdir()
  f <- seed_file(src)
  seed_cache(demo_registry(f$sha256), f)

  # A forced re-hash confirms the bytes are the bytes the entry recorded, which
  # is the wrong question once the declaration has moved underneath it.
  expect_error(getaca("res", registry = demo_registry(strrep("b", 64)), verify = TRUE),
               class = "getaca_error_redeclared")
})

test_that("an unchanged declaration still resolves from the cache", {
  cache <- local_cache()
  src <- withr::local_tempdir()
  f <- seed_file(src)
  reg <- demo_registry(f$sha256)
  seeded <- seed_cache(reg, f)

  expect_equal(getaca("res", registry = reg), seeded$path)
  expect_equal(getaca("res", registry = reg, verify = TRUE), seeded$path)
})

test_that("a processed slot is held to the declaration of the bytes behind it", {
  cache <- local_cache()
  src <- withr::local_tempdir()
  f <- seed_file(src)
  proc <- copying_processor()
  reg <- demo_registry(f$sha256, processor = proc)
  testthat::local_mocked_bindings(try_one = serves_file(f), .package = "getaca")
  getaca("res", registry = reg, quiet = TRUE)

  moved <- demo_registry(strrep("b", 64), processor = proc)
  expect_error(getaca("res", registry = moved),
               class = "getaca_error_redeclared")
})

test_that("a different version is a different resource, not a redeclaration", {
  cache <- local_cache()
  src <- withr::local_tempdir()
  f <- seed_file(src)
  seed_cache(demo_registry(f$sha256), f)

  # 2.0 names its own bytes and is simply not cached, so this is an ordinary
  # uncached resource rather than a conflict.
  two <- registry("demopkg", current = c(res = "2.0"), resources = list(
    resource("res", "1.0", urls = "https://example.invalid/res-1.0.csv",
             sha256 = f$sha256),
    resource("res", "2.0", urls = "https://example.invalid/res-2.0.csv",
             sha256 = strrep("b", 64))
  ))
  withr::local_envvar(list(GETACA_OFFLINE = "true"))
  expect_error(getaca("res", registry = two), class = "getaca_error_offline")
})

test_that("dropping the cached copy accepts the new declaration", {
  cache <- local_cache()
  src <- withr::local_tempdir()
  old <- seed_file(src, contents = "the old bytes")
  new <- seed_file(src, contents = "the new bytes", name = "new.csv")
  seed_cache(demo_registry(old$sha256), old)

  moved <- demo_registry(new$sha256)
  expect_error(getaca("res", registry = moved), class = "getaca_error_redeclared")

  getaca_clean("res", package = "demopkg", what = "broken")
  getaca:::drop_entry(resource_id("demopkg", "res", "1.0"))
  testthat::local_mocked_bindings(try_one = serves_file(new), .package = "getaca")

  expect_equal(getaca:::sha256_file(getaca("res", registry = moved, quiet = TRUE)),
               new$sha256)
})

# A full re-hash has to read the file the caller is handed. Where the
# filesystem allowed a link that is the blob's own bytes either way, but where
# it refused one the view is an independent copy, and hashing the blob would
# certify bytes nobody is going to read.

test_that("a copy view is verified against itself, not against its blob", {
  cache <- local_cache()
  src <- withr::local_tempdir()
  f <- seed_file(src, contents = "the bytes as served")
  reg <- demo_registry(f$sha256)
  seeded <- seed_cache(reg, f, link = copies_only)
  expect_equal(seeded$entry$link, "copy")

  # Same size, different bytes: what the cheap check is documented to miss.
  corrupt(seeded$path, "the bytes as merved")
  expect_equal(getaca:::sha256_file(getaca:::blob_path(f$sha256)), f$sha256)

  expect_error(getaca("res", registry = reg, verify = TRUE),
               class = "getaca_error_cache_corrupt")
})

test_that("a raw view outlives its blob and is still answerable for its bytes", {
  cache <- local_cache()
  src <- withr::local_tempdir()
  f <- seed_file(src, contents = "the bytes as served")
  reg <- demo_registry(f$sha256)
  seeded <- seed_cache(reg, f)
  skip_unless_linked(seeded$entry)

  # A hardlinked view keeps the bytes readable when the blob name goes.
  getaca:::remove_path(getaca:::blob_path(f$sha256))
  expect_equal(getaca("res", registry = reg, verify = TRUE), seeded$path)

  corrupt(seeded$path, "the bytes as merved")
  expect_error(getaca("res", registry = reg, verify = TRUE),
               class = "getaca_error_cache_corrupt")
})

test_that("a processed slot stays verifiable after its raw view is swept", {
  cache <- local_cache()
  src <- withr::local_tempdir()
  f <- seed_file(src)
  reg <- demo_registry(f$sha256, processor = copying_processor())
  testthat::local_mocked_bindings(try_one = serves_file(f), .package = "getaca")
  path <- getaca("res", registry = reg, quiet = TRUE)

  getaca:::remove_path(getaca:::cache_raw_dir(resource_id("demopkg", "res", "1.0")))

  expect_equal(getaca("res", registry = reg, verify = TRUE), path)
})

test_that("an entry with nothing left to hash is refused, not called verified", {
  cache <- local_cache()
  src <- withr::local_tempdir()
  f <- seed_file(src)
  reg <- demo_registry(f$sha256, processor = copying_processor())
  testthat::local_mocked_bindings(try_one = serves_file(f), .package = "getaca")
  getaca("res", registry = reg, quiet = TRUE)
  before <- getaca_info("res", registry = reg)$verified_at

  # A processed tree is identified by the artefact it came from. With the blob
  # and the raw view both gone, nothing the declared checksum describes is left.
  id <- resource_id("demopkg", "res", "1.0")
  getaca:::remove_path(getaca:::blob_path(f$sha256))
  getaca:::remove_path(getaca:::cache_raw_dir(id))

  expect_error(getaca("res", registry = reg, verify = TRUE),
               class = "getaca_error_cache_corrupt")
  # The clock must not move on a check that never ran, or it never runs again.
  expect_equal(getaca_info("res", registry = reg)$verified_at, before)
})

# Bytes are shared and verification stamps are not, so one package can diagnose
# corruption that every other sharer then keeps quiet about for the rest of its
# own window. A verdict on the store's bytes has to reach every slot naming
# them; a verdict on one slot's own copy has to reach no further.

test_that("a mismatch in shared bytes withdraws every other slot's verification", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir(), contents = "the shared backbone")
  testthat::local_mocked_bindings(try_one = serves_file(f), .package = "getaca")
  alpha <- demo_registry(f$sha256, package = "alpha")
  beta <- demo_registry(f$sha256, package = "beta")
  getaca("res", registry = alpha, quiet = TRUE)
  getaca("res", registry = beta, quiet = TRUE)
  skip_unless_linked(getaca_info("res", registry = alpha))

  corrupt(getaca:::blob_path(f$sha256), "the shared backbome")

  expect_error(getaca("res", registry = alpha, verify = TRUE),
               class = "getaca_error_cache_corrupt")
  expect_true(is.na(getaca_info("res", registry = beta)$verified_at))
  # Beta is well inside its own window, and its bytes pass the cheap size
  # check, so this is the access that used to hand back corrupt bytes.
  expect_error(getaca("res", registry = beta),
               class = "getaca_error_cache_corrupt")
})

# A verdict is about one digest. Withdrawing every stamp in the cache would make
# a single corrupt blob re-hash every unrelated resource on the next access,
# which for a cache holding tens of gigabytes is the cost the shared verdict was
# measured against avoiding.
test_that("a mismatch reaches the bytes it is about and no others", {
  cache <- local_cache()
  src <- withr::local_tempdir()
  shared <- seed_file(src, contents = "the shared backbone", name = "shared.csv")
  other <- seed_file(src, contents = "an unrelated resource", name = "other.csv")

  alpha <- demo_registry(shared$sha256, package = "alpha")
  beta <- demo_registry(shared$sha256, package = "beta")
  gamma <- demo_registry(other$sha256, package = "gamma")
  testthat::local_mocked_bindings(try_one = serves_file(shared), .package = "getaca")
  getaca("res", registry = alpha, quiet = TRUE)
  getaca("res", registry = beta, quiet = TRUE)
  skip_unless_linked(getaca_info("res", registry = alpha))
  seed_cache(gamma, other)
  untouched <- getaca_info("res", registry = gamma)$verified_at

  corrupt(getaca:::blob_path(shared$sha256), "the shared backbome")
  expect_error(getaca("res", registry = alpha, verify = TRUE),
               class = "getaca_error_cache_corrupt")

  expect_true(is.na(getaca_info("res", registry = beta)$verified_at))
  expect_equal(getaca_info("res", registry = gamma)$verified_at, untouched)
})

test_that("a sharer that already has no stamp is left as it is", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir(), contents = "the shared backbone")
  testthat::local_mocked_bindings(try_one = serves_file(f), .package = "getaca")
  alpha <- demo_registry(f$sha256, package = "alpha")
  beta <- demo_registry(f$sha256, package = "beta")
  getaca("res", registry = alpha, quiet = TRUE)
  getaca("res", registry = beta, quiet = TRUE)
  skip_unless_linked(getaca_info("res", registry = alpha))

  corrupt(getaca:::blob_path(f$sha256), "the shared backbome")
  expect_error(getaca("res", registry = alpha, verify = TRUE),
               class = "getaca_error_cache_corrupt")
  expect_true(is.na(getaca_info("res", registry = beta)$verified_at))

  # Beta's stamp is already withdrawn, so a second verdict on the same bytes has
  # nothing to withdraw from it and leaves the entry alone.
  expect_error(getaca("res", registry = alpha, verify = TRUE),
               class = "getaca_error_cache_corrupt")
  expect_true(is.na(getaca_info("res", registry = beta)$verified_at))
})

test_that("a vanished path fails the cheap check rather than its comparison", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir())
  reg <- demo_registry(f$sha256)
  seeded <- seed_cache(reg, f)

  expect_true(getaca:::cheap_check_ok(seeded$entry))
  getaca:::remove_path(seeded$path)
  expect_false(getaca:::cheap_check_ok(seeded$entry))
})

test_that("a mismatch in a slot's own copy says nothing about the shared bytes", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir(), contents = "the shared backbone")
  alpha <- demo_registry(f$sha256, package = "alpha")
  beta <- demo_registry(f$sha256, package = "beta")
  seeded <- seed_cache(alpha, f, link = copies_only)
  seed_cache(beta, f)
  before <- getaca_info("res", registry = beta)$verified_at

  corrupt(seeded$path, "the shared backbome")

  expect_error(getaca("res", registry = alpha, verify = TRUE),
               class = "getaca_error_cache_corrupt")
  expect_equal(getaca_info("res", registry = beta)$verified_at, before)
  expect_equal(getaca:::sha256_file(getaca("res", registry = beta, verify = TRUE)),
               f$sha256)
})

test_that("a processed tree failing its own check says nothing about them either", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir(), contents = "the shared backbone")
  testthat::local_mocked_bindings(try_one = serves_file(f), .package = "getaca")
  alpha <- demo_registry(f$sha256, package = "alpha", processor = copying_processor())
  beta <- demo_registry(f$sha256, package = "beta")
  path <- getaca("res", registry = alpha, quiet = TRUE)
  getaca("res", registry = beta, quiet = TRUE)
  before <- getaca_info("res", registry = beta)$verified_at

  # A derived tree belongs to the slot that declared the processor, whatever
  # the bytes it was made from are.
  corrupt(path, "shorter")

  expect_error(getaca("res", registry = alpha),
               class = "getaca_error_cache_corrupt")
  expect_equal(getaca_info("res", registry = beta)$verified_at, before)
})
