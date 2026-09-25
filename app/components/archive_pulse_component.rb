# frozen_string_literal: true

# The archive's vital signs, as a strip of three numbers.
#
# Shown to people who cannot see the pictures. The gate stays shut, but "shut"
# and "empty" should not look the same from outside, and without this they do:
# a locked archive with forty thousand posts in it and a locked archive with
# none render identically once the images are 401s.
#
# A stat that could not be computed is dropped rather than shown as zero. "0
# posts" is not a smaller version of the message, it is the opposite one.
class ArchivePulseComponent < ApplicationComponent
  attr_reader :pulse

  def initialize(pulse:)
    super
    @pulse = pulse
  end

  def render?
    pulse.any?
  end

  # @return [Array<Array>] [value, label] pairs, in reading order, minus any the
  #   database declined to answer for.
  def stats
    [
      (pulse.posts.present? ? [number_with_delimiter(pulse.posts), "posts"] : nil),
      (pulse.tags.present? ? [number_with_delimiter(pulse.tags), "tags"] : nil),
    ].compact
  end

  def newest?
    pulse.newest_at.present?
  end

  # The one that says the archive is not a museum. A count proves size; a
  # timestamp proves something happened here recently.
  def newest_phrase
    "last upload #{time_ago_in_words(pulse.newest_at)} ago"
  end

  # The tooltip's raw material: when the last upload was, and the recent pace
  # of passes. Timestamps, not phrases -- archive_pulse_component.js words them
  # at the moment the tooltip is read, because this strip sits on a page left
  # open for as long as the carousel holds someone, and "2 minutes ago" written
  # at render is a lie a quarter of an hour later.
  def live_data
    cadence = pulse.cadence || {}
    {
      newest_at: pulse.newest_at.iso8601,
      last_at: cadence[:last_at]&.iso8601,
      burst_at: cadence[:burst_at]&.iso8601,
      every: cadence[:every],
    }.compact
  end
end
