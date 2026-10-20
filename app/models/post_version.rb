# frozen_string_literal: true

class PostVersion < ApplicationRecord
  # The maximum number of tags to display in a tag edit. If an edit has more than this many tags, then they will be
  # collapsed instead of showing the full list on the post versions page.
  MAX_DISPLAY_TAGS = 300

  class RevertError < StandardError; end

  # Fork: a history search the fork does not take (refuse_tag_string_patterns!);
  # ApplicationController answers 422 with the message, which says what to
  # search by instead.
  class SearchRefused < StandardError; end
  extend Memoist

  belongs_to :post
  belongs_to_updater counter_cache: "post_update_count"

  def self.enabled?
    Rails.env.test? || Danbooru.config.aws_sqs_archives_url.present?
  end

  def self.database_url
    ENV["ARCHIVE_DATABASE_URL"] || ENV["DATABASE_URL"]
  end

  # Not under test: there DATABASE_URL is the dev container's own database,
  # and the versions must come from the test database (each worker's), inside
  # the test's transaction (ArchiveConnectionsTest).
  establish_connection database_url if enabled? && !Rails.env.test?

  module SearchMethods
    def changed_tags_include(tag)
      where_array_includes_all(:added_tags, [tag]).or(where_array_includes_all(:removed_tags, [tag]))
    end

    def changed_tags_include_all(tags)
      tags.reduce(all) do |relation, tag|
        relation.changed_tags_include(tag)
      end
    end

    def changed_tags_include_any(tags)
      where_array_includes_any(:added_tags, tags).or(where_array_includes_any(:removed_tags, tags))
    end

    # Fork: a match on ONE tag of the snapshot, as the search form says
    # ("Single tag only"), never on the space-joined string, where a pattern
    # could span two tags and no check of one private name could judge it
    # (private_history_ids_hidden_from). A match on one tag implies the
    # ILIKE on the whole string, which keeps the per-tag test to the rows
    # that pass it.
    def tag_matches(string)
      pattern = tag_pattern(string)
      return all if pattern.nil?

      where_ilike(:tags, "*#{pattern}*")
        .where("EXISTS (SELECT 1 FROM unnest(string_to_array(#{qualified_column_for(:tags)}, ' ')) AS name WHERE name ILIKE ?)", pattern.to_escaped_for_sql_like)
    end

    # What tag_matches looks for in one tag: the first word of `string`, as
    # "*word*" when it has no "*" of its own; nil when there is no word.
    def tag_pattern(string)
      tag = string.to_s[/\S+/]
      return nil if tag.nil?

      tag.include?("*") ? tag : "*#{tag}*"
    end

    def search(params, current_user)
      refuse_tag_string_patterns!(params)
      q = matching(params, current_user)

      # Fork: a search over tags answers as though it ran over the rows this
      # viewer is shown -- see private_history_ids_hidden_from.
      if searches_tags?(params)
        hidden = private_history_ids_hidden_from(q, params, current_user, CurrentUser.request)
        q = q.where.not(id: hidden) if hidden.present?
        # A tag search naming a quarantined name hidden from the searcher
        # (TagQuarantine) matches nothing, as a name never used does.
        q = q.none if searched_tag_names(params).intersect?(TagQuarantine.hidden_names_for(current_user))
      end

      q.apply_default_order(params).redacting_private_tags_for(current_user, CurrentUser.request)
    end

    # The search's own conditions, upstream's, with no fork guard: search
    # runs them over the table, and private_history_ids_hidden_from over the
    # rows as a viewer is shown them.
    def matching(params, current_user)
      q = search_attributes(params, %i[id updated_at updater_id post_id tags added_tags removed_tags rating rating_changed parent_id parent_changed source source_changed version], current_user: current_user)

      if params[:changed_tags]
        q = q.changed_tags_include_all(params[:changed_tags].scan(/[^[:space:]]+/))
      end

      if params[:all_changed_tags]
        q = q.changed_tags_include_all(params[:all_changed_tags].scan(/[^[:space:]]+/))
      end

      if params[:any_changed_tags]
        q = q.changed_tags_include_any(params[:any_changed_tags].scan(/[^[:space:]]+/))
      end

      if params[:tag_matches]
        q = q.tag_matches(params[:tag_matches])
      end

      if params[:updater_name].present?
        q = q.where(updater_id: User.name_to_id(params[:updater_name]))
      end

      if params[:is_new].to_s.truthy?
        q = q.where(version: 1)
      elsif params[:is_new].to_s.falsy?
        q = q.where("version != 1")
      end

      q
    end

    TAG_SEARCH_PARAMS = %w[changed_tags all_changed_tags any_changed_tags tag_matches].freeze

    # Fork: the tag-string keys a history search does not take, for anyone.
    # A pattern over the WHOLE tag string can match across two tags, so no
    # check of one private name can judge it; and a whole string ruled out
    # (tags_not_eq) matches a row exactly where a withheld name makes it
    # differ, which the rows as shown cannot say. Each answers 422 with what
    # to search by instead (SearchRefused).
    TAG_STRING_PATTERNS = %w[tags_like tags_ilike tags_not_like tags_not_ilike tags_regex tags_not_regex tags_matches tags_not_eq].freeze

    def refuse_tag_string_patterns!(params)
      refused = params.to_h.select { |key, value| key.to_s.in?(TAG_STRING_PATTERNS) && value.present? }.keys
      return if refused.empty?

      raise SearchRefused, "search[#{refused.join("], search[")}] is not offered on post history: it matches the whole tag string, not one tag. " \
                           "Search by tag with changed_tags, any_changed_tags or tag_matches (one tag, * allowed), " \
                           "or with any_added_tag_matches_regex or any_removed_tag_matches_regex."
    end

    def searched_tag_names(params)
      params.to_h.select { |key, _| key.to_s.in?(TAG_SEARCH_PARAMS) || key.to_s.match?(/\A(tags|added_tags|removed_tags)(_|\z)/) }
            .values.flat_map { |value| Array.wrap(value).flat_map { |v| v.to_s.downcase.scan(/[^[:space:]*,]+/) } }.uniq
    end

    # Every name a tag search could find a private creator tag under: each
    # name it spells (searched_tag_names; a leading "-", a removed tag, names
    # the same tag), each private, alias or rename name one of its per-tag
    # patterns matches (tag_matches, the any_*_tag_matches_regex keys:
    # names_matching), and every name those were moved from or to
    # (FourierPrivateTagLineage.linked_moves) -- a private row's earlier
    # names among them.
    def private_names_searched(params)
      spelled = searched_tag_names(params).map { |name| name.delete_prefix("-") }
      matched = params.to_h.flat_map do |key, value|
        case key.to_s
        when "tag_matches" then names_matching("ILIKE", tag_pattern(value)&.to_escaped_for_sql_like)
        when /\Aany_(added|removed)_tag_matches_regex\z/ then names_matching("~", value.presence && "(?e)#{value}")
        else []
        end
      end
      seeds = (spelled | matched).compact_blank
      seeds.empty? ? [] : FourierPrivateTagLineage.linked_moves(seeds).flat_map { |from, to, _| [from, to] } | seeds
    end

    # Every private creator tag name, and every alias or rename name in each
    # spelling TagMover moves (as it is, *_(cosplay), *_(style):
    # FourierPrivateTagLineage.move_pairs), that `operator` -- ILIKE or ~,
    # never a caller's string -- accepts with `value`.
    def names_matching(operator, value)
      return [] if value.blank?

      moved = <<~SQL.squish
        SELECT DISTINCT spelled FROM (
          SELECT antecedent_name AS name FROM tag_aliases UNION SELECT consequent_name FROM tag_aliases
          UNION SELECT unnest(tags) FROM bulk_update_requests WHERE status NOT IN ('pending', 'rejected')
        ) moved CROSS JOIN LATERAL (VALUES (name), (name || '_(cosplay)'), (name || '_(style)')) AS spellings(spelled)
        WHERE spelled #{operator} ?
      SQL
      FourierTagSource.where(public: false).where("tag #{operator} ?", value).distinct.pluck(:tag) |
        FourierTagSource.connection.select_values(FourierTagSource.sanitize_sql_array([moved, value]))
    end

    def searches_tags?(params)
      params.to_h.any? do |key, value|
        value.present? && (key.to_s.in?(TAG_SEARCH_PARAMS) || key.to_s.match?(/\A((tags|added_tags|removed_tags)(_|\z)|any_(added|removed)_tag_matches_regex\z|(added|removed)_tag_count\z)/))
      end
    end
  end

  # PRIVATE CREATOR TAGS IN HISTORY (fork, F-B10 of the 2026-10-01 leak audit).
  # A private creator tag is shown to the post's creator and nobody else --
  # no admin or moderator bypass (FourierCreatorPrivacy, operator ruling
  # 2026-09-29). Posts from 2026-08-04..06 carried such tags in tag_string,
  # because the posting bot leaked them there, and FourierPrivateTagCleanup
  # took them out with an ORDINARY edit, so the versions before that edit
  # still hold them -- and /post_versions is upstream's, open to anyone.
  # These methods withhold them there: redact_private_tags takes them out of
  # the rows a page shows, and a tag search answers as though it ran over
  # those rows (private_history_ids_hidden_from).
  #
  # ONLY AN ENDED LEAK IS WITHHELD (BUR review 2026-10-19). An occurrence of
  # a private name is withheld where its run (FourierPrivateTagLineage.runs)
  # is the posting bot's or nobody's on record AND has ended. A person's own
  # add of a name the prompt also holds is that person's public choice and
  # shows in full, as the tag itself does (operator ruling 2026-10-19), and
  # so does a label the bot publishes on purpose. A run the post still
  # carries is on its public list, which every other page shows, and is
  # shown here too. Judged by the run, not the version's updater: an alias
  # moving a leaked tag is the system account's edit carrying the bot's
  # leak. A name the private row was moved from (an alias or rename,
  # FourierPrivateTagLineage.earlier_names) is the same prompt term under its
  # old name where its run began before that move, and is judged the same
  # way (private_names_withheld).
  concerning :PrivateCreatorTagMethods do
    class_methods do
      # The ids of the versions `found` (a history search with its conditions
      # applied: matching) finds only through a private creator tag withheld
      # from `user` (private_names_withheld): the rows it matches as stored
      # and no longer matches as shown, judged by running the same search
      # over those rows as shown (shown_rows). The search then answers as
      # though it ran over the rows this viewer is shown -- version by
      # version. Dropping every version of such a post instead made the
      # guard itself confirm a guess: a search for a tag the post visibly
      # changed and a guessed name lost the post exactly when the guess was
      # a withheld prompt term, and a person's own later add of it vanished.
      #
      # Only the posts with a private row under a name the search could find
      # it by (private_names_searched), and a version holding that name, are
      # walked: a search naming no private tag costs its names' alias and
      # rename lookups and one indexed lookup of the private rows under
      # them. Scanning every private row on every history search passed
      # production's 12 s statement timeout on 2026-10-13 (sampling's
      # removed_tags_include_any=troll_jail answered 500). A broad pattern
      # (tag_matches=*a*) still reaches most private rows.
      def private_history_ids_hidden_from(found, params, user, request)
        names = private_names_searched(params)
        return [] if names.empty?

        posts = FourierTagSource.where(public: false, tag: names).distinct.pluck(:post_id)
        posts = unscoped.where(post_id: posts).holding_any(names).distinct.pluck(:post_id) if posts.any?
        return [] if posts.empty?

        readable = FourierCreatorPrivacy.readable_post_ids(Post.where(id: posts).to_a, user, request)
        private_tags = FourierTagSource.where(post_id: posts.reject { |id| readable.include?(id) }, public: false).pluck(:post_id, :tag)
                                       .group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
        withheld = private_names_withheld(private_tags).values.reduce({}, :merge)
        stored = withheld.empty? ? [] : found.where(id: withheld.keys).pluck(:id)
        return [] if stored.empty?

        stored - unscoped.from(shown_rows(stored, withheld, user)).matching(params, user).pluck(:id)
      end

      # SQL for the rows `ids` as `user` is shown them (redact_private_tags:
      # `withheld`'s names out, and the quarantined names hidden from the
      # viewer), under the table's own name, for matching to run over.
      def shown_rows(ids, withheld, user)
        quarantined = TagQuarantine.hidden_names_for(user).to_a
        values = unscoped.where(id: ids).map do |version|
          version.withhold_tags!(withheld.fetch(version.id, []) | quarantined)
          sanitize_sql_array(["(?::integer, ?::text, string_to_array(?, ' '), string_to_array(?, ' '))",
                              version.id, version.tags, Array(version.added_tags).join(" "), Array(version.removed_tags).join(" ")])
        end
        columns = (column_names - %w[tags added_tags removed_tags]).map { |column| "post_versions.#{column}" }
        "(SELECT #{columns.join(", ")}, shown.tags, shown.added_tags, shown.removed_tags FROM post_versions " \
          "JOIN (VALUES #{values.join(", ")}) AS shown(id, tags, added_tags, removed_tags) ON shown.id = post_versions.id) post_versions"
      end

      # Versions that hold one of `names` anywhere a row shows a tag: the
      # snapshot, added_tags or removed_tags. Not added_tags alone: the
      # archive merges an account's edits within the hour into one version
      # and reckons its added_tags against its own earlier snapshot, so a
      # merged version can hold a tag no added_tags names.
      def holding_any(names)
        where("string_to_array(#{qualified_column_for(:tags)}, ' ') && ARRAY[?]::text[]", names)
          .or(where_array_includes_any(:added_tags, names)).or(where_array_includes_any(:removed_tags, names))
      end

      # post_id => { version id => the names withheld from that version },
      # for each post in `private_tags` (post_id => its private creator tag
      # names); a version or a post with nothing withheld is left out.
      #
      # Judged per OCCURRENCE, by its run (FourierPrivateTagLineage.runs): a
      # name is withheld from a version where an occurrence of it there -- in
      # the snapshot, added, or removed -- belongs to a run that
      #   - is not PUBLIC: a person's add, or a label the bot publishes on
      #     purpose, shows in full;
      #   - has ended: a run the post still carries is on its public list,
      #     which every other page shows (operator ruling 2026-10-19), and
      #     withholding it here alone told a stranger it was a prompt term;
      #   - and is the private row's: it went by one of the post's private
      #     names, or it ended under a name the private row was moved from
      #     (FourierPrivateTagLineage.earlier_names) and began before that
      #     move. One begun after it is that name used again -- a rename
      #     leaves no alias -- and the post's own public tag.
      # An occurrence in no snapshot (a merged version's added or removed
      # tags) belongs to no run, and counts as an ended UNKNOWN one begun in
      # that version.
      #
      # Walked from each post's whole history, read only for the posts with
      # a version holding a judged name (holding_any), with the alias and
      # rename lookups and the updaters looked up once for all of them.
      def private_names_withheld(private_tags)
        return {} if private_tags.empty?

        pairs = FourierPrivateTagLineage.linked_moves(private_tags.values.flatten.uniq)
        earlier = private_tags.transform_values { |names| FourierPrivateTagLineage.earlier_names(names.uniq, pairs) }
        held = unscoped.where(post_id: private_tags.keys).holding_any((private_tags.values.flatten | earlier.values.flat_map(&:keys)).uniq).distinct.pluck(:post_id)
        return {} if held.empty?

        carried = Post.where(id: held).pluck(:id, :tag_string).to_h { |id, tags| [id, tags.to_s.split] }
        histories = unscoped.where(post_id: held).order(:post_id, :version, :id).group_by(&:post_id)
        updaters = User.where(id: histories.values.flatten.map(&:updater_id).uniq).pluck(:id, :name).to_h
        by_post = histories.to_h do |post_id, history|
          names = private_tags[post_id]
          withheld = lambda do |run|
            last = run.last
            next false if run.kind == FourierPrivateTagLineage::PUBLIC
            next false if last.ended.nil? && carried.fetch(post_id, []).include?(last.names.last)

            moved_at = earlier[post_id][last.names.last]
            (run.names | last.names).intersect?(names) || (moved_at.present? && run.began.updated_at < moved_at)
          end
          runs = FourierPrivateTagLineage.runs(history, pairs: pairs, updaters: updaters)
          by_version = runs.zip([{}] + runs.map(&:last)).to_h do |(version, after), before|
            removed = Array(version.removed_tags)
            judged = (version.tag_array | Array(version.added_tags) | removed) & (names | earlier[post_id].keys)
            [version.id, judged.select do |name|
              found = [(after[name] if version.tag_array.include?(name)), (before[name] if removed.include?(name))].compact
              found = [FourierPrivateTagLineage::Run.new(FourierPrivateTagLineage::UNKNOWN, version, name).tap { |run| run.ended = version }] if found.empty?
              found.any?(&withheld)
            end]
          end
          [post_id, by_version.select { |_, withheld_names| withheld_names.any? }]
        end
        by_post.select { |_, by_version| by_version.any? }
      end

      # A relation whose rows have redact_private_tags applied when it loads.
      # On the relation rather than in the controller, because the API's
      # respond_with re-derives the relation (it adds the ?only= includes)
      # and loads it afresh -- a redaction applied to the controller's copy
      # never reached the JSON.
      def redacting_private_tags_for(user, request)
        extending(Module.new do
          define_method(:load) do |&block|
            fresh = !loaded?
            super(&block)
            PostVersion.redact_private_tags(@records, user, request) if fresh
            self
          end
        end)
      end

      # Take out of the loaded rows each private creator tag occurrence that
      # private_names_withheld withholds, unless the viewer is that post's
      # creator. In memory only: the rows are marked readonly and never saved.
      #
      # And every quarantined name hidden from the viewer (TagQuarantine) out
      # of every row: a visible post's history can hold a flagged name it
      # once carried.
      def redact_private_tags(versions, user, request)
        versions = versions.to_a
        quarantined = TagQuarantine.hidden_names_for(user)
        if quarantined.any?
          versions.each do |version|
            named = version.tags.to_s.split | Array(version.added_tags) | Array(version.removed_tags)
            version.withhold_tags!(quarantined) if named.intersect?(quarantined)
          end
        end
        private_tags = FourierTagSource.where(post_id: versions.map(&:post_id).uniq, public: false).pluck(:post_id, :tag)
                                       .group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
        return versions if private_tags.empty?

        readable = FourierCreatorPrivacy.readable_post_ids(Post.where(id: private_tags.keys).to_a, user, request)
        withheld = private_names_withheld(private_tags.except(*readable)).values.reduce({}, :merge)
        versions.each do |version|
          names = withheld[version.id]
          version.withhold_tags!(names) if names.present?
        end
      end
    end

    def withhold_tags!(names)
      self.tags = (tags.to_s.split - names).join(" ")
      self.added_tags = Array(added_tags) - names
      self.removed_tags = Array(removed_tags) - names
      flush_cache
      readonly!
    end
  end

  module ArchiveServiceMethods
    extend ActiveSupport::Concern

    class_methods do
      def sqs_service
        SqsService.new(Danbooru.config.aws_sqs_archives_url)
      end

      def queue(post)
        # queue updates to sqs so that if archives goes down for whatever reason it won't
        # block post updates
        raise NotImplementedError, "Archive service is not configured" if !enabled?

        json = {
          "post_id" => post.id,
          "rating" => post.rating,
          "parent_id" => post.parent_id,
          "source" => post.source,
          "updater_id" => CurrentUser.id,
          "updated_at" => post.updated_at.try(:iso8601),
          "created_at" => post.created_at.try(:iso8601),
          "tags" => post.tag_string,
        }
        msg = "add post version\n#{json.to_json}"
        sqs_service.send_message(msg, message_group_id: "post:#{post.id}")
      end
    end
  end

  extend SearchMethods
  include ArchiveServiceMethods

  def tag_array
    tags.split
  end

  def reload
    flush_cache
    super
  end

  def previous
    @previous ||= begin
      # HACK: if all the post versions for this post have already been preloaded,
      # we can use that to avoid a SQL query.
      if association(:post).loaded? && post&.association(:versions)&.loaded?
        [post.versions.sort_by(&:version).reverse.find { |v| v.version < version }]
      else
        PostVersion.where("post_id = ? and version < ?", post_id, version).order(version: :desc).limit(1).to_a
      end
    end
    @previous.first
  end

  def current
    @current ||= PostVersion.where(post_id: post_id).order(version: :desc).limit(1).to_a
    @current.first
  end

  def visible?
    post&.visible?
  end

  def self.status_fields
    {
      tags: "Tags",
      rating: "Rating",
      parent_id: "Parent",
      source: "Source",
    }
  end

  def pretty_rating
    Post::RATINGS[rating] # XXX some old post versions have nil ratings.
  end

  def changes
    delta = {
      added_tags: added_tags,
      removed_tags: removed_tags,
      obsolete_removed_tags: [],
      obsolete_added_tags: [],
      unchanged_tags: [],
    }

    return delta if post.nil?

    latest_tags = post.tag_array
    latest_tags << "rating:#{post.rating}" if post.rating.present?
    latest_tags << "parent:#{post.parent_id}" if post.parent_id.present?
    latest_tags << "source:#{post.source}" if post.source.present?

    if parent_changed
      if parent_id.present?
        delta[:added_tags] << "parent:#{parent_id}"
      end

      if previous
        delta[:removed_tags] << "parent:#{previous.parent_id}"
      end
    end

    if rating_changed
      delta[:added_tags] << "rating:#{rating}"

      if previous
        delta[:removed_tags] << "rating:#{previous.rating}"
      end
    end

    if source_changed
      if source.present?
        delta[:added_tags] << "source:#{source}"
      end

      if previous
        delta[:removed_tags] << "source:#{previous.source}"
      end
    end

    delta[:obsolete_added_tags] = delta[:added_tags] - latest_tags
    delta[:obsolete_removed_tags] = delta[:removed_tags] & latest_tags

    if previous
      delta[:unchanged_tags] = tag_array & previous.tag_array
    else
      delta[:unchanged_tags] = []
    end

    delta
  end

  def added_tags_with_fields
    changes[:added_tags].join(" ")
  end

  def removed_tags_with_fields
    changes[:removed_tags].join(" ")
  end

  def obsolete_added_tags
    changes[:obsolete_added_tags].join(" ")
  end

  def obsolete_removed_tags
    changes[:obsolete_removed_tags].join(" ")
  end

  def unchanged_tags
    changes[:unchanged_tags].join(" ")
  end

  def truncated_source
    source.gsub(%r{^http://}, "").sub(%r{/.+}, "")
  end

  def undo!
    raise RevertError unless post.visible?

    added = changes[:added_tags] - changes[:obsolete_added_tags]
    removed = changes[:removed_tags] - changes[:obsolete_removed_tags]

    # Fork: never publishes a creator's private tag again (BUR review
    # 2026-10-19, M2): undoing FourierPrivateTagCleanup's edit would put back
    # what the posting bot leaked, which history withholds from the very
    # person undoing. The tags it removed are read from the version before.
    FourierPrivateTagLineage.refuse_restore!(post, removed, source: previous)

    added.each do |tag|
      case tag
      when /^source:/
        post.source = ""
      when /^parent:/
        post.parent_id = nil
      else
        escaped_tag = Regexp.escape(tag)
        post.tag_string = post.tag_string.sub(/(?:\A| )#{escaped_tag}(?:\Z| )/, " ").strip
      end
    end
    removed.each do |tag|
      if tag =~ /^source:(.+)$/
        post.source = $1
      else
        post.tag_string = "#{post.tag_string} #{tag}".strip
      end
    end

    post.save!
  end

  def self.available_includes
    [:updater, :post]
  end

  memoize :previous, :tag_array, :changes, :added_tags_with_fields, :removed_tags_with_fields, :obsolete_removed_tags, :obsolete_added_tags, :unchanged_tags
end
