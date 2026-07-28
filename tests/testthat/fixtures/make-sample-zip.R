# Builds the zip archive test-unpack.R extracts.
#
# Every other format the tests need, base R writes: utils::tar() makes the
# tarballs and gzfile()/bzfile()/xzfile() make the single compressed files.
# Nothing in base R writes a zip, and utils::zip() shells out to a program that
# is not on every machine a check runs on, so this one archive is committed and
# only read. Regenerate from the package root with:
#
#   Rscript tests/testthat/fixtures/make-sample-zip.R
#
# Layout, which the tests assert on:
#
#   names.csv
#   tables/synonyms.csv
#   tables/ranks.csv

out <- "tests/testthat/fixtures/sample.zip"

staging <- tempfile("sample-zip-")
dir.create(file.path(staging, "tables"), recursive = TRUE)

write_bytes <- function(path, text) {
  con <- file(path, open = "wb")
  on.exit(close(con))
  writeBin(charToRaw(text), con)
}

write_bytes(file.path(staging, "names.csv"), "id,name\n1,Fagus sylvatica\n")
write_bytes(file.path(staging, "tables", "synonyms.csv"), "id,synonym\n1,Fagus silvatica\n")
write_bytes(file.path(staging, "tables", "ranks.csv"), "id,rank\n1,species\n")

owd <- setwd(staging)
on.exit(setwd(owd), add = TRUE)
unlink(file.path(owd, out))
status <- utils::zip(file.path(owd, out),
                     files = c("names.csv", "tables"),
                     flags = "-r9Xq")
setwd(owd)

if (!identical(as.integer(status), 0L) || !file.exists(out)) {
  stop("could not build ", out, ": zip exited with status ", status)
}

cat("wrote", out, paste0("(", file.size(out), " bytes)"), "\n")
print(utils::unzip(out, list = TRUE)[, c("Name", "Length")])
