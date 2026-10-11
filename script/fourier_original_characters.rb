# frozen_string_literal: true

# ORIGINAL CHARACTERS (operator rulings 2026-10-11): an original character's
# tag is <name>_(<creator>), a creator claims and keeps it (CharacterClaim),
# and every approved claim implies the copyright tag `original`.
#
#   bin/rails runner script/fourier_original_characters.rb -- --as NAME [--oc-owner LOCALPART]           dry run
#   bin/rails runner script/fourier_original_characters.rb -- --as NAME [--oc-owner LOCALPART] --apply   write
#
# NAME is the booru admin every write is made as.
#
# ALWAYS: `original` exists as a copyright tag with a wiki page -- created
# when missing, re-filed as copyright when filed otherwise (the dry run says
# how many posts it carries first), and an existing wiki page never
# overwritten.
#
# WITH --oc-owner LOCALPART, the tags in the four 2026-09-19 shapes
# (oc_<name>, character_oc_<name>, <name>_oc, <name>_character_oc) are
# LOCALPART's (operator, 2026-10-11: "oc_name is my personal tag"), and each
# one is moved onto <name>_(LOCALPART):
#   - alias <old> -> <name>_(LOCALPART) (TagAlias.approve!): its posts, wiki
#     and provenance move, and anyone typing the old name gets the new one;
#     two old shapes of one name land on the same tag;
#   - the target filed as a character, implying `original` (and `original`
#     put back to copyright after: upstream gives an EMPTY umbrella tag the
#     category of the tag implying it);
#   - when a creator gallery has the slug LOCALPART, its claim on the target,
#     APPROVED by NAME (an admin decision, in the mod log) unless one already
#     stands.
# A target the claim rule refuses (CharacterClaim.name_refusal), or an alias
# the booru refuses, is reported REFUSED with why, and then the WHOLE RUN
# writes nothing, --apply or not, and exits 1.
#
# WITHOUT --oc-owner those tags are only reported: each with its category,
# post count and the recorded creators of its posts (FourierPostCreator).
#
# ALWAYS REPORTED, never changed: every tag already named <name>_(<slug>) for
# an existing creator gallery, with its post count and whether it has a wiki
# page -- the names whose claim will wait for an admin because they have
# history.
#
# Running it again after --apply changes nothing: every step says it is
# already done.
require "optparse"

as_name = nil
apply = false
owner = nil
parser = OptionParser.new do |opts|
  # A write is asked for by its whole name, never an abbreviation.
  opts.require_exact = true
  opts.on("--as NAME") { |name| as_name = name }
  opts.on("--oc-owner LOCALPART") { |localpart| owner = localpart }
  opts.on("--apply") { apply = true }
end
begin
  parser.parse!(ARGV.reject { |arg| arg == "--" })
rescue OptionParser::ParseError => e
  warn "FAIL: #{e.message}"
  warn "fix:  --as <your booru admin name> [--oc-owner <matrix localpart>] [--apply], spelled out in full; without --apply it is a dry run."
  exit 2
end

admin = User.find_by_name(as_name.to_s)
if admin.nil? || !admin.is_admin?
  warn "FAIL: #{as_name.inspect} is #{admin.nil? ? "no booru account" : "not an admin"}."
  warn "fix:  --as <your booru admin name>; the change is made as that account."
  exit 2
end

# A Matrix localpart as the homeserver issues it: lower case, and only the
# characters the Matrix grammar allows.
if !owner.nil? && !owner.match?(%r{\A[a-z0-9._=/-]+\z})
  warn "FAIL: --oc-owner #{owner.inspect} is not a Matrix localpart."
  warn "fix:  --oc-owner <the owner's Matrix name without @ or :server, in lower case>, e.g. --oc-owner saber"
  exit 2
end

original = CharacterClaim::ORIGINAL
original_wiki = <<~DTEXT.strip
  A character, setting or work made by its creator rather than taken from an existing series.

  On this site an original character's tag is its name with its creator's Matrix name in brackets, for example maple_(saber). A creator claims theirs from their creator page; once it is theirs, its wiki page is theirs to write, and its tag implies [[#{original}]].
DTEXT

# The 2026-09-19 rule's four shapes (FourierTagSource::LEGACY_ORIGINAL_CHARACTER),
# as a Postgres regex.
old_rule = "^((character_)?oc_[a-z0-9].*|.*[a-z0-9]_(character_)?oc)$"
# The regex finds candidates; the booru's own reading decides, so a name that
# already ends in a creator in brackets (oc_(series)) is never listed as one.
old_tags = Tag.where("name ~ ?", old_rule).order(:name).pluck(:name, :category, :post_count)
              .select { |name, _, _| FourierTagSource.legacy_original_character(name) }
slugs = CreatorGallery.pluck(:slug)
named = slugs.empty? ? [] : Tag.where("substring(name from '_\\(([^()]+)\\)$') IN (?)", slugs).order(:name).pluck(:name, :post_count)
wikis = WikiPage.where(title: named.map(&:first), is_deleted: false).pluck(:title).to_set
gallery = owner && CreatorGallery.find_by(slug: owner)
# Old-shape tags no alias has moved yet: what a run without --oc-owner leaves.
moved = TagAlias.active.where(antecedent_name: old_tags.map(&:first)).pluck(:antecedent_name).to_set
unmoved = old_tags.count { |name, _, _| moved.exclude?(name) }

total = 2 + old_tags.size + named.size
step = 0
say = ->(line) { puts "[#{step += 1}/#{total}] #{line}" }
detail = ->(line) { puts "      #{line}" }
refused = []
writes = 0
touched = [original] # whose category caches a rolled-back run must forget

# ONE TRANSACTION. The booru's own relationship validations and callbacks
# create the tags they name, so anything that asked them would leave empty
# tags behind on a dry run. So every step is really taken, inside it, and
# the dry run -- or a run with anything REFUSED -- rolls all of it back:
# what the dry run prints is what --apply does, the booru's own refusals
# included, and --apply commits every step or none.
ActiveRecord::Base.transaction do
  CurrentUser.scoped(admin) do
    # 1. `original`, a copyright tag.
    tag = Tag.find_by_name(original)
    if tag&.copyright?
      say.call("tag #{original}: already copyright (#{tag.post_count} #{"post".pluralize(tag.post_count)})")
    else
      say.call("tag #{original}: #{tag ? "#{tag.category_name.downcase}, #{tag.post_count} #{"post".pluralize(tag.post_count)}" : "missing"} -> copyright")
      writes += 1
      if tag
        tag.update!(category: Tag.categories.copyright, updater: admin)
      else
        Tag.find_or_create_by_name(original, category: "copyright", current_user: admin)
      end
    end

    # 2. Its wiki page, left as it is when it exists.
    page = WikiPage.find_by(title: original)
    if page && !page.is_deleted?
      say.call("wiki #{original}: exists (##{page.id}), left as it is")
    else
      say.call("wiki #{original}: #{page ? "deleted page, restored with" : "new page"}\n#{original_wiki.gsub(/^/, "      ")}")
      writes += 1
      page ? page.update!(body: original_wiki, is_deleted: false) : WikiPage.create!(title: original, body: original_wiki)
    end

    # 3. The old rule's tags, and who posted them; with --oc-owner, each moved
    # onto <name>_(owner).
    old_tags.each do |name, category, count|
      posters = FourierPostCreator.where(post_id: Post.raw_tag_match(name).select(:id)).distinct.order(:mxid).pluck(:mxid)
      say.call("oc_ tag #{name}: #{TagCategory.reverse_mapping[category]}, #{count} #{"post".pluralize(count)}, " \
               "posted by #{posters.any? ? posters.join(", ") : "no recorded creator"}")
      next if owner.nil?

      base = FourierTagSource.legacy_original_character(name)
      target = "#{base}_(#{owner})"
      touched.push(name, target)
      refuse = lambda do |why|
        refused << "#{name} -> #{target}: #{why}"
        detail.call("REFUSED #{refused.last}")
      end

      why = CharacterClaim.name_refusal(target, owner, CreatorPrefixes.entries)
      probe = Tag.new(name: target)
      why ||= "#{target} is not a valid tag name: #{probe.errors.full_messages.join("; ")}" if probe.invalid?(:name)
      next refuse.call(why) if why

      # Each move in a savepoint of its own, so a refusal the database raises
      # leaves the outer transaction able to report the rest.
      ActiveRecord::Base.transaction(requires_new: true) do
        # The alias.
        standing = TagAlias.active.find_by(antecedent_name: name)
        if standing&.consequent_name == target
          detail.call("alias #{name} -> #{target}: already in place")
        elsif standing
          next refuse.call("#{name} is already aliased to #{standing.consequent_name}: an admin removes that alias " \
                           "(/tag_aliases), or names that tag's owner, then run this again")
        else
          detail.call("alias #{name} -> #{target}: #{count} #{"post".pluralize(count)} #{(count == 1) ? "moves" : "move"}")
          writes += 1
          TagAlias.approve!(antecedent_name: name, consequent_name: target, approver: admin)
        end

        # The target, a character.
        tag = Tag.find_by_name(target)
        if tag.character?
          detail.call("#{target}: already a character")
        elsif tag.general?
          detail.call("#{target}: general -> character")
          writes += 1
          tag.update!(category: TagCategory::CHARACTER, updater: admin)
        else
          next refuse.call("#{target} is filed as #{tag.category_name.downcase} (from #{name}): an admin re-files #{name} " \
                           "as a character, then run this again")
        end

        # Implying `original`, which stays copyright.
        if tag.implies?(original)
          detail.call("#{target} already implies #{original}")
        else
          detail.call("#{target} implies #{original}")
          writes += 1
          TagImplication.approve!(antecedent_name: target, consequent_name: original, approver: admin)
          umbrella = Tag.find_by_name(original)
          umbrella.update!(category: Tag.categories.copyright, updater: admin) unless umbrella.copyright?
        end

        # The owner's claim, when the owner has a gallery.
        if gallery.nil?
          detail.call("no creator gallery #{owner}: no claim filed (one can be filed from the creator page once it exists)")
        elsif CharacterClaim.standing_on([target]).any?
          detail.call("claim #{target} for @#{owner}: already stands")
        else
          detail.call("claim #{target} for @#{owner}: approved by #{admin.name}")
          writes += 1
          claim = CharacterClaim.pending.find_by(tag_name: target, creator_gallery: gallery)
          claim ||= CharacterClaim.create!(creator_gallery: gallery, tag_name: target)
          claim.approve!(by: admin)
        end
      rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
        refuse.call(e.respond_to?(:record) ? e.record.errors.full_messages.join("; ") : e.message)
        raise ActiveRecord::Rollback
      end
    end

    # 4. Tags already named for an existing creator. Report only.
    named.each do |name, count|
      say.call("named for creator #{name[FourierTagSource::ORIGINAL_CHARACTER, 2]}: #{name}, #{count} #{"post".pluralize(count)}, " \
               "#{wikis.include?(name) ? "wiki page" : "no wiki page"}")
    end
  end
  raise ActiveRecord::Rollback if !apply || refused.any?
end

# A rolled-back run took real steps, and a tag's category is cached outside
# the database: forget what those steps cached.
touched.each { |name| Cache.delete("tag-category:#{Cache.hash(name)}") } if !apply || refused.any?

if owner.nil?
  puts "oc_ tags from the 2026-09-19 rule: #{old_tags.size}, reported only (--oc-owner <localpart> moves them onto <name>_(<localpart>)). " \
       "Tags named for an existing creator: #{named.size}, reported only."
else
  puts "oc_ tags from the 2026-09-19 rule: #{old_tags.size}, each moved onto <name>_(#{owner}). Tags named for an existing creator: #{named.size}, reported only."
end

if refused.any?
  puts "REFUSED: #{refused.size}. The whole run wrote nothing:"
  refused.each { |line| puts "  #{line}" }
  warn "fix:  settle each REFUSED line as it says, then run this again; nothing is written while any line is refused."
  exit 1
elsif writes.zero? && owner.nil? && unmoved.positive?
  # Not "every step is done": without --oc-owner these were only reported.
  puts "nothing written: #{unmoved} oc_ #{"tag".pluralize(unmoved)} above #{(unmoved == 1) ? "has" : "have"} not moved; --oc-owner <localpart> moves them."
elsif writes.zero?
  puts "nothing to write: every step is already done."
elsif apply
  puts "done: #{writes} #{"change".pluralize(writes)} written as #{admin.name}."
else
  puts "DRY RUN -- nothing written. #{writes} #{"change".pluralize(writes)} above; read them, then run again with --apply."
end
