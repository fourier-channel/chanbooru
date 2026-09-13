# frozen_string_literal: true

class UploadPolicy < ApplicationPolicy
  def create?
    unbanned?
  end

  def show?
    user.is_moderator? || record.uploader_id == user.id
  end

  def rate_limit_for_create(**_options)
    if record.invalid?
      { action: "uploads:create:invalid", rate: 1.0 / 1.second, burst: 1 }
    elsif user.is_builder?
      # 24/min -> 48/min (operator, 2026-09-13). The 24 was upstream's default
      # for danbooru.donmai.us (evazion, June 2025), never sized for this box,
      # and in 22,419 minutes of upload activity it had bound us for five. It
      # bound us immediately once fourier-sampling started handing the booru
      # the bytes at INGEST rather than at post time: live arrivals alone are
      # ~22/min, the pre-switch backlog the poster still creates by URL adds
      # ~9/min, and the tmpfs spool grew from 38 MB to 700 MB in an hour
      # against a bucket that could not take both. Measured cost of an asset
      # here is ~1.3s of decode, render and rclone writes, so 48/min is about
      # one core of six with 37 GB free -- and it is verified by asking the
      # running app, not by reading this file back.
      { action: "uploads:create", rate: 48.0 / 1.minute, burst: 120 } # 2880 per hour
    elsif user.posts.active.exists?(created_at: ..4.hours.ago)
      { action: "uploads:create", rate: 8.0 / 1.minute, burst: 60 } # 480 per hour, 540 in first hour
    elsif user.posts.exists?(created_at: ..4.hours.ago)
      { action: "uploads:create", rate: 4.0 / 1.minute, burst: 30 } # 240 per hour, 270 in first hour
    elsif user.uploads.completed.exists?(created_at: ..4.hours.ago)
      { action: "uploads:create", rate: 2.0 / 1.minute, burst: 15 } # 120 per hour, 135 in first hour
    else
      { action: "uploads:create", rate: 1.0 / 1.minute, burst: 10 } # 60 per hour, 70 in first hour
    end
  end

  def permitted_attributes
    [:source, :referer_url, { files: {}}]
  end
end
