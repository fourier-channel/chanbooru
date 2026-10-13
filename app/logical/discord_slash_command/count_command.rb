# frozen_string_literal: true

class DiscordSlashCommand
  class CountCommand < DiscordSlashCommand
    self.name = "count"
    self.description = "Do a tag search and return the number of results"
    self.options = [{
      name: "tags",
      description: "The tags to search",
      required: true,
      type: ApplicationCommandOptionType::String,
    }]

    def call
      tags = params[:tags]
      # Fork: counted as a signed-out visitor, with the implicit metatags --
      # a Discord channel is not a booru session, and an unfiltered count
      # confirmed hidden posts and names (jailed, flagged, gated).
      count = PostQuery.normalize(tags, current_user: User.anonymous).with_implicit_metatags.fast_count(timeout: 9_000, estimate_count: false, skip_cache: true)

      respond_with("`#{tags}`: #{count} posts")
    end
  end
end
