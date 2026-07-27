# Precedence is what decides which registry state a name resolves through, so
# each rung is asserted against the one below it rather than in isolation. The
# clamp and GETACA_OFFLINE sit above everything here and are covered in
# test-resolve.R; these tests release the clamp so the rungs beneath it are
# reachable at all.

test_that("an option outranks the environment for policy", {
  withr::local_envvar(list(NOT_CRAN = "true", GETACA_OFFLINE = "",
                           GETACA_POLICY = "current"))
  withr::local_options(list(getaca.policy = "bundled"))
  expect_equal(getaca_policy(), "bundled")
})

test_that("the environment outranks a registry's own policy", {
  withr::local_envvar(list(NOT_CRAN = "true", GETACA_OFFLINE = "",
                           GETACA_POLICY = "pinned"))
  withr::local_options(list(getaca.policy = NULL))
  expect_equal(getaca:::effective_policy("current"), "pinned")
})

test_that("a registry's own policy outranks the bundled default", {
  withr::local_envvar(list(NOT_CRAN = "true", GETACA_OFFLINE = "",
                           GETACA_POLICY = ""))
  withr::local_options(list(getaca.policy = NULL))
  expect_equal(getaca:::effective_policy("current"), "current")
  expect_equal(getaca:::effective_policy(NULL), "bundled")
})

test_that("setting a policy takes effect and returns it invisibly", {
  withr::local_envvar(list(NOT_CRAN = "true", GETACA_OFFLINE = "",
                           GETACA_POLICY = ""))
  withr::local_options(list(getaca.policy = NULL))

  expect_invisible(getaca_policy("current"))
  expect_equal(getOption("getaca.policy"), "current")
  expect_equal(getaca_policy(), "current")
})

test_that("a policy that does not exist is refused rather than stored", {
  withr::local_options(list(getaca.policy = NULL))
  expect_error(getaca_policy("whenever"))
  expect_null(getOption("getaca.policy"))
})

test_that("the cache directory follows the same precedence", {
  withr::local_options(list(getaca.cache = "~/from-option"))
  withr::local_envvar(list(GETACA_CACHE = "~/from-env"))
  expect_equal(getaca_cache_dir(), path.expand("~/from-option"))

  withr::local_options(list(getaca.cache = NULL))
  expect_equal(getaca_cache_dir(), path.expand("~/from-env"))

  withr::local_envvar(list(GETACA_CACHE = ""))
  expect_equal(getaca_cache_dir(), tools::R_user_dir("getaca", "cache"))
})

test_that("asking where the cache is does not create it", {
  dir <- withr::local_tempdir()
  target <- file.path(dir, "not-yet")
  withr::local_options(list(getaca.cache = target))

  expect_equal(getaca_cache_dir(), target)
  expect_false(dir.exists(target))
})

test_that("a setting reads from the option, then the environment, then falls back", {
  withr::local_options(list(getaca.verify_days = 7))
  withr::local_envvar(list(GETACA_VERIFY_DAYS = "14"))
  expect_equal(getaca:::getaca_setting("verify_days", 90), 7)

  withr::local_options(list(getaca.verify_days = NULL))
  expect_equal(getaca:::getaca_setting("verify_days", 90), 14)

  withr::local_envvar(list(GETACA_VERIFY_DAYS = ""))
  expect_equal(getaca:::getaca_setting("verify_days", 90), 90)
})

# Every retention setting is arithmetic downstream: a day count is multiplied by
# 86400 and a ceiling is compared against a byte total. A string would either
# error or, for the comparison, silently order "1e+10" against "1000" and never
# sweep, so the environment has to arrive converted rather than as text.
test_that("a setting from the environment arrives as a number", {
  withr::local_options(list(getaca.max_bytes = NULL, getaca.supersede_days = NULL))
  withr::local_envvar(list(GETACA_MAX_BYTES = "1000",
                           GETACA_SUPERSEDE_DAYS = "5"))

  expect_true(is.numeric(getaca:::setting_max_bytes()))
  expect_equal(getaca:::setting_max_bytes(), 1000)
  expect_gt(1e10, getaca:::setting_max_bytes())
  expect_s3_class(Sys.time() - getaca:::setting_supersede_days() * 86400, "POSIXct")
})

test_that("each retention setting has its own name and default", {
  withr::local_options(list(getaca.supersede_days = NULL, getaca.verify_days = NULL,
                            getaca.max_bytes = NULL, getaca.timeout = NULL,
                            getaca.lock_stale_seconds = NULL))
  withr::local_envvar(list(GETACA_SUPERSEDE_DAYS = "", GETACA_VERIFY_DAYS = "",
                           GETACA_MAX_BYTES = "", GETACA_TIMEOUT = "",
                           GETACA_LOCK_STALE_SECONDS = ""))

  expect_equal(getaca:::setting_supersede_days(), 30)
  expect_equal(getaca:::setting_verify_days(), 90)
  expect_equal(getaca:::setting_max_bytes(), 20 * 1024^3)
  expect_equal(getaca:::setting_timeout(), 3600)
  expect_equal(getaca:::setting_lock_stale(), 1800)
})

test_that("GETACA_OFFLINE accepts the spellings it documents", {
  withr::local_envvar(list(NOT_CRAN = "true"))
  for (yes in c("1", "true", "TRUE", "yes", "Yes")) {
    withr::with_envvar(list(GETACA_OFFLINE = yes), {
      expect_true(getaca:::is_offline_forced())
    })
  }
  for (no in c("", "0", "false", "no", "maybe")) {
    withr::with_envvar(list(GETACA_OFFLINE = no), {
      expect_false(getaca:::is_offline_forced())
    })
  }
})

# The clamp reads three separate variables because R CMD check does not set one
# of them reliably across versions, and NOT_CRAN has to override all of them.
test_that("any check variable trips the clamp and NOT_CRAN releases it", {
  for (v in c("_R_CHECK_PACKAGE_NAME_", "_R_CHECK_TIMINGS_", "_R_CHECK_LICENSE_")) {
    withr::with_envvar(
      structure(list("demopkg", ""), names = c(v, "NOT_CRAN")),
      expect_true(getaca:::in_r_check())
    )
    withr::with_envvar(
      structure(list("demopkg", "true"), names = c(v, "NOT_CRAN")),
      expect_false(getaca:::in_r_check())
    )
  }
})
