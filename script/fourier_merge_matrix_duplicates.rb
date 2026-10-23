# frozen_string_literal: true

# ONE PICTURE, ONE POST (operator, 2026-10-16: "No copies of objects, is a
# given. Losing visibility isn't acceptable either."). Some pictures exist as
# two posts: a Matrix post (source mxc://..., holding the RAW upload, posted
# before stripping existed) and a 4chan post whose file is the STRIPPED
# version of that upload. Today the tunnel's duplicate path never makes the
# second post: the Matrix image becomes an ALIAS (post_mxcs, source 'alias')
# of the post already on the booru. This applies that retroactively, one
# pair at a time: the 4chan post SURVIVES, the Matrix post is RETIRED.
#
#   bin/rails runner script/fourier_merge_matrix_duplicates.rb -- --as NAME --pair R:S [--pair ...]          dry run
#   bin/rails runner script/fourier_merge_matrix_duplicates.rb -- --as NAME --pairs-file PATH --apply        write
#
# NAME is the booru admin every write is made as. --pair R:S names the post
# to RETIRE (the Matrix one) and the post that SURVIVES; it can be given any
# number of times. --pairs-file PATH reads one "R:S" (or "R S") per line, "#"
# comment lines and blank lines ignored; PATH "-" reads stdin, for a
# container whose tree is read-only:
#
#   ssh <host> 'docker exec -i <container> bin/rails runner script/fourier_merge_matrix_duplicates.rb -- --as NAME --pairs-file - --apply' < pairs.txt
#
# EACH PAIR, in its own transaction, on --apply:
#   - every post_mxcs row of R is re-mapped to S as an 'alias', and both
#     posts' room_ids are recomputed (PostMxc.recompute_room_ids!). S stays
#     {0}: an alias does not make a post a Matrix post, its image is served
#     by the booru door, which follows the post;
#   - R's tags S lacks are added to S as NAME, through the post's own tag
#     edit (versions and counts move with it) -- never a creator's PRIVATE
#     tag, which lives in its FourierTagSource row and never in tag_string;
#   - R's recorded creator (FourierPostCreator) moves to S, so S's creator
#     decides S's visibility and is served its generation data; R's tag
#     sources merge into S's (one row per tag: bits OR-ed, approved beats
#     pending, public beats private, the earlier created_at kept, as a tag
#     move merges them); the generation record is checked to be filed under
#     S's md5, or re-filed there when it was filed under R's;
#   - favorites (Post#give_favorites_to_parent, through Post#delete!),
#     votes, comments, notes (Note#copy_to), pools and favorite groups (R's
#     id replaced in place, no duplicates), the creator's per-post rows
#     (allows and blocks, audience overrides and their groups, the gallery's
#     curated set), artist commentary, and R's own child posts move to S;
#   - R becomes S's child and is deleted (Post#delete!) with the reason
#     "merged into post #S: the same picture (Matrix duplicate)": an
#     ORDINARY deletion. It is not a jailing and is not reported to the
#     jail panel. No file is expunged or removed.
#
# REFUSED, by name, with the fix, and that pair writes nothing (the others
# still run): a post that does not exist; R with no post_mxcs row; S deleted,
# jailed or itself a Matrix post; R jailed or already deleted by something
# else; a different recorded creator on each, or an artist commentary on
# each (both named); a generation record that ties R's upload to a third
# md5; or anything the booru itself refuses. A pair this script already
# merged is reported as "already merged" and left alone, so running it again
# after --apply changes nothing. Exit 1 when any pair was refused.
require "optparse"

as_name = nil
apply = false
pairs = [] # [where, retired id, survivor id] in the order given
malformed = []
parse_pair = lambda do |where, text|
  match = text.strip.match(/\A#?(\d+)\s*(?::|\s)\s*#?(\d+)\z/)
  if match
    pairs << [where, match[1].to_i, match[2].to_i]
  else
    malformed << "#{where}: #{text.strip.inspect} is not R:S (the post to retire, \":\", then the post that survives)"
  end
end
parser = OptionParser.new do |opts|
  # A write is asked for by its whole name, never an abbreviation.
  opts.require_exact = true
  opts.on("--as NAME") { |name| as_name = name }
  opts.on("--pair R:S") { |arg| parse_pair.call("--pair #{arg}", arg) }
  opts.on("--pairs-file PATH") do |path|
    where = (path == "-") ? "stdin" : path
    text = (path == "-") ? $stdin.read : File.read(path)
    text.each_line.with_index(1) do |line, number|
      next if line.strip.empty? || line.strip.start_with?("#")

      parse_pair.call("#{where} line #{number}", line)
    end
  rescue SystemCallError => e
    malformed << "--pairs-file #{path}: #{e.message}"
  end
  opts.on("--apply") { apply = true }
end
usage = "--as <your booru admin name> --pair RETIRED:SURVIVOR [--pair ...] [--pairs-file PATH|-] [--apply], spelled out in full; " \
        "without --apply it is a dry run."
begin
  parser.parse!(ARGV.reject { |arg| arg == "--" })
rescue OptionParser::ParseError => e
  warn "FAIL: #{e.message}"
  warn "fix:  #{usage}"
  exit 2
end
if malformed.any? || pairs.empty?
  malformed.each { |why| warn "FAIL: #{why}" }
  warn "FAIL: no pair given" if pairs.empty? && malformed.empty?
  warn "fix:  #{usage}"
  exit 2
end

admin = User.find_by_name(as_name.to_s)
if admin.nil? || !admin.is_admin?
  warn "FAIL: #{as_name.inspect} is #{admin.nil? ? "no booru account" : "not an admin"}."
  warn "fix:  --as <your booru admin name>; the change is made as that account."
  exit 2
end

reason_for = ->(survivor_id) { "merged into post ##{survivor_id}: the same picture (Matrix duplicate)" }
refusal = Class.new(StandardError)
refused = []
merged = []
already = []
total = pairs.size
detail = ->(line) { puts "      #{line}" }
noun = ->(count, word) { "#{count} #{word.pluralize(count)}" }

pairs.each_with_index do |(where, retired_id, survivor_id), index|
  puts "[#{index + 1}/#{total}] pair ##{retired_id} -> ##{survivor_id} (#{where})"
  CreatorVisibility.forget!
  begin
    ActiveRecord::Base.transaction do
      CurrentUser.scoped(admin) do
        refuse = ->(why) { raise refusal, why }
        refuse.call("a post cannot be merged into itself. fix: name the Matrix post first and the post that survives second") if retired_id == survivor_id
        retired = Post.find_by(id: retired_id)
        survivor = Post.find_by(id: survivor_id)
        refuse.call("post ##{retired_id} does not exist (the post to retire). fix: check the pair's ids, RETIRED:SURVIVOR") if retired.nil?
        refuse.call("post ##{survivor_id} does not exist (the survivor). fix: check the pair's ids, RETIRED:SURVIVOR") if survivor.nil?

        reason = reason_for.call(survivor.id)
        if retired.is_deleted? && retired.parent_id == survivor.id && retired.flags.exists?(reason: reason)
          detail.call("already merged: ##{retired.id} is a deleted child of ##{survivor.id} with the reason \"#{reason}\"; nothing to do")
          already << where
          next
        end

        # THE REFUSALS, before any write.
        mxcs = PostMxc.where(post_id: retired.id).order(:mxc).pluck(:mxc, :source)
        if mxcs.empty?
          refuse.call("##{retired.id} has no mxc mapping (no post_mxcs row), so it holds no Matrix image to alias. " \
                      "fix: check the pair -- the Matrix post (source mxc://...) comes first, the survivor second")
        end
        banished = TagBanishment.post_tags
        if survivor.jailed? || survivor.tag_array.intersect?(banished)
          refuse.call("survivor ##{survivor.id} is jailed (or carries a banished tag): a jailed post cannot take another's place. " \
                      "fix: release it in sampling's jail panel first, or leave this pair out")
        end
        refuse.call("survivor ##{survivor.id} is deleted: a deleted post cannot take another's place. fix: undelete it first, or leave this pair out") if survivor.is_deleted?
        if survivor.source.to_s.start_with?("mxc://") || PostMxc.exists?(post_id: survivor.id, source: PostMxc::POST_SOURCE)
          refuse.call("survivor ##{survivor.id} is itself a Matrix post (source #{survivor.source}): the survivor must be the booru post, which stays visible beyond any room. " \
                      "fix: name the non-Matrix post as the survivor")
        end
        if retired.jailed? || retired.tag_array.intersect?(banished)
          refuse.call("##{retired.id} is jailed (or carries a banished tag): its tags would jail the survivor. fix: release it in sampling's jail panel first, or leave this pair out")
        end
        refuse.call("##{retired.id} is already deleted, not by this script. fix: undelete it first, then run this again") if retired.is_deleted?
        creators = FourierPostCreator.where(post_id: [retired.id, survivor.id]).pluck(:post_id, :mxid).to_h
        if creators[retired.id] && creators[survivor.id] && !FourierPostCreator.same_mxid?(creators[retired.id], creators[survivor.id])
          refuse.call("the two posts have different recorded creators: ##{retired.id} #{creators[retired.id]}, ##{survivor.id} #{creators[survivor.id]}. " \
                      "fix: settle which account made the picture (fourier_post_creators), then run this again")
        end
        commentaries = ArtistCommentary.where(post_id: [retired.id, survivor.id]).pluck(:post_id)
        if commentaries.size == 2
          refuse.call("both posts have an artist commentary (##{retired.id} and ##{survivor.id}), and a post has one. " \
                      "fix: merge the text into ##{survivor.id}'s commentary on the site, delete ##{retired.id}'s, then run this again")
        end
        record = FourierGenerationMetadata.find_by(md5: survivor.md5)
        raw_record = FourierGenerationMetadata.find_by(raw_md5: retired.md5)
        if raw_record && raw_record.md5 != survivor.md5 && raw_record.md5 != retired.md5
          refuse.call("the generation record says ##{retired.id}'s upload (raw md5 #{retired.md5}) was stripped to md5 #{raw_record.md5}, " \
                      "but ##{survivor.id}'s file is #{survivor.md5}: they are not the same picture by that record. fix: check the pair")
        end

        detail.call("##{retired.id}: #{retired.source}, md5 #{retired.md5}, rating #{retired.rating}; ##{survivor.id}: #{survivor.source}, md5 #{survivor.md5}, rating #{survivor.rating}")
        if record&.raw_md5 == retired.md5
          detail.call("identity: the generation record ties them -- raw upload #{retired.md5} stripped to #{survivor.md5}")
        else
          detail.call("identity: no generation record ties them; merged on the pair as given")
        end

        # 1. TAGS: the union, through the survivor's own tag edit, as NAME.
        private_tags = FourierTagSource.where(post_id: retired.id, public: false).pluck(:tag)
        # The tags the booru derives from a post's own file and source
        # (non-web_source on an mxc post, highres, ...) stay each post's own.
        derived = retired.tag_array & Post::AUTOMATIC_TAGS
        adding = retired.tag_array - survivor.tag_array - private_tags - derived
        if adding.any?
          survivor.add_tag(*adding)
          survivor.save!
          lost = adding - survivor.reload.tag_array
          refuse.call("the booru did not take #{lost.join(" ")} onto ##{survivor.id}. fix: add them by hand, or leave this pair out") if lost.any?
        end
        detail.call("tags: #{adding.any? ? adding.map { |tag| "+#{tag}" }.join(" ") : "nothing to add"}" \
                    "#{"; kept off tag_string (the creator's private tags): #{private_tags.join(" ")}" if private_tags.any?}" \
                    "#{"; left to each post (derived from its own file or source): #{derived.join(" ")}" if derived.any?}")

        # 2. THE CREATOR, so the survivor is the creator's to decide.
        creator = FourierPostCreator.find_by(post_id: retired.id)
        if creator.nil?
          detail.call("creator: none recorded on ##{retired.id}")
        elsif creators[survivor.id]
          detail.call("creator: #{creators[survivor.id]} already recorded on ##{survivor.id}")
        else
          creator.update!(post_id: survivor.id)
          detail.call("creator: #{creator.mxid} moves to ##{survivor.id}")
        end
        CreatorVisibility.forget!

        # 3. THE CREATOR'S PER-POST ROWS: allows and blocks, audience overrides
        #    and their groups, the gallery's band rows -- before anything
        #    below asks who may see the survivor (a favorite group's owner
        #    the creator let in). A row the survivor already has for the
        #    same key stays the survivor's.
        {
          CreatorUserRule => %i[creator_gallery_id user_id],
          CreatorPostAudience => %i[creator_gallery_id],
          CreatorAudienceGroup => %i[creator_group_id],
          CreatorGalleryPost => %i[creator_gallery_id band],
        }.each do |model, key|
          moved = kept = 0
          model.where(post_id: retired.id).order(:id).each do |row|
            if model.exists?(row.slice(*key).merge(post_id: survivor.id))
              kept += 1
            else
              row.update!(post_id: survivor.id)
              moved += 1
            end
          end
          detail.call("#{model.model_name.human.downcase.pluralize}: #{moved} moved#{", #{kept} kept (##{survivor.id} has its own)" if kept.positive?}")
        end
        CreatorVisibility.forget!

        # 4. TAG SOURCES, merged as a tag move merges them (FourierTagSource.move_tag!).
        rows = FourierTagSource.where(post_id: retired.id).pluck(:tag, :source, :status, :public, :added_by, :created_at)
        if rows.any?
          FourierTagSource.upsert_all(
            rows.map { |tag, source, status, pub, added_by, created_at| { post_id: survivor.id, tag: tag, source: source, status: status, public: pub, added_by: added_by, created_at: created_at } },
            unique_by: %i[post_id tag],
            on_duplicate: Arel.sql(<<~SQL.squish),
              source = fourier_tag_sources.source | excluded.source,
              status = LEAST(fourier_tag_sources.status, excluded.status),
              public = fourier_tag_sources.public OR excluded.public,
              created_at = LEAST(fourier_tag_sources.created_at, excluded.created_at)
            SQL
          )
          FourierTagSource.where(post_id: retired.id).delete_all
        end
        detail.call("tag sources: #{noun.call(rows.size, "row")} merged into ##{survivor.id}")

        # 5. THE GENERATION RECORD, keyed by md5: served on the survivor once it
        #    is filed under the survivor's md5 and its creator is the survivor's.
        if record
          detail.call("generation record: filed under ##{survivor.id}'s md5, owner #{record.poster || "none"}")
        elsif (own = FourierGenerationMetadata.find_by(md5: retired.md5))
          own.update!(md5: survivor.md5, raw_md5: own.raw_md5 || retired.md5)
          detail.call("generation record: re-filed from ##{retired.id}'s md5 to ##{survivor.id}'s (raw md5 #{own.raw_md5}), owner #{own.poster || "none"}")
        else
          detail.call("generation record: none")
        end

        # 6. THE MATRIX IMAGE, an alias of the survivor; the survivor stays {0}.
        PostMxc.where(post_id: retired.id).update_all(post_id: survivor.id, source: PostMxc::ALIAS, updated_at: Time.zone.now)
        PostMxc.recompute_room_ids!([retired.id, survivor.id])
        mxcs.each { |mxc, source| detail.call("mxc #{mxc}: alias of ##{survivor.id} (was ##{retired.id}'s #{source})") }
        rooms = Post.where(id: survivor.id).pick(:room_ids)
        unless rooms == [MatrixViewerRooms::NOT_MATRIX]
          refuse.call("##{survivor.id}'s room set would be #{rooms.inspect}, not {0}: it would become a Matrix post. fix: report this; nothing was written")
        end

        # 7. LISTS THAT NAME THE POST: pools and favorite groups, in place.
        [Pool, FavoriteGroup].each do |model|
          lists = model.where("? = ANY(post_ids)", retired.id).order(:id).to_a
          lists.each do |list|
            list.update!(post_ids: list.post_ids.map { |id| (id == retired.id) ? survivor.id : id }.uniq)
          end
          detail.call("#{model.model_name.human.downcase.pluralize}: #{lists.any? ? lists.map { |list| "##{list.id}" }.join(", ") : "none"}")
        end

        # 8. COMMENTS, then the survivor's comment dates from what it now has.
        comments = Comment.where(post_id: retired.id).update_all(post_id: survivor.id)
        if comments.positive?
          live = Comment.where(post_id: survivor.id, is_deleted: false)
          survivor.update_columns(last_commented_at: live.maximum(:created_at), last_comment_bumped_at: live.where(do_not_bump_post: false).maximum(:created_at))
        end
        detail.call("comments: #{comments}")

        # 9. NOTES, copied by upstream's Note#copy_to; the originals stay on the
        #    deleted post as its history.
        notes = Note.active.where(post_id: retired.id).order(:id).to_a
        notes.each do |note|
          refuse.call("note ##{note.id} could not be copied to ##{survivor.id}. fix: copy it by hand, or leave this pair out") unless note.copy_to(survivor)
        end
        detail.call("notes: #{notes.size}")

        # 10. ARTIST COMMENTARY (one per post; both was refused above).
        if commentaries == [retired.id]
          ArtistCommentary.where(post_id: retired.id).update_all(post_id: survivor.id)
          detail.call("artist commentary: moves to ##{survivor.id}")
        end

        # 11. THE RETIRED POST'S OWN CHILDREN.
        children = Post.where(parent_id: retired.id).order(:id).to_a
        children.each { |child| child.update!(parent_id: survivor.id) }
        detail.call("child posts: #{children.any? ? children.map { |child| "##{child.id}" }.join(", ") : "none"}")

        # 12. RETIRE IT: the survivor's child, deleted with the reason -- and
        #     its favorites go to the survivor (upstream's mechanism).
        favorites = Favorite.where(post_id: retired.id).count
        retired.reload.update!(parent_id: survivor.id)
        retired.delete!(reason, move_favorites: true, user: admin)
        detail.call("favorites: #{favorites} (moved to ##{survivor.id}; one already there stays one)")

        # 13. VOTES still on it, once the favorites' own upvotes have moved.
        votes = PostVote.active.where(post_id: retired.id).order(:id).to_a
        kept = votes.count { |vote| PostVote.active.exists?(post_id: survivor.id, user_id: vote.user_id) }
        votes.each do |vote|
          next if PostVote.active.exists?(post_id: survivor.id, user_id: vote.user_id)

          PostVote.create!(post: survivor, user: vote.user, score: vote.score)
          vote.soft_delete!(updater: vote.user)
        end
        detail.call("votes: #{votes.size - kept} moved#{", #{kept} kept on ##{retired.id} (the voter already voted on ##{survivor.id})" if kept.positive?}")
        detail.call("##{retired.id}: deleted, child of ##{survivor.id}, reason \"#{reason}\" -- an ordinary deletion, not a jailing; its file is kept")

        merged << where
        raise ActiveRecord::Rollback unless apply
      end
    end
  rescue refusal, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, ActiveRecord::StatementInvalid => e
    why = e.is_a?(refusal) ? e.message : "the booru refused a write: #{e.message}. fix: settle what it names, then run this again"
    detail.call("REFUSED #{why}")
    refused << "#{where}: #{why}"
  end
  CreatorVisibility.forget!
end

puts "pairs: #{total}; #{apply ? "merged" : "would merge"}: #{merged.size}; already merged: #{already.size}; refused: #{refused.size}."
if refused.any?
  puts "REFUSED -- each of these pairs wrote nothing:"
  refused.each { |line| puts "  #{line}" }
  warn "fix:  settle each REFUSED pair as it says, then run this again; the merged pairs are done and will report \"already merged\"."
  exit 1
elsif merged.empty?
  puts "nothing to write: every pair is already merged."
elsif apply
  puts "done: #{noun.call(merged.size, "pair")} merged as #{admin.name}."
else
  puts "DRY RUN -- nothing written. Read the moves above, then run again with --apply."
end
