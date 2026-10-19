# frozen_string_literal: true

class BulkUpdateRequest < ApplicationRecord
  # The quarantine's name half (NamesTags, TagQuarantine): rows naming a
  # flagged or banished tag are withheld from the viewers its name is.
  prepend NamesTags

  names_tags(->(names) { ["bulk_update_requests.tags && ARRAY[:names]::text[]", { names: names }] }, &:tags)

  # Fork: "partial" -- the run reached the end but skipped posts that
  # refused the edit (Processor#process!); it can be approved again, as a
  # failed one can.
  STATUSES = %w[pending approved rejected processing failed partial]

  # Fork: the reason is a column (it lived only in the forum post), so a
  # request keeps it while the forum is retired; the title only ever named
  # the topic.
  attr_accessor :title

  # defines :dtext_reason
  #
  # Fork: the media embed limits are checked when the reason is written, not
  # on every save. dtext_attribute picks its condition when the class loads,
  # before the column's reason_changed? exists, so given the limits it
  # checked them whenever the reason was present -- and once the reason is a
  # column, a post embedded in it and rerated since made every later save
  # (approve!, reject!, each line a run records, the pruner) raise. Given
  # `true` it parses the embeds and its own check has no limits to apply.
  dtext_attribute :reason, media_embeds: true
  # XXX media embed validations must match forum post validations
  validates :reason, media_embed: { max_embeds: 5, max_large_emojis: 5, max_small_emojis: 100, max_video_size: 1.megabyte, sfw_only: true }, if: :reason_changed?

  belongs_to :user
  belongs_to :forum_topic, optional: true
  belongs_to :forum_post, optional: true
  belongs_to :approver, optional: true, class_name: "User"

  has_many :votes, through: :forum_post

  delegate :approval_level, to: :processor

  normalizes :script, with: ->(script) { script.to_s.unicode_normalize(:nfc).normalize_whitespace.strip }

  # XXX these validations must match the forum post validations
  validates :reason, visible_string: true, length: { maximum: 20_000 }, on: :create
  validates :title, visible_string: true, length: { maximum: 200 }, on: :create, if: ->(bur) { bur.forum_topic_id.blank? && !bur.forum_retired? }

  validates :script, visible_string: true, length: { maximum: 20_000 }, if: :script_changed?
  # Fork: while the forum is retired a request is attached to no topic or post (forum_retired?).
  validate if: -> { forum_retired? && (forum_topic_id_changed? || forum_post_id_changed?) && (forum_topic_id || forum_post_id).present? } do
    errors.add(:base, "Forum topics are retired on this site, so a request cannot be attached to one. Send the request without forum_topic_id or forum_post_id")
  end
  validates :forum_topic, presence: true, if: ->(bur) { bur.forum_topic_id.present? }
  validates :forum_post, presence: true, if: ->(bur) { bur.forum_post_id.present? }
  validates :status, inclusion: { in: STATUSES }
  validate :validate_script, if: :script_changed?
  validates_associated :forum_topic, if: :forum_topic_changed?
  validates_associated :forum_post, if: :forum_post_changed?

  before_save :update_tags, if: :script_changed?
  # Fork: the record of the last run (results) describes the script that
  # ran. An edit clears it: its line numbers and commands would no longer
  # match the script, and a command in it could name a tag the edit took
  # out of `tags`, by which NamesTags judges who may read the row.
  before_save -> { self.results = [] }, if: -> { persisted? && script_changed? }
  # Fork: no topic while the forum is retired (forum_retired?).
  after_create :create_forum_topic, unless: -> { forum_retired? }

  scope :pending_first, -> { order(Arel.sql("(case status when 'processing' then 0 when 'pending' then 1 when 'approved' then 2 when 'rejected' then 3 when 'failed' then 4 when 'partial' then 5 else 6 end)")) }
  scope :pending, -> { where(status: "pending") }
  scope :approved, -> { where(status: "approved") }
  scope :rejected, -> { where(status: "rejected") }
  scope :processing, -> { where(status: "processing") }
  scope :failed, -> { where(status: "failed") }
  scope :has_topic, -> { where.not(forum_topic: nil) }

  module SearchMethods
    def search(params, current_user)
      q = search_attributes(params, [:id, :created_at, :updated_at, :script, :tags, :user, :forum_topic, :forum_post, :approver], current_user: current_user)

      statuses = params[:status].to_s.split(",")

      if statuses.present?
        q = q.where(status: statuses)
      end

      # Fork: judged over the statuses asked for, by the policy the
      # can_approve field answers from (#can_approve), so a partial, failed
      # or rejected request an admin may approve again is found by it. With
      # no status it is upstream's queue: the pending requests.
      if params[:can_approve].present?
        can_approve = params[:can_approve].to_s.truthy?
        candidates = statuses.present? ? q : q.pending
        tags = Tag.where(name: candidates.select(Arel.sql("unnest(tags)"))).to_a

        ids = candidates.select { |bur| Pundit.policy!(current_user, bur).approve?(tags:) == can_approve }.map(&:id)
        q = q.where(id: ids)
      end

      params[:order] ||= "status_desc"

      if params[:score].present? || params[:order].in?(%w[score score_desc score_asc])
        q = q.with_score
      end

      if params[:score].present?
        q = q.where_numeric_matches(:score, params[:score])
      end

      case params[:order]
      when "id_desc"
        q = q.order(id: :desc)
      when "id_asc"
        q = q.order(id: :asc)
      when "updated_at_desc"
        q = q.order(updated_at: :desc)
      when "updated_at_asc"
        q = q.order(updated_at: :asc)
      when "score", "score_desc"
        q = q.order(score: :desc, id: :desc)
      when "score_asc"
        q = q.order(score: :asc, id: :desc)
      else
        q = q.apply_default_order(params)
      end

      q
    end

    def with_score
      subquery = left_outer_joins(:votes).group(:id).select("bulk_update_requests.*")
      subquery = subquery.select("COALESCE(SUM(forum_post_votes.score), 0) AS score")
      from(subquery.arel.as("bulk_update_requests"))
    end
  end

  module ApprovalMethods
    def forum_updater
      @forum_updater ||= ForumUpdater.new(forum_topic)
    end

    def approve!(approver)
      transaction do
        CurrentUser.scoped(approver) do
          # Fork: a script that no longer passes its checks (a line gone
          # stale since it was filed: another alias now conflicts) is refused
          # with its reasons and the lines at fault, before anything is
          # written -- the request keeps its status and approver. Upstream's
          # validate! raised a bare ActiveModel::ValidationError: a 500 with
          # no words. Rejecting is offered to an approver who may reject it
          # (destroy?: a pending request, an admin or its requester). The
          # words name no tag the approver may not be shown (withheld).
          unless processor.valid?(:approval)
            messages, line_errors = withheld(processor.errors.full_messages, processor.line_errors, approver)
            raise BulkUpdateRequest::Processor::Error.new(
              "BUR ##{id} was not approved and is unchanged. Its script no longer passes the checks: #{messages.join("; ")}. " \
              "Fix: edit its script on the booru so every line is valid today, then approve it again#{", or reject it" if policy(approver).destroy?}.",
              errors: line_errors,
            )
          end
          # Fork: and clear the last run's record (results), so a retry
          # never shows the previous run's failure or skips.
          update!(status: "processing", approver: approver, results: [])
          processor.process_later!
          forum_updater.update("The #{bulk_update_request_link} (forum ##{forum_post.id}) has been approved by @#{approver.name}.") if forum_post.present?
        end
      end
    end

    def create_forum_topic
      body = "[bur:#{id}]\n\n#{reason}"

      self.forum_topic = ForumTopic.new(title: title, category: "Tags", creator: user) unless forum_topic.present?
      self.forum_post = forum_topic.forum_posts.build(body: body, creator: user) unless forum_post.present?

      save!
    end

    def reject!(rejector = User.system)
      transaction do
        update!(status: "rejected")
        forum_updater.update("The #{bulk_update_request_link} (forum ##{forum_post.id}) has been rejected by @#{rejector.name}.") if forum_post.present?
      end
    end

    def bulk_update_request_link
      %{"bulk update request ##{id}":#{Routes.bulk_update_requests_path(search: { id: id })}}
    end
  end

  def validate_script
    @line_errors = []

    # Fork: a request naming a quarantined tag the requester may not be
    # shown (TagQuarantine) is refused without naming which -- and BEFORE
    # the script's own checks, whose words (a rename refused because its
    # tag "is flagged for review") would say more than the refusal may.
    #
    # A posting bot (TagBanishment.pipeline?: tunnel, sample) files for a
    # person whose sight it does not know, and itself sees every name; so
    # what it files may name only what a signed-out visitor may, on every
    # change of the script (operator, 2026-10-19). The lines at fault are
    # listed with a reason that names no tag.
    bot = TagBanishment.pipeline?(CurrentUser.user)
    if new_record? || bot
      hidden = TagQuarantine.hidden_names_for(bot ? User.anonymous : CurrentUser.user)
      naming = processor.lines.select { |line| line.command.affected_tags.intersect?(hidden) }
      if naming.any?
        @line_errors = naming.map { |line| line.error("This line names a tag only an admin may change") }
        return errors.add(:base, "This request names a tag only an admin may change. Ask an admin to make it")
      end
    end

    if processor.invalid?(:request)
      messages, @line_errors = withheld(processor.errors.full_messages, processor.line_errors, bot ? User.anonymous : CurrentUser.user)
      messages.each { |error| errors.add(:base, error) }
    end
  rescue CreatorPrefixes::ConfigError => e
    # Fork: while the creator-prefix list is broken nothing can say whether
    # the filer is a posting bot (TagBanishment.pipeline? asks
    # CreatorPrefixes.editor?, which raises), and every filing below admin
    # answered 500. Refused in words instead, as a locked tag edit is; what
    # is wrong with the list goes to the log, since the refusal reaches a
    # room through the bot (technetium-81, 2026-10-19).
    Rails.logger.error("bulk update request: not checked, the creator-prefix list is broken: #{e.message}")
    @line_errors = []
    errors.add(:base, "This request cannot be checked while the creator-prefix list is broken; the server log says what is wrong. The site owner fixes the list, then try again")
  end

  # Fork: the script's own checks run with the system account's sight
  # (Processor#validate_script), so their words can name a quarantined tag
  # the script does not -- "x is already aliased to <a banished name>",
  # "x is aliased to <a flagged name>". `messages` and `line_errors` as
  # `viewer` may read them: each one naming a tag hidden from the viewer
  # (TagQuarantine.hidden_names_for; a filing bot reads as a signed-out
  # visitor) is replaced by a sentence that names none. The line and its
  # text are the filer's own words and stay.
  def withheld(messages, line_errors, viewer)
    hidden = TagQuarantine.hidden_names_for(viewer).flat_map { |name| [name, name.tr("_", " ")] }.uniq
    return [messages, line_errors] if hidden.empty?

    names = /(?<![[:alnum:]_])#{Regexp.union(hidden)}(?![[:alnum:]_])/
    [
      messages.map { |message| message.match?(names) ? "A line conflicts with a tag only an admin may change. Ask an admin to make it" : message }.uniq,
      line_errors.map { |error| error[:reason].match?(names) ? error.merge(reason: "This line conflicts with a tag only an admin may change") : error },
    ]
  end

  # Fork: is the forum retired (FourierRetiredSections: it 404s for everyone
  # but the owner)? Then a request opens no topic and needs no title for
  # one, keeps its reason on itself, may not be attached to a topic or post,
  # and serves neither through ?only= -- every link it answers with goes to
  # the request. Asked on each call: the list is configuration.
  def self.forum_retired?
    Danbooru.config.retired_sections.include?("forum_topics")
  end

  delegate :forum_retired?, to: :class

  # Fork: the script lines the last validation refused, each { line:, text:,
  # reason: } (BulkUpdateRequest::Processor::Line#error) -- what a refused
  # filing answers with (BulkUpdateRequestsController#create).
  def line_errors
    @line_errors.to_a
  end

  # Fork: may the viewer approve, or reject, this request -- asked of the
  # policy methods the approve and destroy actions authorize against, so the
  # JSON (BulkUpdateRequestPolicy#api_attributes), the page's buttons and the
  # actions cannot disagree. They say "may attempt": the action authorizes
  # again, and an approval can still be refused (Processor::Error, 422).
  # Named without "?": the name is the JSON key, which ?only= selects by.
  def can_approve # rubocop:disable Naming/PredicateMethod
    policy(CurrentUser.user).approve?
  end

  def can_reject # rubocop:disable Naming/PredicateMethod
    policy(CurrentUser.user).destroy?
  end

  # Fork: the record of the last run (results, written by
  # Processor#process!) as the viewer may read it, one entry a script line:
  # { line:, command:, state:, matched:, skipped:, skipped_post_ids:,
  # skipped_reasons: [{ message:, count: }], error:, remedy: }. Each line's
  # skipped post ids are held to the posts the viewer may see
  # (Post.visible_ids_among), at most 100: a bulk retag reaches deleted,
  # gated and creator-hidden posts too (Post.bulk_tag_match). The counts and
  # reasons are the same for every reader (operator default, 2026-10-19).
  # The raw column, which holds every id, is never served
  # (BulkUpdateRequestPolicy#api_attributes).
  def lines
    visible = Post.visible_ids_among(results.flat_map { |line| line["skipped_post_ids"].to_a }, CurrentUser.user).to_set
    results.map { |line| line.merge("skipped_post_ids" => line["skipped_post_ids"].to_a.select { |id| visible.include?(id) }.first(100)) }
  end

  # Fork: the skips of the last run, summed over its lines: a post skipped
  # by two lines counts twice, so it is a count of post edits, not of posts.
  def skipped_count
    results.sum { |line| line["skipped"].to_i }
  end

  # Fork: the script line the last run stopped at, or nil.
  def failed_line
    results.find { |line| line["state"] == "failed" }&.dig("line")
  end

  extend SearchMethods
  include ApprovalMethods

  def update_tags
    self.tags = processor.affected_tags
  end

  def processor
    @processor ||= BulkUpdateRequest::Processor.new(self)
  end

  def has_too_many_votes_to_edit?
    (forum_post&.votes&.count.presence || 0) >= 5
  end

  def is_pending?
    status == "pending"
  end

  def is_approved?
    status.in?(%w[approved processing])
  end

  def is_rejected?
    status == "rejected"
  end

  def self.available_includes
    # Fork: a request filed before the forum was retired would otherwise
    # serve its topic and post (?only=forum_post[body]) to whoever reads it.
    forum_retired? ? [:user, :approver] : [:user, :forum_topic, :forum_post, :approver]
  end
end
