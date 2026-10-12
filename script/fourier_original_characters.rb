# frozen_string_literal: true

# ORIGINAL CHARACTERS (operator rulings 2026-10-11 and 2026-10-12): an
# original character's tag is <name>_(<creator>), a creator owns theirs
# (CharacterClaim), and every owned one implies the copyright tag `original`.
# The tags from the 2026-09-19 rule (oc_<name>, character_oc_<name>,
# <name>_oc, <name>_character_oc) recorded no owner, and the poster of an
# image is not its character's creator (operator, 2026-10-12: "Many of these
# characters belong to other creators, I'll just be the first one to post
# them"). So their owners come from the operator, and from nowhere else.
#
#   bin/rails runner script/fourier_original_characters.rb -- --as NAME                                   dry run + template
#   bin/rails runner script/fourier_original_characters.rb -- --as NAME --map OLD=CREATOR [--map ...]     dry run of a map
#   bin/rails runner script/fourier_original_characters.rb -- --as NAME --map-file PATH --apply           write
#
# NAME is the booru admin every write is made as, and the approver of every
# move. --map OLD=CREATOR names one tag's creator by their Matrix name; it can
# be given any number of times. --map-file PATH reads "OLD CREATOR" pairs, one
# per line, "#" comment lines and blank lines ignored; PATH "-" reads stdin,
# for a container whose tree is read-only:
#
#   ssh <host> 'docker exec -i <container> bin/rails runner script/fourier_original_characters.rb -- --as NAME --map-file - --apply' < map.txt
#
# ALWAYS: `original` exists as a copyright tag with a wiki page -- created
# when missing, re-filed as copyright when filed otherwise (the dry run says
# how many posts it carries first), an existing wiki page never overwritten.
#
# ALWAYS LISTED: every legacy tag, with its category, post count, the
# recorded posters of its posts (FourierPostCreator) -- shown to help the
# operator remember, never used to decide -- and whether it is mapped or
# already moved; then a ready-to-fill template of "OLD <creator>" lines for
# the ones neither mapped nor moved, which saves straight to a --map-file.
#
# EACH MAPPED TAG, on --apply, is moved onto <name>_(CREATOR):
#   - the target filed as a character, implying `original` (and `original`
#     put back to copyright after: upstream gives an EMPTY umbrella tag the
#     category of the tag implying it);
#   - alias OLD -> <name>_(CREATOR) (TagAlias.approve!): its posts, wiki and
#     provenance move, and anyone typing the old name gets the new one;
#   - CREATOR's ownership, by the move itself (TagMover ->
#     CharacterClaim.take_up_on_move!), approved by NAME: at once when a
#     creator gallery named CREATOR exists, otherwise HELD for that name and
#     approved the moment the gallery is made.
# UNMAPPED tags are untouched, and listed.
#
# REFUSED, by name, and then the WHOLE RUN writes nothing, --apply or not,
# and exits 1: a malformed map line, a map line naming a tag that is not a
# legacy tag, a CREATOR that is not a Matrix name, one tag mapped to two
# creators, a target the claim rule refuses (CharacterClaim.move_refusal: a
# creator prefix, a qualifier the booru reserves such as cosplay), a mapped
# tag already aliased somewhere else, or anything the booru itself refuses.
#
# ALWAYS REPORTED, never changed: every tag already named <name>_(<slug>) for
# an existing creator gallery, with its post count and whether it has a wiki
# page.
#
# Running it again with the same map after --apply changes nothing: every
# step says it is already done.
require "optparse"

as_name = nil
apply = false
pairs = [] # [where, old, creator] in the order given
malformed = []
parser = OptionParser.new do |opts|
  # A write is asked for by its whole name, never an abbreviation.
  opts.require_exact = true
  opts.on("--as NAME") { |name| as_name = name }
  opts.on("--map OLD=CREATOR") do |arg|
    old, creator, extra = arg.split("=")
    if old.blank? || creator.blank? || !extra.nil?
      malformed << "--map #{arg.inspect} is not OLD=CREATOR (the legacy tag, \"=\", then the creator's Matrix name)"
    else
      pairs << ["#{old}=#{creator}", old, creator]
    end
  end
  opts.on("--map-file PATH") do |path|
    where = (path == "-") ? "stdin" : path
    text = (path == "-") ? $stdin.read : File.read(path)
    text.each_line.with_index(1) do |line, number|
      next if line.strip.empty? || line.strip.start_with?("#")

      fields = line.split
      if fields.size == 2
        pairs << ["#{where} line #{number} (#{fields.join(" ")})", *fields]
      else
        malformed << "#{where}: line #{number} #{line.strip.inspect} is not \"OLD CREATOR\" (two words: the legacy tag, then the creator's Matrix name)"
      end
    end
  rescue SystemCallError => e
    malformed << "--map-file #{path}: #{e.message}"
  end
  opts.on("--apply") { apply = true }
end
begin
  parser.parse!(ARGV.reject { |arg| arg == "--" })
rescue OptionParser::ParseError => e
  warn "FAIL: #{e.message}"
  warn "fix:  --as <your booru admin name> [--map OLD=CREATOR ...] [--map-file PATH|-] [--apply], spelled out in full; " \
       "without --apply it is a dry run. (--oc-owner is gone: every tag's creator is named on its own.)"
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

# The 2026-09-19 rule's four shapes (FourierTagSource::LEGACY_ORIGINAL_CHARACTER),
# as a Postgres regex.
old_rule = "^((character_)?oc_[a-z0-9].*|.*[a-z0-9]_(character_)?oc)$"
# The regex finds candidates; the booru's own reading decides, so a name that
# already ends in a creator in brackets (oc_maple_(saber)) is never listed.
old_tags = Tag.where("name ~ ?", old_rule).order(:name).pluck(:name, :category, :post_count)
              .select { |name, _, _| FourierTagSource.legacy_original_character(name) }
legacy = old_tags.to_set(&:first)
moved = TagAlias.active.where(antecedent_name: legacy.to_a).pluck(:antecedent_name, :consequent_name).to_h
slugs = CreatorGallery.pluck(:slug)
named = slugs.empty? ? [] : Tag.where("substring(name from '_\\(([^()]+)\\)$') IN (?)", slugs).order(:name).pluck(:name, :post_count)
wikis = WikiPage.where(title: named.map(&:first), is_deleted: false).pluck(:title).to_set

# THE MAP, checked whole before anything is written: every refusal by name.
refused = malformed.map { |why| "map #{why}" }
map = {}
pairs.each do |where, old_input, creator|
  old = Tag.normalize_name(old_input)
  why = nil
  if legacy.exclude?(old)
    why = "#{old} is not a legacy original-character tag (one of the oc_ tags this lists): name one of those"
  elsif !creator.match?(CreatorGallery::SLUG)
    why = "#{creator} is not a creator's name: their Matrix name, without @ or :server, in lower case (e.g. selphdestruct)"
  elsif map.key?(old) && map[old] != creator
    why = "#{old} is mapped twice: to #{map[old]} and to #{creator}; keep the right one"
  end
  next refused << "map #{where}: #{why}" if why

  map[old] = creator
end
refused.each { |why| puts "REFUSED #{why}" }

total = 2 + old_tags.size + named.size
step = 0
say = ->(line) { puts "[#{step += 1}/#{total}] #{line}" }
detail = ->(line) { puts "      #{line}" }
writes = 0
touched = [original] # whose category caches a rolled-back run must forget
posters_of = {}

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

    # 3. Every legacy tag; each MAPPED one moved onto <name>_(creator).
    old_tags.each do |name, category, count|
      posters = posters_of[name] = FourierPostCreator.where(post_id: Post.raw_tag_match(name).select(:id)).distinct.order(:mxid).pluck(:mxid)
      creator = map[name]
      base = FourierTagSource.legacy_original_character(name)
      target = creator && "#{base}_(#{creator})"
      state = moved[name] ? "aliased to #{moved[name]}" : "not mapped"
      state = "mapped to #{target}" if creator
      say.call("oc_ tag #{name}: #{TagCategory.reverse_mapping[category]}, #{count} #{"post".pluralize(count)}, " \
               "posted by #{posters.any? ? posters.join(", ") : "no recorded creator"}, #{state}")
      next if creator.nil?

      touched.push(name, target)
      refuse = lambda do |why|
        refused << why
        detail.call("REFUSED #{why}")
      end

      standing = TagAlias.active.find_by(antecedent_name: name)
      if standing && standing.consequent_name != target
        next refuse.call("#{name} -> #{target}: #{name} is already aliased to #{standing.consequent_name}: an admin removes that alias " \
                         "(/tag_aliases), or map #{name} to that tag's creator, then run this again")
      end
      why = CharacterClaim.move_refusal(name, target)
      next refuse.call(why) if why

      # Each move in a savepoint of its own, so a refusal the database raises
      # leaves the outer transaction able to report the rest.
      ActiveRecord::Base.transaction(requires_new: true) do
        # The target, a character.
        tag = Tag.find_by_name(target)
        if tag&.character?
          detail.call("#{target}: already a character")
        elsif tag.nil? || tag.general?
          detail.call("#{target}: #{tag ? "general" : "new tag"} -> character")
          writes += 1
          tag ? tag.update!(category: TagCategory::CHARACTER, updater: admin) : Tag.find_or_create_by_name(target, category: "character", current_user: admin)
          tag = Tag.find_by_name(target)
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

        # The alias; its move assigns the ownership (TagMover).
        moving = standing.nil?
        if moving
          detail.call("alias #{name} -> #{target}: #{count} #{"post".pluralize(count)} #{(count == 1) ? "moves" : "move"}")
          writes += 1
          TagAlias.approve!(antecedent_name: name, consequent_name: target, approver: admin)
        else
          detail.call("alias #{name} -> #{target}: already in place")
        end

        # Who owns it now: the move's doing, read back, never assumed.
        claim = CharacterClaim.standing_on([target]).first
        held = CharacterClaim.held.find_by(tag_name: target)
        if claim
          detail.call("owner of #{target}: @#{claim.slug}, #{moving ? "approved by #{admin.name}" : "already stands"}")
        elsif held
          detail.call("owner of #{target}: held for @#{held.creator_slug}, approved by #{held.approver&.name || admin.name} " \
                      "the moment a creator gallery named #{held.creator_slug} exists#{" (already held)" unless moving}")
        else
          # Only reachable for an alias made before moves assigned ownership,
          # or a claim since withdrawn or released: said, not re-granted.
          statuses = CharacterClaim.where(tag_name: target).pluck(:status)
          detail.call("owner of #{target}: none (#{statuses.any? ? "its claims are #{statuses.join(", ")}" : "no claim"}); " \
                      "the alias was made earlier, so no move assigned one now: an admin settles it at /admin/artist_claims")
        end
      rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid, CharacterClaim::MoveRefused => e
        refuse.call("#{name} -> #{target}: #{e.respond_to?(:record) ? e.record.errors.full_messages.join("; ") : e.message}")
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

# The template: every legacy tag neither mapped nor already moved, one
# "OLD <creator>" line each, ready to fill and save as a --map-file.
unmapped = old_tags.map(&:first).reject { |name| map.key?(name) || moved.key?(name) }
if unmapped.any?
  puts "--- map template: put each creator's Matrix name in place of <creator>, delete the lines you are not mapping yet, " \
       "and pass the file with --map-file (an unfilled line is refused) ---"
  old_tags.each do |name, _, count|
    next unless unmapped.include?(name)

    posters = posters_of[name]
    puts "# #{name}: #{count} #{"post".pluralize(count)}, posted by #{posters.any? ? posters.join(", ") : "no recorded creator"}"
    puts "#{name} <creator>"
  end
  puts "--- end of template ---"
end

puts "Legacy oc_ tags: #{old_tags.size}; mapped this run: #{map.size}. Tags named for an existing creator: #{named.size}, reported only."
puts "#{unmapped.size} legacy #{"tag".pluralize(unmapped.size)} not mapped, left as they are: #{unmapped.join(", ")}." if unmapped.any?

if refused.any?
  puts "REFUSED: #{refused.size}. The whole run wrote nothing:"
  refused.each { |line| puts "  #{line}" }
  warn "fix:  settle each REFUSED line as it says, then run this again; nothing is written while any line is refused."
  exit 1
elsif writes.zero?
  puts "nothing to write: every step is already done."
elsif apply
  puts "done: #{writes} #{"change".pluralize(writes)} written as #{admin.name}."
else
  puts "DRY RUN -- nothing written. #{writes} #{"change".pluralize(writes)} above; read them, then run again with --apply."
end
