# frozen_string_literal: true

require "test_helper"

# The Creator Identity dashboard (operator, 2026-11-05): the creator's names,
# their original characters and who sees their posts in one place, at
# edit?view=identity (no new routes), under one "Manage Creator Identity"
# button. Its Claim Pool starts with the page's direct-name counterparts,
# grows by search, shows the names that cannot be had greyed with why, and
# sends everything ticked in one request with a note. Popped out (popout=1)
# it is drawn without the site's menus, and every answer from it comes back
# there.
class CreatorIdentityDashboardTest < ActionDispatch::IntegrationTest
  MAPLE = { "X-Fourier-Identity" => "@maple:41chan.net" }.freeze

  setup do
    CreatorPrefixes.reset!
    @maple = create(:user)
    @admin = create(:admin_user)
    @gallery = CreatorGallery.create!(slug: "maple", matrix_id: "@maple:41chan.net", user: @maple)
    as(@admin) do
      %w[4chan_maple aichan_maple 4chan_maple_alt].each { |name| create(:tag, name: name, category: TagCategory::ARTIST, post_count: 2) }
    end
  end

  def dashboard(user = @maple, headers: MAPLE, **params)
    get_auth edit_creator_gallery_path(@gallery, view: "identity", **params), user, headers: headers
  end

  def pool_row(name) = "#creator-claims li.creator-pool-row[data-name='#{name}']"

  context "the page" do
    should "carry the instructions, the three boxes and the Manage Creator Identity way in" do
      dashboard

      assert_response :success
      assert_select "#creator-identity-help li", count: 3
      assert_select "#creator-identity #creator-account"
      assert_select "#creator-identity #creator-claims h3", text: "Claim Pool"
      assert_select "#creator-identity #creator-characters"
      assert_select "#creator-identity #creator-visibility"
      assert_select "#creator-identity [data-identity-popout]", count: 1
      assert_select "#creator-identity [data-identity-tour='creator_name']", count: 1
      assert_select "#creator-identity [data-identity-tour='oc']", count: 1
    end

    should "be reached from the gallery by one Manage Creator Identity button" do
      get_auth creator_gallery_path(@gallery), @maple, headers: MAPLE

      assert_select "a[href='#{edit_creator_gallery_path(@gallery, view: "identity")}']", minimum: 1
    end

    should "be read-only to anyone but the claimant" do
      dashboard(create(:user), headers: {})

      assert_response 403
    end
  end

  context "the Claim Pool" do
    should "start with the direct-name counterparts, ticked and available for immediate claim" do
      dashboard

      %w[4chan_maple aichan_maple].each do |name|
        assert_select "#{pool_row(name)}[data-outcome='immediate'] input[name='claim_tag[]'][value='#{name}'][checked]", count: 1
        assert_select pool_row(name), text: /available for immediate claim/
      end
      assert_select "#creator-identity[data-direct-match='true']", count: 1
    end

    should "show a counterpart nobody has posted under, unusable, with why" do
      Tag.find_by_name("aichan_maple").update!(post_count: 0)
      dashboard

      assert_select "#{pool_row("aichan_maple")}[data-outcome='refused'] input[disabled]", count: 1
      assert_select pool_row("aichan_maple"), text: /unavailable: nothing is posted under aichan_maple yet/
    end

    should "grow by search, unticked, each name labelled for review" do
      dashboard(creator_q: "maple_alt")

      assert_select "#{pool_row("4chan_maple_alt")}[data-outcome='requested'] input[name='claim_tag[]']:not([checked])", count: 1
      assert_select pool_row("4chan_maple_alt"), text: /an admin reviews it/
    end

    should "show a name another creator holds in the search, unusable, with why" do
      rival = CreatorGallery.create!(slug: "rival", matrix_id: "@rival:41chan.net", user: create(:user))
      as(@admin) { create(:tag, name: "4chan_rival", category: TagCategory::ARTIST, post_count: 3) }
      CreatorClaimRequest.file!(gallery: rival, user: rival.user, names: ["4chan_rival"])
      dashboard(creator_q: "4chan_rival")

      assert_select "#{pool_row("4chan_rival")}[data-outcome='refused'] input[disabled]", count: 1
      assert_select pool_row("4chan_rival"), text: /unavailable: .*4chan_rival/
    end

    should "answer the page's search with the found rows alone" do
      dashboard(creator_q: "maple_alt", fragment: "pool")

      assert_response :success
      assert_select "li.creator-pool-row[data-name='4chan_maple_alt']", count: 1
      assert_select "#creator-identity", count: 0
    end

    should "keep a name a link brought, ticked" do
      dashboard(pool: ["4chan_maple_alt"])

      assert_select "#{pool_row("4chan_maple_alt")} input[checked]", count: 1
    end
  end

  context "sending the pool" do
    should "approve the direct matches at once and file the rest as one request with the note" do
      put_auth creator_gallery_path(@gallery, view: "identity"), @maple,
               headers: MAPLE, params: { claim_tag: ["", "4chan_maple", "4chan_maple_alt"], claim_note: "I post as maple_alt on /aco/" }

      assert_redirected_to edit_creator_gallery_path(@gallery, view: "identity", anchor: "creator-claims")
      assert(ArtistClaim.find_by!(tag_name: "4chan_maple").approved?)
      request = CreatorClaimRequest.sole
      assert_equal("I post as maple_alt on /aco/", request.note)
      assert_equal(["4chan_maple_alt"], request.artist_claims.map(&:tag_name))
      assert_match(/4chan_maple is yours now\. Asked for 4chan_maple_alt: an admin reviews the request/, flash[:notice])
    end

    should "say so when nothing was ticked" do
      put_auth creator_gallery_path(@gallery, view: "identity"), @maple, headers: MAPLE, params: { claim_tag: [""] }

      assert_match(/Nothing filed: tick at least one name/, flash[:notice])
      assert_equal(0, ArtistClaim.count)
    end

    should "come back to the popped-out window from it" do
      put_auth creator_gallery_path(@gallery, view: "identity", popout: "1"), @maple, headers: MAPLE, params: { claim_tag: ["4chan_maple"] }

      assert_redirected_to edit_creator_gallery_path(@gallery, view: "identity", popout: "1", anchor: "creator-claims")
    end
  end

  context "original characters" do
    should "offer a character under the creator's name, by another's posts, as available for immediate claim" do
      as(@admin) { create(:post, tag_string: "pine_(maple)") }
      dashboard

      assert_select "#creator-characters [data-identity-step='ready'] li", text: /pine_\(maple\).*available for immediate claim/m
      assert_select "#creator-characters [data-identity-step='ready'] input[name='claim_character'][value='pine_(maple)']", count: 1
    end

    should "create a new one from the dashboard and come back to it" do
      put_auth creator_gallery_path(@gallery, view: "identity"), @maple, headers: MAPLE, params: { claim_character: "acorn" }

      assert_redirected_to edit_creator_gallery_path(@gallery, view: "identity", anchor: "creator-characters")
      assert(CharacterClaim.find_by!(tag_name: "acorn_(maple)").approved?)
    end
  end

  context "popped out" do
    should "be drawn without the site's menus, in the site's preset, with the way back" do
      dashboard(popout: "1")

      assert_response :success
      assert_select "#top.modnav", count: 0
      assert_select "body[data-preset]", count: 1
      assert_select "#creator-identity.creator-identity-popout[data-popout='true']", count: 1
      assert_select "#creator-identity [data-identity-dock]", count: 1
      assert_select "#creator-identity [data-identity-popout]", count: 0
      assert_select ".creator-pool-search input[name='popout'][value='1']", count: 1
    end
  end

  context "the tours" do
    should "carry how each tour ended, for the page to offer the next" do
      ModulationSetting.record!(@maple, nil, "tours" => { "creator_name" => "skipped" })
      dashboard

      assert_select "#creator-identity[data-tour-creator-name='skipped'][data-tour-oc='']", count: 1
    end

    should "be remembered through the settings route" do
      login_as(@maple)
      patch modulation_settings_path, params: { tours: { oc: "done" }}, as: :json

      assert_response :success
      assert_equal({ "oc" => "done" }, ModulationSetting.for_viewer(@maple)["tours"])
    end
  end
end
