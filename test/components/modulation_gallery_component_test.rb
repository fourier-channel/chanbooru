# frozen_string_literal: true

require "test_helper"

# The Modulation gallery's pager and empty states under the gallery window
# (GALLERY_WINDOW.md section 2): prev, next and the count, never a page
# number -- a page cannot be numbered once each box depends on the viewer's
# own blocklist -- and an empty state for each reason the box can be empty.
class ModulationGalleryComponentTest < ViewComponent::TestCase
  def draw(tags, user: @member, page: nil)
    CurrentUser.scoped(user) do
      render_inline(ModulationGalleryComponent.new(post_set: PostSets::Post.new(tags, page, nil, user: user, window: :page), viewer: user))
    end
  end

  setup do
    @member = create(:user)
    as(@member) { create_list(:post, 3, tag_string: "gcomp") }
  end

  should "draw prev, next and the count, and no page number" do
    draw("gcomp")
    assert_css(".modgal-pager a.modgal-page[rel=prev][data-shortcut='a left'][aria-disabled=true]")
    assert_css(".modgal-pager a.modgal-page[rel=next][data-shortcut='d right'][aria-disabled=true]")
    assert_css(".modgal-pager .modgal-page-count", text: "3 posts in this search")
    assert_no_text(/page \d/)
    assert_css("p.modgal-window-status[role=status]", visible: :all)
  end

  should "leave the count out when the search could not be counted" do
    PostSets::Post.any_instance.stubs(:post_count).returns(nil)
    draw("gcomp")
    assert_no_css(".modgal-page-count")
  end

  should "carry both blocklist empty states, hidden until the window needs one" do
    draw("gcomp")
    assert_css(".modgal-empty--blocked[hidden]", text: /hidden by your blocklist.*Fix: lift a block/m, visible: :hidden)
    assert_css(".modgal-empty--capped[hidden]", text: /one page of results.*Fix:/m, visible: :hidden)
  end

  should "say there are no results when there are none" do
    draw("gcomp_nothing_here")
    assert_css("p.modgal-empty", text: /No tags exist with that exact combination/)
    assert_no_css(".modgal-empty--blocked", visible: :all)
    assert_no_css(".modgal-grid")
  end

  should "say why an order:none search cannot page" do
    draw("gcomp order:none")
    assert_css(".modgal-window-status", text: /order:none has no order to page through. Fix: pick a sort/)
    assert_no_css(".modgal-grid[data-window]")
  end

  # Fork: a provenance row stays behind when its tag leaves the post (BUR
  # review 2026-10-19, claim 1): a hand edit, a bulk update and the
  # private-tag cleanup all write tag_string and never the sidecar, and undo
  # and revert bring the tag back with its provenance. Such a dormant row is
  # provenance for nothing on that post, so it may neither colour another
  # card's pill nor put its name into the page.
  context "a provenance row whose tag has left its post" do
    setup do
      @bot = create(:builder_user, name: "tunnel")
      @carrier, @emptied = as(@bot) { create_list(:post, 2, tag_string: "gdorm dormant_x kept_y") }
      FourierTagSource.record_partition!(@emptied, { auto: %w[dormant_x kept_y] }, @bot)
      as(@member) { @emptied.update!(tag_string: "gdorm kept_y") }
      assert(FourierTagSource.exists?(post_id: @emptied.id, tag: "dormant_x", public: true), "fixture: the row stayed behind")
    end

    should "not colour a page pill from a row whose tag has left its own post" do
      draw("gdorm -gdorm_absent")

      assert_css(".mod-unitag [data-tag='dormant_x'].mod-pill--unsourced")
      assert_css(".mod-unitag [data-tag='dormant_x'] .mod-pill-dot--manual")
      assert_css(".mod-unitag [data-tag='kept_y'].mod-pill--auto", text: "kept y")
    end

    should "not publish a dormant row's name in data-tag-marks" do
      draw("gdorm -gdorm_absent")
      marks = page.find(".modgal-card[data-id='#{@emptied.id}']", visible: :all)["data-tag-marks"]

      assert_equal(%w[kept_y], JSON.parse(marks).keys)
    end
  end
end
