FactoryBot.define do
  factory :creator_gallery do
    sequence(:slug) { |n| "creator#{n}" }
    matrix_id { "@#{slug}:example.com" }
    title { "Creator #{slug}" }
    bio { "" }
    style { "grid" }
  end
end
