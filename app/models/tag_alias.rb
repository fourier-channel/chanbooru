# frozen_string_literal: true

class TagAlias < TagRelationship
  # Validate that the alias doesn't exist yet when it's created or when a BUR
  # is requested, but not when a BUR is approved (to allow failed BURs to be reapproved)
  validates :antecedent_name, uniqueness: { scope: :status, conditions: -> { active }, on: %i[create update request] }
  validate :absence_of_transitive_relation
  validate :not_moving_out_of_quarantine

  before_create :delete_conflicting_relationships

  scope :empty, -> { joins(:consequent_tag).merge(Tag.empty) }

  # Given a list of tag names, return a hash mapping aliased names to real names.
  def self.aliases_for(names)
    return {} if names.empty?

    aliases = active.where(antecedent_name: names).to_h { |ta| [ta.antecedent_name, ta.consequent_name] }

    abbreviations = names.select { |name| name.starts_with?("/") && !aliases.key?(name) }
    abbreviations.each do |abbrev|
      tag = Tag.nonempty.find_by_abbreviation(abbrev)
      aliases[abbrev] = tag.name if tag.present?
    end

    aliases
  end

  # Given a list of tag names, return a new list with aliased tag names replaced by real tag names.
  def self.to_aliased(names)
    names = Array.wrap(names).map(&:to_s)
    aliases = aliases_for(names)
    names.map { |name| aliases.fetch(name, name) }
  end

  def process!
    TagMover.new(antecedent_name, consequent_name, user: User.system, approver: approver).move!
  end

  # We don't want a -> b && b -> c chains if the b -> c alias was created
  # first. If the a -> b alias was created first, the new one will be allowed
  # and the old one will be moved automatically instead.
  def absence_of_transitive_relation
    return if is_rejected?

    tag_alias = TagAlias.active.find_by(antecedent_name: consequent_name)
    if tag_alias.present? && tag_alias.consequent_name != antecedent_name
      errors.add(:base, "#{tag_alias.antecedent_name} is already aliased to #{tag_alias.consequent_name}")
    end
  end

  # Fork: moving a quarantined tag (TagQuarantine) onto a tag that is not
  # quarantined at least as strictly would show its posts to everyone the
  # quarantine hides them from -- the move retags them. Refused, with the
  # way forward; allowed when the new name already carries the same state
  # (or banished, which is stricter than flagged).
  def self.quarantine_move_refusal(old_name, new_name)
    flagged = TagQuarantine.flagged_names
    banished = TagQuarantine.banished_names
    if banished.include?(old_name) && banished.exclude?(new_name)
      "#{old_name} is banished; moving it to #{new_name} would show its posts. Banish #{new_name} first"
    elsif flagged.include?(old_name) && flagged.exclude?(new_name) && banished.exclude?(new_name)
      "#{old_name} is flagged for review; moving it to #{new_name} would show its posts to everyone. Flag #{new_name} first, or release #{old_name} from the review queue"
    end
  end

  def not_moving_out_of_quarantine
    return if is_rejected? || is_deleted?

    refusal = TagAlias.quarantine_move_refusal(antecedent_name, consequent_name)
    errors.add(:base, refusal) if refusal
  end

  # Allow aliases to be reversed. If A -> B already exists, but we're trying to
  # create B -> A, then automatically delete A -> B so we can make B -> A.
  # Also automatically remove implications that are being replaced by aliases
  def delete_conflicting_relationships
    tag_relationships = []
    tag_relationships << TagAlias.active.find_by(antecedent_name: consequent_name, consequent_name: antecedent_name)
    tag_relationships << TagImplication.active.find_by(antecedent_name: antecedent_name, consequent_name: consequent_name)
    tag_relationships << TagImplication.active.find_by(antecedent_name: consequent_name, consequent_name: antecedent_name)
    tag_relationships.each { |rel| rel.reject!(User.system) if rel.present? }
  end
end
