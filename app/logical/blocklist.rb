# frozen_string_literal: true

# The person's blocklist: the ONLY client-side filter on this site (operator,
# 2026-10-13). It replaced upstream's "blacklist" under a new name and lost
# the site-enforced rules that used to ride along with it: server withholding
# (jail, banish, flag, creator prefix) is the gate, and nothing client-side is
# a safety net.
#
# STORAGE. A signed-in person's list is the users.blacklisted_tags column
# (upstream's name, kept: renaming it is churn nobody sees). One block per
# line, upstream's rule syntax unchanged -- several tags on a line hide only
# posts that have all of them, a leading - exempts, ~ is "any of", rating: and
# score:< work -- so a pill in the header panel is exactly one line. A locked
# block ends with the word LOCK_MARKER ("spider %locked"). The marker lives in
# the text rather than in a column of its own because the text is what every
# other path already carries: a tag rename rewrites the list word by word
# (User#rewrite_blacklist) and the marker rides along; an account reset clears
# one field, not two; and no tag can ever be spelled with a leading %
# (TagNameValidator), so the marker can never collide with a real rule.
#
# A signed-out viewer's list lives in that browser's localStorage (key
# "blocklist", JSON [{rule, locked}]), applied by the same engine; an edit
# sends it here to be normalised and checked and stores nothing on the server.
# The first page a person sees after signing in merges it into the account
# (op "merge") and clears the key.
#
# EDITS go through PATCH /modulation/settings with a JSON body
#   {"blocklist": {"op": "add"|"remove"|"lock"|"unlock"|"merge",
#                  "rule": "<one line>", "blocks": [{rule, locked}] (merge),
#                  "list": [{rule, locked}] (signed out only)}}
# and answer {"blocklist": [{rule, locked}, ...]}, or 422 {"error": "..."}
# whose text names the remedy.
#
# OTHER APPS READ IT from GET /profile.json, which answers the signed-in
# person's own record and nobody else's: "blocklist" is
# [{"rule": "spider", "locked": true}, ...], parsed here so no reader has to
# know about the marker. Do not parse "blacklisted_tags" (the raw text) from
# another app. A request that carries no booru session is anonymous and gets
# []. Pinned by test/functional/blocklist_test.rb ("read by another app").
module Blocklist
  LOCK_MARKER = "%locked"
  OPS = %w[add remove lock unlock merge].freeze

  # One line of the list. #as_json is what the page, the panel and
  # /profile.json all receive.
  Block = Data.define(:rule, :locked) do
    def as_json(*)
      { "rule" => rule, "locked" => locked }
    end

    # /profile.xml: without this a block is written as its #inspect text.
    def to_xml(options = {})
      as_json.to_xml(options)
    end
  end

  # An edit that cannot be made. The message is shown to the person as-is,
  # so it always says what to do instead.
  class Refused < StandardError; end

  module_function

  # @param text [String, nil] the stored list
  # @return [Array<Block>] one block per non-blank line, in order; a rule
  #   written twice is one block, locked if either copy was.
  def parse(text)
    text.to_s.lines.filter_map { |line| parse_line(line) }
        .group_by(&:rule)
        .map { |rule, copies| Block.new(rule: rule, locked: copies.any?(&:locked)) }
  end

  # @return [Block, nil]
  def parse_line(line)
    words = line.downcase.split
    rule = (words - [LOCK_MARKER]).join(" ").gsub(/(rating:\w)\w+/, '\1')
    Block.new(rule: rule, locked: words.include?(LOCK_MARKER)) if rule.present?
  end

  def serialize(blocks)
    blocks.map { |b| b.locked ? "#{b.rule} #{LOCK_MARKER}" : b.rule }.join("\n")
  end

  # The rule a person typed, in the form it is stored and matched in.
  def normalize_rule(input)
    words = input.to_s.downcase.split
    raise Refused, "#{LOCK_MARKER} is the lock marker, not a tag. Block the tag, then press the padlock on its pill to lock it." if words.include?(LOCK_MARKER)
    rule = words.join(" ").gsub(/(rating:\w)\w+/, '\1')
    raise Refused, "Type a tag to block first, then press Enter or Block." if rule.blank?
    rule
  end

  # Apply one edit to a stored list. Line-wise: every line the edit does not
  # touch is kept exactly as the person wrote it.
  #
  # @return [String] the new text
  def edit(text, op:, rule: nil, blocks: nil)
    text = text.to_s
    case op.to_s
    when "add"
      rule = normalize_rule(rule)
      return text if parse(text).any? { |b| b.rule == rule }
      [text.presence, rule].compact.join("\n")
    when "remove"
      rule = normalize_rule(rule)
      block = parse(text).find { |b| b.rule == rule }
      return text if block.nil?
      raise Refused, "'#{rule}' is locked. Unlock it first (the padlock on its pill), then remove it." if block.locked
      text.lines.map(&:chomp).reject { |line| parse_line(line)&.rule == rule }.join("\n")
    when "lock", "unlock"
      rule = normalize_rule(rule)
      unless parse(text).any? { |b| b.rule == rule }
        raise Refused, "'#{rule}' is not on your blocklist any more (another tab may have removed it). Reload the page to see your current list."
      end
      text.lines.map(&:chomp).map { |line| (parse_line(line)&.rule == rule) ? set_lock(line, op == "lock") : line }.join("\n")
    when "merge"
      from_client(blocks).reduce(text) do |merged, block|
        merged = edit(merged, op: "add", rule: block.rule)
        block.locked ? edit(merged, op: "lock", rule: block.rule) : merged
      end
    else
      raise Refused, "Unknown blocklist edit '#{op}'. Use one of: #{OPS.join(", ")}."
    end
  end

  def set_lock(line, locked)
    words = line.split.reject { |word| word.downcase == LOCK_MARKER }
    (locked ? words + [LOCK_MARKER] : words).join(" ")
  end

  # A list sent by a browser: whatever is not a {rule: String} is dropped.
  # @return [Array<Block>]
  def from_client(list)
    lines = Array.wrap(list).filter_map do |item|
      item = item.to_unsafe_h if item.respond_to?(:to_unsafe_h)
      next unless item.is_a?(Hash) && item.with_indifferent_access[:rule].is_a?(String)
      item = item.with_indifferent_access
      ActiveModel::Type::Boolean.new.cast(item[:locked]) ? "#{item[:rule]} #{LOCK_MARKER}" : item[:rule]
    end
    parse(lines.join("\n"))
  end

  # Make one edit for this viewer.
  #
  # Signed in: on the account's CURRENT stored list, under a row lock, so a
  # tab holding an old copy cannot overwrite what another tab added. The
  # write is validated on the :blocklist context, which is what refuses
  # dropping a locked line however the edit arrives. `list` is ignored.
  #
  # Signed out: on the list the browser sent (`list`); nothing is stored here.
  #
  # @raise [Refused] with a message that names the remedy
  # @return [Array<Block>] the list after the edit
  def apply!(user, op:, rule: nil, blocks: nil, list: nil)
    return apply_signed_out(list, op: op, rule: rule, blocks: blocks) if user.is_anonymous?

    user.with_lock do
      user.blacklisted_tags = edit(user.blacklisted_tags, op: op, rule: rule, blocks: blocks)
      raise Refused, user.errors.full_messages.join("; ") unless user.save(context: [:update, :blocklist])
    end
    user.blocklist
  end

  def apply_signed_out(list, op:, rule:, blocks:)
    text = edit(serialize(from_client(list)), op: op, rule: rule, blocks: blocks)
    if text.lines.size > User::MAX_BLACKLIST_RULES
      raise Refused, "Blocklist can't have more than #{User::MAX_BLACKLIST_RULES} blocks. Remove one you no longer need first."
    end
    parse(text)
  end
end
