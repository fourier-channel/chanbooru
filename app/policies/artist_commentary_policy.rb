# frozen_string_literal: true

class ArtistCommentaryPolicy < ApplicationPolicy
  def create_or_update?
    unbanned?
  end

  def revert?
    unbanned?
  end

  def rate_limit_for_write(**_options)
    if record.invalid?
      { action: "artist_commentaries:write:invalid", rate: 1.0 / 1.second, burst: 1 }
    elsif user.artist_commentary_versions.exists?(post: record, created_at: 1.hour.ago..)
      { action: "artist_commentaries:write:artist-commentary-#{record.id}", rate: 4.0 / 1.minute, burst: 10 } # 240 per hour, 250 in first hour
    elsif user.is_builder?
      # 60/min, matching posts:create (operator, 2026-09-30). The sampling
      # poster writes one commentary per post -- the 4chan attribution -- so this
      # bucket is charged exactly as often as posts:create. It was left at 24/min
      # when uploads:create (39c883acf) and posts:create (311cc9ffd) were raised
      # on 2026-09-13, and so became the one ceiling holding posting to 24/min
      # with a 165k backlog waiting. The write is a row insert and a version row;
      # the expensive work stayed in uploads:create.
      { action: "artist_commentaries:write", rate: 60.0 / 1.minute, burst: 60 } # 3600 per hour
    elsif user.artist_commentary_versions.exists?(created_at: ..24.hours.ago)
      { action: "artist_commentaries:write", rate: 4.0 / 1.minute, burst: 30 } # 240 per hour, 300 in first hour
    else
      { action: "artist_commentaries:write", rate: 1.0 / 1.minute, burst: 20 } # 60 per hour, 80 in first hour
    end
  end

  def permitted_attributes
    %i[
      original_description original_title
      translated_description translated_title
      commentary_tags
    ]
  end
end
