test_that("a remote channel may add mirrors and versions", {
  bundled <- demo_registry(strrep("a", 64))
  fetched <- registry("demopkg", list(
    resource("res", "1.0",
             urls = c("https://mirror.invalid/res-1.0.csv",
                      "https://example.invalid/res-1.0.csv"),
             sha256 = strrep("a", 64)),
    resource("res", "2.0",
             urls = "https://example.invalid/res-2.0.csv",
             sha256 = strrep("b", 64))
  ))
  expect_true(getaca:::assert_immutable(bundled, fetched))
})

test_that("a remote channel may not redefine a published version", {
  bundled <- demo_registry(strrep("a", 64))
  fetched <- demo_registry(strrep("b", 64))
  expect_error(
    getaca:::assert_immutable(bundled, fetched),
    class = "getaca_error_invalid_registry"
  )
  expect_error(getaca:::assert_immutable(bundled, fetched), "res@1.0")
})

test_that("resolution collapses to offline under R CMD check", {
  withr::local_envvar(list(
    "_R_CHECK_PACKAGE_NAME_" = "demopkg",
    NOT_CRAN = ""
  ))
  withr::local_options(list(getaca.policy = "current"))
  expect_equal(getaca_policy(), "offline")
})

test_that("NOT_CRAN releases the check clamp", {
  withr::local_envvar(list(
    "_R_CHECK_PACKAGE_NAME_" = "demopkg",
    NOT_CRAN = "true"
  ))
  withr::local_options(list(getaca.policy = "bundled"))
  expect_equal(getaca_policy(), "bundled")
})

test_that("GETACA_OFFLINE forces offline resolution", {
  withr::local_envvar(list(GETACA_OFFLINE = "true", NOT_CRAN = "true"))
  withr::local_options(list(getaca.policy = "current"))
  expect_equal(getaca_policy(), "offline")
})

test_that("an explicit version bypasses channel resolution", {
  reg <- registry("demopkg", list(
    resource("res", "1.0", urls = "https://e.invalid/a", sha256 = strrep("a", 64)),
    resource("res", "2.0", urls = "https://e.invalid/b", sha256 = strrep("b", 64))
  ))
  expect_equal(resolve_resource("res", registry = reg)$id$version, "2.0")
  expect_equal(resolve_resource("res", registry = reg, version = "1.0")$id$version, "1.0")
})

test_that("a package with no registry says so, naming the conventional path", {
  expect_error(
    resolve_resource("res", package = "stats"),
    class = "getaca_error_invalid_registry"
  )
  expect_error(resolve_resource("res", package = "stats"), "inst/getaca/registry.rds")
})
