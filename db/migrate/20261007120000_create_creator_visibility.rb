# frozen_string_literal: true

# WHO SEES A CREATOR'S POSTS -- the rows a creator's panel writes (design
# CREATOR_VISIBILITY sections 4, 5, 7 and 9, ruled 2026-10-07: "the artist
# claim ... allows the user access to a control panel that lets them set the
# visibility of their posts both on a general, per 'group' and per-user
# case"). CreatorVisibility decides from these rows; nothing here enforces.
#
# Keyed on the CREATOR GALLERY (the creator identity: the only stored link
# from a verified Matrix account to a booru account, and what CreatorControl
# names as a post's controller) and on booru USERS as viewers, because the
# media gate and every query path know only the booru session (section 9).
#
#   creator_galleries.default_audience  the creator's general default; NULL
#                                       until they choose (Q7: only the
#                                       creator's own "public" opens their
#                                       Matrix image, so unset must not be
#                                       stored as public)
#   creator_post_audiences              one override per post AND controller
#                                       (section 9: two claimants, narrowest
#                                       wins -- neither writes over the other)
#   creator_groups                      a creator's groups (41chan_saber_tier_1)
#   creator_audience_groups             which groups an audience includes:
#                                       post_id NULL = the creator default
#   creator_group_memberships           who is in a group, who added them,
#                                       how, and until when
#   creator_join_requests               Q5: a user asks, the creator decides
#   creator_user_rules                  allow / block, creator-wide or per post
#
# Every rule is in the database as well as the models: CHECKs on the closed
# vocabularies, partial unique indexes for "one per scope" (a NULL post_id is
# the creator-wide scope, and NULLs never collide in a plain unique index),
# and cascading FKs so an expunged post, a dissolved group or a deleted
# gallery leaves nothing behind that a later reader could misread.
#
# ADDITIVE ONLY: production runs db:prepare at container start and --rollback
# never reverses a schema, so the previous release must boot against this
# one. New tables, and one new nullable column (no rewrite of
# creator_galleries).
class CreateCreatorVisibility < ActiveRecord::Migration[8.1]
  def change
    add_column :creator_galleries, :default_audience, :string
    add_check_constraint :creator_galleries, "default_audience IN ('public', 'groups', 'private')",
                         name: "creator_galleries_default_audience_known"

    create_table :creator_groups do |t|
      t.references :creator_gallery, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.integer :tier
      t.timestamps
      t.index :name, unique: true
      t.check_constraint "tier IS NULL OR tier >= 1", name: "creator_groups_tier_positive"
    end

    create_table :creator_group_memberships do |t|
      t.references :creator_group, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :added_by, null: false, foreign_key: { to_table: :users }
      t.string :source, null: false
      t.datetime :expires_at
      t.timestamps
      t.index [:creator_group_id, :user_id], unique: true
      t.check_constraint "source IN ('creator', 'request', 'automation')", name: "creator_group_memberships_source_known"
    end

    create_table :creator_join_requests do |t|
      t.references :creator_group, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :status, null: false, default: "pending"
      t.references :decided_by, foreign_key: { to_table: :users }
      t.datetime :decided_at
      t.string :note, null: false, default: ""
      t.timestamps
      t.index [:creator_group_id, :user_id], unique: true, where: "status = 'pending'",
                                             name: "index_creator_join_requests_one_pending"
      t.check_constraint "status IN ('pending', 'approved', 'rejected')", name: "creator_join_requests_status_known"
    end

    create_table :creator_post_audiences do |t|
      t.references :post, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :creator_gallery, null: false, foreign_key: { on_delete: :cascade }
      t.string :audience, null: false, default: "inherit"
      t.references :updated_by, null: false, foreign_key: { to_table: :users }
      t.timestamps
      t.index [:post_id, :creator_gallery_id], unique: true
      t.index :audience
      t.check_constraint "audience IN ('inherit', 'public', 'groups', 'private')", name: "creator_post_audiences_audience_known"
    end

    create_table :creator_audience_groups do |t|
      t.references :creator_group, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :post, foreign_key: { on_delete: :cascade }
      t.timestamps
      t.index [:creator_group_id, :post_id], unique: true, where: "post_id IS NOT NULL",
                                             name: "index_creator_audience_groups_one_per_post"
      t.index :creator_group_id, unique: true, where: "post_id IS NULL",
                                 name: "index_creator_audience_groups_one_per_default"
    end

    create_table :creator_user_rules do |t|
      t.references :creator_gallery, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :post, foreign_key: { on_delete: :cascade }
      t.string :rule, null: false
      t.references :updated_by, null: false, foreign_key: { to_table: :users }
      t.timestamps
      t.index [:creator_gallery_id, :user_id], unique: true, where: "post_id IS NULL",
                                               name: "index_creator_user_rules_one_creator_wide"
      t.index [:creator_gallery_id, :user_id, :post_id], unique: true, where: "post_id IS NOT NULL",
                                                         name: "index_creator_user_rules_one_per_post"
      t.check_constraint "rule IN ('allow', 'block')", name: "creator_user_rules_rule_known"
    end
  end
end
