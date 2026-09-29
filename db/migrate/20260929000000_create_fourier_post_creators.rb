# frozen_string_literal: true

# WHO MADE A POST, recorded once (operator ruling 2026-09-29: "creator decides
# who can see what, always"). The post's creator alone reads its private
# creator tags and its generation data; see FourierCreatorPrivacy.
#
# Recorded by the posting bot at post creation, from the AUTHENTICATED sender
# of the Matrix event it posted -- POST /fourier/posts/:post_id/creator.json.
# Not derived from the post's 41chan_<localpart> tag: any member can edit a
# post's tags (PostPolicy#update? is unbanned? && visible?), so a tag on the
# post proves nothing about who posted it.
#
# One row per post, never overwritten (the endpoint answers a second, different
# mxid with a 409). Cascades with the post: an expunged post has no creator.
class CreateFourierPostCreators < ActiveRecord::Migration[8.1]
  def change
    create_table :fourier_post_creators do |t|
      t.references :post, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :mxid, null: false        # "@alice:41chan.net" -- the Matrix account that posted it
      t.bigint :recorded_by, null: false # the booru user that recorded it (the bot, or a backfill)
      t.timestamps
    end
    add_foreign_key :fourier_post_creators, :users, column: :recorded_by
  end
end
