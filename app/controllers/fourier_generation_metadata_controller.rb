# frozen_string_literal: true

# AI generation data the tunnel took out of an image before posting it
# (operator ruling 2026-09-28), readable by the post's creator alone (ruling
# 2026-09-29, FourierCreatorPrivacy). See FourierGenerationMetadata.
#
# POST /fourier/generation_metadata.json   builder+ (the posting bots)
#   { md5: "<md5 of the STRIPPED bytes>", raw_md5: "<md5 before stripping>",
#     source: "matrix" | "discord",
#     poster: "@alice:41chan.net" | "discord:<id>" | null,
#     fields: { "png:parameters": "<original text>", ... } }
#   -> 200 { md5, stored: <number of fields> }. Upsert by md5. raw_md5 and
#   source are kept from the first write, and so is poster, the record's
#   owner -- except that a write with poster null (an admin's !rescan
#   re-read) to a record with no owner adopts the recorded creator of the
#   post holding the md5, if there is one (FourierGenerationMetadata). The
#   response NEVER echoes field text.
#   -> 409 { error, fix, reason }, nothing changed, where `reason` is one of
#        raw_md5_conflict   no record for this md5, and this raw_md5 is
#                           already filed under ANOTHER md5
#        raw_md5_mismatch   the record for this md5 was filed from a
#                           different original (another raw_md5)
#        poster_mismatch    the record for this md5 was filed by a different
#                           poster; only that poster or a re-read replaces it
#      Only poster_mismatch means "the booru kept the record it already has
#      for this post". The other two mean this send was not recorded.
#
# GET /fourier/generation_metadata/raw/:raw_md5.json   builder+
#   -> 200 { md5 } for the record an original was filed under, or 404. No
#   field text. How the tunnel finds the post an original became, whatever
#   the strip rules were when it was posted.
#
# GET /posts/:post_id/generation_data.json   the browser read
#   -> 200 { md5, source, fields, created_at, updated_at } for a viewer
#   FourierCreatorPrivacy admits for that post, when the record is the one
#   this post's creator owns (FourierGenerationMetadata.for_post); the same
#   404 for everyone else AND for a post or record that does not exist, so
#   the answer never says whether there was one.
#
# The two bot routes are under /fourier/, which nginx hands to fourier-auth:
# only a caller on the danbooru container itself (the bots) reaches them. The
# browser read is NOT under /fourier/ -- it has to reach Rails through nginx,
# with the identity lookup nginx does for every other page.
class FourierGenerationMetadataController < ApplicationController
  # The body is read field by field below, never mass-assigned, so there is
  # nothing to wrap -- and wrapping would copy up to four megabytes of field
  # text into a second params key for nothing. (FourierTagSourcesController
  # documents the other half of this trap: a wrapped key list that is missing
  # a key drops it silently.)
  wrap_parameters false
  respond_to :json

  def show
    skip_authorization # the gate is FourierCreatorPrivacy below, per post and per request

    post = Post.find_by(id: params[:post_id])
    record = FourierGenerationMetadata.for_post(post) if post
    # ONE raise for "no such post", "no record" (for_post answers nil for a
    # record this post's creator does not own, too) and "not yours". The
    # error page carries the exception's class, message and backtrace, so two
    # raise sites would answer from two lines and tell the cases apart.
    raise ActiveRecord::RecordNotFound unless record && FourierCreatorPrivacy.visible_to?(post, CurrentUser.user, request)

    render json: record.api_payload, status: 200
  end

  def raw
    raise User::PrivilegeError unless CurrentUser.user.is_builder?
    skip_authorization # gated on is_builder? above

    raw_md5 = params[:raw_md5]
    unless FourierGenerationMetadata.valid_md5?(raw_md5)
      return invalid("raw_md5 must be 32 lowercase hex characters, got #{raw_md5.to_s.first(40).inspect}",
                     "send the md5 of the bytes as they arrived, before stripping, as lowercase hex")
    end

    md5 = FourierGenerationMetadata.where(raw_md5: raw_md5).pick(:md5)
    if md5.nil?
      return render json: {
        error: "no record for raw_md5 #{raw_md5}",
        fix: "none needed: this original has not been filed, so it is not a known duplicate",
      }, status: 404
    end

    render json: { md5: md5 }, status: 200
  end

  def create
    raise User::PrivilegeError unless CurrentUser.user.is_builder?
    skip_authorization # gated on is_builder? above, as FourierTagSourcesController is

    md5 = params[:md5]
    unless FourierGenerationMetadata.valid_md5?(md5)
      return invalid("md5 must be 32 lowercase hex characters, got #{md5.to_s.first(40).inspect}",
                     "send the md5 of the STRIPPED bytes -- the file the booru holds -- as lowercase hex")
    end

    raw_md5 = params[:raw_md5]
    unless FourierGenerationMetadata.valid_md5?(raw_md5)
      return invalid("raw_md5 must be 32 lowercase hex characters, got #{raw_md5.to_s.first(40).inspect}",
                     "send the md5 of the bytes as they arrived, before anything was stripped, as lowercase hex")
    end

    source = params[:source]
    unless FourierGenerationMetadata::SOURCES.include?(source)
      return invalid("source must be one of #{FourierGenerationMetadata::SOURCES.join(", ")}, got #{source.to_s.first(40).inspect}",
                     "send \"matrix\" for a Matrix upload or \"discord\" for a Discord one")
    end

    poster = params[:poster]
    unless poster.nil? || FourierGenerationMetadata.valid_poster?(poster)
      return invalid("poster must be an MXID, discord:<numeric id>, or null, with no spaces or control characters",
                     "send the posting account as @user:server or discord:<id>, or null for an admin's re-read")
    end

    fields = params[:fields]
    fields = fields.to_unsafe_h if fields.is_a?(ActionController::Parameters)
    unless fields.is_a?(Hash) && fields.any?
      return invalid("fields must be a non-empty object",
                     "send {\"fields\": {\"png:parameters\": \"<original text>\"}} -- one key per field taken out of the image")
    end

    bad_key = fields.keys.find { |key| !key.to_s.match?(FourierGenerationMetadata::FIELD_KEY) }
    if bad_key
      return invalid("field key #{bad_key.to_s.first(80).inspect} is not one this endpoint knows",
                     "name each field png:<keyword>, exif:<TagName>, iptc:<Name>, xmp, webp:xmp, jpeg:COM or gif:Comment")
    end

    bad_value = fields.keys.find { |key| !fields[key].is_a?(String) }
    if bad_value
      return invalid("field #{bad_value.to_s.first(80).inspect} must be a string",
                     "send each field's original text as a string, unparsed")
    end

    # Postgres refuses a NUL anywhere in jsonb, and refusing it here is a 422
    # the sender can act on instead of a 500 from the database.
    nul_value = fields.keys.find { |key| fields[key].include?("\u0000") }
    if nul_value
      return invalid("field #{nul_value.to_s.first(80).inspect} contains a NUL character, which cannot be stored",
                     "remove NUL characters from field text before sending (a C string's terminator is not part of the text)")
    end

    bytes = FourierGenerationMetadata.fields_bytes(fields)
    if bytes > FourierGenerationMetadata::MAX_FIELDS_BYTES
      return render json: {
        error: "fields total #{bytes} bytes, over the #{FourierGenerationMetadata::MAX_FIELDS_BYTES}-byte limit",
        fix: "send only generation data (prompts, settings, workflows); anything larger is not text taken out of one image",
      }, status: 413
    end

    upsert!(md5, raw_md5, source, poster, fields)
  end

  private

  def invalid(error, fix)
    render json: { error: error, fix: fix }, status: 422
  end

  # A 409 carries `reason`, one fixed word per cause, for the sender to branch
  # on: the error text is for a person and may change.
  def conflict(reason, error, fix)
    render json: { error: error, fix: fix, reason: reason }, status: 409
  end

  # Upsert by md5, under the write rules on FourierGenerationMetadata. Two
  # sends racing for a new md5 both miss the find and one loses the unique
  # index; that one retries once and lands on the existing-record branch.
  def upsert!(md5, raw_md5, source, poster, fields)
    attempts = 0
    begin
      record = FourierGenerationMetadata.find_by(md5: md5)
      if record.nil?
        taken = FourierGenerationMetadata.where(raw_md5: raw_md5).pick(:md5)
        if taken
          return conflict("raw_md5_conflict", "raw_md5 #{raw_md5} is already filed under md5 #{taken}",
                          "this original was posted before: look it up with GET /fourier/generation_metadata/raw/#{raw_md5}.json and treat this upload as a duplicate of that post; nothing was recorded for md5 #{md5}")
        end

        owner = poster || FourierGenerationMetadata.recorded_creator_for(md5)
        record = FourierGenerationMetadata.create!(md5: md5, raw_md5: raw_md5, source: source, poster: owner, fields: fields)
      elsif record.raw_md5.present? && record.raw_md5 != raw_md5
        return conflict("raw_md5_mismatch", "the record for md5 #{md5} was filed from a different original (raw_md5 #{record.raw_md5}, not #{raw_md5})",
                        "two originals stripped to the same bytes, and the record keeps the first one's text; nothing was changed. If this original's text is the one wanted, that is an admin's database change")
      elsif record.replaceable_by?(poster)
        changes = { fields: fields }
        changes[:poster] = FourierGenerationMetadata.recorded_creator_for(md5) if poster.nil? && record.poster.nil?
        record.update!(changes.compact)
      else
        return conflict("poster_mismatch", "the record for md5 #{md5} was filed by a different poster, and only that poster or an admin's re-read (poster null) may replace it",
                        "none needed: the booru kept the record it already has for this post; send the original poster, or null for an admin-initiated re-read, to replace it")
      end
    rescue ActiveRecord::RecordNotUnique
      attempts += 1
      retry if attempts == 1
      raise
    end

    render json: { md5: record.md5, stored: record.fields.size }, status: 200
  end
end
