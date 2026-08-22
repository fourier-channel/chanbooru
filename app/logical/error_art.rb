# frozen_string_literal: true

# The copy and colours for the error images.
#
# One source of truth. These are rendered as standalone SVGs served at
# /errors/<status>.svg, which means they are loaded through <img> -- and an SVG
# in an <img> is an isolated document: no page CSS reaches it, and no CSS custom
# property from the theme is visible inside it. So the palette is baked in here
# rather than referenced, and this file is where it has to be kept in step with
# the Modulation tokens if those ever move.
#
# Wording is deliberately plain and says what the reader can DO about it, or
# admits when there is nothing. A status code alone tells a visitor nothing; a
# broken-image icon tells them less.
class ErrorArt
  # Warm-dark, matching the Modulation surfaces. Duplicated from the theme by
  # necessity (see above), not by accident.
  INK = "#e8e6e0"
  INK_DIM = "#9a968c"
  SURFACE = "#1b1a17"
  LINE = "#34322c"

  # accent per severity
  RED = "#ff6b7a"     # you cannot have this
  ORANGE = "#ff9d3c"  # slow down / temporary
  BLUE = "#6db8ff"    # not here
  GOLD = "#c9a15a"    # our fault
  GREEN = "#38e08a"

  ERRORS = {
    400 => { title: "Bad Request!",   accent: ORANGE, body: "This means the request came out garbled. Reloading usually settles it." },
    401 => { title: "Who Goes There!", accent: BLUE,  body: "This means you need to be logged in to see this. Signing in should do it." },
    403 => { title: "Not Authorized!", accent: RED,   body: "This means you don't have permission to see this image." },
    404 => { title: "Not Found!",      accent: BLUE,  body: "This means the image you were looking for isn't here." },
    405 => { title: "Not That Way!",   accent: ORANGE, body: "This means the request was made in a way this page doesn't accept." },
    406 => { title: "Can't Serve That!", accent: ORANGE, body: "This means you asked for a format this page can't produce." },
    410 => { title: "That's Far Enough!", accent: ORANGE, body: "This means the page exists but is past how far your account can browse. Searching still works." },
    422 => { title: "Too Many Tags!",  accent: ORANGE, body: "This means the search asked for more tags than your account is allowed at once." },
    429 => { title: "Slow Down!",      accent: ORANGE, body: "This means you're browsing faster than the server thinks you should be able to. If you encounter this during normal use, please report it." },
    451 => { title: "Taken Down!",     accent: RED,    body: "This means the image was removed following a takedown request or a rule violation." },
    500 => { title: "We Broke It!",    accent: GOLD,   body: "This means something failed on our end, not yours. It's worth reporting if it keeps happening." },
    501 => { title: "Not Built Yet!",  accent: GOLD,   body: "This means you found something that isn't finished." },
    502 => { title: "Bad Gateway!",    accent: GOLD,   body: "Something went wrong somewhere, and we're trying to figure out who to blame." },
    503 => { title: "Back Shortly!",   accent: GOLD,   body: "This means the server is down or busy. It's usually brief." },
    504 => { title: "Took Too Long!",  accent: GOLD,   body: "This means something upstream never answered. Trying again often works." },
  }.freeze

  # Anything unrecognised still gets a card rather than a broken-image icon --
  # the whole point is that the reader learns something.
  FALLBACK = { title: "Unavailable!", accent: INK_DIM, body: "This image couldn't be loaded, and the server didn't say why." }.freeze

  attr_reader :status

  def initialize(status)
    @status = status.to_i
  end

  def known?
    ERRORS.key?(status)
  end

  def entry
    ERRORS.fetch(status, FALLBACK)
  end

  def title = entry[:title]
  def accent = entry[:accent]
  def body = entry[:body]

  # The big number. An unknown status still shows whatever it was, so a reader
  # reporting it has something to quote.
  def code
    status.positive? ? status.to_s : "?"
  end

  def self.statuses
    ERRORS.keys
  end
end
