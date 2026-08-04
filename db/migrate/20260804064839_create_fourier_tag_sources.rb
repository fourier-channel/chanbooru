# frozen_string_literal: true

class CreateFourierTagSources < ActiveRecord::Migration[8.1]
  def change
    create_table :fourier_tag_sources do |t|
      t.references :post, null: false, foreign_key: true, index: false
      t.string :tag, null: false
      t.integer :source, null: false             # bitflag: 1=creator 2=auto 4=human 8=meta
      t.integer :status, null: false, default: 0 # 0=approved 1=pending
      t.bigint :added_by                          # user id (creator attribution)
      t.datetime :created_at, null: false
    end
    add_index :fourier_tag_sources, %i[post_id tag], unique: true
    add_index :fourier_tag_sources, %i[post_id status]
  end
end
