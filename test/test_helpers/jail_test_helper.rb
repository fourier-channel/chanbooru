# frozen_string_literal: true

# R2 (operator 2026-11-20): only the jail adds or takes off troll_jail
# (Post#validate_jail_tag_change refuses everyone else). A fixture that needs
# the tag on a post, or off a released one, writes it inside this block, which
# lets whoever is the current user write it the way the jail panel's account
# (Post.jail_tagger?) does. It stands in for the jail, not for a hand edit: a
# test of the refusal itself never uses it.
module JailTestHelper
  def as_the_jail
    Post.stubs(:jail_tagger?).returns(true)
    yield
  ensure
    Post.unstub(:jail_tagger?)
  end
end
