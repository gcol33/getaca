test_that("a remote channel may add mirrors and versions", {
  bundled <- demo_registry(strrep("a", 64))
  fetched <- registry("demopkg", current = c(res = "2.0"), resources = list(
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
  reg <- registry("demopkg", current = c(res = "2.0"), resources = list(
    resource("res", "1.0", urls = "https://e.invalid/a", sha256 = strrep("a", 64)),
    resource("res", "2.0", urls = "https://e.invalid/b", sha256 = strrep("b", 64))
  ))
  expect_equal(resolve_resource("res", registry = reg)$id$version, "2.0")
  expect_equal(resolve_resource("res", registry = reg, version = "1.0")$id$version, "1.0")
})

test_that("a bare name resolves to the head the registry names, not the last declared", {
  reg <- registry("demopkg", current = c(res = "2026-09"), resources = list(
    resource("res", "2026-09", urls = "https://e.invalid/b", sha256 = strrep("b", 64)),
    resource("res", "2026-03", urls = "https://e.invalid/a", sha256 = strrep("a", 64))
  ))
  expect_equal(resolve_resource("res", registry = reg)$id$version, "2026-09")
})

test_that("a version the channel head does not name still resolves explicitly", {
  reg <- registry("demopkg", current = c(res = "2.0"), resources = list(
    resource("res", "1.0", urls = "https://e.invalid/a", sha256 = strrep("a", 64)),
    resource("res", "2.0", urls = "https://e.invalid/b", sha256 = strrep("b", 64))
  ))
  expect_equal(resolve_resource("res", registry = reg, version = "1.0")$id$version, "1.0")
  expect_error(
    resolve_resource("res", registry = reg, version = "3.0"),
    class = "getaca_error_invalid_registry"
  )
})

test_that("a remote channel may move the head without republishing bytes", {
  local_registries()
  bundled <- registry("demopkg", current = c(res = "1.0"), resources = list(
    resource("res", "1.0", urls = "https://e.invalid/a", sha256 = strrep("a", 64))
  ), remote = "https://registry.invalid/demopkg.rds", policy = "current")

  moved <- registry("demopkg", current = c(res = "2.0"), resources = list(
    resource("res", "1.0", urls = "https://e.invalid/a", sha256 = strrep("a", 64)),
    resource("res", "2.0", urls = "https://e.invalid/b", sha256 = strrep("b", 64))
  ))

  channel <- getaca:::remote_channel(bundled, fetch = function(url, dest) {
    registry_write(moved, dest)
    TRUE
  })

  expect_equal(getaca:::select_record(channel, "res")$version, "2.0")
  expect_equal(getaca:::select_record(bundled, "res")$version, "1.0")
})

test_that("a pin file freezes what an analysis resolves", {
  cache <- local_cache()
  dir <- withr::local_tempdir()
  pins <- file.path(dir, "getaca.pins.rds")
  withr::local_options(list(getaca.pin_file = pins))

  frozen <- registry("demopkg", list(
    resource("res", "1.0", urls = "https://e.invalid/a", sha256 = strrep("a", 64))
  ))
  saveRDS(list(demopkg = frozen), pins)

  # The installed registry has moved on; the pin holds the analysis in place.
  installed <- registry("demopkg", current = c(res = "2.0"), resources = list(
    resource("res", "1.0", urls = "https://e.invalid/a", sha256 = strrep("a", 64)),
    resource("res", "2.0", urls = "https://e.invalid/b", sha256 = strrep("b", 64))
  ))

  expect_equal(resolve_resource("res", registry = installed)$id$version, "2.0")
  expect_equal(
    resolve_resource("res", registry = installed, policy = "pinned")$id$version,
    "1.0"
  )
  expect_equal(
    resolve_resource("res", registry = installed, policy = "pinned")$source,
    "pinned"
  )
})

test_that("a missing pin file says how to make one", {
  cache <- local_cache()
  dir <- withr::local_tempdir()
  withr::local_options(list(getaca.pin_file = file.path(dir, "absent.rds")))
  reg <- demo_registry(strrep("a", 64))

  expect_error(
    resolve_resource("res", registry = reg, policy = "pinned"),
    class = "getaca_error_invalid_registry"
  )
  expect_error(
    resolve_resource("res", registry = reg, policy = "pinned"),
    "getaca_pin"
  )
})

test_that("a pin file that omits the package says which one", {
  cache <- local_cache()
  dir <- withr::local_tempdir()
  pins <- file.path(dir, "getaca.pins.rds")
  withr::local_options(list(getaca.pin_file = pins))
  saveRDS(list(otherpkg = demo_registry(strrep("a", 64), package = "otherpkg")), pins)

  expect_error(
    resolve_resource("res", registry = demo_registry(strrep("a", 64)), policy = "pinned"),
    "records nothing for package 'demopkg'"
  )
})

test_that("a pin file may not redefine a published version either", {
  cache <- local_cache()
  dir <- withr::local_tempdir()
  pins <- file.path(dir, "getaca.pins.rds")
  withr::local_options(list(getaca.pin_file = pins))
  saveRDS(list(demopkg = demo_registry(strrep("b", 64))), pins)

  expect_error(
    resolve_resource("res", registry = demo_registry(strrep("a", 64)), policy = "pinned"),
    class = "getaca_error_invalid_registry"
  )
  # The rule is shared with the remote channel; the message says which of the
  # two is at fault.
  expect_error(
    resolve_resource("res", registry = demo_registry(strrep("a", 64)), policy = "pinned"),
    "the pin file redefines published version"
  )
})

test_that("resolution reports the policy actually in force", {
  reg <- demo_registry(strrep("a", 64))
  withr::local_envvar(list(NOT_CRAN = "true", GETACA_OFFLINE = "", GETACA_POLICY = ""))
  withr::local_options(list(getaca.policy = NULL))

  expect_equal(resolve_resource("res", registry = reg)$policy, "bundled")
  expect_equal(resolve_resource("res", registry = reg, policy = "offline")$policy,
               "offline")
})

test_that("an offline call never reaches the network, whatever the session is set to", {
  cache <- local_cache()
  withr::local_envvar(list(NOT_CRAN = "true", GETACA_OFFLINE = "", GETACA_POLICY = ""))
  withr::local_options(list(getaca.policy = "bundled"))
  testthat::local_mocked_bindings(
    try_one = function(...) stop("the network should not have been reached"),
    .package = "getaca"
  )

  expect_error(
    getaca("res", registry = demo_registry(strrep("a", 64)), policy = "offline"),
    class = "getaca_error_offline"
  )
})

test_that("pinning a package with no registry warns rather than failing", {
  cache <- local_cache()
  dir <- withr::local_tempdir()
  expect_warning(
    getaca_pin("stats", path = file.path(dir, "pins.rds")),
    "ships no getaca registry"
  )
})

test_that("a package with no registry says so, naming the conventional path", {
  expect_error(
    resolve_resource("res", package = "stats"),
    class = "getaca_error_invalid_registry"
  )
  expect_error(resolve_resource("res", package = "stats"), "inst/getaca/registry.rds")
})
