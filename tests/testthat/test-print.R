shown <- function(x) paste(utils::capture.output(print(x)), collapse = "\n")

test_that("a resource id formats as package/name@version", {
  id <- resource_id("taxify", "wfo", "2026-06")

  expect_equal(format(id), "taxify/wfo@2026-06")
  expect_equal(as.character(id), "taxify/wfo@2026-06")
  expect_match(shown(id), "taxify/wfo@2026-06", fixed = TRUE)
})

test_that("printing a record shows what identifies it and where it came from", {
  rec <- resource("wfo", "2026-06",
                  urls = c("https://primary.invalid/wfo.zip",
                           "https://mirror.invalid/wfo.zip"),
                  sha256 = strrep("a", 64),
                  size = 1048576,
                  license = "CC-BY-4.0",
                  upstream = list(release = "WFO 2026-06"),
                  processor = processor("unzip", function(input, output_dir) output_dir))

  out <- shown(rec)
  expect_match(out, "wfo")
  expect_match(out, "2026-06")
  expect_match(out, "CC-BY-4.0")
  expect_match(out, "1,048,576")
  expect_match(out, "built from")
  expect_match(out, "WFO 2026-06")
  expect_match(out, "unzip")
  expect_match(out, "mirror.invalid")
})

test_that("a record with unknown size says unknown rather than NA", {
  rec <- resource("res", "1.0", urls = "https://a.invalid/f", sha256 = strrep("a", 64))
  expect_match(shown(rec), "unknown")
})

test_that("a record formats to one line naming its version and license", {
  rec <- resource("res", "1.0", urls = "https://a.invalid/f",
                  sha256 = strrep("a", 64), license = "MIT")
  expect_match(format(rec), "res@1.0", fixed = TRUE)
  expect_match(format(rec), "MIT", fixed = TRUE)
})

test_that("printing a registry lists the package, policy and declarations", {
  reg <- registry("demopkg", list(
    resource("one", "1.0", urls = "https://a.invalid/one", sha256 = strrep("a", 64)),
    resource("two", "2.0", urls = "https://a.invalid/two", sha256 = strrep("b", 64))
  ), remote = "https://registry.invalid/demopkg.rds", policy = "current")

  out <- shown(reg)
  expect_match(out, "demopkg")
  expect_match(out, "digest: sha256:", fixed = TRUE)
  expect_match(out, "current")
  expect_match(out, "registry.invalid")
  expect_match(out, "one@1.0", fixed = TRUE)
  expect_match(out, "two@2.0", fixed = TRUE)
})

test_that("printing a registry marks the channel head", {
  reg <- registry("demopkg", current = c(res = "2026-09"), resources = list(
    resource("res", "2026-03", urls = "https://a.invalid/a", sha256 = strrep("a", 64)),
    resource("res", "2026-09", urls = "https://a.invalid/b", sha256 = strrep("b", 64))
  ))

  lines <- utils::capture.output(print(reg))
  expect_match(grep("2026-09", lines, value = TRUE), "(current)", fixed = TRUE)
  expect_false(any(grepl("(current)", grep("2026-03", lines, value = TRUE), fixed = TRUE)))
})

# A registry gains its publication date and its signing keys only once it has
# been written and read back, so both lines are absent from a registry built in
# a session and present on the one a package ships.
test_that("printing a published registry shows when it was published and who may sign it", {
  dir <- withr::local_tempdir()
  key <- registry_keygen(file.path(dir, "key"))
  reg <- registry("demopkg", keys = key, resources = list(
    resource("res", "1.0", urls = "https://a.invalid/a", sha256 = strrep("a", 64))
  ))

  expect_false(grepl("created:", shown(reg)))

  path <- registry_write(reg, file.path(dir, "registry.rds"),
                         created = as.POSIXct("2026-01-01 09:30:00", tz = "UTC"))
  out <- shown(registry_read(path))

  expect_match(out, "created: 2026-01-01")
  expect_match(out, "signed by: ed25519:")
})

test_that("printing a cache entry shows the provenance getaca kept", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir())
  reg <- demo_registry(f$sha256, license = "CC-BY-4.0")
  seeded <- seed_cache(reg, f)

  out <- shown(seeded$entry)
  expect_match(out, "demopkg/res@1.0", fixed = TRUE)
  expect_match(out, "CC-BY-4.0")
  expect_match(out, "bundled registry sha256:", fixed = TRUE)
  expect_match(out, as.character(utils::packageVersion("getaca")), fixed = TRUE)
  expect_match(out, "full re-hash")
  expect_match(out, "size and mtime")
})

test_that("a pinned entry built from something says both", {
  cache <- local_cache()
  f <- seed_file(withr::local_tempdir())
  reg <- demo_registry(f$sha256, upstream = list(release = "WFO 2026-06"))
  seeded <- seed_cache(reg, f)
  entry <- seeded$entry
  entry$pinned <- TRUE
  entry$processor_id <- "unzip"

  out <- shown(entry)
  expect_match(out, "built from")
  expect_match(out, "WFO 2026-06")
  expect_match(out, "processor")
  expect_match(out, "never garbage collected")
})
