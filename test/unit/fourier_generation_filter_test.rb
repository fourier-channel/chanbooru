require "test_helper"

# The one filter every place media metadata leaves goes through
# (FourierGenerationFilter). The key names here are what ExifTool reports for
# each generator's fields, measured with the exiftool in the booru image.
class FourierGenerationFilterTest < ActiveSupport::TestCase
  CREATOR = "@alice:41chan.net"

  context "FourierGenerationFilter" do
    should "name the generation keys every generator writes" do
      %w[
        PNG:Parameters PNG:Prompt PNG:Workflow PNG:Comment PNG:Description
        PNG:Sd-metadata PNG:Dream PNG:Invokeai_metadata PNG:Invokeai_graph PNG:Invokeai_workflow
        PNG:Fooocus_scheme PNG:Sui_image_params PNG:Source PNG:GenerationTime
        PNG:Negative_prompt PNG:Sampler_name PNG:PromptItxt
        ExifIFD:UserComment IFD0:ImageDescription IFD0:XPComment File:Comment
        XMP-dc:Description XMP-exif:UserComment XMP-tiff:ImageDescription
        png:parameters
      ].each { |key| assert FourierGenerationFilter.generation?(key), key }
    end

    # Finding 4 (round one): each of these was shown to a signed-out viewer.
    should "name Easy Diffusion's per-setting chunks, A1111's extras chunks and EXIF DocumentName" do
      %w[
        PNG:Use_stable_diffusion_model PNG:Num_inference_steps PNG:Guidance_scale PNG:Clip_skip
        PNG:Use_vae_model PNG:Use_hypernetwork_model PNG:Use_embedding_models PNG:Use_lora_model
        PNG:Lora_alpha PNG:Width PNG:Scheduler_name PNG:Seed PNG:Tiling
        PNG:Postprocessing PNG:Extras IFD0:DocumentName IPTC:Caption-Abstract
      ].each { |key| assert FourierGenerationFilter.generation?(key, "x"), key }
    end

    should "leave ordinary keys alone" do
      %w[
        PNG:ColorType PNG:ImageWidth PNG:Software PNG:Title PNG:Gamma
        IFD0:Orientation IFD0:Make IFD0:Model ExifIFD:DateTimeOriginal
        ICC_Profile:ProfileDescription ICC_Profile:DeviceModelDesc File:ColorComponents
        GIF:Comment XMP-x:XMPToolkit
      ].each { |key| refute FourierGenerationFilter.generation?(key, "Canon"), key }
      refute FourierGenerationFilter.generation?("XMP-x:XMPToolkit", "Image::ExifTool 12.40")
      refute FourierGenerationFilter.generation?("ExifIFD:DateTimeOriginal", "2024:01:01 12:00:00")
    end

    # ComfyUI's WebP writer: prompt in Model, workflow in Make, and any further
    # extra_pnginfo entry as "<name>:{...}" below them.
    should "catch generation data by value in a camera field" do
      assert FourierGenerationFilter.generation?("IFD0:Make", "workflow:{\"nodes\": []}")
      assert FourierGenerationFilter.generation?("IFD0:Model", "prompt:{\"3\": {}}")
      assert FourierGenerationFilter.generation?("IFD0:Model", "Prompt: null")
      assert FourierGenerationFilter.generation?("IFD0:Software", "extra_node_info:{\"a\": 1}")
      assert FourierGenerationFilter.generation?("IFD0:Artist", "a cat\nSteps: 20, Sampler: Euler a, CFG scale: 7")
      refute FourierGenerationFilter.generation?("IFD0:Make", "Canon")
      refute FourierGenerationFilter.generation?("IFD0:Model", "NIKON D850")
    end

    context "shown" do
      setup do
        @metadata = { "PNG:Parameters" => "p", "PNG:ColorType" => "RGB", "IFD0:Make" => "workflow:{}" }
        @post = create(:post)
        FourierPostCreator.create!(post: @post, mxid: CREATOR, recorded_by: @post.uploader_id)
      end

      should "withhold generation keys from everyone but the creator -- admins included" do
        [create(:user), create(:moderator_user), create(:admin_user), create(:owner_user), User.anonymous, nil].each do |user|
          assert_equal({ "PNG:ColorType" => "RGB" }, FourierGenerationFilter.visible(@metadata, @post, user, nil), user&.level_string.inspect)
        end
        creator = ActionDispatch::TestRequest.create("HTTP_X_FOURIER_IDENTITY" => CREATOR)
        assert_equal @metadata, FourierGenerationFilter.visible(@metadata, @post, User.anonymous, creator)
        assert_equal 3, @metadata.size, "the argument is not mutated"
      end

      should "withhold them from everyone when there is no post, since there is no creator" do
        creator = ActionDispatch::TestRequest.create("HTTP_X_FOURIER_IDENTITY" => CREATOR)
        assert_equal({ "PNG:ColorType" => "RGB" }, FourierGenerationFilter.visible(@metadata, nil, create(:admin_user), creator))
      end
    end

    should "withhold a search naming a generation key, whoever asks" do
      assert FourierGenerationFilter.search_withheld?({ metadata_has_key: "PNG:Parameters" })
      assert FourierGenerationFilter.search_withheld?({ metadata: { "PNG:Parameters" => "x" } })
      assert FourierGenerationFilter.search_withheld?({ metadata: { "PNG:Guidance_scale" => "7" } })
      assert FourierGenerationFilter.search_withheld?({ metadata: { "IFD0:Make" => "workflow:{}" } })
      assert FourierGenerationFilter.search_withheld?(ActionController::Parameters.new(metadata: { "PNG:Prompt" => "x" }))
      refute FourierGenerationFilter.search_withheld?({ metadata: { "PNG:ColorType" => "RGB" } })
      refute FourierGenerationFilter.search_withheld?({ metadata_has_key: "PNG:ColorType" })
      refute FourierGenerationFilter.search_withheld?({})
    end

    # Finding 16 (round one): an array stringified to '["PNG:Parameters"]',
    # matched nothing, and Rails then bound the one element straight into the
    # jsonb `?` query. Every shape the query string can produce is checked.
    should "withhold a generation key in every shape the params can take" do
      assert FourierGenerationFilter.search_withheld?({ metadata_has_key: ["PNG:Parameters"] })
      assert FourierGenerationFilter.search_withheld?({ metadata_has_key: ["PNG:ColorType", "PNG:Parameters"] })
      assert FourierGenerationFilter.search_withheld?({ metadata_has_key: { "a" => "PNG:Parameters" } })
      assert FourierGenerationFilter.search_withheld?(ActionController::Parameters.new(metadata_has_key: ["PNG:Parameters"]))
      assert FourierGenerationFilter.search_withheld?({ metadata: { "IFD0:Make" => ["workflow:{}"] } })
      assert FourierGenerationFilter.search_withheld?({ metadata: { "PNG:Parameters" => { "nested" => "x" } } })
      assert FourierGenerationFilter.search_withheld?({ metadata: { "PNG:Parameters" => nil } })
      refute FourierGenerationFilter.search_withheld?({ metadata_has_key: ["PNG:ColorType"] })
    end

    should "recognise an exif: term on a generation key, with or without a value" do
      assert FourierGenerationFilter.exif_term?("PNG:Parameters")
      assert FourierGenerationFilter.exif_term?("PNG:Parameters=a cat")
      assert FourierGenerationFilter.exif_term?("PNG:Num_inference_steps=20")
      assert FourierGenerationFilter.exif_term?("IFD0:Make=workflow:{}")
      refute FourierGenerationFilter.exif_term?("File:ColorComponents=3")
    end
  end
end
