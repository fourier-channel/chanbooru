# frozen_string_literal: true

# What a visitor meets at /users/new while 41chan is closed.
#
# This page is the end of a trail: the front page shows pictures that will not
# load, the cards on them say "you would need to be logged in", and a visitor
# who follows that reasonably arrives here to make an account. Answering them
# with a greyed-out form and "Registrations are currently disabled" leaves them
# with the two questions the trail actually raised -- for how long, and is there
# something I should be doing -- and answers neither.
#
# So this says both, and names someone to ask. It is deliberately built to look
# like a full-size sibling of the error cards: same accent rule, same mono
# voice, same habit of explaining rather than announcing. A visitor who has
# already read three of those cards should recognise this as the same site
# talking, not a different page that happens to be in the way.
class SignupClosedComponent < ApplicationComponent
  attr_reader :viewer, :url

  def initialize(viewer:, url: nil)
    super
    @viewer = viewer
    @url = url
  end

  # Built here rather than taken from the controller: users_controller is
  # upstream's file, and a page that is entirely this fork's should not need a
  # line added to it.
  def pulse
    @pulse ||= ArchivePulse.new(viewer: viewer)
  end
end
