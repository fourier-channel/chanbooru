# frozen_string_literal: true

# Sections this fork does not run: comments, notes and the forum.
#
# Operator ruling 2026-09-06. They were removed from the header first, but a
# link removed from a nav is not a page that is gone -- every one of these was
# still reachable by typing the URL, still crawlable, still answering on the
# JSON API, and still accepting writes. Hiding the door is not closing it.
#
# So they 404, and they 404 the way a hidden post does: ActiveRecord::
# RecordNotFound, which ApplicationController renders as "That record was not
# found." A visitor cannot tell a retired section from a URL that never
# existed, which is the point -- a 403 would confirm there is something there.
#
# Upstream already had a guard on two of these, but it was
# `redirect_to root_path`, HTML only, and keyed on comments_enabled? /
# forum_enabled?. Three things wrong with it for this purpose: a redirect
# announces the page exists, `request.format.html?` leaves .json and .atom
# wide open, and notes had no flag at all. This replaces it rather than
# joining it.
#
# The OWNER keeps full access. These sections still hold real records -- old
# forum topics, notes on posts -- and retiring a section must not mean losing
# the ability to look at what is in it.
# Lives in app/logical/concerns, not app/controllers/concerns, because this app
# names its autoload roots explicitly (config/application.rb) and
# app/controllers/concerns is not one of them. ExperiencePreset, the other
# concern ApplicationController includes, is here for the same reason.
module FourierRetiredSections
  extend ActiveSupport::Concern

  # The list lives in config/danbooru_local_config.rb, next to the other
  # fork-chosen restrictions, and is EMPTY under Rails.env.test? so the
  # inherited suite still measures upstream's behaviour. See that method for
  # why, and fourier_retired_sections_test for where this is actually proven.
  #
  # It is matched against `controller_name`, so a section covers every
  # controller that serves it -- votes and version histories included.

  # No `included do before_action` here on purpose. Filters run in declaration
  # order and `include` sits at the top of the class body, which would put this
  # BEFORE set_current_user -- so it would decide "is this the owner?" against
  # a CurrentUser that had not been loaded yet, and lock the owner out of every
  # retired section. ApplicationController declares the filter itself, in the
  # one position where the answer is knowable.
  private

  def reject_retired_section
    return unless Danbooru.config.retired_sections.include?(controller_name)
    return if CurrentUser.user.is_owner?

    raise ActiveRecord::RecordNotFound
  end
end
