# frozen_string_literal: true

require "test_helper"

# The strip of post cards on Modulation's subject pages: the gallery's card in
# a grid of its own, never the gallery's window (no .modgal, no .modgal-grid,
# no is-off), and nothing at all when the viewer is drawn no posts.
class ModulationPostStripComponentTest < ViewComponent::TestCase
  def draw(relation, user: @member, **options, &block)
    CurrentUser.scoped(user) do
      surface = PostStripSurface.new(relation: relation, viewer: user, query: "pscomp")
      render_inline(ModulationPostStripComponent.new(surface: surface, **options), &block)
    end
  end

  setup do
    @member = create(:user)
    @posts = as(@member) { create_list(:post, 3, tag_string: "pscomp") }
  end

  should "draw the gallery's cards in a strip, without the gallery or its window" do
    draw(Post.where(id: @posts.map(&:id)).order(id: :desc), title: "Posts", href: "/posts?tags=pscomp")

    assert_css("section.modstrip > h2.mod-label.modstrip-title > a[href='/posts?tags=pscomp']", text: "Posts")
    assert_css(".modstrip-grid > a.modgal-card", count: 3)
    @posts.each { |post| assert_css("a.modgal-card[data-id='#{post.id}'][data-tags][data-tag-marks]") }
    assert_no_css(".modgal")
    assert_no_css(".modgal-grid")
    assert_no_css(".is-off")
    assert_no_css("[data-key]")
    assert_no_css("[data-tag-categories]")
  end

  should "draw a title without a link, and a footer" do
    draw(Post.where(id: @posts.first.id), title: "Posts") { |strip| strip.with_footer { "more" } }

    assert_css("h2.modstrip-title", text: "Posts")
    assert_no_css("h2.modstrip-title a")
    assert_css(".modstrip-footer", text: "more")
  end

  should "say its empty_text under its heading when the viewer is drawn no posts" do
    draw(Post.where(id: -1), title: "Posts", href: "/posts?tags=pscomp", empty_text: "No posts found.")

    assert_css("section.modstrip > h2.modstrip-title > a[href='/posts?tags=pscomp']", text: "Posts")
    assert_css("section.modstrip > p.modstrip-empty", text: "No posts found.")
    assert_no_css(".modstrip-grid")
  end

  should "keep its footer when the viewer is drawn no posts" do
    draw(Post.where(id: -1)) { |strip| strip.with_footer { "the way back" } }

    assert_css("section.modstrip > .modstrip-footer", text: "the way back")
    assert_no_css(".modstrip-grid")
    assert_no_css(".modstrip-empty")
  end

  should "draw no empty_text when it draws cards" do
    draw(Post.where(id: @posts.map(&:id)), empty_text: "No posts found.")

    assert_css(".modstrip-grid > a.modgal-card", count: 3)
    assert_no_css(".modstrip-empty")
  end

  should "draw nothing when the viewer is drawn no posts" do
    draw(Post.where(id: -1), title: "Posts")

    assert_no_css(".modstrip")
    assert_equal("", rendered_content.strip)
  end
end
