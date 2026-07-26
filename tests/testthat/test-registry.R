test_that("a registry round-trips through its stored form", {
  dir <- withr::local_tempdir()
  reg <- demo_registry(strrep("a", 64))
  path <- registry_write(reg, file.path(dir, "getaca", "registry.rds"))
  expect_true(file.exists(path))
  expect_equal(registry_read(path), reg)
})

test_that("duplicate declarations are refused", {
  expect_error(
    registry("demopkg", list(
      resource("res", "1.0", urls = "https://e.org/f", sha256 = strrep("a", 64)),
      resource("res", "1.0", urls = "https://e.org/g", sha256 = strrep("b", 64))
    )),
    class = "getaca_error_invalid_registry"
  )
})

test_that("two packages may declare the same resource name without colliding", {
  a <- demo_registry(strrep("a", 64), package = "pkgA")
  b <- demo_registry(strrep("b", 64), package = "pkgB")
  ida <- resolve_resource("res", registry = a)$id
  idb <- resolve_resource("res", registry = b)$id
  expect_false(identical(format(ida), format(idb)))
  expect_false(identical(getaca:::cache_version_dir(ida),
                         getaca:::cache_version_dir(idb)))
})

test_that("an unknown resource name names what is on offer", {
  reg <- demo_registry(strrep("a", 64))
  expect_error(
    resolve_resource("nope", registry = reg),
    class = "getaca_error_invalid_registry"
  )
  expect_error(resolve_resource("nope", registry = reg), "res")
})

test_that("YAML authoring produces the same model as the R constructor", {
  skip_if_not_installed("yaml")
  dir <- withr::local_tempdir()
  path <- file.path(dir, "registry.yml")
  writeLines(c(
    "res:",
    "  version: '1.0'",
    "  urls:",
    "    - https://example.invalid/res-1.0.csv",
    paste0("  sha256: '", strrep("a", 64), "'"),
    "  license: CC-BY-4.0"
  ), path)

  reg <- as_registry(path, package = "demopkg")
  expect_equal(reg$resources$res$sha256, strrep("a", 64))
  expect_equal(reg$resources$res$license, "CC-BY-4.0")
  expect_equal(reg$resources$res$urls, "https://example.invalid/res-1.0.csv")
})
