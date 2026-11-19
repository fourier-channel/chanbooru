# frozen_string_literal: true

# A post's family on Modulation's post page: its parent and siblings, and its
# children, as post strips under the viewer -- upstream's two relationship
# notices draw the same posts as a gallery (posts/partials/show/_parent_notice
# and _child_notice), and this page had only their words.
#
# The posts are the ones the controller already decided for the viewer
# (Post#relatives_shown_to, which the page's notices read too), so a card is
# never drawn for a relative the notices would not name. The strip surface
# then draws only what PostPreviewComponent.drawable? allows, as for any list.
# No counts: a strip shows the posts it draws and links to the full search.
#
# The section carries the post's id. The post view navigates client-side, so
# after a step these strips belong to a post that is no longer on screen;
# modulation_post_family.js hides the section whenever the address is not
# this post's. Server-rendered for the first post only, fail closed after.
class ModulationPostFamilyComponent < ApplicationComponent
  attr_reader :post, :viewer

  # @param post [Post] the post on the page
  # @param viewer [User] whom every decision is made for
  # @param relatives [Hash, nil] Post#relatives_shown_to(viewer)'s answer,
  #   as the controller built it for the page; nil asks for it here
  def initialize(post:, viewer:, relatives: nil)
    super
    @post = post
    @viewer = viewer
    @relatives = relatives
  end

  def render?
    groups.any?
  end

  # Each group the viewer is drawn a relative of: a title, the full search
  # it links to, and its strip surface. A strip whose only card is this post
  # is no family -- a signed-out viewer's child hidden by rating left a
  # "Children" strip holding the post they were already looking at.
  def groups
    @groups ||= [parent_group, children_group].compact.select { |group| group[:surface].posts.any? { it.id != post.id } }
  end

  private

  def relatives
    @relatives ||= post.relatives_shown_to(viewer)
  end

  # Upstream's parent notice draws [parent, *siblings]; the siblings include
  # this post, as they do there. The title names what the strip draws: a
  # parent relatives_shown_to keeps can still be one the strip does not draw
  # (safe mode, a level or ban block -- drawable? asks more), and its
  # siblings then stand under "Siblings", not a "Parent" with no card. The
  # link keeps the parent's id, which the parent notice already shows.
  def parent_group
    parent = relatives[:parent]
    return if parent.nil?

    surface = strip_surface([parent, *relatives[:siblings]], parent)
    drawn = surface.posts.map(&:id)
    others = drawn.any? { it != parent.id && it != post.id }
    title = if drawn.include?(parent.id)
      others ? "Parent and siblings" : "Parent"
    else
      "Siblings"
    end
    { title: title, href: posts_path(tags: "parent:#{parent.id}"), surface: surface }
  end

  # Upstream's child notice draws [post, *children], under the same condition
  # this page's child notice uses (PostSurface#notices).
  def children_group
    children = Array(relatives[:children])
    return unless post.has_visible_children?(viewer) && children.any?

    { title: "Children", href: posts_path(tags: "parent:#{post.id}"), surface: strip_surface([post, *children], post) }
  end

  # show_deleted: true, as upstream's notices ask; relatives_shown_to has
  # already left out the deleted posts this viewer is not shown.
  def strip_surface(posts, parent)
    PostStripSurface.new(relation: posts, viewer: viewer, query: "parent:#{parent.id}", show_deleted: true)
  end
end
