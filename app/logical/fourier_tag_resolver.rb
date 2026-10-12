# frozen_string_literal: true

# A prompt-derived name -> the tag this booru already has for it.
#
# The tunnel scrapes creator tags out of an image's generation prompt, and a
# prompt names a character the way its author typed it: "hilda", "Hilda
# (Pokemon)", an alias, a spelling the booru moved on from. Recorded verbatim,
# such a name matched no Tag row, so the post page could file it nowhere but
# the general flow, and a posted one was minted as a new general tag
# (operator, 2026-09-19: "prompt metadata tags aren't being recognized as
# having a potential character/series name match an existing tag and are
# being posted as general tags").
#
# This runs at the single write path (FourierTagSource.record_partition!), so
# every writer -- tunnel, sampling -- is corrected the same way and none
# has to talk to the tags API to do it. Four steps, cheapest and surest first,
# each only for the names the previous step left unresolved:
#
#   1. normalise, then the booru's own ALIASES (TagAlias.to_aliased) -- this
#      is what Post#normalize_tags does to a tag_string, so provenance rows
#      end up under the same names as the tags they describe;
#   2. a name that exists as a tag is done;
#   3. an UNQUALIFIED name matches a QUALIFIED identifying tag when exactly one
#      exists for that stem: hilda -> hilda_(pokemon). Identifying kinds only
#      (artist, character, copyright), non-empty only, and only when unique --
#      two candidates is a guess, and a guess here mis-attributes a picture --
#      and never an ORIGINAL CHARACTER (below);
#   4. a QUALIFIED name the booru does not have matches its stem when the stem
#      is an identifying tag AND the bracket names a SERIES (a copyright tag):
#      hatsune_miku_(vocaloid) -> hatsune_miku.
#
# THE BRACKET HAS TWO MEANINGS (2026-10-12). Since the original-character
# rule (an OC is <name>_(<creator>)), the bracket names a series in
# hilda_(pokemon) and a CREATOR in kayla_(selphdestruct) -- the operator:
# "multiple conflicting uses of the same dataspace by different things".
# Steps 3 and 4 guess across the bracket, and were written for series only:
# on OC names step 3 turned any prompt's plain "kayla" into selphdestruct's
# character, and step 4 turned a not-yet-known kayla_(alice) into whatever
# existing character is called kayla. So step 3 never lands on an original
# character (a tag implying `original`, or one with a standing claim), and
# step 4 folds only a series' bracket.
#
# What it never does: invent a tag, or move a name that already exists. A name
# nothing matches is returned as itself.
module FourierTagResolver
  IDENTIFYING = [TagCategory::ARTIST, TagCategory::CHARACTER, TagCategory::COPYRIGHT].freeze
  QUALIFIER = /_\([^()]*\)\z/

  # @param names [Array<String>]
  # @return [Hash{String => String}] given name -> resolved name (identity when unresolved)
  def self.resolve(names)
    given = Array(names).map { |n| Tag.normalize_name(n.to_s) }.reject(&:blank?).uniq
    return {} if given.empty?

    map = given.zip(TagAlias.to_aliased(given)).to_h
    existing = Tag.where(name: map.values.uniq).pluck(:name).to_set
    open = map.reject { |_, v| existing.include?(v) }
    return map if open.empty?

    # 3. stem -> the one qualified identifying tag
    stems = open.values.grep_v(QUALIFIER).uniq
    if stems.any?
      patterns = stems.map { |s| "#{s.gsub(/([\\%_])/) { "\\#{$1}" }}\\_(%" }
      candidates = Tag.nonempty.where(category: IDENTIFYING).where("tags.name LIKE ANY (ARRAY[?])", patterns)
                      .where.not(name: TagImplication.active.where(consequent_name: "original").select(:antecedent_name))
                      .where.not(name: CharacterClaim.where(status: [CharacterClaim::APPROVED, CharacterClaim::HELD]).select(:tag_name))
                      .pluck(:name)
      by_stem = candidates.group_by { |n| n.sub(QUALIFIER, "") }
      open.each do |k, v|
        c = by_stem[v]
        map[k] = c.first if c && c.size == 1
      end
    end

    # 4. qualified but unknown -> its stem, when the stem is an identifying tag
    #    and the bracket is a series (a copyright tag), never a creator
    qualified = open.select { |_, v| v.match?(QUALIFIER) }
    if qualified.any?
      stem_of = qualified.transform_values { |v| v.sub(QUALIFIER, "") }
      bracket_of = qualified.transform_values { |v| v[/_\(([^()]*)\)\z/, 1] }
      known = Tag.nonempty.where(category: IDENTIFYING, name: stem_of.values.uniq).pluck(:name).to_set
      series = Tag.where(category: TagCategory::COPYRIGHT, name: bracket_of.values.uniq).pluck(:name).to_set
      stem_of.each { |k, stem| map[k] = stem if known.include?(stem) && series.include?(bracket_of[k]) }
    end

    map
  end
end
