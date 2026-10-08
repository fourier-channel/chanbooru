# frozen_string_literal: true

# Which creators are HERE RIGHT NOW. A creator is active when a post of theirs
# was created inside Danbooru.config.creator_active_window -- whether they
# uploaded it themselves or fourier-sampling / fourier-tunnel attributed it to
# them by tag. Both roads end in the same two facts about a recent post: the
# tags it carries and who uploaded it. So this reads the posts of the last
# window once, and answers for every name asked in one pass; the page's lamps
# and the poll behind them call it with the artist tags on screen.
#
# "Directly to the booru" is matched on the uploader's NAME, two ways: the
# booru account's name as the tag itself, and the tunnel's minted form
# `41chan_<localpart>` -- the poster tag it gives every Matrix sender's posts,
# so a creator who uploads through the booru and posts through the tunnel is
# one creator to the lamp.
#
# FOR ONE VIEWER (2026-10-08). Only posts that exist for the viewer light a
# lamp: a post hidden from them (Post.hidden_from -- its creator's panel, a
# hidden creator prefix, gated from a signed-out visitor, deleted or jailed)
# is not "a post created recently" to them. Before this the lamps counted
# every post, so the front page -- the hero band, which is the signed-out
# visitor's draw (CLAUDE.md) -- announced the moment a creator posted
# something private, and the poll confirmed tag names that exist only on
# hidden posts, which autocomplete and the tag index withhold.
#
# Cost: one indexed range scan on posts.created_at (the window is minutes, so
# tens to a few hundred rows), one query for which of those are hidden from
# the viewer, and one lookup of their uploaders. No per-tag search, no
# tag_match, so a page with three artist tags costs the same as a page with
# one.
module CreatorActivity
  TUNNEL_PREFIX = "41chan_"
  # How many names one ask may carry. The cost above does not grow with the
  # count -- it is a set lookup per name -- so the cap only bounds the request
  # itself. 100 fits the landing carousel, whose rows can name fifty featured
  # creators and more besides; the post page asks about a handful.
  MAX_NAMES = 100

  def self.window
    Danbooru.config.creator_active_window
  end

  # @param names [Array<String>] artist tag names
  # @param viewer [User] whose lamps these are: only posts that exist for them count
  # @return [Array<String>] the subset that is active now, in the order given
  def self.active(names, viewer:)
    names = Array(names).map(&:to_s).reject(&:blank?).uniq
    return [] if names.empty?

    rows = Post.where("posts.created_at > ?", window.ago).pluck(:id, :tag_string, :uploader_id)
    hidden = Post.hidden_ids_among(rows.map(&:first), viewer)
    recent = rows.reject { |id, _, _| hidden.include?(id) }.map { |_, tag_string, uploader_id| [tag_string, uploader_id] }
    return [] if recent.empty?

    tagged = recent.flat_map { |tag_string, _| tag_string.to_s.split }.to_set
    uploaders = User.where(id: recent.map(&:last).uniq).pluck(:name).map(&:downcase).to_set

    names.select do |name|
      down = name.downcase
      tagged.include?(name) || uploaders.include?(down) || uploaders.include?(down.delete_prefix(TUNNEL_PREFIX))
    end
  end
end
