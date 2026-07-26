# A cached copy is bytes plus the declaration they were verified against. When
# the declaration moves and the version label does not, the two disagree about
# what that version means, and a cache hit must not settle the disagreement by
# staying quiet.

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
  proc <- processor("copy", function(path, dir) {
    out <- file.path(dir, "processed.csv")
    file.copy(path, out)
    out
  })
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
