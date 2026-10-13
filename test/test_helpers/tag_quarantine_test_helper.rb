# frozen_string_literal: true

# The banished and flagged lists are rows (TagQuarantine) since 2026-10-12,
# not a config method to stub: a test that needs a name banished or flagged
# makes the row, as the review queue would.
module TagQuarantineTestHelper
  def banish_tags!(*names, by: User.system)
    names.flatten.each do |name|
      tag = Tag.find_or_create_by_name(name)
      row = TagQuarantine.find_by(tag_id: tag.id) || TagQuarantine.new(tag: tag)
      row.update!(state: TagQuarantine::BANISHED, banished_by: by, banished_at: Time.zone.now)
    end
    CreatorVisibility.forget!
  end

  def flag_tags!(*names, by: User.system)
    names.flatten.each do |name|
      TagQuarantine.create!(tag: Tag.find_or_create_by_name(name), state: TagQuarantine::FLAGGED, flagged_by: by, flagged_at: Time.zone.now)
    end
    CreatorVisibility.forget!
  end
end
