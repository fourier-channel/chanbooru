# frozen_string_literal: true

# Sidecar provenance for a post's tags (the redesigned tag buckets). Rides
# alongside Danbooru's denormalised tag_string without touching core tables.
# One row per (post, tag). `source` is a bitflag so a tag can be several sources
# at once (creator AND auto => the "both" bucket). Also carries creator
# attribution and the created_at used for the grace-period edit lock.
class FourierTagSource < ApplicationRecord
  belongs_to :post

  # source bitflags
  CREATOR = 1
  AUTO    = 2
  HUMAN   = 4
  META    = 8

  # status
  APPROVED = 0
  PENDING  = 1

  scope :approved, -> { where(status: APPROVED) }
  scope :pending,  -> { where(status: PENDING) }
  scope :meta,     -> { where("source & ? > 0", META) }
  scope :content,  -> { where("source & ? = 0", META) }

  def creator? = source & CREATOR > 0
  def auto?    = source & AUTO > 0
  def human?   = source & HUMAN > 0
  def meta?    = source & META > 0
  def both?    = creator? && auto?
  def pending? = status == PENDING

  # The visual bucket for the redesigned tag UI.
  def bucket
    return :meta if meta?
    return :both if both?
    return :creator if creator?

    :auto
  end
end
