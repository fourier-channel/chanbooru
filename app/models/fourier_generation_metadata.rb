# frozen_string_literal: true

# AI generation data -- prompts, settings, workflows -- that the tunnel took
# OUT of an image before posting it (operator ruling 2026-09-28). The file the
# booru serves is the stripped one, so this record is the only copy, and it is
# PRIVATE to the creator of the post that carries the image (operator ruling
# 2026-09-29). Not admins, not moderators, not the posting bot that wrote it.
# FourierCreatorPrivacy is that rule; this class stores, and decides which
# record a post is served (for_post).
#
# One record per md5 -- the md5 of the STRIPPED bytes, which is the md5 the
# post and its media asset carry. `raw_md5` is the md5 of the bytes the tunnel
# was handed, before stripping: it does not move when the strip rules do, so
# GET /fourier/generation_metadata/raw/:raw_md5.json finds the post an
# original was posted as under any rules.
#
# Written only by POST /fourier/generation_metadata.json
# (FourierGenerationMetadataController). `raw_md5` and `source` are set by the
# first write and never change. `fields` are replaced by a later write only
# when it names the same original (raw_md5) and the same poster, or no poster
# at all (an admin's !rescan re-read); anything else is refused with a 409
# that says which, and nothing changes.
#
# THE OWNER IS `poster`, and a record is SERVED only while its owner is the
# CURRENT post's recorded creator (FourierPostCreator) -- see for_post. The
# record is keyed by md5 and outlives its post: an expunged post frees its
# md5, and whoever uploads the same bytes next has a new post, a new creator
# (or none), and must not inherit the first creator's prompt (round-two
# findings 3 and 13). A write with no poster (a !rescan) adopts the recorded
# creator of the post that holds the md5 when the record has no owner yet,
# and leaves it ownerless -- served to nobody -- when there is none. An owner,
# once set, never changes.
#
# `fields` maps a field key naming where the text came from to the original
# text, unmodified:
#   png:<keyword>     a PNG tEXt/iTXt/zTXt chunk (png:parameters, png:prompt,
#                     png:workflow, png:Comment, png:Description, ...),
#                     including ImageMagick's png:exif:<TagName> mirrors and
#                     png:stealth, the payload a generator hid in the alpha
#                     channel's low bits
#   exif:<TagName>    an EXIF field (exif:UserComment, exif:ImageDescription,
#                     exif:XPComment, exif:Make, exif:Model, ...)
#   iptc:<Name>       an IPTC dataset, by ExifTool's name (iptc:Caption-Abstract)
#   xmp, webp:xmp     an XMP packet
#   jpeg:COM          a JPEG comment segment
#   gif:Comment       a GIF comment extension
# The whole list the tunnel can send is pinned, as a list, in
# test/functional/fourier_generation_metadata_controller_test.rb and in
# fourier-tunnel's strip-generation.test.js.
class FourierGenerationMetadata < ApplicationRecord
  self.table_name = "fourier_generation_metadata"

  SOURCES = %w[matrix discord].freeze
  MD5 = /\A[0-9a-f]{32}\z/
  # Who posted the image, as the sender named them: a Matrix user id or a
  # Discord account. The record's OWNER: it decides who may REPLACE the
  # fields, and the record is served only while it is the post's recorded
  # creator (for_post). Who may READ it is then the post's creator
  # (FourierCreatorPrivacy). A Discord poster owns a record nobody is served
  # yet: no Discord creator can be recorded. No control characters: a NUL
  # here is a 500 from the database, not a 422.
  POSTER = /\A(?:@[^:\s\x00-\x1f\x7f]+:[^\s\x00-\x1f\x7f]+|discord:[0-9]+)\z/
  MAX_POSTER_LENGTH = 255
  # The grammar of a field key; see the class comment. A PNG keyword is 1 to
  # 79 printable characters (PNG spec 11.3.4.2); an IPTC name is ExifTool's,
  # which may carry a hyphen (Caption-Abstract, Writer-Editor). gif:Comment is
  # a literal: a GIF has one comment carrier, and the tunnel names it so.
  FIELD_KEY = /\A(?:png:[^\x00-\x1f\x7f]{1,79}|exif:[A-Za-z][A-Za-z0-9]{0,63}|iptc:[A-Za-z][A-Za-z0-9-]{0,63}|xmp|webp:xmp|jpeg:COM|gif:Comment)\z/
  # Keys plus values, in bytes. A ComfyUI workflow is tens of kilobytes; four
  # megabytes is room for several and still refuses a body that is not text
  # taken out of one image.
  MAX_FIELDS_BYTES = 4 * 1024 * 1024

  validates :md5, format: { with: MD5 }, uniqueness: true
  validates :raw_md5, format: { with: MD5 }, allow_nil: true
  validates :source, inclusion: { in: SOURCES }
  validates :poster, format: { with: POSTER }, length: { maximum: MAX_POSTER_LENGTH }, allow_nil: true

  def self.valid_md5?(md5)
    md5.is_a?(String) && md5.match?(MD5)
  end

  def self.valid_poster?(poster)
    poster.is_a?(String) && poster.length <= MAX_POSTER_LENGTH && poster.match?(POSTER)
  end

  # The record SERVED for this post: the one filed under its md5, and only
  # while its owner is the post's recorded creator. Nil otherwise -- no record,
  # an ownerless one, one whose owner made an earlier post with these bytes,
  # or a post with no recorded creator at all -- and every caller answers nil
  # exactly as it answers "nothing was filed". Who may then READ it is
  # FourierCreatorPrivacy's question, asked separately.
  def self.for_post(post)
    return nil unless valid_md5?(post&.md5)

    record = find_by(md5: post.md5)
    record if record&.owned_by?(FourierPostCreator.where(post_id: post.id).pick(:mxid))
  end

  # The recorded creator of the post that holds `md5` now, or nil: the owner a
  # write with no poster adopts.
  def self.recorded_creator_for(md5)
    FourierPostCreator.joins(:post).where(posts: { md5: md5 }).pick(:mxid)
  end

  # Is `mxid` this record's owner? An MXID compares case-insensitively, as
  # FourierIdentity compares one; an ownerless record is nobody's.
  def owned_by?(mxid)
    FourierPostCreator.same_mxid?(poster, mxid)
  end

  # Total size of a fields hash as MAX_FIELDS_BYTES counts it.
  def self.fields_bytes(fields)
    fields.sum { |key, value| key.to_s.bytesize + value.to_s.bytesize }
  end

  # May a write naming `poster` replace this record's fields? The poster the
  # record was first written with, or none -- an admin-initiated re-read,
  # which carries no sender. An MXID compares case-insensitively, as
  # FourierIdentity compares one.
  def replaceable_by?(poster)
    return true if poster.nil?
    return false if self.poster.nil?

    poster.start_with?("@") ? self.poster.casecmp?(poster) : self.poster == poster
  end

  # The read. Carries the field text, so it goes only to a viewer
  # FourierCreatorPrivacy has admitted for the post carrying this image.
  def api_payload
    {
      md5: md5,
      source: source,
      fields: fields,
      created_at: created_at,
      updated_at: updated_at,
    }
  end
end
