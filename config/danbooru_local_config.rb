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

    # Storage lives in R2, not on this box (operator ruling 2026-08-11: the booru
    # holds no media; R2 receives, holds and serves it).
    #
    # Rclone rather than Null. Null makes `store` a no-op, which silently
    # discards the bytes of anything that is not already in R2 -- a person
    # uploading here would get a post, no file, and a permanent 404. Manual
    # uploads are coming, and further media sources after them (operator,
    # 2026-08-12), so that hole is not survivable. Null also makes `open` a
    # no-op, which breaks IQDB indexing, `regenerate!` and the media controller;
    # rclone reads back, so all three keep working with no change to them.
    #
    # Keys are mapped onto fourier-sampling's layout so the bucket holds ONE
    # scheme rather than two writers with two conventions:
    #
    #   /original/f2/b6/<md5>.png      -> media/<md5>.png
    #   /180x180/f2/b6/<md5>.jpg       -> variants/<md5>/180x180.jpg
    #   /720x720/f2/b6/<md5>.webp      -> variants/<md5>/720x720.webp
    #   /sample/f2/b6/sample-<md5>.jpg -> variants/<md5>/sample.jpg
    #
    # The extension is carried through rather than fixed, because the formats
    # are not uniform: convert_file renders 720x720 as webp q75 and the rest as
    # jpeg q85. fourier-sampling matches that exactly, so whichever side writes
    # first, the other finds the object it expects.
    #
    # An UNRECOGNISED path falls through to rclone's plain layout rather than
    # being force-mapped. A silent misroute is worse than an obvious one.
    #
    # Requires RCLONE_S3_* in this service's environment. Note it is
    # RCLONE_S3_*, the backend-type form, NOT RCLONE_CONFIG_<NAME>_*: `key`
    # emits `:s3:` and the named-remote form fails with
    # "didn't find backend called ...".
    def storage_manager
      @storage_manager ||= begin
        klass = Class.new(StorageManager::Rclone) do
          def file_url(path)
            return path if path.to_s.start_with?("/fourier/")
            super
          end

          def key(path)
            mapped = fourier_key(path)
            return super if mapped.nil?
            ":#{remote}:#{bucket}/#{mapped}"
          end

          # nil when the path is not one we recognise, so `key` can fall back.
          def fourier_key(path)
            p = path.to_s
            if (m = %r{\A/original/\w{2}/\w{2}/(?<md5>[0-9a-f]{32})(?<ext>\.\w+)\z}.match(p))
              "media/#{m[:md5]}#{m[:ext]}"
            elsif (m = %r{\A/sample/\w{2}/\w{2}/sample-(?<md5>[0-9a-f]{32})(?<ext>\.\w+)\z}.match(p))
              "variants/#{m[:md5]}/sample#{m[:ext]}"
            elsif (m = %r{\A/(?<type>180x180|360x360|720x720)/\w{2}/\w{2}/(?<md5>[0-9a-f]{32})(?<ext>\.\w+)\z}.match(p))
              "variants/#{m[:md5]}/#{m[:type]}#{m[:ext]}"
            end
          end
        end
        klass.new(
          remote: "s3",
          # R2 tokens cannot create or probe a bucket. Without this, rclone's
          # default bucket check turns every `store` into
          # "AccessDenied ... status code: 403" -- reads succeed, writes fail,
          # so it would have looked healthy until the first upload. Verified on
          # the box: identical copy fails without the flag and round-trips with
          # it. In code rather than an env var on purpose: it is a property of
          # the backend, not a credential, and a missing env var would break
          # writes silently.
          rclone_options: ["--s3-no-check-bucket"],
          # No default on purpose. A wrong-but-plausible fallback would write
          # media into whichever bucket happened to be named here; an
          # unconfigured deploy should fail loudly at boot instead. The name is
          # also infrastructure detail, and this repo is public.
          bucket: ENV.fetch("R2_BUCKET"),
          base_url: "#{Danbooru.config.canonical_url}/data",
        )
      end
    end
  end
end
