# frozen_string_literal: true

# Prints the JSON that script/anonymize_for_dev.sql and its verifier read
# (psql -v cfg=...). It reads configuration only and opens no database
# connection; the names it prints are the service accounts and creator
# prefixes the app's own config already holds, so the SQL never spells them.
#
#   FOURIER_CREATOR_PREFIXES=<production's creator_prefixes.yml> \
#     bin/rails runner script/anonymize_for_dev_config.rb > cfg.json
#
# RULES is the operator's ruling of 2026-10-18, one entry per creator prefix:
# imageboard names are public and kept; Matrix localparts and Discord
# usernames are pseudonymized. A prefix in the live list with no rule here
# stops the run, so a prefix added later cannot pass through unclassified.
# testguild_ is a Discord guild prefix: Discord usernames, like aichan_.
RULES = { "4chan_" => "keep", "41chan_" => "pseudonymize", "aichan_" => "pseudonymize", "testguild_" => "pseudonymize" }.freeze

prefixes = CreatorPrefixes.config
unruled = prefixes[:entries].map(&:prefix) - RULES.keys
if unruled.any?
  abort "anonymize_for_dev_config: no keep|pseudonymize rule for creator prefix #{unruled.join(", ")}. " \
        "Fix: add each to RULES in #{__FILE__} (the operator decides which)."
end

names = ->(list) { Array(list).map { |name| name.to_s.strip.downcase }.reject(&:empty?) }
jail = names.call(Danbooru.config.fourier_jail_release_names) +
       names.call(Danbooru.config.fourier_posting_bot_names) +
       names.call([Danbooru.config.system_user])
keep = jail + names.call(Danbooru.config.fourier_quarantine_reader_names) + names.call(prefixes[:editors])

puts({
  keep_names: keep.uniq,
  jail_names: jail.uniq,
  matrix_server: Danbooru.config.fourier_matrix_server_name.to_s,
  jail_tag: Danbooru.config.troll_jail_tag.to_s,
  prefixes: prefixes[:entries].map do |entry|
    { prefix: entry.prefix, provenance: entry.provenance, target_kind: entry.target_kind, action: RULES.fetch(entry.prefix) }
  end,
}.to_json)
