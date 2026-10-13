# frozen_string_literal: true

# THE NAME HALF OF THE QUARANTINE (TagQuarantine, operator rulings
# 2026-10-12: a flagged tag's "entire existence should immediately
# disappear"). A visible post cannot carry a quarantined name -- the post
# itself is hidden -- so what is left are the records that NAME a tag on
# their own: a wiki page titled with it, an artist entry, an alias or
# implication, a bulk update request, a tag version, a wiki link, an AI
# tag, a claim. Each such model declares, once, which of its rows name
# which tags:
#
#   names_tags(->(names) { <a where.not condition naming any of names> }) { |record| <its names> }
#
# and gets, for a viewer the names are hidden from (TagQuarantine.
# hidden_names_for: flagged names below admin but the bots, banished names
# to all but the pipeline):
#
#   - without_hidden_posts(user): the listing rule every index door applies
#     (ApplicationRecord.paginated_search), narrowed;
#   - visible(user): the same narrowing, so a NESTED association search
#     (Searchable, search[antecedent_implications][consequent_name]=...)
#     cannot ask whether a hidden name exists through a visible row;
#   - hidden_by_post_from? / refuses_write_from?: a single record naming one
#     answers 404 on a read and a write (ApplicationController#authorize),
#     and is dropped from every nested include
#     (ApplicationRecord#serializable_add_includes).
#
# Nothing quarantined adds nothing: the condition is built only when a name
# is hidden from the viewer.
module NamesTags
  extend ActiveSupport::Concern

  module ListingMethods
    def without_hidden_posts(user)
      without_hidden_tag_names(super, user)
    end

    def visible(user)
      without_hidden_tag_names(super, user)
    end

    private

    def without_hidden_tag_names(relation, user)
      names = TagQuarantine.hidden_names_for(user)
      return relation if names.empty?

      condition = instance_exec(names, &names_tags_condition)
      condition.is_a?(Array) ? relation.where.not(sanitize_sql_array(condition)) : relation.where.not(condition)
    end
  end

  class_methods do
    # @param condition [Proc] names -> a where condition (a Hash, or an SQL
    #   array) matching the rows that name any of `names`
    # @param block [Proc] record -> the tag names this record names
    def names_tags(condition, &block)
      @names_tags_condition = condition
      @names_tags_names = block
      singleton_class.prepend(ListingMethods) unless singleton_class.include?(ListingMethods)
    end

    def names_tags_condition = @names_tags_condition || superclass.names_tags_condition
    def names_tags_names = @names_tags_names || superclass.names_tags_names
  end

  # Whether this record names a tag whose name is hidden from `user`.
  def names_hidden_tag?(user)
    hidden = TagQuarantine.hidden_names_for(user)
    return false if hidden.empty?

    named = Array(self.class.names_tags_names.call(self)).compact.map(&:to_s)
    named.intersect?(hidden)
  end

  def hidden_by_post_from?(user)
    super || names_hidden_tag?(user)
  end

  def refuses_write_from?(user)
    super || names_hidden_tag?(user)
  end
end
