demo <- function(..., current = NULL, package = "demopkg", remote = NULL,
                 policy = "bundled") {
  registry(package, list(...), current = current, remote = remote, policy = policy)
}

res <- function(name = "res", version = "1.0", sha = strrep("a", 64), ...) {
  resource(name, version, urls = "https://example.invalid/res.csv", sha256 = sha, ...)
}

test_that("the manifest names its format and renders the declaration", {
  reg <- demo(
    res("wfo", "2026-06", license = "CC-BY-4.0", size = 1048576,
        upstream = list(release = "2026-06")),
    remote = "https://registry.invalid/demopkg.rds"
  )

  lines <- unclass(registry_manifest(reg))

  expect_equal(lines[1], "getaca-manifest 1")
  expect_true("package demopkg" %in% lines)
  expect_true("remote https://registry.invalid/demopkg.rds" %in% lines)
  expect_true("resource wfo 2026-06" %in% lines)
  expect_true("  size 1048576" %in% lines)
  expect_true("  license CC-BY-4.0" %in% lines)
  expect_true("  url https://example.invalid/res.csv" %in% lines)
  expect_true("  upstream release 2026-06" %in% lines)
})

test_that("a large size renders as digits rather than scientific notation", {
  reg <- demo(res(size = 2.5e9))
  expect_true("  size 2500000000" %in% unclass(registry_manifest(reg)))
})

test_that("absent fields contribute no line at all", {
  reg <- demo(res())
  lines <- unclass(registry_manifest(reg))

  expect_false(any(grepl("^remote", lines)))
  expect_false(any(grepl("^\\s*size", lines)))
  expect_false(any(grepl("^\\s*license", lines)))
  expect_false(any(grepl("^current", lines)))
})

test_that("a digest is self-describing and hexadecimal", {
  expect_match(registry_digest(demo(res())), "^sha256:[0-9a-f]{64}$")
})

test_that("the same declaration digests the same however it was built", {
  a <- demo(res("one"), res("two", sha = strrep("b", 64)))
  b <- demo(res("two", sha = strrep("b", 64)), res("one"))

  expect_equal(registry_digest(a), registry_digest(b))
})

test_that("mirror order is kept, because mirrors are tried in order", {
  urls <- c("https://a.invalid/f", "https://b.invalid/f")
  a <- demo(resource("res", "1.0", urls = urls, sha256 = strrep("a", 64)))
  b <- demo(resource("res", "1.0", urls = rev(urls), sha256 = strrep("a", 64)))

  expect_false(identical(registry_digest(a), registry_digest(b)))
})

test_that("a processor contributes its id, not its closure", {
  body_one <- processor("unzip", function(input, output_dir) output_dir)
  body_two <- processor("unzip", function(input, output_dir) {
    invisible(input)
    output_dir
  })
  renamed <- processor("unzip-v2", function(input, output_dir) output_dir)

  same <- lapply(list(body_one, body_two), function(p) demo(res(processor = p)))
  expect_equal(registry_digest(same[[1]]), registry_digest(same[[2]]))
  expect_false(identical(
    registry_digest(same[[1]]),
    registry_digest(demo(res(processor = renamed)))
  ))

  # The reason the manifest exists: hashing the serialised object would make a
  # registry's identity depend on the closure it happens to be carrying.
  serialised <- function(x) getaca:::sha256_bytes(serialize(x, NULL))
  expect_false(identical(serialised(same[[1]]), serialised(same[[2]])))
})

test_that("what a name resolves to is part of the identity", {
  two <- list(res("wfo", "2026-03"), res("wfo", "2026-09", sha = strrep("b", 64)))
  a <- registry("demopkg", two, current = c(wfo = "2026-03"))
  b <- registry("demopkg", two, current = c(wfo = "2026-09"))

  expect_false(identical(registry_digest(a), registry_digest(b)))
})

test_that("changing declared bytes changes the identity", {
  expect_false(identical(
    registry_digest(demo(res(sha = strrep("a", 64)))),
    registry_digest(demo(res(sha = strrep("b", 64))))
  ))
})

test_that("prose and defaults are outside the identity", {
  plain <- demo(res())
  described <- demo(res(description = "the reference backbone"))
  other_policy <- demo(res(), policy = "current")

  expect_equal(registry_digest(plain), registry_digest(described))
  expect_equal(registry_digest(plain), registry_digest(other_policy))
})

test_that("publication time is outside the identity, so rewriting keeps it", {
  dir <- withr::local_tempdir()
  reg <- demo(res())
  first <- file.path(dir, "first.rds")
  second <- file.path(dir, "second.rds")

  registry_write(reg, first, created = as.POSIXct("2026-01-01", tz = "UTC"))
  registry_write(reg, second, created = as.POSIXct("2026-07-01", tz = "UTC"))

  a <- registry_read(first)
  b <- registry_read(second)

  expect_false(identical(a$created, b$created))
  expect_equal(registry_digest(a), registry_digest(b))
  expect_equal(registry_digest(a), registry_digest(reg))
})

test_that("escaping keeps field boundaries unambiguous", {
  # Without escaping the space, these two would render the same upstream line.
  a <- demo(res(upstream = list(`source release` = "x")))
  b <- demo(res(upstream = list(source = "release x")))

  expect_false(identical(registry_digest(a), registry_digest(b)))
  expect_true("  upstream source\\srelease x" %in% unclass(registry_manifest(a)))
})

test_that("a manifest prints as the text it is", {
  out <- paste(utils::capture.output(print(registry_manifest(demo(res())))),
               collapse = "\n")
  expect_match(out, "getaca-manifest 1", fixed = TRUE)
  expect_match(out, "resource res 1.0", fixed = TRUE)
})

test_that("the short form keeps the algorithm and enough hex to recognise", {
  full <- registry_digest(demo(res()))
  expect_equal(getaca:::short_digest(full), substr(full, 1, nchar("sha256:") + 12))
  expect_true(is.na(getaca:::short_digest(NA_character_)))
})
