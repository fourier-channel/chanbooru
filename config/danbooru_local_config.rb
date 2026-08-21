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

    # ---- Content restriction ----

    # Tags visible only to Gold+ (level 30). A non-Gold viewer still sees the
    # post listed with its tags; the IMAGE is replaced by an upgrade prompt, and
    # PostPolicy strips md5, file_url, large_file_url and preview_file_url from
    # the API, so the file identifiers are never handed out either.
    #
    # Purpose is to avoid accidentally SERVING illegal content, not to judge it.
    # Anything found to be actually illegal is handled separately and upstream:
    # Cloudflare scans for CSAM before it reaches this box.
    #
    # Two constraints on what may go in this list:
    #
    #   1. Plain [a-z0-9_] only. RESTRICTED_TAGS_REGEX interpolates these
    #      straight into a pattern with NO Regexp.escape, so a tag containing
    #      metacharacters -- anything shaped like foo_(bar) -- either mismatches
    #      or raises at class load and takes the app down.
    #   2. Changing this list needs a --force-recreate, not a restart. The regex
    #      is built with /o, so it is interpolated once at class load, and this
    #      file is a single-file bind mount whose inode the running container
    #      holds open.
    #
    # troll_jail is applied by fourier-sampling when an image is sent to troll
    # jail and removed when it is released, so visibility follows the jail state
    # with no second switch to keep in sync.
    #
    # NOTE: %w[] takes NO comments. A comment inside the literal becomes DATA --
    # every word of it, including any with regex metacharacters. Doing exactly
    # that on 2026-08-12 turned "# Jailed content, hidden pending review
    # (operator ...)" into 40-odd bogus entries; it did not crash, because
    # "(operator|2026-08-12)" happens to be a valid group, it just silently
    # restricted words like hidden, content, review and troll. Keep prose out
    # here, above the literal.
    #
    # A tag that does not exist yet is inert -- the match is against tag_string,
    # not the tags table -- so listing ones the tagger has not emitted yet is
    # deliberate and costs nothing.
    def restricted_tags
      %w[
        loli
        shota
        toddlercon
        child
        toddler
        baby
        infant
        young
        aged_down
        age_regression
        troll_jail
      ]
    end

    # ---- Fourier media gating ----

    # Same-origin base path that nginx will proxy to fourier-auth.
    def fourier_gate_path
      "/fourier"
    end

    # Where Matrix media lives for every surface. Not a booru-specific origin:
    # this is the homeserver's own authenticated-media endpoint, fronted by the
    # Cloudflare Worker that serves it from R2. One URL, one check, one copy.
    def fourier_media_origin
      ENV.fetch("FOURIER_MEDIA_ORIGIN", "https://matrix.41chan.net")
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

      # Matrix-sourced media goes to the CANONICAL Matrix media URL -- the same
      # one Element and Technetium request, byte for byte.
      #
      # Operator ruling 2026-08-15: "41chan is 41chan... the entire site is
      # supposed to be multiple surfaces into the same exact data. One source of
      # truth." A booru-specific media path meant this surface deciding for
      # itself what a user may see; now it asks the same endpoint, which asks
      # the same gate, which applies the same room check. The booru shows the
      # image if and only if the viewer is in the room it was posted to.
      #
      # An <img> cannot send a Bearer token, so the browser presents the
      # fourier_session cookie instead -- scoped to .41chan.net for exactly this
      # reason. booru.41chan.net and matrix.41chan.net are the same SITE, so a
      # SameSite=Lax cookie rides along on the subresource load.
      m = %r{\Amxc://(?<server>[A-Za-z0-9.:-]+)/(?<id>[A-Za-z0-9_-]+)\z}.match(source.to_s)
      if m
        base = "#{fourier_media_origin}/_matrix/client/v1/media"
        if size
          return "#{base}/thumbnail/#{m[:server]}/#{m[:id]}?width=#{size[0]}&height=#{size[1]}&method=scale"
        end
        return "#{base}/download/#{m[:server]}/#{m[:id]}"
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
      # Development and test have no R2 credentials and no reason to want them:
      # the dev stack ships its own image volume, and upstream's local storage
      # manager serves it directly. Falling back here keeps `bin/dev` usable
      # without handing a dev box production bucket access.
      #
      # Deployed environments are NOT covered by this and still hit the
      # ENV.fetch("R2_BUCKET") below -- an unconfigured deploy must fail loudly,
      # which is the whole point of that fetch having no default.
      return super if Rails.env.development? || Rails.env.test?

      @storage_manager ||= begin
        klass = Class.new(StorageManager::Rclone) do
          # Pass our own URLs through untouched. The base_url join is for files
          # this storage manager serves; these are served by the media endpoint
          # every other surface uses, so joining a base onto them produced
          # https://booru.41chan.net/data/https://matrix.41chan.net/... -- a URL
          # that is wrong in a way an <img> reports only as a broken image.
          def file_url(path)
            return path if path.to_s.start_with?("/fourier/", "http://", "https://")
            super
          end

          # Never re-upload an object that is content-addressed.
          #
          # media/<md5>.<ext> is keyed by the digest of its own bytes, so an
          # object already at that key IS those bytes -- there is nothing a
          # second write can change. danbooru was re-uploading every original it
          # had just FETCHED from that exact key: measured 2026-08-12, the
          # uploader wrote media/ at 05:16:19 and danbooru overwrote it at
          # 05:57:38, two seconds before creating the post. Roughly 1.6MB of
          # pointless upload per image.
          #
          # --ignore-existing rather than a separate existence check, so this
          # costs no extra round trip. Scoped to media/ ONLY: variant keys are
          # md5 PLUS a variant name, not a digest of their contents, so
          # re-rendering one must still be able to overwrite it.
          def store(file, path)
            k = fourier_key(path)
            if k&.start_with?("media/")
              rclone "copyto", "--ignore-existing", file.path, key(path)
            else
              super
            end
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
