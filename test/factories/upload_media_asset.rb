FactoryBot.define do
  factory :upload_media_asset do
    upload
    media_asset
    # Fork: an image's URL, as a real source_url is. A URL that does not look like
    # an image is fetched, to see what site it is, and no test contacts one.
    source_url { "#{Faker::Internet.url}.jpg" }
  end
end
