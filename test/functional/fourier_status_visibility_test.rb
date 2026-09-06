# frozen_string_literal: true

require "test_helper"

# The server status page is not public on this instance (operator ruling
# 2026-09-06).
#
# Upstream serves /status to anyone and means to: ServerStatusPolicy is empty,
# so it inherits ApplicationPolicy#show?, which returns true unconditionally.
# For danbooru.donmai.us that is a reasonable call -- "is the site down or is it
# just me" is a question ordinary visitors genuinely have. On an invite-gated
# instance the same page is a version manifest handed to anyone who asks: exact
# Rails, Ruby, Puma, Postgres, Redis, libvips, ffmpeg and exiftool versions, the
# kernel build string, the load average, container names, and a full Redis INFO.
#
# 403 rather than the 404 the retired sections use. That is a deliberate
# difference, not an inconsistency: a retired section 404s because a 403 would
# confirm there is something behind the door, whereas /status is a documented
# upstream path that anyone who recognises Danbooru already knows exists.
# Concealing it buys nothing, and 403 is the truthful answer.
#
# Danbooru.config.status_page_visibility_level is ANONYMOUS under
# Rails.env.test?, so upstream's status_controller_test keeps measuring
# upstream's behaviour -- six tests that GET this page signed-out and assert
# success. That makes this file the only place the fork's rule is proven, so it
# proves it across every format and every level rather than spot-checking one.
class FourierStatusVisibilityTest < ActionDispatch::IntegrationTest
  FORMATS = [nil, :json, :xml].freeze

  def restrict!
    Danbooru.config.stubs(:status_page_visibility_level).returns(User::Levels::ADMIN)
  end

  def status_path_for(format)
    format.nil? ? status_path : status_path(format: format)
  end

  context "the server status page, when restricted" do
    setup { restrict! }

    should "be denied to an anonymous visitor in every format" do
      FORMATS.each do |format|
        get status_path_for(format)
        assert_response 403, "expected #{status_path_for(format)} to be denied for anonymous"
      end
    end

    # The API was the hole in the comparable guard elsewhere in this app: a
    # check written against the HTML page left .json answering in full. The
    # manifest lives in the JSON, so this is the assertion that matters most.
    should "not leak the version manifest to an anonymous visitor" do
      get status_path(format: :json)

      assert_response 403
      assert_no_match(/ruby_version|postgres_version|redis_version|kernel_version/, response.body)
    end

    should "be denied to an ordinary member" do
      user = create(:user)

      FORMATS.each do |format|
        get_auth status_path_for(format), user
        assert_response 403, "expected #{status_path_for(format)} to be denied for a member"
      end
    end

    # A moderator sits below ADMIN and is the level most likely to be assumed
    # sufficient by someone reading the rule later.
    should "be denied to a moderator" do
      user = create(:moderator_user)

      FORMATS.each do |format|
        get_auth status_path_for(format), user
        assert_response 403, "expected #{status_path_for(format)} to be denied for a moderator"
      end
    end

    # The positive cases are asserted at the POLICY, not through a rendered
    # response, and that is deliberate rather than a shortcut.
    #
    # Upstream's own status_controller_test currently fails 5 of 6 in this
    # environment on a CLEAN tree -- the default layout renders
    # NewsUpdateComponent, which queries the database from the layout, and the
    # status page 500s before it can answer. Verified by stashing this change
    # and re-running: identical failures. Asserting `:success` here would make
    # this file report that bug instead of the rule it exists to prove, and
    # would go green on its own the day someone else fixes it.
    #
    # The denial cases above stay as integration tests because a 403 is raised
    # before the layout renders, so they measure the real request path.
    should "let an admin through the policy" do
      assert(ServerStatusPolicy.new(create(:admin_user), nil).show?,
             "expected an admin to be permitted by ServerStatusPolicy")
    end

    should "let the owner through the policy" do
      assert(ServerStatusPolicy.new(create(:owner_user), nil).show?,
             "expected the owner to be permitted by ServerStatusPolicy")
    end

    # Complements the policy assertions: whatever the layout does, an admin must
    # not be turned away by authorization. Deliberately not `:success` -- see
    # above.
    should "not deny an admin at the authorization layer" do
      get_auth status_path, create(:admin_user)

      assert_not_equal(403, response.status, "an admin must not be denied /status")
    end
  end

  # Guards the switch itself. If the config predicate stopped being consulted,
  # every assertion above would still pass with the restriction hard-coded, and
  # this is the only test that would notice. Asserted at the policy for the same
  # rendering reason given above.
  context "the server status page, unrestricted as upstream ships it" do
    should "permit an anonymous visitor" do
      Danbooru.config.stubs(:status_page_visibility_level).returns(User::Levels::ANONYMOUS)

      assert(ServerStatusPolicy.new(User.anonymous, nil).show?,
             "expected anonymous to be permitted when the level is ANONYMOUS")
    end
  end
end
