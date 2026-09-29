# frozen_string_literal: true

# MediaMetadata represents the EXIF and other metadata associated with a
# MediaAsset (an uploaded image or video file). The `metadata` field contains a
# JSON hash of the file's metadata as returned by ExifTool.
#
# @see ExifTool
# @see https://exiftool.org/TagNames/index.html
class MediaMetadata < ApplicationRecord
  self.table_name = "media_metadata"

  attribute :id
  attribute :created_at
  attribute :updated_at
  attribute :media_asset_id
  attribute :metadata
  belongs_to :media_asset

  def self.search(params, current_user)
    q = search_attributes(params, [:id, :created_at, :updated_at, :media_asset, :metadata], current_user: current_user)
    # fourier: a search naming a generation key (a prompt, a workflow) finds
    # nothing, for everyone -- a has-key search would list every image
    # carrying a prompt, and a value search would confirm a guessed one, across
    # every creator at once. Every association search that reaches metadata
    # (posts, media assets, uploads) arrives here. See FourierGenerationFilter.
    q = q.none if FourierGenerationFilter.search_withheld?(params)
    q.apply_default_order(params)
  end

  def file=(file_or_path)
    self.metadata = MediaFile.open(file_or_path).metadata
  end

  def metadata
    ExifTool::Metadata.new(self[:metadata])
  end

  # fourier: the metadata `user` on `request` may be SHOWN, as a plain Hash --
  # generation data (prompts, settings, workflows) withheld from everyone but
  # the creator of the post carrying this image (FourierCreatorPrivacy; not
  # admins). `metadata` itself stays whole: is_ai_generated? and the rest of
  # the app read it, and nothing that reads it sends it anywhere. Anything
  # that DOES send it somewhere uses this. See FourierGenerationFilter.
  #
  # The request defaults to the current one because the creator is known by
  # the verified Matrix identity it carries, and serializable_hash, below,
  # is reached from serializers that are handed no request.
  def visible_metadata(user = CurrentUser.user, request = CurrentUser.request)
    FourierGenerationFilter.visible(metadata, media_asset&.post, user, request)
  end

  # The API door: /media_metadata.json, and every `only=media_metadata`
  # include from posts, media assets and uploads, in JSON and XML alike
  # (the XML serializer builds from this same hash).
  def serializable_hash(...)
    hash = super
    hash["metadata"] = visible_metadata if hash.key?("metadata")
    hash
  end

  def frame_delays
    metadata["Ugoira:FrameDelays"].to_a
  end

  def self.available_includes
    [:media_asset]
  end
end
