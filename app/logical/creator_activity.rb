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
# Cost: one indexed range scan on posts.created_at (the window is minutes, so
# tens to a few hundred rows) and one lookup of their uploaders. No per-tag
# search, no tag_match, so a page with three artist tags costs the same as a
# page with one.
module CreatorActivity
  TUNNEL_PREFIX = "41chan_"

  def self.window
    Danbooru.config.creator_active_window
  end

  # @param names [Array<String>] artist tag names
  # @return [Array<String>] the subset that is active now, in the order given
  def self.active(names)
    names = Array(names).map(&:to_s).reject(&:blank?).uniq
    return [] if names.empty?

    recent = Post.where("posts.created_at > ?", window.ago).pluck(:tag_string, :uploader_id)
    return [] if recent.empty?

    tagged = recent.flat_map { |tag_string, _| tag_string.to_s.split }.to_set
    uploaders = User.where(id: recent.map(&:last).uniq).pluck(:name).map(&:downcase).to_set

    names.select do |name|
      down = name.downcase
      tagged.include?(name) || uploaders.include?(down) || uploaders.include?(down.delete_prefix(TUNNEL_PREFIX))
    end
  end
end
