caught <- function(expr) tryCatch(expr, condition = function(e) e)

test_that("an uncached resource is not available, and asking costs no network", {
  cache <- local_cache()
  reg <- demo_registry(strrep("a", 64))

  testthat::local_mocked_bindings(
    try_one = function(...) stop("availability must not reach the network"),
    .package = "getaca"
  )
  expect_false(getaca_available("res", registry = reg))
})

test_that("a cached resource is available", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir())
  reg <- demo_registry(f$sha256)
  seed_cache(reg, f)

  expect_true(getaca_available("res", registry = reg))
})

test_that("a cached resource that no longer matches its entry is not available", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir())
  reg <- demo_registry(f$sha256)
  seeded <- seed_cache(reg, f)
  writeBin(charToRaw("truncated"), seeded$path)

  expect_false(getaca_available("res", registry = reg))
})

test_that("an unknown resource is not available rather than an error", {
  cache <- local_cache()
  expect_false(getaca_available("nope", registry = demo_registry(strrep("a", 64))))
})

test_that("an unavailable resource degrades to NULL with a message", {
  cache <- local_cache()
  withr::local_envvar(list(GETACA_OFFLINE = "true"))
  reg <- demo_registry(strrep("a", 64))

  expect_message(path <- getaca_optional("res", registry = reg), "abbreviated")
  expect_null(path)
})

test_that("an available resource is returned by the optional accessor", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir())
  reg <- demo_registry(f$sha256)
  seeded <- seed_cache(reg, f)

  expect_equal(getaca_optional("res", registry = reg), seeded$path)
})

test_that("an uncached resource skips the test that needs it, naming the remedy", {
  cache <- local_cache()
  reg <- demo_registry(strrep("a", 64))

  cond <- caught(getaca_skip_if_unavailable("res", registry = reg))

  expect_s3_class(cond, "skip")
  expect_match(conditionMessage(cond), "getaca_prefetch")
  expect_match(conditionMessage(cond), "demopkg")
})

test_that("a cached resource skips nothing", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir())
  reg <- demo_registry(f$sha256)
  seed_cache(reg, f)

  expect_null(getaca_skip_if_unavailable("res", registry = reg))
})

test_that("a skip names the declaring package when one was given", {
  cache <- local_cache()
  cond <- caught(getaca_skip_if_unavailable("res", package = "stats"))

  expect_s3_class(cond, "skip")
  expect_match(conditionMessage(cond), "stats")
})
