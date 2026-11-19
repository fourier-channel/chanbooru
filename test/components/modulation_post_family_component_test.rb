# frozen_string_literal: true

require "test_helper"

# A post's family on Modulation's post page: its parent and siblings, and its
# children, as post strips -- exactly the posts upstream's relationship
# notices would draw for the viewer, and nothing when there are none.
class ModulationPostFamilyComponentTest < ViewComponent::TestCase
  def draw(post, user: @member, relatives: nil)
    CurrentUser.scoped(user) do
      render_inline(ModulationPostFamilyComponent.new(post: post.reload, viewer: user, relatives: relatives))
    end
  end

  def card_ids(strip_title)
    page.find("section.modstrip", text: strip_title).all("a.modgal-card").map { |card| card["data-id"].to_i }
  end

  setup do
    @member = create(:user)
    @parent = as(@member) { create(:post) }
    @child = as(@member) { create(:post, parent: @parent) }
    @sibling = as(@member) { create(:post, parent: @parent) }
  end

  should "draw the parent and siblings for a child, the post among them, linked to the family search" do
    draw(@child)

    assert_css("section.modfamily[data-post-id='#{@child.id}']")
    assert_css("section.modfamily > section.modstrip", count: 1)
    assert_css("h2.modstrip-title > a[href='/posts?tags=parent%3A#{@parent.id}']", text: "Parent and siblings")
    assert_equal([@parent.id, @child.id, @sibling.id].sort, card_ids("Parent and siblings").sort)
    assert_no_css(".modstrip-empty")
    assert_no_css(".modgal")
  end

  should "draw the children for a parent, the post among them" do
    draw(@parent)

    assert_css("section.modfamily > section.modstrip", count: 1)
    assert_css("h2.modstrip-title > a[href='/posts?tags=parent%3A#{@parent.id}']", text: "Children")
    assert_equal([@parent.id, @child.id, @sibling.id].sort, card_ids("Children").sort)
  end

  should "say Parent, not siblings, for an only child" do
    only = as(@member) { create(:post, parent: as(@member) { create(:post) }) }
    draw(only)

    assert_css("h2.modstrip-title", text: "Parent")
    assert_no_css("h2.modstrip-title", text: "siblings")
  end

  should "draw both groups for a post that has a parent and children" do
    grandchild = as(@member) { create(:post, parent: @child) }
    draw(@child)

    assert_css("section.modfamily > section.modstrip", count: 2)
    assert_includes(card_ids("Children"), grandchild.id)
  end

  should "draw nothing for a post with no family" do
    draw(as(@member) { create(:post) })

    assert_no_css(".modfamily")
    assert_equal("", rendered_content.strip)
  end

  # A deleted child is a relative this member is not shown
  # (relatives_shown_to: no show_deleted_children), so no card names it, and
  # a parent whose only child is deleted has no children group at all.
  should "draw no card for a deleted child the viewer is not shown" do
    as(@member) { @sibling.update_columns(is_deleted: true) }
    draw(@child)
    refute_includes(card_ids("Parent"), @sibling.id)

    lone = as(@member) { create(:post) }
    as(@member) { create(:post, parent: lone).update_columns(is_deleted: true) }
    draw(lone)
    assert_no_css(".modfamily")
  end

  # A relative the viewer may not be drawn leaves the post alone in its
  # strip, and a strip of only the post on the page is not drawn: a banned
  # post is not drawable below Approver, so neither group survives here.
  should "draw no group whose only card is the post itself" do
    banned = as(@member) { create(:post, parent: @parent) }
    banned.update_columns(is_banned: true)

    draw(@parent, relatives: { parent: nil, siblings: [], children: [banned] })
    assert_no_css(".modfamily")

    draw(@child, relatives: { parent: banned, siblings: [@child], children: [] })
    assert_no_css(".modfamily")
  end

  # relatives_shown_to keeps a parent the strip may still not draw (safe
  # mode, a level or ban block). Its siblings are drawn under "Siblings":
  # a "Parent" title over a strip with no parent card names a post that
  # is not there.
  should "title a strip whose parent is not drawn Siblings" do
    banned = as(@member) { create(:post) }
    banned.update_columns(is_banned: true)

    draw(@child, relatives: { parent: banned, siblings: [@child, @sibling], children: [] })
    assert_css("h2.modstrip-title > a[href='/posts?tags=parent%3A#{banned.id}']", text: "Siblings")
    assert_no_css("h2.modstrip-title", text: "Parent")
    assert_equal([@child.id, @sibling.id].sort, card_ids("Siblings").sort)
  end

  # The caller's relatives are the ones drawn: the controller decided them
  # for the page, and a post it left out is never drawn here.
  should "draw only the relatives it is handed" do
    draw(@parent, relatives: { parent: nil, siblings: [], children: [@child] })

    assert_equal([@parent.id, @child.id].sort, card_ids("Children").sort)
  end
end
