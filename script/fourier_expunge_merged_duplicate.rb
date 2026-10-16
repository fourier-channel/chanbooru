# frozen_string_literal: true

# EXPUNGE ONE RETIRED MATRIX DUPLICATE (operator, 2026-10-16: "expunge all
# seven retired Matrix posts", run by the operator one post at a time, each
# block with the proof the files are gone).
#
# script/fourier_merge_matrix_duplicates.rb retired each Matrix post into the
# 4chan post holding the same picture and KEPT its files. This removes what is
# left of one retired post, for good:
#
#   - every object of its media asset that EXISTS in R2 (its thumbnail set,
#     variants/<raw md5>/...; the original media/<raw md5>.<ext> is normally
#     already absent -- canon moved the raw upload aside), DELETED, not
#     trashed: Post#expunge! trashes, and a trashed object is moved to
#     /trash/<path> in the same bucket, which keeps it;
#   - canon's moved-aside raw upload, superseded/local_content/<xx>/<yy>/<rest
#     of the mxc media id>, through the same rclone remote;
#   - the post record, as Post#expunge! removes it (the permanent-delete mod
#     log entry, children and parent, tag counts, pools, favorite groups,
#     iqdb), without its trash step; the media asset is marked expunged.
#
#   bin/rails runner script/fourier_expunge_merged_duplicate.rb -- --post ID --as NAME            dry run
#   bin/rails runner script/fourier_expunge_merged_duplicate.rb -- --post ID --as NAME --apply    expunge
#
# It refuses anything but a retired merge child: deleted, its parent the
# survivor, deleted with the merge's own reason, the survivor live. Files go
# first and the record after, so a run interrupted between them is finished by
# running it again (an absent object is skipped, never an error). Every run
# ends by asking R2 again for every key and printing what it finds: after
# --apply each must be ABSENT, or the script exits 1.
require "optparse"
require "json"
require "open3"

post_id = nil
as_name = nil
apply = false
parser = OptionParser.new do |opts|
  opts.require_exact = true
  opts.on("--post ID", Integer) { |v| post_id = v }
  opts.on("--as NAME") { |v| as_name = v }
  opts.on("--apply") { apply = true }
end
begin
  parser.parse!(ARGV.reject { |arg| arg == "--" })
rescue OptionParser::ParseError => e
  warn "FAIL: #{e.message}"
  warn "fix:  --post <retired post id> --as <admin name> [--apply], spelled out in full"
  exit 2
end

admin = User.find_by_name(as_name.to_s)
if admin.nil? || !admin.is_admin?
  warn "FAIL: #{as_name.inspect} is #{admin.nil? ? "no booru account" : "not an admin"}."
  warn "fix:  --as <your booru admin name>; the permanent-delete mod log names that account."
  exit 2
end
if post_id.nil?
  warn "FAIL: no --post given."
  warn "fix:  --post <retired post id>, one at a time."
  exit 2
end

MERGE_REASON = ->(survivor_id) { "merged into post ##{survivor_id}: the same picture (Matrix duplicate)" }
MXC = %r{\Amxc://[^/]+/(?<id>[A-Za-z0-9_-]{5,})\z}

post = Post.find_by(id: post_id)
if post.nil?
  refusal =
    "no post ##{post_id} (already expunged, or the wrong id)"
elsif !post.is_deleted?
  refusal =
    "post ##{post_id} is not deleted: only a retired merge child is expunged here"
elsif post.parent_id.nil?
  refusal =
    "post ##{post_id} has no parent: a retired merge child is the child of its survivor"
elsif (survivor = Post.find_by(id: post.parent_id)).nil? || survivor.is_deleted?
  refusal =
    "post ##{post_id}'s parent ##{post.parent_id} is not a live post: the survivor must be live before its duplicate is expunged"
elsif !post.flags.exists?(reason: MERGE_REASON.call(post.parent_id))
  refusal =
    "post ##{post_id} was not deleted by the merge (its deletion reason is not \"#{MERGE_REASON.call(post.parent_id)}\")"
elsif !(match = MXC.match(post.source.to_s))
  refusal =
    "post ##{post_id}'s source #{post.source.inspect} is not an mxc:// address: not a retired Matrix post"
end
if refusal
  warn "REFUSED: #{refusal}."
  warn "fix:  give the id of a retired Matrix post the merge script deleted into a live survivor."
  exit 1
end

sm = Danbooru.config.storage_manager
asset = post.media_asset
media_id = match[:id]

# [label, rclone target] for every object this post may still have.
targets = asset.variants.map do |v|
  mapped = sm.fourier_key(v.file_path)
  [mapped || v.file_path, sm.key(v.file_path)]
end
raw_key = "superseded/local_content/#{media_id[0, 2]}/#{media_id[2, 2]}/#{media_id[4..]}"
targets << [raw_key, ":#{sm.remote}:#{sm.bucket}/#{raw_key}"]

# The answer for one object: true present, false absent, or raises naming the
# rclone failure -- never guessed.
present = lambda do |target|
  out, err, status = Open3.capture3(sm.rclone_path, *sm.rclone_options, "lsjson", "--stat", target)
  return true if status.success? && out.strip.start_with?("{")
  return false if err.include?("object not found") || err.include?("directory not found") || err.include?("not found")

  raise "rclone lsjson --stat #{target} failed: #{err.lines.grep_v(/NOTICE/).join.strip.presence || "exit #{status.exitstatus}"}"
end

survivor = Post.find(post.parent_id)
puts "post ##{post.id} (md5 #{post.md5}, #{post.source}) -- retired into ##{survivor.id} (md5 #{survivor.md5}, live)"
deleted = []
targets.each_with_index do |(label, target), i|
  here = present.call(target)
  puts "[#{i + 1}/#{targets.size}] #{label}: #{here ? "present" : "absent"}#{" -- would delete" if here && !apply}"
  next unless here && apply

  _out, err, status = Open3.capture3(sm.rclone_path, *sm.rclone_options, "deletefile", target)
  raise "rclone deletefile #{target} failed: #{err.lines.grep_v(/NOTICE/).join.strip}" unless status.success?

  deleted << label
  puts "      deleted #{label}"
end

if apply
  Post.transaction do
    CurrentUser.scoped(admin) do
      Post.without_timeout do
        # Post#expunge! less its media_asset.trash! (see the header).
        ModAction.log("permanently deleted post ##{post.id} (md5=#{post.md5}), a Matrix duplicate merged into post ##{survivor.id}", :post_permanent_delete, subject: nil, user: admin)
        post.send(:update_children_on_destroy)
        Tag.decrement_post_counts(post.tag_array)
        post.remove_from_all_pools
        post.remove_from_fav_groups
        post.destroy!
        post.send(:update_parent_on_destroy)
      end
      asset.purge_cached_urls!
      asset.update!(status: :expunged)
      ModAction.log("expunged media asset ##{asset.id} (md5=#{asset.md5}): its files deleted", :media_asset_expunge, subject: asset, user: admin)
    end
  end
  post.remove_iqdb
end

# THE PROOF: ask R2 again for every key.
puts apply ? "--- after: every key must be ABSENT" : "--- dry run: nothing written"
left = targets.select { |(label, target)| present.call(target).tap { |here| puts "  #{label}: #{here ? "PRESENT" : "absent"}" } }
record = Post.exists?(post.id)
puts "  post ##{post.id} record: #{record ? "PRESENT" : "absent"}; media asset ##{asset.id}: #{asset.reload.status}"
if apply
  if left.any? || record
    warn "FAIL: #{left.size} object(s) still present#{", and the post record" if record}; run again to finish (absent objects are skipped)."
    exit 1
  end
  puts "done: post ##{post.id} expunged, #{deleted.size} object(s) deleted: #{deleted.join(", ")}"
end
