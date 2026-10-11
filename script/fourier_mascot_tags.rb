# frozen_string_literal: true

# THE SITE MASCOTS' TAGS (operator, 2026-10-11): one copyright tag for the
# site, one character tag per mascot under her full name, her nickname
# aliased to it, each character implying the site and `mascot`, and a wiki
# page each saying who she is and which Matrix account is hers.
#
#   bin/rails runner script/fourier_mascot_tags.rb -- --as NAME             dry run
#   bin/rails runner script/fourier_mascot_tags.rb -- --as NAME --apply     write
#
# NAME is the booru admin the changes are made as (the approver of every
# alias and implication, the updater of every tag and wiki page).
#
# The dry run prints every step and what is there now -- an existing tag's
# category and post count, an existing wiki page, an alias or implication
# already in place -- and checks each alias and implication the way the
# booru would. Nothing is written without --apply. Running it again after
# --apply changes nothing: every step is skipped when already in place, and
# an EXISTING wiki page is never overwritten (edit it on the site instead).
#
# The ownership is the copyright tag: tag a post `neru-chan` and the alias
# makes it `tonneru-chan`, whose implications add `41chan` and `mascot`.
# NOT `41chan_<anything>`: since 2026-10-04 that prefix is a creator tag, so
# `41chan_mascot` would read as a creator named "mascot".
require "optparse"

SITE = "41chan"
MASCOT = "mascot"

# One row per mascot. `nickname` is the name she is usually called, aliased
# to her full name; nil when she has none.
MASCOTS = [
  {
    tag: "fourier-chan", nickname: nil, matrix: "@fourier:41chan.net",
    about: "She is the site's guide, who welcomes newcomers and answers when someone asks for help.",
  },
  {
    tag: "tonneru-chan", nickname: "neru-chan", matrix: "@tunnel:41chan.net",
    about: "She is the site's tunnel, who carries images and their tags between the site's systems. Her name is [i]tonneru[/i], \"tunnel\".",
  },
  {
    tag: "sampuru-chan", nickname: "puru-chan", matrix: "@sample:41chan.net",
    about: "She is the site's sampler, who gathers the archive and reports its numbers. Her name is [i]sampuru[/i], \"sample\".",
  },
  {
    tag: "yoi-chan", nickname: nil, matrix: "@yoi:41chan.net",
    about: "She is the site's reporter on its own health. Her name is literally 41chan: [i]yo[/i] (4) and [i]i[/i] (1).",
  },
].freeze

def display_name(name) = name.sub(/\A./, &:upcase)

def mascot_wiki(row)
  name = display_name(row[:tag])
  called = row[:nickname] ? ", usually called #{display_name(row[:nickname])}," : ""
  <<~DTEXT.strip
    #{name}#{called} is one of [[#{SITE}]]'s site mascots. #{row[:about]}

    h4. Accounts

    * Matrix: [nodtext]#{row[:matrix]}[/nodtext]

    h4. See also

    * [[#{SITE}]], for the other site mascots
  DTEXT
end

def site_wiki
  lines = MASCOTS.map do |row|
    row[:nickname] ? "* [[#{row[:tag]}]] (#{display_name(row[:nickname])})" : "* [[#{row[:tag]}]]"
  end
  <<~DTEXT.strip
    41chan is the site this booru belongs to. A post tagged with one of its site mascots is tagged 41chan too.

    h4. Site mascots

    #{lines.join("\n")}
  DTEXT
end

MASCOT_WIKI = <<~DTEXT.strip
  A character who is the official mascot of a site, a company or a product.

  See [[#{SITE}]] for this site's own.
DTEXT

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
  warn "fix:  --as <your booru admin name>; the changes are made as that account."
  exit 2
end

tags = { SITE => "copyright", MASCOT => "general" }.merge(MASCOTS.to_h { |row| [row[:tag], "character"] })
wikis = { SITE => site_wiki, MASCOT => MASCOT_WIKI }.merge(MASCOTS.to_h { |row| [row[:tag], mascot_wiki(row)] })
aliases = MASCOTS.select { |row| row[:nickname] }.map { |row| [row[:nickname], row[:tag]] }
implications = MASCOTS.flat_map { |row| [[row[:tag], SITE], [row[:tag], MASCOT]] }

failures = []
step = 0
total = tags.size + wikis.size + aliases.size + implications.size
say = ->(line) { puts "[#{step += 1}/#{total}] #{line}" }

# ONE TRANSACTION. The booru's own alias and implication checks create the
# tags they name, so a dry run that merely asked them would leave empty tags
# behind: the dry run rolls everything back, and --apply commits every step
# or, on any failure, none of them.
ActiveRecord::Base.transaction do
  CurrentUser.scoped(admin) do
    # 1. Tags, in their categories. Created when missing; a category is changed
    #    only when it differs, and the dry run says how many posts it carries.
    tags.each do |name, category|
      tag = Tag.find_by_name(name)
      want = Tag.categories.value_for(category)
      if tag && tag.category == want
        say.call("tag #{name}: already #{category} (#{tag.post_count} posts)")
        next
      end

      now = tag ? "#{tag.category_name.downcase}, #{tag.post_count} posts" : "missing"
      say.call("tag #{name}: #{now} -> #{category}")
      next unless apply

      if tag
        tag.update!(category: want, updater: admin)
      else
        Tag.find_or_create_by_name(name, category: category, current_user: admin)
      end
    end

    # 2. Wiki pages, before the implications (the booru asks a tag with posts
    #    to have one). An existing page is left as it is.
    wikis.each do |title, body|
      page = WikiPage.find_by(title: title)
      if page && !page.is_deleted?
        say.call("wiki #{title}: exists (##{page.id}), left as it is")
        next
      end

      row = MASCOTS.find { |m| m[:tag] == title }
      other_names = (row && row[:nickname]) ? [row[:nickname]] : []
      say.call("wiki #{title}: #{page ? "deleted page, restored with" : "new page"}#{" (other names: #{other_names.join(", ")})" if other_names.any?}\n#{body.gsub(/^/, "      ")}")
      next unless apply

      if page
        page.update!(body: body, other_names: other_names, is_deleted: false)
      else
        WikiPage.create!(title: title, body: body, other_names: other_names)
      end
    end

    # 3. Nicknames aliased to full names. A nickname tag already holding posts
    #    has them moved onto the full name by the alias itself.
    aliases.each do |from, to|
      if TagAlias.active.exists?(antecedent_name: from, consequent_name: to)
        say.call("alias #{from} -> #{to}: already in place")
        next
      end

      check = TagAlias.new(creator: admin, antecedent_name: from, consequent_name: to)
      held = Tag.find_by_name(from)&.post_count.to_i
      if check.valid?
        say.call("alias #{from} -> #{to}#{" (moves #{held} posts)" if held.positive?}")
      else
        say.call("alias #{from} -> #{to}: REFUSED -- #{check.errors.full_messages.join("; ")}")
        failures << "alias #{from} -> #{to}"
        next
      end
      next unless apply

      TagAlias.approve!(antecedent_name: from, consequent_name: to, approver: admin)
    end

    # 4. Each mascot implies the site and `mascot`.
    implications.each do |from, to|
      if TagImplication.active.exists?(antecedent_name: from, consequent_name: to)
        say.call("implication #{from} -> #{to}: already in place")
        next
      end

      check = TagImplication.new(creator: admin, antecedent_name: from, consequent_name: to)
      if check.valid?
        say.call("implication #{from} -> #{to}")
      else
        say.call("implication #{from} -> #{to}: REFUSED -- #{check.errors.full_messages.join("; ")}")
        failures << "implication #{from} -> #{to}"
        next
      end
      next unless apply

      TagImplication.approve!(antecedent_name: from, consequent_name: to, approver: admin)

      # Upstream gives an EMPTY umbrella tag its child's category when an
      # implication to it is approved (TagImplication#process!), so a fresh
      # 41chan came out a character tag on the dev run. Put it back.
      umbrella = Tag.find_by_name(to)
      want = Tag.categories.value_for(tags[to])
      next if umbrella.category == want

      umbrella.update!(category: want, updater: admin)
      puts "      #{to} put back to #{tags[to]} (the booru gives an empty tag the category of the tag implying it)"
    end
  end
  raise ActiveRecord::Rollback if !apply || failures.any?
end

if failures.any?
  warn "FAIL: #{failures.size} step(s) refused: #{failures.join(", ")} -- the reasons are on their lines above."
  warn "fix:  nothing was written (all or nothing). Resolve what each line names, then run again."
  exit 1
end

if apply
  puts "done: #{total} steps, made as #{admin.name}. Aliases and implications update existing posts as they are approved."
else
  puts "DRY RUN -- nothing written. Read the steps above, then run again with --apply."
end
