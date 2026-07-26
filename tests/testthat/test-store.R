# Serves a known file as though it had been downloaded, so a retrieval can be
# exercised end to end without a network.
serves_file <- function(file) {
  function(url, dest, quiet = FALSE) {
    file.copy(file$path, dest, overwrite = TRUE)
    list(success = TRUE, reason = NA_character_)
  }
}

staged <- function(file) {
  dest <- file.path(getaca:::cache_tmp_dir(), basename(file$path))
  file.copy(file$path, dest, overwrite = TRUE)
  dest
}

test_that("admitted bytes are named by their digest and shard on it", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir())

  blob <- getaca:::admit(staged(f), f$sha256)

  expect_true(file.exists(blob))
  expect_equal(basename(blob), f$sha256)
  expect_equal(basename(dirname(blob)), substr(f$sha256, 1, 2))
  expect_equal(getaca:::sha256_file(blob), f$sha256)
})

test_that("admitting the same bytes twice keeps one copy", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir())

  first <- getaca:::admit(staged(f), f$sha256)
  second_source <- staged(f)
  second <- getaca:::admit(second_source, f$sha256)

  expect_equal(first, second)
  expect_false(file.exists(second_source))
  expect_length(getaca:::all_blobs(), 1L)
})

test_that("a blob is read-only, so a caller cannot damage what others share", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir())
  blob <- getaca:::admit(staged(f), f$sha256)

  expect_false(file.access(blob, 2) == 0)
})

test_that("a view carries the readable name and the bytes of its blob", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir(), contents = "payload")
  getaca:::admit(staged(f), f$sha256)
  rec <- getaca::resource("res", "1.0", urls = "https://a.invalid/wfo-2026.zip",
                          sha256 = f$sha256)
  id <- getaca::resource_id("demopkg", "res", "1.0")

  placed <- getaca:::place(id, rec)

  expect_equal(basename(placed$path), "wfo-2026.zip")
  expect_equal(getaca:::sha256_file(placed$path), f$sha256)
  expect_true(placed$link %in% c("hardlink", "symlink", "copy"))
})

test_that("the link ladder falls through to copying when links are refused", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir(), contents = "payload")
  getaca:::admit(staged(f), f$sha256)
  dest <- file.path(withr::local_tempdir(), "view.csv")

  method <- getaca:::materialise(f$sha256, dest,
                                 link = function(from, to) {
                                   if (isTRUE(file.copy(from, to))) "copy" else NA_character_
                                 })

  expect_equal(method, "copy")
  expect_equal(getaca:::sha256_file(dest), f$sha256)
})

test_that("a link that cannot be made at all is reported, not returned", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir())
  getaca:::admit(staged(f), f$sha256)

  expect_error(
    getaca:::materialise(f$sha256, file.path(withr::local_tempdir(), "v"),
                         link = function(from, to) NA_character_),
    "could not place the verified file into the cache"
  )
})

test_that("two packages declaring one file store it once and transfer it once", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir(), contents = "the shared backbone")
  transfers <- 0L
  counting <- function(url, dest, quiet = FALSE) {
    transfers <<- transfers + 1L
    file.copy(f$path, dest, overwrite = TRUE)
    list(success = TRUE, reason = NA_character_)
  }
  testthat::local_mocked_bindings(try_one = counting, .package = "getaca")

  one <- getaca("res", registry = demo_registry(f$sha256, package = "alpha"),
                quiet = TRUE)
  two <- getaca("res", registry = demo_registry(f$sha256, package = "beta"),
                quiet = TRUE)

  expect_equal(transfers, 1L)
  expect_false(identical(one, two))
  expect_length(getaca:::all_blobs(), 1L)
  expect_equal(getaca:::sha256_file(two), f$sha256)
})

test_that("each package keeps its own record of shared bytes", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir(), contents = "the shared backbone")
  testthat::local_mocked_bindings(try_one = serves_file(f), .package = "getaca")
  alpha <- demo_registry(f$sha256, package = "alpha", license = "CC-BY-4.0")
  beta <- demo_registry(f$sha256, package = "beta", license = "CC0-1.0")

  getaca("res", registry = alpha, quiet = TRUE)
  getaca("res", registry = beta, quiet = TRUE)

  expect_equal(getaca_info("res", registry = alpha)$license, "CC-BY-4.0")
  expect_equal(getaca_info("res", registry = beta)$license, "CC0-1.0")
  expect_equal(nrow(getaca_catalogue()), 2L)
})

test_that("bytes nothing declares are swept, and bytes something declares are not", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir())
  reg <- demo_registry(f$sha256)
  seed_cache(reg, f)
  orphan <- seed_file(withr::local_tempdir(), contents = "nobody's", name = "o.csv")
  getaca:::admit(staged(orphan), orphan$sha256)

  out <- getaca_clean(what = "unreferenced")

  expect_equal(nrow(out), 1L)
  expect_equal(out$reason, "no declaration references these bytes")
  expect_false(getaca:::blob_exists(orphan$sha256))
  expect_true(getaca:::blob_exists(f$sha256))
})

test_that("one package's sweep never takes bytes another package still names", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir(), contents = "the shared backbone")
  testthat::local_mocked_bindings(try_one = serves_file(f), .package = "getaca")
  getaca("res", registry = demo_registry(f$sha256, package = "alpha"), quiet = TRUE)
  getaca("res", registry = demo_registry(f$sha256, package = "beta"), quiet = TRUE)

  # alpha drops out entirely, which leaves beta as the only reason to keep the
  # bytes. A sweep restricted to alpha must still see beta's claim.
  for (e in getaca:::read_index("alpha")) getaca:::drop_cached(e)
  getaca_clean(package = "alpha")

  expect_true(getaca:::blob_exists(f$sha256))
  expect_equal(getaca:::sha256_file(getaca_info("res",
    registry = demo_registry(f$sha256, package = "beta"))$path), f$sha256)
})

test_that("a blob under an active lock survives a sweep that cannot see its entry", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir())
  getaca:::admit(staged(f), f$sha256)

  lock <- getaca:::acquire_lock(f$sha256)
  on.exit(getaca:::release_lock(lock))
  out <- getaca_clean(what = "unreferenced")

  expect_equal(nrow(out), 0L)
  expect_true(getaca:::blob_exists(f$sha256))
})

test_that("the size ceiling counts shared bytes once", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir(), contents = strrep("x", 500))
  testthat::local_mocked_bindings(try_one = serves_file(f), .package = "getaca")
  alpha <- demo_registry(f$sha256, package = "alpha")
  getaca("res", registry = alpha, quiet = TRUE)
  getaca("res", registry = demo_registry(f$sha256, package = "beta"), quiet = TRUE)
  skip_unless_linked(getaca_info("res", registry = alpha))

  # Two declarations of a 500 byte file occupy 500 bytes, not 1000.
  expect_equal(getaca:::cache_bytes(), 500)
})

test_that("eviction frees the bytes only when it removes the last name for them", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir(), contents = strrep("x", 500))
  testthat::local_mocked_bindings(try_one = serves_file(f), .package = "getaca")
  getaca("res", registry = demo_registry(f$sha256, package = "alpha"), quiet = TRUE)
  getaca("res", registry = demo_registry(f$sha256, package = "beta"), quiet = TRUE)

  withr::local_options(list(getaca.max_bytes = 1))
  getaca_clean(package = "alpha", what = "lru")
  expect_true(getaca:::blob_exists(f$sha256))

  getaca_clean(package = "beta", what = "lru")
  expect_false(getaca:::blob_exists(f$sha256))
})

test_that("a copy left in a slot is adopted rather than downloaded again", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir(), contents = "payload")
  reg <- demo_registry(f$sha256)
  id <- getaca::resource_id("demopkg", "res", "1.0")

  # A cache built before the store existed: bytes in the version slot, no blob.
  raw <- getaca:::cache_raw_dir(id)
  dir.create(raw, recursive = TRUE, showWarnings = FALSE)
  file.copy(f$path, file.path(raw, "res-1.0.csv"))
  testthat::local_mocked_bindings(
    try_one = function(...) stop("the local copy should have answered this"),
    .package = "getaca"
  )

  path <- getaca("res", registry = reg, quiet = TRUE)

  expect_equal(getaca:::sha256_file(path), f$sha256)
  expect_true(getaca:::blob_exists(f$sha256))
})

test_that("a slot holding the wrong bytes is refetched rather than adopted", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir(), contents = "payload")
  reg <- demo_registry(f$sha256)
  id <- getaca::resource_id("demopkg", "res", "1.0")
  raw <- getaca:::cache_raw_dir(id)
  dir.create(raw, recursive = TRUE, showWarnings = FALSE)
  writeBin(charToRaw("something else entirely"), file.path(raw, "res-1.0.csv"))
  testthat::local_mocked_bindings(try_one = serves_file(f), .package = "getaca")

  path <- getaca("res", registry = reg, quiet = TRUE)

  expect_equal(getaca:::sha256_file(path), f$sha256)
})

test_that("removal restores write permission, which Windows requires", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir())
  blob <- getaca:::admit(staged(f), f$sha256)

  expect_equal(unlink(blob), 1L)
  expect_true(file.exists(blob))
  expect_true(getaca:::remove_path(blob))
  expect_false(file.exists(blob))
})

test_that("a sealed file inside a directory does not block its removal", {
  dir <- withr::local_tempdir()
  tree <- file.path(dir, "proc-unzip")
  dir.create(tree)
  writeBin(charToRaw("x"), file.path(tree, "inner"))
  Sys.chmod(file.path(tree, "inner"), "0444")

  expect_true(getaca:::remove_path(tree))
  expect_false(dir.exists(tree))
})

test_that("provenance says how the slot reaches its bytes", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir())
  reg <- demo_registry(f$sha256)
  seed_cache(reg, f)

  info <- getaca_info("res", registry = reg)
  expect_true(info$link %in% c("hardlink", "symlink", "copy"))
  expect_match(paste(utils::capture.output(print(info)), collapse = "\n"),
               "store       ")
  expect_equal(getaca_catalogue(registry = reg)$link, info$link)
})
