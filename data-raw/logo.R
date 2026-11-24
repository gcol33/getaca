# Hex logo: the console progress bar of a transfer, filling in twelve steps,
# holding at 100% and starting again, over the SHA-256 digest of the sample
# fixture drawn as a tiled 16 x 16 bit matrix that drifts by one tile per
# loop. Reduced motion and renderers without animation rest at 67% over a
# still digest.
# Run from the package root: Rscript data-raw/logo.R

source("data-raw/bits.R")

paper <- "#F5F6F8"; ink <- "#2B3A4A"; blue <- "#2E6F9E"; rest <- "#B4BDC8"
bit <- "#DCE2E9"; cell <- 26; tile <- 16 * cell; drift <- 40
digest <- unname(tools::sha256sum("tests/testthat/fixtures/sample.zip"))
tiles <- expand.grid(x = c(-tile, 0, tile), y = c(-116, -116 + tile))
background <- function(class, animate) paste0(
  '<g class="', class, '" clip-path="url(#hex)"><g fill="', bit, '">',
  if (animate) sprintf(
    '<animateTransform attributeName="transform" type="translate" from="0 0" to="%s 0" dur="%ss" repeatCount="indefinite"/>',
    tile, drift) else "",
  paste(sprintf('<use href="#digest" x="%s" y="%s"/>', tiles$x, tiles$y), collapse = ""),
  '</g></g>')
halo <- sprintf('stroke="%s" stroke-linejoin="round" paint-order="stroke"', paper)
mono <- "Consolas, 'SFMono-Regular', Menlo, monospace"
hex <- function(radius) {
  angle <- seq(-90, 210, by = 60) * pi / 180
  paste(sprintf("%.2f,%.2f", 260 + radius * cos(angle), 300 + radius * sin(angle)), collapse = " ")
}
n <- 12; hold <- 4; frames <- n + 1 + hold; step <- 0.6; dur <- frames * step
still_at <- 8
x0 <- 76; x1 <- 444; seg <- (x1 - x0) / n; gap <- 6; top <- 280; h <- 54
key_times <- paste(sprintf("%.4f", (seq_len(frames) - 1) / frames), collapse = ";")
discrete <- function(values) sprintf(
  '<animate attributeName="opacity" calcMode="discrete" dur="%ss" repeatCount="indefinite" keyTimes="%s" values="%s"/>',
  dur, key_times, paste(values, collapse = ";"))
frame <- seq_len(frames) - 1
filled <- pmin(frame, n)
segment <- function(i, animate) {
  x <- x0 + (i - 1) * seg + gap / 2
  paste0(sprintf('<rect x="%.1f" y="%s" width="%.1f" height="10" rx="3" fill="%s"/>', x, top + h / 2 - 5, seg - gap, rest),
         sprintf('<rect x="%.1f" y="%s" width="%.1f" height="%s" rx="4" fill="%s" opacity="%d">%s</rect>',
                 x, top, seg - gap, h, blue, as.integer(i <= still_at),
                 if (animate) discrete(as.integer(filled >= i)) else ""))
}
percent <- function(k, animate) sprintf(
  '<text x="260" y="240" text-anchor="middle" font-family="%s" font-weight="bold" font-size="104" fill="%s" %s stroke-width="12" opacity="%d">%d%%%s</text>',
  mono, ink, halo, as.integer(k == still_at), round(100 * k / n), if (animate) discrete(as.integer(filled == k)) else "")
bracket <- function(x, dir) sprintf(
  '<path d="M%s %sh%sv%sh%s" fill="none" stroke="%s" stroke-width="9" stroke-linecap="round" stroke-linejoin="round"/>',
  x - dir * 16, top - 12, dir * 16, h + 24, -dir * 16, ink)
layer <- function(class, animate) paste0('<g class="', class, '">',
  paste(vapply(seq_len(n), segment, character(1), animate = animate), collapse = ""),
  if (animate) paste(vapply(0:n, percent, character(1), animate = TRUE), collapse = "") else percent(still_at, FALSE), '</g>')
svg <- paste0(
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 520 600" role="img" aria-label="getaca logo">',
  '<title>getaca logo</title>',
  '<style>.still{display:none}@media(prefers-reduced-motion:reduce){.moving{display:none}.still{display:inline}}</style>',
  '<defs><clipPath id="hex"><polygon points="', hex(288), '"/></clipPath>',
  '<path id="digest" d="', cells_path(bits(digest) == 1, 0, 0, cell), '"/></defs>',
  '<polygon points="', hex(288), '" fill="', paper, '"/>',
  background("moving", TRUE), background("still", FALSE),
  sprintf('<rect x="%s" y="%s" width="%s" height="%s" rx="6" fill="%s"/>',
          x0 - 28, top - 12, x1 - x0 + 56, h + 24, paper),
  bracket(x0 - 12, -1), bracket(x1 + 12, 1), layer("moving", TRUE), layer("still", FALSE),
  '<text x="260" y="462" text-anchor="middle" font-family="Georgia, \'Times New Roman\', serif" font-weight="bold" font-style="italic" font-size="78" fill="', blue, '" ', halo, ' stroke-width="10">getaca</text>',
  '<polygon points="', hex(291), '" fill="none" stroke="', ink, '" stroke-width="18" stroke-linejoin="round"/></svg>')
stopifnot(!grepl("Inf|NaN", svg), nchar(svg, type = "bytes") < 200000)
dir.create("man/figures", recursive = TRUE, showWarnings = FALSE)
writeLines(svg, "man/figures/logo.svg", useBytes = TRUE)
