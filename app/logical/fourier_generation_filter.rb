# frozen_string_literal: true

# THE ONE FILTER for AI generation data in ExifTool metadata. Generation data
# -- prompts, settings, workflows -- is the creator's (operator rulings
# 2026-09-28 and 2026-09-29): visible to the creator of the post carrying the
# image, and to nobody else. Not admins.
# FourierCreatorPrivacy decides who that is; this decides which keys it covers.
#
# The booru runs ExifTool on every original and stores the whole result in
# media_metadata. Until this filter, every key of it left the site to anyone:
# the media asset page listed it, /media_metadata.json and every `only=`
# include of it served it, and exif: / search[metadata] let anyone probe it --
# so a prompt the uploader never meant to publish was one click from the
# image. The tunnel now strips generation data on ingest and files it in
# FourierGenerationMetadata, but rows written before that, and anything
# uploaded by another route, still carry it here.
#
# Every place metadata LEAVES goes through this module and nowhere else:
#   views        MediaMetadata#visible_metadata (media_assets/show, _table)
#   JSON / XML   MediaMetadata#serializable_hash
#   search       MediaMetadata.search (search[metadata], metadata_has_key, and
#                every association search that reaches it) and
#                MediaAsset.exif_matches (the exif: metatag on posts, media
#                assets and upload media assets)
#
# SEARCH IS REFUSED FOR EVERYONE, the creator included. A search spans every
# image at once, so it would answer one creator's question with every other
# creator's rows -- a has-key search lists which images carry a prompt, and a
# value search confirms a guessed one. The answer is the same for every
# viewer (nothing), so a search's cached post count is no one's secret.
#
# Stored rows are NOT modified. is_ai_generated? and everything else inside
# the app keep reading the full metadata; this decides only what a viewer is
# shown.
#
# Hiding is the safe direction: a key wrongly caught here is still there for
# the creator, while a key wrongly missed is a published prompt. The list
# leans accordingly -- PNG:Description, for one, is a stock PNG keyword that
# is not always a prompt, and it is hidden anyway because NovelAI writes the
# prompt there.
module FourierGenerationFilter
  module_function

  # Exact ExifTool -G1 keys, compared case-insensitively. The PNG names are
  # what ExifTool makes of each generator's tEXt/iTXt keyword, measured with
  # the exiftool in the booru image on 2026-09-28 ("Generation time" becomes
  # PNG:GenerationTime, "invokeai_metadata" PNG:Invokeai_metadata): the first
  # letter upper-cased, the rest as written. PNG:Postprocessing and
  # PNG:Extras are A1111's extras-tab chunks; IFD0:DocumentName is an EXIF
  # text field generators write a prompt into as readily as ImageDescription.
  KEYS = %w[
    PNG:Parameters
    PNG:Prompt
    PNG:Workflow
    PNG:Comment
    PNG:Description
    PNG:Sd-metadata
    PNG:Dream
    PNG:Invokeai_metadata
    PNG:Invokeai_graph
    PNG:Invokeai_workflow
    PNG:Fooocus_scheme
    PNG:Sui_image_params
    PNG:Source
    PNG:GenerationTime
    PNG:Postprocessing
    PNG:Extras
    ExifIFD:UserComment
    IFD0:ImageDescription
    IFD0:XPComment
    IFD0:DocumentName
    IPTC:Caption-Abstract
    File:Comment
  ].to_set(&:downcase).freeze

  # Easy Diffusion writes ONE PNG CHUNK PER SETTING, named after the setting,
  # so its model, VAE, LoRA and embedding names, step count, CFG and the rest
  # each arrive as a key of their own (PNG:Use_stable_diffusion_model,
  # PNG:Num_inference_steps, PNG:Guidance_scale, ...). Its task keys, as its
  # save_utils names them. Named rather than guessed at by word, because
  # "model", "steps" and "scale" are ordinary English and would catch keys
  # that are not settings.
  EASY_DIFFUSION_KEYS = %w[
    prompt negative_prompt original_prompt active_tags inactive_tags seed
    used_random_seed num_outputs num_inference_steps guidance_scale
    distilled_guidance_scale prompt_strength width height sampler_name
    scheduler_name clip_skip tiling vram_usage_level
    use_stable_diffusion_model use_vae_model use_hypernetwork_model
    hypernetwork_strength use_lora_model lora_alpha use_embeddings_model
    use_embedding_models use_controlnet_model control_filter_to_apply
    control_alpha use_face_correction use_upscale upscale_amount
    latent_upscaler_steps enable_vae_tiling output_format output_quality
    output_lossless metadata_output_format block_nsfw
    show_only_filtered_image stream_image_progress stream_progress_updates
    preserve_init_image_color_profile strict_mask_border
  ].to_set { |key| "png:#{key}" }.freeze

  # Keys caught by shape rather than by name.
  #  - A PNG text keyword naming generation content: an iTXt variant of any
  #    of the above gets a name of its own, and generators keep inventing
  #    keywords with these words in them.
  #  - An XMP property carrying a caption, comment or prompt (dc:Description,
  #    exif:UserComment, tiff:ImageDescription and generator-specific names).
  #    XMP only: ICC_Profile:ProfileDescription also says "Description" and is
  #    a colour profile, not a prompt.
  KEY_PATTERNS = [
    /\APNG:.*(prompt|workflow|parameters|invokeai|comfy|sampler|seed|lora|checkpoint|cfg)/i,
    /\AXMP-[^:]+:(Description|UserComment|ImageDescription|.*Prompt.*|.*Workflow.*|.*Parameters.*)\z/i,
  ].freeze

  # Values that ARE generation data wherever they sit. ComfyUI's WebP writer
  # puts its graphs in EXIF camera fields: "prompt:{...}" in Model (0x0110),
  # "workflow:{...}" in Make (0x010f), and any further extra_pnginfo entry as
  # "<name>:{...}" in the fields below those. No camera maker or model is
  # named like a labelled JSON object, so that shape is caught in any field,
  # and a bare "prompt:" or "workflow:" label is caught whatever follows it.
  # A1111's settings line carries "Steps: N, Sampler: X" whichever field a
  # tool copied it into.
  VALUE_PATTERNS = [
    /\A\s*(prompt|workflow)\s*:/i,
    /\A\s*[\w.-]+\s*:\s*(?:[\[{]|null\b)/,
    /\bSteps: \d+, Sampler: /,
  ].freeze

  # Is this metadata key -- or this key with this value -- generation data?
  def generation?(key, value = nil)
    name = key.to_s.strip
    down = name.downcase
    return true if KEYS.include?(down) || EASY_DIFFUSION_KEYS.include?(down)
    return true if KEY_PATTERNS.any? { name.match?(it) }

    value.is_a?(String) && VALUE_PATTERNS.any? { value.match?(it) }
  end

  # Does this metadata carry any generation data at all?
  def carries_generation?(metadata)
    metadata.to_h.any? { |key, value| generation?(key, value) }
  end

  # The metadata `user` on `request` may see, as a plain Hash: everything for
  # the creator of `post` (FourierCreatorPrivacy), and everything but the
  # generation data for anyone else -- which is also the answer when there is
  # no post, since then there is no creator. Never mutates its argument. The
  # creator is looked up only when there is something to withhold.
  def visible(metadata, post, user, request)
    hash = metadata.to_h
    return hash unless carries_generation?(hash)
    return hash if post && FourierCreatorPrivacy.visible_to?(post, user, request)

    hash.reject { |key, value| generation?(key, value) }
  end

  # Does this media_metadata search ask about generation data? Both jsonb
  # search forms -- search[metadata][<key>]=<value> and
  # search[metadata_has_key]=<key> -- in EVERY shape the params can take: a
  # string, and also an array (search[metadata_has_key][]=PNG:Parameters,
  # which Rails binds back into the very same `?` query) or a nested hash. A
  # key is checked wherever it sits, and a value wherever it sits. Refused
  # for everyone; see the class comment.
  def search_withheld?(params)
    params = params.try(:to_unsafe_h) || params.try(:with_indifferent_access) || {}

    pairs = params[:metadata]
    pairs = pairs.to_unsafe_h if pairs.respond_to?(:to_unsafe_h)
    withheld = pairs.is_a?(Hash) && pairs.any? do |key, value|
      values = leaves(value)
      values.empty? ? generation?(key) : values.any? { generation?(key, it) }
    end

    withheld || leaves(params[:metadata_has_key]).any? { generation?(it) }
  end

  # Every string inside `value`, however it is nested: the keys AND values of
  # a hash, the elements of an array, or the string itself.
  def leaves(value)
    value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
    case value
    when Hash then value.flat_map { |key, inner| [key.to_s] + leaves(inner) }
    when Array then value.flat_map { leaves(it) }
    when nil then []
    else [value.to_s]
    end
  end

  # Does this exif: term ("Key" or "Key=value") ask about generation data?
  def exif_term?(term)
    key, value = term.to_s.split("=", 2)
    generation?(key, value)
  end
end
