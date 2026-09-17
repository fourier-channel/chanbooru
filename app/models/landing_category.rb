# frozen_string_literal: true

# One carousel category on the landing page: what it is called, whether it is
# shown, and what it searches.
#
# STRUCTURED, NOT A QUERY BOX -- the reasoning is inherited verbatim from
# LandingSetting, which this generalises. An anonymous visitor may search only
# TWO TAGS, and the landing page runs as whoever is looking at it. A third term
# does not narrow a row, it EMPTIES it, and an empty category is dropped from
# the page rather than rendered blank -- so the front page would silently lose
# a row for logged-out visitors and look perfect to the admin who broke it.
#
# Hence #queries returns ONE QUERY PER TAG and never one query of all of them.
# Twenty featured artists is twenty one-term searches, not one twenty-term
# search. #max_terms is validated at or below two whether the category is
# enabled or not: a disabled trap that arms itself when somebody flips the
# toggle is the same bug with a delay on it.
class LandingCategory < ApplicationRecord
  # Matches the sampler's postSourceUrl(board, thread, post); if that host ever
  # changes, this is the other half of the pair and the row goes empty until it
  # is changed too. Moved here from LandingSetting with the category config.
  SOURCE_HOST = "https://boards.4chan.org"
  # The tag the sampler puts on archive-sourced bytes. Live captures carry
  # nothing extra, so this is excluded rather than required.
  ARCHIVE_TAG = "no_train"

  KINDS = %w[board tags galleries].freeze
  # A FIXED MAP, not free text, so the panel can only offer orderings that
  # cannot break a row. "random" is deliberately absent: it would destroy the
  # queue behaviour the showcase depends on, where a row only changes when
  # something new arrives to replace what fell off the end.
  ORDERINGS = { "new" => nil, "favcount" => "order:favcount", "score" => "order:score" }.freeze
  # 30 x QUERY_TIMEOUT_SECONDS is 90s, which is fine in a background job and
  # would be an outage in a request. The cap is here so the panel cannot ask
  # for something the refresh job cannot finish.
  MAX_TAGS = 30
  MAX_TERMS = 2

  # Mirrored from the migration's seed. The seed carries the live front page
  # over on production; this carries it on a database that never ran the seed,
  # which is every fresh dev and test database -- db:prepare loads structure.sql
  # and marks every migration already-run, so a migration-only seed never fires
  # there and the carousel would come up empty.
  DEFAULTS = [
    { key: "new",       label: "Fresh from DEGEN",    enabled: true,  position: 0, kind: "board", board: "b", fresh_only: true, tags: [], ordering: "new" },
    { key: "favorites", label: "Community Favorites", enabled: true,  position: 1, kind: "tags",  board: nil, fresh_only: true, tags: [], ordering: "favcount" },
    { key: "promoted", label: "Promoted Creators", enabled: true, position: 2, kind: "galleries", board: nil, fresh_only: true, tags: [], ordering: "new" },
    { key: "featured", label: "Featured Creators", enabled: false, position: 3, kind: "tags", board: nil, fresh_only: true, tags: [], ordering: "new" },
  ].freeze

  belongs_to :creator_gallery, optional: true

  # `normalizes` BEFORE `array_attribute`; Artist carries the same ordering
  # constraint with the same note.
  normalizes :tags, with: ->(tags) { Array(tags).filter_map { |t| Tag.normalize_name(t).presence }.uniq }
  array_attribute :tags

  validates :key, presence: true, uniqueness: true,
                  format: { with: /\A[a-z][a-z0-9_]{0,30}\z/ }
  validates :label, presence: true, length: { maximum: 40 }
  validates :kind, inclusion: { in: KINDS }
  validates :ordering, inclusion: { in: ORDERINGS.keys }
  validates :board, format: { with: /\A[a-z0-9]{1,10}\z/,
                              message: "is a board slug like 'b', without slashes" }, allow_nil: true
  validate :board_matches_kind
  validate :tags_are_usable
  validate :terms_within_the_anonymous_limit

  scope :visible, -> { where(enabled: true).order(:position, :id) }

  # Every category, seeded rows included, whether or not the database has them.
  def self.configured
    rows = order(:position, :id).to_a
    have = rows.to_set(&:key)
    missing = DEFAULTS.reject { |d| have.include?(d[:key]) }.map { |d| new(d) }
    (rows + missing).sort_by { |c| [c.position, c.key] }
  end

  # ONE QUERY PER TAG. Never one query of all of them -- see the class note.
  def queries
    case kind
    when "board"
      q = "source:#{SOURCE_HOST}/#{board}/*"
      q += " -#{ARCHIVE_TAG}" if fresh_only?
      [q]
    when "tags"
      order_term = ORDERINGS[ordering]
      return [order_term].compact if tags.blank?

      tags.map { |t| [t, order_term].compact.join(" ") }
    else
      []
    end
  end

  # The widest query this category will ask for, in terms.
  def max_terms
    queries.map { |q| q.split.length }.max.to_i
  end

  private

  def board_matches_kind
    if kind == "board"
      errors.add(:board, "is required for a board category") if board.blank?
    elsif board.present?
      errors.add(:board, "only applies to a board category")
    end
  end

  # Written as a validate_ method rather than a validates_each: TagNameValidator
  # is an EachValidator and would be handed the whole array.
  def tags_are_usable
    errors.add(:tags, "cannot be more than #{MAX_TAGS}") if tags.length > MAX_TAGS
    tags.each do |name|
      errors.add(:tags, "#{name} cannot contain a space or a comma") if name.match?(/[[:space:],]/)
      errors.add(:tags, "#{name} cannot start with a metatag") if name.include?(":")
      errors.add(:tags, "#{name} cannot begin or end with an underscore") if name.start_with?("_") || name.end_with?("_")
    end
  end

  def terms_within_the_anonymous_limit
    return if max_terms <= MAX_TERMS

    errors.add(:base, "a category may search at most #{MAX_TERMS} terms at once -- " \
                      "a longer search does not narrow the row for a logged-out visitor, it empties it")
  end
end
