# frozen_string_literal: true

# Applies a tag edit to all posts matching a search query.
# The left-hand side is a post search and the right-hand side is a string that will be added to that post's tag string.
class BulkUpdateRequest::Command::MassUpdate < BulkUpdateRequest::Command
  def self.regex
    /\A(?:mass update|update) (?<first_search>.+?) -> (?<second_search>.*)\z/i
  end

  def initialize(params)
    @first_search = params[:first_search]
    @second_search = params[:second_search]
  end

  def from_query
    PostQuery.new(@first_search)
  end

  def to_query
    PostQuery.new(@second_search)
  end

  def affected_tags
    from_query.tag_names + to_query.tag_names
  end

  def process!(**)
    self.class.mass_update(@first_search, @second_search)
  end

  def to_dtext
    lhs = PostQuery.normalize(@first_search, apply_aliases: false)
    rhs = PostQuery.normalize(@second_search, apply_aliases: false)

    lhs_link = lhs.is_simple_tag? ? "[[#{@first_search}]]" : "{{#{@first_search}}}"
    rhs_link = rhs.is_simple_tag? ? "[[#{@second_search}]]" : "{{#{@second_search}}}"

    "mass update #{lhs_link} -> #{rhs_link}"
  end

  def validate(errors:, **)
    if from_query.is_null_search?
      errors.add(:base, "Can't mass update {{#{@first_search}}} -> {{#{@second_search}}} (the search {{#{@first_search}}} has a syntax error)")
    end
  end

  # Fork: returns { matched:, skipped: [{ post_id:, reasons: }] } -- every
  # post the search matched, and each one that did not take the whole edit,
  # with its reasons, logged as it is skipped. A post did not take it when
  # its save refused (its validation messages; the post is unchanged), or
  # when it saved without part of the edit: Post leaves out a deprecated or
  # invalid tag it was given and keeps a tag an implication holds, and only
  # warns (added_tags_are_valid, removed_tags_are_valid), so what it left out
  # is read off the saved post and said in Post's own words. Upstream
  # dropped save's answer, so neither was told. The block runs on pool
  # threads (parallel_find_each), hence the concurrent counter and list.
  # Any other exception still propagates and fails the line.
  def self.mass_update(antecedent, consequent, user: User.system)
    matched = Concurrent::AtomicFixnum.new
    skipped = Concurrent::Array.new

    CurrentUser.scoped(user) do
      # Every matching post, whoever may see it (Post.bulk_tag_match).
      Post.bulk_tag_match(antecedent, User.anonymous).reorder(nil).parallel_find_each do |post|
        matched.increment
        post.with_lock do
          post.tag_string += " #{consequent}"
          if post.save
            edit = post.post_edit
            left_out = (edit.user_added_tag_names - post.tag_array) | (post.tag_array & edit.user_removed_tag_names)
            next if left_out.empty?

            said = post.warnings.full_messages.select { |message| message.start_with?("Couldn't add tag") || left_out.any? { |name| message.include?("[[#{name}]]") } }
            reasons = said.presence || ["#{left_out.map { |name| "[[#{name}]]" }.to_sentence} could not be changed on this post"]
          else
            reasons = post.errors.full_messages
          end
          skipped << { post_id: post.id, reasons: reasons }
          DanbooruLogger.info("post ##{post.id}: skipped by mass update #{antecedent} -> #{consequent}: #{reasons.join("; ")}")
        end
      end
    end

    { matched: matched.value, skipped: skipped.to_a }
  end
end
