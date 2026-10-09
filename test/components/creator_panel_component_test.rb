# frozen_string_literal: true

require "test_helper"

# The creator's panel as drawn (CreatorPanelComponent; the creator panel,
# 2026-10-09): the refusal line in place of the panel for a non-writer, the
# member counts, the kept-out badge, the member cap, and a fixed number of
# queries however many members and overrides there are.
class CreatorPanelComponentTest < ViewComponent::TestCase
  def queries_during(&)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &)
    count
  end

  def maple_post
    post = as(@tunnel) { create(:post, uploader: @tunnel, tag_string: "landscape") }
    FourierPostCreator.create!(post: post, mxid: "@maple:41chan.net", recorded_by: @tunnel.id)
    post
  end

  # Each render starts from the same caches: the release cache lives for the
  # process, so whether an earlier test had filled it depended on the seed,
  # and moved a query count by one.
  def render_panel(refusal: nil, viewer: @maple, **place)
    CreatorVisibility.forget!
    CreatorTagRelease.reset_cache!
    with_request_url "/creators/maple/edit" do
      render_inline(CreatorPanelComponent.new(gallery: @gallery, viewer: viewer, refusal: refusal, place: place))
    end
  end

  setup do
    CreatorPrefixes.reset!
    @tunnel = create(:builder_user, name: "tunnel")
    @maple = create(:user)
    @gallery = CreatorGallery.create!(slug: "maple", matrix_id: "@maple:41chan.net", user: @maple)
    @tier = CreatorGroup.make!(@gallery, name: "41chan_maple_tier_1", tier: 1, by: @maple)
    CurrentUser.user = @maple
  end

  teardown do
    CurrentUser.user = nil
  end

  should "draw only the refusal for someone who may not use it" do
    render_panel(refusal: "Sign in to the booru as maple to manage who sees your posts.")

    assert_css(".modcreator-panel-refusal", text: "Sign in to the booru as maple to manage who sees your posts.")
    assert_no_css("form")
  end

  should "count active and ended members apart, and badge one kept out" do
    kept = create(:user)
    @tier.add_member!(kept, by: @maple)
    @tier.add_member!(create(:user), by: @maple, expires_at: 1.day.from_now)
    CreatorUserRule.set!(@gallery, kept, rule: "block", by: @maple)
    travel(2.days) { render_panel }

    assert_css(".modcreator-panel-group summary", text: /1 member \(1 ended\)/)
    # said in words a touch screen shows, not only in a tooltip
    assert_css(".modcreator-panel-badge", text: "kept out: a block beats membership", visible: :all)
  end

  should "show at most the member cap a group, saying how to find the rest" do
    3.times { @tier.add_member!(create(:user), by: @maple) }
    stub_const(CreatorPanelComponent, :MEMBER_LIMIT, 2) { render_panel }

    assert_css(".modcreator-panel-group > .modcreator-panel-members > li", count: 2, visible: :all)
    assert_text(:all, "Showing the first 2 by name")
  end

  should "ask the same number of queries for one member and override as for many" do
    @tier.add_member!(create(:user), by: @maple)
    CreatorPostAudience.set!(maple_post, gallery: @gallery, audience: "private", by: @maple)
    CreatorUserRule.set!(@gallery, create(:user), rule: "allow", by: @maple, post: maple_post)
    few = queries_during { render_panel }

    4.times { @tier.add_member!(create(:user), by: @maple) }
    3.times { CreatorPostAudience.set!(maple_post, gallery: @gallery, audience: "private", by: @maple) }
    2.times { CreatorUserRule.set!(@gallery, create(:user), rule: "block", by: @maple, post: maple_post) }
    many = queries_during { render_panel }

    assert_equal(few, many)
  end

  # Enter in a text field submits the form's FIRST submit button. A form
  # whose first button is "Let in" turned the keyboard path to "Keep out"
  # into an allow. The choice is a pair of radios, neither chosen, and one
  # button that carries no rule.
  should "make Let in or Keep out an explicit choice that Enter cannot make" do
    render_panel(post_id: maple_post.id)

    forms = page.all("form", visible: :all).select { |f| f.has_css?("input[name=panel][value=set_rule]", visible: :all) }

    assert_equal(2, forms.size)
    forms.each do |form|
      assert_equal(%w[allow block], form.all("input[type=radio][name=rule]", visible: :all).map(&:value))
      assert(form.all("input[type=radio][name=rule]", visible: :all).none?(&:checked?), "a rule was chosen in advance")
      assert(form.all("button[name=rule], input[type=submit][name=rule]", visible: :all).none?, "a submit button carries a rule")
    end
  end

  # Fail closed: a group run by hand is never named to visitors.
  should "leave Let people ask to join unticked on a new group, and say what the name may hold" do
    render_panel

    assert_css("form.modcreator-panel-make input[type=checkbox][name=open_to_requests]:not([checked])")
    assert_css("form.modcreator-panel-make input[name=suffix][title*='lowercase letters and digits']")
    assert_text(:all, "Lowercase letters and digits, words joined by single underscores")
  end

  should "name every field and every repeated button for a screen reader" do
    member = create(:user, name: "bobbin")
    @tier.add_member!(member, by: @maple)
    CreatorJoinRequest.file!(@tier.tap { |t| t.update!(open_to_requests: true) }, create(:user))
    render_panel

    assert_css("fieldset.modcreator-panel-choice legend", text: "Who sees these posts", visible: :all)
    fields = page.all("input[type=text], input[type=search], input[type=number], input[type=date]", visible: :all).to_a
    fields.each do |field|
      labelled = field.all(:xpath, "ancestor::label", visible: :all).any? || field[:"aria-label"].present?

      assert(labelled, "a #{field[:type]} field named #{field[:name]} has no label")
    end
    assert_css("button[aria-label='Remove bobbin from 41chan_maple_tier_1']", visible: :all)
  end

  # Q3: tiers nest. What the panel says matches what member? enforces.
  should "say tier groups nest in the default's words, and count higher tiers in a dissolve" do
    tier2 = CreatorGroup.make!(@gallery, name: "41chan_maple_tier_2", tier: 2, by: @maple)
    @tier.add_member!(create(:user), by: @maple)
    3.times { tier2.add_member!(create(:user), by: @maple) }
    @gallery.set_default_audience!("groups", by: @maple, group_ids: [@tier.id])
    render_panel(post_id: maple_post.id)

    assert_text(:all, "Use my default (Members of 41chan_maple_tier_1 (and every higher tier))")
    confirm = page.find("button[data-confirm^='Dissolve 41chan_maple_tier_1?']", visible: :all)["data-confirm"]

    assert_match(/Its 1 member, and the 3 members of higher tiers, lose what it alone let them see/, confirm)
  end

  should "draw the group the last write was on open, and only that one" do
    other = CreatorGroup.make!(@gallery, name: "41chan_maple_friends", by: @maple)
    render_panel(open_group: other.id)

    assert_css("details#creator-panel-group-#{other.id}[open]", visible: :all)
    assert_css("details#creator-panel-group-#{@tier.id}:not([open])", visible: :all)
  end

  should "say when the name box matches no member of a group, and offer to clear it" do
    @tier.add_member!(create(:user, name: "bobbin"), by: @maple)
    render_panel(member_q: "zzz")

    assert_text(:all, "No member of 41chan_maple_tier_1 matches \"zzz\".")
    assert_css("a[href='/creators/maple/edit#creator-panel-groups']", text: "Clear search", visible: :all)
    assert_css("form[action='/creators/maple/edit#creator-panel-groups'] input[name=member_q]", visible: :all)
  end

  # The name box filters the people lists too: an empty heading under a
  # search says it is the search that is empty, never "Nobody." -- the
  # block still stands (second repair, 2026-10-09).
  should "say an empty people list under a search is the search's, not that nobody is set" do
    CreatorUserRule.set!(@gallery, create(:user, name: "carol"), rule: "block", by: @maple)
    render_panel(member_q: "bob")

    assert_no_text(:all, "Nobody.")
    assert_css("#creator-panel-people p", text: "Nobody matching \"bob\".", count: 2, visible: :all)
    assert_css("#creator-panel-people a[href='/creators/maple/edit#creator-panel-people']", text: "Clear search", visible: :all)
    render_panel

    assert_css("#creator-panel-people p", text: "Nobody.", count: 1, visible: :all)
  end

  # Fail loudly (2026-09-13): no capped list ends without saying so.
  should "say how many are not shown on every capped list" do
    @tier.update!(open_to_requests: true)
    3.times { CreatorUserRule.set!(@gallery, create(:user), rule: "block", by: @maple) }
    post = maple_post
    3.times { CreatorUserRule.set!(@gallery, create(:user), rule: "allow", by: @maple, post: post) }
    3.times { CreatorJoinRequest.file!(@tier, create(:user)) }
    3.times { @tier.add_member!(create(:user), by: @maple, expires_at: 1.day.from_now) }
    travel(2.days) { stub_const(CreatorPanelComponent, :MEMBER_LIMIT, 2) { render_panel } }

    assert_text(:all, "The oldest 2 of 3 are shown; the rest appear as you answer these.")
    assert_text(:all, "Showing 2 of 3 ended members by name; find others with the name box above.")
    assert_text(:all, "Showing 2 of 3 people set for all your posts by name; find others with the name box.")
    assert_text(:all, "Showing 2 of 3 settings on single posts; find others with the name box, or open a post below to see all of its own.")
    assert_css("#creator-panel-people li", text: /all your posts/, count: 2, visible: :all)
  end

  # Stage-4 browser check (2026-10-09): at 390px the five-column requests
  # table ran 650px wide and pushed Let in / Refuse off the page. It sits in
  # its own scroll box, and every cell names its column for the stacked
  # phone layout (creator_panel_component.scss).
  should "keep the requests table inside its own scroll box, each cell naming its column" do
    @tier.update!(open_to_requests: true)
    CreatorJoinRequest.file!(@tier, create(:user), note: "hi")
    render_panel

    assert_css("#creator-panel-requests .modcreator-panel-scroll > table.modcreator-panel-table", visible: :all)
    assert_equal(%w[Who Group Note Asked], page.all("#creator-panel-requests tbody td[data-label]", visible: :all).pluck("data-label"))
  end

  should "draw the decided requests as a bordered block in line with the others" do
    @tier.update!(open_to_requests: true)
    CreatorJoinRequest.file!(@tier, create(:user)).reject!(by: @maple, note: "")
    render_panel

    assert_css("details.modcreator-panel-block.modcreator-panel-decided", visible: :all)
  end

  # A post left on Members of my groups by a dissolved group: said once.
  should "say a groups override listing no group once" do
    friends = CreatorGroup.make!(@gallery, name: "41chan_maple_friends", by: @maple)
    CreatorPostAudience.set!(maple_post, gallery: @gallery, audience: "groups", by: @maple, group_ids: [friends.id])
    friends.dissolve!(by: @maple)
    render_panel

    row = page.find(".modcreator-panel-posts li", visible: :all)

    assert_equal(1, row.text(:all).scan("Members of my groups").size, row.text(:all))
    assert_no_text(:all, "with no group listed")
    assert_css(".modcreator-panel-posts li .modcreator-panel-warn", text: /lists no group, so only you, admins and people you name see it/, visible: :all)
  end

  should "give every heading its own words, naming the creator to an admin acting for them" do
    render_panel
    headings = page.all("h2, h3", visible: :all).map { |h| h.text(:all).strip }

    assert_equal(headings.uniq, headings, "two headings read the same")
    assert_includes(headings, "Who sees your posts")
    assert_includes(headings, "Default for your posts")
    assert_includes(headings, "Your groups")

    render_panel(viewer: create(:admin_user))
    headings = page.all("h2, h3", visible: :all).map { |h| h.text(:all).strip }

    assert_includes(headings, "Who sees maple's posts")
    assert_includes(headings, "Default for maple's posts")
    assert_includes(headings, "maple's groups")
    assert(headings.none? { |h| h.match?(/\byour\b/i) }, headings.inspect)
  end

  should "list creator-wide settings by name in the database, under the cap" do
    %w[cyd ann bob].each { |name| CreatorUserRule.set!(@gallery, create(:user, name: name), rule: "allow", by: @maple) }
    stub_const(CreatorPanelComponent, :MEMBER_LIMIT, 2) { render_panel }

    assert_equal(%w[ann bob], page.all("#creator-panel-people li", visible: :all).map { |li| li.text[/\A\s*(\w+)/, 1] })
  end
end
