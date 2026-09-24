# frozen_string_literal: true

# The landing carousel's carousel-wide settings: how fast the slides move. One
# row, edited from /admin/landing_setting, read by ModulationLandingComponent.
#
# IT USED TO BE THE "NEW" ROW'S TARGET, and the board, fresh_only and label
# columns are what is left of that. On 2026-09-17 every row moved onto
# LandingCategory: 5a844dad7 seeded the "new" category from this row, and
# 8b8f06cee made LandingShowcase read the table. From then on those three
# columns were read by NOTHING -- yet the console kept offering them, and
# saving them flashed "The front page now shows ..." while the front page
# stayed exactly as it was, beside the Categories form that edits the row the
# showcase really reads. Two controls for one setting, one dead and saying
# otherwise. They are gone from the form, the policy and this model.
#
# The columns stay until a migration drops them. Nothing may start reading
# them again: LandingCategory is the one place a row is configured, and its
# class note carries the two-term reasoning that used to live here.
class LandingSetting < ApplicationRecord
  # HOW FAST THE SLIDES MOVE, in milliseconds, bounded at both ends.
  #
  # The floor is not taste. Below about a second a slide cannot be read before
  # it leaves, and the carousel's auto-advance drives a transition on every
  # step -- a value of 0 or 50 would not be a fast carousel, it would be a
  # permanent animation on the page the bare domain serves to everyone, which
  # this project has already paid for once (one infinite box-shadow animation
  # idled a surface at 45% of a core).
  # The ceiling stops a typo turning the carousel into a still image: 120000 is
  # two minutes, past which nobody would see it move at all.
  ADVANCE_MS_RANGE = (1_500..120_000)

  validates :advance_ms, numericality: {
    only_integer: true,
    greater_than_or_equal_to: ADVANCE_MS_RANGE.min,
    less_than_or_equal_to: ADVANCE_MS_RANGE.max,
    message: "must be between #{ADVANCE_MS_RANGE.min} and #{ADVANCE_MS_RANGE.max} milliseconds",
  }

  def self.current
    first || new
  end
end
