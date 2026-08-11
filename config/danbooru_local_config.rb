# frozen_string_literal: true

module Danbooru
  class CustomConfiguration < Configuration
    # ---- existing chanbooru settings ----

    def app_name
      "chanbooru"
    end

    def enable_signup?
      false
    end

    def custom_html_header_content
      <<~HTML
        <style>
          form#signup-form input { opacity: 0.4; pointer-events: none; }
          form#signup-form button { opacity: 0.4; pointer-events: none; }
        </style>
        <script>
          document.addEventListener("DOMContentLoaded", function() {
            var form = document.querySelector("form#signup-form");
            if (form) {
              var notice = document.createElement("div");
              notice.style.cssText = "background:#1a1a1a;border:1px solid #555;color:#aaa;padding:1rem;margin-bottom:1rem;text-align:center;";
              notice.textContent = "Registrations are currently disabled.";
              form.prepend(notice);
            }
          });
        </script>
      HTML
    end

    # ---- Fourier media gating ----

    # Same-origin base path that nginx will proxy to fourier-auth.
    def fourier_gate_path
      "/fourier"
    end

    # Danbooru variant type -> Synapse thumbnail size.
    # original and full are deliberately absent: they get the ungated-size download.
    FOURIER_VARIANT_SIZES = {
      "180x180": [180, 180],
      "360x360": [360, 360],
      "720x720": [720, 720],
      sample:    [850, 850],
    }.freeze

    # Media the booru does not hold is served from R2 through the fourier-auth
    # gate. Two kinds, two routes, because they are authorised differently:
    #
    #   mxc://...  -> /fourier/media/<server>/<id>   room membership (Synapse)
    #   everything -> /fourier/booru/<md5>.<ext>     fourier session (the same
    #                                                fourier login already used
    #                                                to view Synapse media)
    #
    # The second route exists because a 4chan image lives in no Matrix room, so
    # the mxc route's authorisation question is meaningless for it. See
    # fourier-auth booru-media.js.
    #
    # PRECONDITION for the booru branch: the object is in R2 under
    # media/<md5>.<ext>, put there by fourier-sampling's uploader. A post whose
    # bytes exist only on this disk must NOT be routed here -- it would 404.
    # As of 2026-08-11 that is every post: the 32 mxc ones are in R2 via
    # Synapse's s3-storage-provider, post 34 via the uploader, and post 1 (the
    # legacy source="test" upload) was copied up as part of this change.
    def media_asset_file_url(variant, custom_filename)
      source = variant.media_asset.post&.source
      size = FOURIER_VARIANT_SIZES[variant.type]

      m = %r{\Amxc://(?<server>[A-Za-z0-9.:-]+)/(?<id>[A-Za-z0-9_-]+)\z}.match(source.to_s)
      if m
        url = "#{fourier_gate_path}/media/#{m[:server]}/#{m[:id]}"
        url += "?w=#{size[0]}&h=#{size[1]}" if size
        return url
      end

      asset = variant.media_asset
      return super if asset.md5.blank? || asset.file_ext.blank?

      url = "#{fourier_gate_path}/booru/#{asset.md5}.#{asset.file_ext}"
      # Same ?w=/?h= shape as the mxc branch; the gate snaps it to a rendition
      # fourier-sampling actually uploaded.
      url += "?w=#{size[0]}&h=#{size[1]}" if size
      url
    end

    # Pass gate URLs through untouched; everything else gets normal
    # base_url joining. Subclass is built at call time because
    # StorageManager::Local isn't autoloaded when this file is required.
    def storage_manager
      @storage_manager ||= begin
        klass = Class.new(StorageManager::Local) do
          def file_url(path)
            return path if path.to_s.start_with?("/fourier/")
            super
          end
        end
        klass.new(base_url: "#{Danbooru.config.canonical_url}/data", base_dir: Danbooru.config.image_storage_path)
      end
    end
  end
end
