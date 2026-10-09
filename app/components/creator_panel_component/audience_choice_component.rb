# frozen_string_literal: true

# The three audiences and the group ticks, each with what it means -- the
# same choice for the creator default and for one post (CREATOR_VISIBILITY
# section 4 and Q4; the creator panel, 2026-10-09). The post's form adds
# "use my default" (`inherit`, the default's words). Nothing is ticked for a
# default not chosen yet: the explicit no-opinion state is shown as such.
class CreatorPanelComponent::AudienceChoiceComponent < ApplicationComponent
  CHOICES = [
    ["public", "Everyone", "Anyone the site already lets see a post. People in a group you tick, or people you name below, can also see posts the site would otherwise hold back from their account level."],
    ["groups", "Members of my groups", "Only the groups you tick, people you name below, admins and you."],
    ["private", "Private", "Only you, admins and people you name one by one. Groups never open a private post."],
  ].freeze

  attr_reader :name, :chosen, :groups, :ticked, :inherit

  # @param groups [Array<Array(Integer, String)>] [id, label] pairs
  # @param inherit [String, nil] the default's words, offering "use my
  #   default"; nil for the default's own form
  def initialize(name:, chosen:, groups:, ticked:, inherit:)
    super
    @name = name
    @chosen = chosen
    @groups = groups
    @ticked = ticked
    @inherit = inherit
  end

  def choices
    inherit ? [["inherit", "Use my default (#{inherit})", "This post follows whatever your default says."], *CHOICES] : CHOICES
  end
end
