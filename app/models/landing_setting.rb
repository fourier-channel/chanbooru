# frozen_string_literal: true

# The landing console's page-wide settings: how fast the slides move, and the
# posts the error page draws its picture from. One row, edited from
# /admin/landing_setting, read by ModulationLandingComponent and
# ErrorPagePicture.
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

  # THE ERROR PAGE'S PICTURES (operator, 2026-10-11): booru posts by id, one
  # drawn at random on each load of the "Oh No!" page (ErrorPagePicture, which
  # also decides which of them a viewer may be shown). Each id once, in the
  # order given, and a bounded number: the console lists every one with its
  # status, and the pick caches the list.
  ERROR_PAGE_POSTS_MAX = 50

  # What the console types: ids separated by spaces, commas or newlines.
  ID_SEPARATORS = /[\s,]+/

  normalizes :error_page_post_ids, with: ->(ids) { ids.uniq }

  validate :error_page_post_ids_are_post_ids

  # Saved, the box shows the list as stored (deduplicated, one separator),
  # not as it was typed.
  after_save { @error_page_post_ids_text = @unreadable_post_ids = nil }

  # The list as the console's text box shows it: what was typed, while a
  # refused save is shown back to be corrected, otherwise the saved ids.
  def error_page_post_ids_text
    @error_page_post_ids_text || error_page_post_ids.join(" ")
  end

  # Parse the console's text box. A token that is not a positive integer is
  # kept aside to be refused by name, rather than dropped or cast to 0.
  def error_page_post_ids_text=(text)
    @error_page_post_ids_text = text.to_s
    tokens = @error_page_post_ids_text.split(ID_SEPARATORS).compact_blank
    @unreadable_post_ids = tokens.grep_v(/\A[1-9][0-9]*\z/)
    self.error_page_post_ids = (tokens - @unreadable_post_ids).map(&:to_i)
  end

  def self.current
    first || new
  end

  private

  # Every error names itself and its remedy (ruling 2026-09-14). Whether each
  # post EXISTS is asked only when the list changed: a post expunged after it
  # was listed must not stop the slide speed saving -- the console marks it
  # "missing" instead.
  def error_page_post_ids_are_post_ids
    ids = error_page_post_ids.to_a
    if @unreadable_post_ids.present?
      errors.add(:base, "Error page pictures: #{@unreadable_post_ids.map { |t| "\"#{t}\"" }.join(", ")} #{(@unreadable_post_ids.size == 1) ? "is not a post id" : "are not post ids"}. List post numbers only, like 1234 5678.")
    end
    if ids.any? { |id| !id.is_a?(Integer) || id < 1 }
      errors.add(:base, "Error page pictures: post ids are positive whole numbers. Remove #{ids.reject { |id| id.is_a?(Integer) && id >= 1 }.join(", ")}.")
    end
    if ids.size > ERROR_PAGE_POSTS_MAX
      errors.add(:base, "Error page pictures: #{ids.size} posts listed, and at most #{ERROR_PAGE_POSTS_MAX} may be. Remove #{ids.size - ERROR_PAGE_POSTS_MAX}.")
    end
    return unless will_save_change_to_error_page_post_ids? && errors.empty?

    missing = ids - Post.where(id: ids).pluck(:id)
    return if missing.empty?

    errors.add(:base, "Error page pictures: no post #{missing.map { |id| "##{id}" }.join(", ")} -- remove #{(missing.size == 1) ? "it" : "them"}, or correct the number.")
  end
end
