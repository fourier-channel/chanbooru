# frozen_string_literal: true

# ORIGINAL CHARACTERS (operator rulings 2026-10-11): an original character's
# tag is <name>_(<creator>), a creator claims and keeps it (CharacterClaim),
# and every approved claim implies the copyright tag `original`.
#
#   bin/rails runner script/fourier_original_characters.rb -- --as NAME             dry run
#   bin/rails runner script/fourier_original_characters.rb -- --as NAME --apply     write
#
# NAME is the booru admin the one write is made as.
#
# THE ONE WRITE: `original` exists as a copyright tag with a wiki page --
# created when missing, re-filed as copyright when filed otherwise (the dry
# run says how many posts it carries first), and an existing wiki page never
# overwritten. Running it again after --apply changes nothing.
#
# THE REST IS A REPORT, and writes nothing:
#   - every tag the 2026-09-19 rule made (oc_<name>, <name>_oc and their
#     character_ forms), with its category, post count and the recorded
#     creators of its posts (FourierPostCreator). That rule is replaced, and
#     code moves none of these: the operator decides each one, by alias or
#     rename, from this list;
#   - every tag already named <name>_(<slug>) for an existing creator gallery,
#     with its post count and whether it has a wiki page: the names whose
#     claim will wait for an admin because they have history.
require "optparse"

as_name = nil
apply = false
parser = OptionParser.new do |opts|
  # A write is asked for by its whole name, never an abbreviation.
  opts.require_exact = true
  opts.on("--as NAME") { |name| as_name = name }
  opts.on("--apply") { apply = true }
end
begin
  parser.parse!(ARGV.reject { |arg| arg == "--" })
rescue OptionParser::ParseError => e
  warn "FAIL: #{e.message}"
  warn "fix:  --as <your booru admin name> [--apply], spelled out in full; without --apply it is a dry run."
  exit 2
end

admin = User.find_by_name(as_name.to_s)
if admin.nil? || !admin.is_admin?
  warn "FAIL: #{as_name.inspect} is #{admin.nil? ? "no booru account" : "not an admin"}."
  warn "fix:  --as <your booru admin name>; the change is made as that account."
  exit 2
end

original = CharacterClaim::ORIGINAL
original_wiki = <<~DTEXT.strip
  A character, setting or work made by its creator rather than taken from an existing series.

  On this site an original character's tag is its name with its creator's Matrix name in brackets, for example maple_(saber). A creator claims theirs from their creator page; once it is theirs, its wiki page is theirs to write, and its tag implies [[#{original}]].
DTEXT

# The 2026-09-19 rule, kept here only to find what it made (Postgres regex).
old_rule = "^((character_)?oc_[a-z0-9].*|.*[a-z0-9]_(character_)?oc)$"
old_tags = Tag.where("name ~ ?", old_rule).order(:name).pluck(:name, :category, :post_count)
slugs = CreatorGallery.pluck(:slug)
named = slugs.empty? ? [] : Tag.where("substring(name from '_\\(([^()]+)\\)$') IN (?)", slugs).order(:name).pluck(:name, :post_count)
wikis = WikiPage.where(title: named.map(&:first), is_deleted: false).pluck(:title).to_set

total = 2 + old_tags.size + named.size
step = 0
say = ->(line) { puts "[#{step += 1}/#{total}] #{line}" }

# ONE TRANSACTION. The booru's own relationship validations and callbacks
# create the tags they name, so anything that asked them would leave empty
# tags behind on a dry run: the dry run rolls everything back, and --apply
# commits every step or none.
ActiveRecord::Base.transaction do
  CurrentUser.scoped(admin) do
    # 1. `original`, a copyright tag.
    tag = Tag.find_by_name(original)
    if tag&.copyright?
      say.call("tag #{original}: already copyright (#{tag.post_count} #{"post".pluralize(tag.post_count)})")
    else
      say.call("tag #{original}: #{tag ? "#{tag.category_name.downcase}, #{tag.post_count} #{"post".pluralize(tag.post_count)}" : "missing"} -> copyright")
      if apply
        if tag
          tag.update!(category: Tag.categories.copyright, updater: admin)
        else
          Tag.find_or_create_by_name(original, category: "copyright", current_user: admin)
        end
      end
    end

    # 2. Its wiki page, left as it is when it exists.
    page = WikiPage.find_by(title: original)
    if page && !page.is_deleted?
      say.call("wiki #{original}: exists (##{page.id}), left as it is")
    else
      say.call("wiki #{original}: #{page ? "deleted page, restored with" : "new page"}\n#{original_wiki.gsub(/^/, "      ")}")
      if apply
        page ? page.update!(body: original_wiki, is_deleted: false) : WikiPage.create!(title: original, body: original_wiki)
      end
    end

    # 3. The old rule's tags, and who posted them. Report only.
    old_tags.each do |name, category, count|
      posters = FourierPostCreator.where(post_id: Post.raw_tag_match(name).select(:id)).distinct.order(:mxid).pluck(:mxid)
      say.call("oc_ tag #{name}: #{TagCategory.reverse_mapping[category]}, #{count} #{"post".pluralize(count)}, " \
               "posted by #{posters.any? ? posters.join(", ") : "no recorded creator"}")
    end

    # 4. Tags already named for an existing creator. Report only.
    named.each do |name, count|
      say.call("named for creator #{name[FourierTagSource::ORIGINAL_CHARACTER, 2]}: #{name}, #{count} #{"post".pluralize(count)}, " \
               "#{wikis.include?(name) ? "wiki page" : "no wiki page"}")
    end
  end
  raise ActiveRecord::Rollback unless apply
end

puts "oc_ tags from the 2026-09-19 rule: #{old_tags.size}. Tags named for an existing creator: #{named.size}. Neither list was changed."
if apply
  puts "done: #{original} is a copyright tag with a wiki page, made as #{admin.name}."
else
  puts "DRY RUN -- nothing written. Read the steps above, then run again with --apply."
end
