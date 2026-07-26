test_that("a declared resource appears before it is ever downloaded", {
  cache <- local_cache()
  reg <- demo_registry(strrep("a", 64), license = "CC-BY-4.0")

  out <- getaca_catalogue(registry = reg)

  expect_equal(nrow(out), 1L)
  expect_equal(out$name, "res")
  expect_equal(out$version, "1.0")
  expect_true(out$declared)
  expect_false(out$cached)
  expect_equal(out$license, "CC-BY-4.0")
  expect_true(is.na(out$path))
  expect_true(is.na(out$verified_at))
})

test_that("a cached copy of a declared resource is reported as both", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir())
  reg <- demo_registry(f$sha256, license = "CC-BY-4.0")
  seeded <- seed_cache(reg, f)

  out <- getaca_catalogue(registry = reg)

  expect_equal(nrow(out), 1L)
  expect_true(out$declared)
  expect_true(out$cached)
  expect_equal(out$path, seeded$path)
  expect_equal(out$size, file.info(f$path)$size)
  expect_equal(out$source, "bundled")
})

test_that("a cached version the registry no longer names is reported as undeclared", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir())
  old <- demo_registry(f$sha256, version = "1.0")
  seed_cache(old, f)
  moved_on <- demo_registry(strrep("b", 64), version = "2.0")

  out <- getaca_catalogue(registry = moved_on)

  expect_equal(nrow(out), 2L)
  expect_equal(out$version, c("2.0", "1.0"))
  expect_equal(out$declared, c(TRUE, FALSE))
  expect_equal(out$cached, c(FALSE, TRUE))
})

test_that("cached bytes with no readable registry are reported as unknown, not undeclared", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir())
  seed_cache(demo_registry(f$sha256), f)

  out <- getaca_catalogue(package = "demopkg")

  expect_equal(nrow(out), 1L)
  expect_true(is.na(out$declared))
  expect_true(out$cached)
})

test_that("declared and cached rows bind into one table in declaration order", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir())
  reg <- registry("demopkg", list(
    resource("res", "1.0", urls = "https://example.invalid/a", sha256 = f$sha256),
    resource("other", "3.0", urls = "https://example.invalid/b", sha256 = strrep("c", 64))
  ))
  seed_cache(reg, f, name = "res")

  out <- getaca_catalogue(registry = reg)

  expect_equal(out$name, c("res", "other"))
  expect_equal(out$cached, c(TRUE, FALSE))
  expect_true(all(out$declared))
})

test_that("a processed resource is declared under the processor that produced it", {
  cache <- local_cache()
  reg <- registry("demopkg", list(
    resource("res", "1.0", urls = "https://example.invalid/a",
             sha256 = strrep("a", 64),
             processor = processor("unzip", function(input, output_dir) output_dir))
  ))

  out <- getaca_catalogue(registry = reg)

  expect_equal(out$processor, "unzip")
  expect_false(out$cached)
})

test_that("an empty catalogue keeps its columns", {
  cache <- local_cache()

  out <- getaca_catalogue(package = "nosuchpackage")

  expect_equal(nrow(out), 0L)
  expect_setequal(
    names(out),
    c("package", "name", "version", "current", "processor", "declared", "cached",
      "size", "license", "source", "revision", "verified_at", "accessed_at",
      "pinned", "path")
  )
  expect_s3_class(out$verified_at, "POSIXct")
})

test_that("the catalogue marks the version a bare request resolves to", {
  cache <- local_cache()
  reg <- registry("demopkg", current = c(res = "2026-09"), resources = list(
    resource("res", "2026-09", urls = "https://example.invalid/a", sha256 = strrep("a", 64)),
    resource("res", "2026-03", urls = "https://example.invalid/b", sha256 = strrep("b", 64)),
    resource("solo", "1.0", urls = "https://example.invalid/c", sha256 = strrep("c", 64))
  ))

  out <- getaca_catalogue(registry = reg)

  expect_equal(out$version, c("2026-09", "2026-03", "1.0"))
  expect_equal(out$current, c(TRUE, FALSE, TRUE))
})

test_that("current is unknown when no registry could be read", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir())
  seed_cache(demo_registry(f$sha256), f)

  out <- getaca_catalogue(package = "demopkg")

  expect_true(is.na(out$current))
})

test_that("the catalogue reports every package holding cached resources", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir())
  seed_cache(demo_registry(f$sha256, package = "onepkg"), f)
  seed_cache(demo_registry(f$sha256, package = "twopkg"), f)

  out <- getaca_catalogue()

  expect_true(all(c("onepkg", "twopkg") %in% out$package))
})

test_that("a package is discovered by the registry it ships, not by registration", {
  cache <- local_cache()
  lib <- withr::local_tempdir()
  dir.create(file.path(lib, "shippingpkg", "getaca"), recursive = TRUE)
  registry_write(
    demo_registry(strrep("a", 64), package = "shippingpkg"),
    file.path(lib, "shippingpkg", "getaca", "registry.rds")
  )
  withr::local_libpaths(lib, action = "prefix")

  expect_true("shippingpkg" %in% getaca:::packages_declaring_resources())
})
