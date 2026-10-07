# frozen_string_literal: true

# MediaMetadata represents the EXIF and other metadata associated with a
# MediaAsset (an uploaded image or video file). The `metadata` field contains a
# JSON hash of the file's metadata as returned by ExifTool.
#
# @see ExifTool
# @see https://exiftool.org/TagNames/index.html
class MediaMetadata < ApplicationRecord
  # Fork: rows name posts: a media asset and the post on it. Listing them is
  # members only (MembersOnly, ApplicationRecord.names_posts?).
  def self.names_posts? = true

  self.table_name = "media_metadata"

  attribute :id
  attribute :created_at
  attribute :updated_at
  attribute :media_asset_id
  attribute :metadata
  belongs_to :media_asset

  # fork: the metadata of an asset the viewer may not see is not theirs to
  # read either. MediaAssetPolicy#can_see_image? hides an UNPOSTED asset from
  # everyone but an admin and its uploader (unposted_media_assets_restricted?),
  # and /media_metadata.json went on listing every asset's ExifTool output to
  # anyone, unposted ones included. Every Matrix image has an unposted asset
  # (fourier-tunnel canon.js, 2026-10-01), DM pictures among them, and a phone
  # photo's metadata is its camera, its timestamps and, where the phone wrote
  # one, its GPS position. A posted asset is unchanged here.
  def self.visible(user)
    return all unless Danbooru.config.unposted_media_assets_restricted?
    return all if user.is_admin?

    posted = MediaAsset.where(md5: Post.select(:md5)).select(:id)
    uploaded = UploadMediaAsset.joins(:upload).where(uploads: { uploader_id: user.id }).select(:media_asset_id)
    where(media_asset_id: posted).or(where(media_asset_id: uploaded))
  end

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
    # fork: nothing of an asset the viewer may not see. The listing is scoped
    # by MediaMetadata.visible; this covers the includes that reach a row from
    # an upload a moderator can list (?only=media_assets[media_metadata]).
    return {} if media_asset.present? && !MediaAssetPolicy.new(user, media_asset).can_see_image?

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
