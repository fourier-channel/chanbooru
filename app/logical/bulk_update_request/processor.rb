# frozen_string_literal: true

# Process a bulk update request. Parses the request and applies each line in
# sequence.
class BulkUpdateRequest::Processor
  # Maximum number of lines a BUR may have.
  MAXIMUM_SCRIPT_LENGTH = 100

  include ActiveModel::Validations

  # Fork: the request was refused -- a filing whose script does not pass its
  # checks (BulkUpdateRequestsController#create), or an approval whose script
  # no longer does (BulkUpdateRequest#approve!). ApplicationController answers
  # it 422 with the sentence and `errors`, one { line:, text:, reason: } per
  # script line at fault (Line#error; empty when no line is), the shape the
  # Technetium card and the bot that relays it read (technetium-81, 2026-10-19).
  class Error < StandardError
    attr_reader :errors

    def initialize(message = nil, errors: [])
      super(message)
      @errors = errors
    end
  end

  # Fork: a line of the run record keeps at most this many skipped post ids;
  # its `skipped` counts every one. A whole-site mass update whose every
  # post refused would otherwise write a million ids into one row, once a
  # line. The page and the API show at most 100, those the viewer may see
  # (BulkUpdateRequest#lines).
  SKIPPED_IDS_KEPT = 1_000

  # Fork: one line of the script -- its 1-based number in the script as
  # stored, its text as parsed, and its command.
  Line = Struct.new(:number, :text, :command) do
    # This line's entry in a refusal (Error#errors).
    def error(reason) = { line: number, text: text, reason: reason }

    # This line's entry in the record of a run (BulkUpdateRequest#results),
    # in `state`: running, done, skipped_some, failed or not_run. `matched`
    # and `skipped` are nil where nothing was counted -- a line that does not
    # retag by search matches nothing countable, a line that stopped midway
    # counted nothing that can be trusted, and a line that never ran counted
    # nothing at all. Each skip's reasons are
    # its post's validation messages, totalled by message; a post that
    # refused without one still counts, under a sentence that says so.
    def result(state, matched: nil, skipped: nil, skips: [], error: nil, remedy: nil)
      reasons = skips.flat_map { |skip| skip[:reasons].presence || ["The post could not be saved, and gave no reason"] }.tally
      {
        line: number, command: command.to_dtext, state: state, matched: matched, skipped: skipped,
        skipped_post_ids: skips.pluck(:post_id).first(SKIPPED_IDS_KEPT),
        skipped_reasons: reasons.sort_by { |_message, count| -count }.map { |message, count| { message: message, count: count } },
        error: error, remedy: remedy,
      }
    end

    # The entry for this line once its command returned `value`: what
    # MassUpdate.mass_update counted (BulkUpdateRequest::Command#process!),
    # or nothing counted.
    def finished(value)
      return result("done", skipped: 0) unless value.is_a?(Hash)

      skips = value[:skipped]
      return result("done", matched: value[:matched], skipped: 0) if skips.empty?

      remedy = "These posts did not take the whole edit: each was left unchanged, or took only part of the edit, for the reason given; every other post was updated. Fix each post, or change the line so it is valid for them, then approve this request again: the run starts again from line 1."
      result("skipped_some", matched: value[:matched], skipped: skips.size, skips: skips, remedy: remedy)
    end

    # The entry for this line when it raised `exception`, in words: a
    # record's own validation messages, or a fixed sentence. Never the raw
    # exception text or its class: a bot relays this into a community room
    # (technetium-81, 2026-10-19), and a driver's message can carry a host or
    # SQL. The raw error stays in the job's log.
    def failed(exception)
      messages = exception.record&.errors&.full_messages.presence if exception.is_a?(ActiveRecord::RecordInvalid)
      kept = "Nothing was rolled back: the lines before it were applied and kept, and the lines after it did not run."
      if messages
        result("failed", error: "Line #{number} stopped: #{messages.join("; ")}.", remedy: "#{kept} Fix what it names, then approve this request again: the run starts again from line 1.")
      else
        # Fork: the jobs pages are retired (FourierRetiredSections: a 404 to
        # all but the owner), so this names who can read the error, and where.
        result("failed", error: "Line #{number} stopped on an unexpected error.", remedy: "#{kept} Only the site owner can read the full error in the server log; once its cause is fixed, approve this request again: the run starts again from line 1.")
      end
    end
  end

  # Fork: the script lines the last validation refused (Line#error), as
  # `errors` holds its messages.
  attr_reader :line_errors

  attr_reader :bulk_update_request

  delegate :script, :forum_topic, :approver, to: :bulk_update_request
  validate :validate_script_length
  validate :validate_duplicate_lines
  validate :validate_script

  # @param bulk_update_request [BulkUpdateRequest] the BUR
  def initialize(bulk_update_request)
    @bulk_update_request = bulk_update_request
    @line_errors = []
  end

  # Fork: line_errors are the last validation's, reset with `errors`.
  def valid?(context = nil)
    @line_errors = []
    super
  end

  # Fork: parse the script into its lines, numbered as the script has them
  # (a blank line is counted, and skipped).
  def lines
    script.split(/\r\n|\r|\n/).each_with_index.filter_map do |line, index|
      text = line.gsub(/[[:space:]]+/, " ").strip
      Line.new(index + 1, text, BulkUpdateRequest::Command.parse(text)) if text.present?
    end
  end

  # Parse the script into a list of commands.
  def commands
    lines.map(&:command)
  end

  # Validate the bulk update request when it is created or approved.
  #
  # validation_context will be either :request (when the BUR is first created
  # or edited) or :approval (when the BUR is approved). Certain validations
  # only run when the BUR is requested, not when it's approved.
  def validate_script
    CurrentUser.scoped(User.system) do
      BulkUpdateRequest.transaction(requires_new: true) do
        # Fork: and note which line each error came from (line_errors).
        lines.each do |line|
          before = errors.size
          line.command.validate(context: validation_context, errors: errors)
          reasons = errors.objects.drop(before).map(&:message)
          @line_errors << line.error(reasons.join("; ")) if reasons.any?
        end

        raise ActiveRecord::Rollback
      end
    end
  end

  # Validate that the script isn't too long.
  def validate_script_length
    if commands.size > MAXIMUM_SCRIPT_LENGTH
      errors.add(:base, "Bulk update request is too long (maximum size: #{MAXIMUM_SCRIPT_LENGTH} lines). Split your request into smaller chunks and try again.")
      throw :abort
    end
  end

  def validate_duplicate_lines
    # Fork: grouped by line rather than tallied, so each repeat after the
    # first is named in line_errors.
    lines.group_by { |line| line.command.to_dtext }.values.select { |same| same.size > 1 }.each do |same|
      errors.add(:base, "Duplicate line found: #{same.first.command.to_dtext}")
      @line_errors += same.drop(1).map { |line| line.error("This line repeats line #{same.first.number}") }
    end
    throw :abort if errors.present?
  end

  # Schedule the bulk update request to be processed later, in the background.
  def process_later!
    ProcessBulkUpdateRequestJob.perform_later(bulk_update_request)
  end

  # Process the bulk update request immediately.
  #
  # Fork: and keep the record of the run on the request (results, one entry
  # a line, Line#result), written through as each line starts and ends, so a
  # long run shows where it is and a stopped one shows where it stopped:
  # each line done, or done with posts skipped (skipped_some); the line that
  # raised failed, in words, with what to do; the lines after it not run.
  # Lines before a failure stay applied, as upstream -- a request is
  # approved again from line 1, and validation, not a transaction, is the
  # all-or-nothing gate. A run that skipped any post ends "partial", which
  # can be approved again; upstream called it approved.
  def process!
    run = []
    results = []

    CurrentUser.scoped(User.system) do
      run = lines
      bulk_update_request.update!(status: "processing")

      run.each do |line|
        results << line.result("running")
        bulk_update_request.update!(results: results.as_json)
        results[-1] = line.finished(line.command.process!(approver: approver, forum_topic: forum_topic))
        bulk_update_request.update!(results: results.as_json)
      end

      bulk_update_request.update!(status: results.pluck(:state).include?("skipped_some") ? "partial" : "approved")
    rescue StandardError => e
      results[-1] = run[results.size - 1].failed(e) if results.last&.dig(:state) == "running"
      results += run.drop(results.size).map { |line| line.result("not_run") }
      bulk_update_request.update!(status: "failed", results: results.as_json)
      raise
    end
  end

  # The list of tags in the script. Used to search BURs by tag.
  # @return [Array<String>] the list of tags
  def affected_tags
    commands.flat_map(&:affected_tags).sort.uniq
  end

  # Convert the BUR to DText format.
  # @return [String]
  def to_dtext
    commands.map(&:to_dtext).join("\n")
  end

  # @param tags [Array<Tag>, nil] preloaded tags to look up instead of querying individually. Used to filter for approvable BURs by the controller without hitting n+1 issues.
  # @return [Integer] the minimum level required to approve this BUR.
  # @see User::Levels
  def approval_level(tags: nil)
    commands.map { |command| command.approval_level(tags:) }.max
  end
end
