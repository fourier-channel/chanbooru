require "test_helper"

class TagsControllerTest < ActionDispatch::IntegrationTest
  context "The tags controller" do
    setup do
      @user = create(:builder_user)
      @tag = create(:tag, name: "touhou", category: Tag.categories.copyright, post_count: 1)
    end

    context "index action" do
      should "render" do
        get tags_path
        assert_response :success
      end

      should "render for a sitemap" do
        get tags_path(format: :sitemap)
        assert_response :success
        assert_equal(Tag.count, response.parsed_body.css("urlset url loc").size)
      end

      context "with blank search parameters" do
        should "strip the blank parameters with a redirect" do
          get tags_path, params: { search: { name: "touhou", category: "" }}
          assert_redirected_to tags_path(search: { name: "touhou" })
        end
      end

      context "searching" do
        setup do
          as(@user) do
            @miku = create(:character_tag, name: "miku")
            @hatsune_miku = create(:character_tag, name: "hatsune_miku")
            @wokada = create(:artist_tag, name: "wokada")
            @vocaloid = create(:copyright_tag, name: "vocaloid")
            @weapon = create(:tag, name: "weapon")
            @axe = create(:tag, name: "axe")
            @empty = create(:tag, name: "empty", post_count: 0)

            create(:tag_alias, antecedent_name: "miku", consequent_name: "hatsune_miku")
            create(:tag_implication, antecedent_name: "axe", consequent_name: "weapon")
            create(:wiki_page, title: "hatsune_miku", body: "[[vocaloid]]")
            create(:artist, name: "wokada")
          end

          should "render" do
            get tags_path
            assert_response :success
          end

          should respond_to_search.with { [@empty, @axe, @weapon, @vocaloid, @wokada, @hatsune_miku, @miku, @tag] }
          should respond_to_search(name_matches: "hatsune_miku").with { @hatsune_miku }
          should respond_to_search(name_normalize: "HATSUNE_MIKU  ").with { @hatsune_miku }
          should respond_to_search(name_or_alias_matches: "miku").with { [@hatsune_miku, @miku] }
          should respond_to_search(fuzzy_name_matches: "hatsune_mika", order: "similarity").with { @hatsune_miku }
          should respond_to_search(name: "empty", hide_empty: "true").with { [] }
          should respond_to_search(name: "empty", hide_empty: "false").with { [@empty] }
          should respond_to_search(name: "empty", is_empty: "true").with { [@empty] }
          should respond_to_search(name: "empty", is_empty: "false").with { [] }

          context "using includes" do
            should respond_to_search(name: "wokada", has_artist: "true").with { @wokada }
            should respond_to_search(name: "hatsune_miku", has_artist: "false").with { @hatsune_miku }
            should respond_to_search(name: "hatsune_miku", has_wiki_page: "true").with { @hatsune_miku }
            should respond_to_search(name: "vocaloid", has_wiki_page: "false").with { @vocaloid }
            should respond_to_search(consequent_aliases: { antecedent_name: "miku" }).with { @hatsune_miku }
            should respond_to_search(consequent_implications: { antecedent_name: "axe" }).with { @weapon }
            should respond_to_search(wiki_page: { body_matches: "*vocaloid*" }).with { @hatsune_miku }
            should respond_to_search(artist: { is_banned: "false" }).with { @wokada }
            should respond_to_search(has_dtext_links: "true").with { @vocaloid }
          end
        end
      end

      context "searching by name" do
        subject { Tag }

        should "treat backslashes literally when the search doesn't contain a '*' wildcard" do
          t1 = create(:tag, name: ":\\")    # the literal tag :\
          t2 = create(:tag, name: "\\\\//") # the literal tag \\//

          assert_search_equals([t1], name_or_alias_matches: ":\\")    # the literal tag :\
          assert_search_equals([t2], name_or_alias_matches: "\\\\//") # the literal tag \\//
          assert_search_equals([], name_or_alias_matches: ":\\\\")    # the literal tag :\\
        end
      end
    end

    context "show action" do
      should "render" do
        get tag_path(@tag)
        assert_response :success
      end
    end

    context "edit action" do
      should "render" do
        get_auth edit_tag_path(@tag), @user
        assert_response :success
        assert_select("#tag_category")
      end

      should "not give the option to change the category for a large tag" do
        @tag.update!(post_count: 1000)
        get_auth edit_tag_path(@tag), @user
        assert_response :success
        assert_not_select("#tag_category")
      end

      should "not give the option to change the category for artist tags" do
        @tag = create(:tag, category: Tag.categories.artist)
        @artist = create(:artist, name: @tag.name)
        get_auth edit_tag_path(@tag), @user
        assert_response :success
        assert_not_select("#tag_category")
      end
    end

    context "update action" do
      setup do
        @mod = create(:moderator_user)
      end

      should "update the category for an empty tag" do
        @tag = create(:tag, category: Tag.categories.copyright, post_count: 0)
        put_auth tag_path(@tag), @user, params: { tag: { category: Tag.categories.general }}

        assert_redirected_to tag_path(@tag)
        assert_equal(Tag.categories.general, @tag.reload.category)

        assert_equal(2, @tag.versions.count)

        assert_equal(1, @tag.first_version.version)
        assert_equal(@tag.created_at, @tag.first_version.created_at)
        assert_equal(@tag.created_at, @tag.first_version.updated_at)
        assert_nil(@tag.first_version.updater)
        assert_equal(Tag.categories.copyright, @tag.first_version.category)

        assert_equal(2, @tag.last_version.version)
        assert_equal(@user, @tag.last_version.updater)
        assert_equal(Tag.categories.general, @tag.last_version.category)
      end

      context "for a tag with >50 posts" do
        setup do
          @tag.update(post_count: 100)
        end

        should "not update the category for a member" do
          @member = create(:member_user)
          put_auth tag_path(@tag), @member, params: { tag: { category: Tag.categories.general }}

          assert_response 403
          assert_not_equal(Tag.categories.general, @tag.reload.category)
          assert_equal(0, @tag.versions.count)
        end

        should "update the category for a builder" do
          put_auth tag_path(@tag), @user, params: { tag: { category: Tag.categories.general }}

          assert_redirected_to @tag
          assert_equal(Tag.categories.general, @tag.reload.category)

          assert_equal(2, @tag.versions.count)
          assert_nil(@tag.first_version.updater)
          assert_equal(@user, @tag.last_version.updater)
          assert_equal(Tag.categories.copyright, @tag.first_version.category)
          assert_equal(Tag.categories.general, @tag.last_version.category)
        end
      end

      should "not change category when the tag is too large to be changed by a builder" do
        @tag = create(:tag, category: Tag.categories.general, post_count: 1001)
        put_auth tag_path(@tag), @user, params: { tag: { category: Tag.categories.artist }}

        assert_response 403
        assert_equal(Tag.categories.general, @tag.reload.category)
        assert_equal(0, @tag.versions.count)
      end

      should "not change the category of an artist tag" do
        @tag = create(:tag, category: Tag.categories.artist)
        @artist = create(:artist, name: @tag.name)

        put_auth tag_path(@tag), @user, params: { tag: { category: Tag.categories.character }}
        assert_response 403
        assert(@tag.reload.artist?)
        assert_equal(0, @tag.versions.count)
      end

      context "for deprecation" do
        setup do
          @deprecated_tag = create(:tag, name: "bad_tag", category: Tag.categories.general, post_count: 0, is_deprecated: true)
          @nondeprecated_tag = create(:tag, name: "log", category: Tag.categories.general, post_count: 0)
          @normal_tag = create(:tag, name: "random", category: Tag.categories.general, post_count: 1000)
          create(:wiki_page, title: "bad_tag", body: "[[bad_tag]]")
          create(:wiki_page, title: "log", body: "[[log]]")
          create(:wiki_page, title: "random", body: "[[random]]")

          @normal_user = create(:member_user)
          @admin = create(:admin_user)
        end

        should "allow admins to deprecate a tag" do
          put_auth tag_path(@normal_tag), @admin, params: { tag: { is_deprecated: true }}

          assert_redirected_to @normal_tag
          assert_equal(true, @normal_tag.reload.is_deprecated?)

          assert_equal(2, @normal_tag.versions.count)
          assert_nil(@normal_tag.first_version.updater)
          assert_equal(@admin, @normal_tag.last_version.updater)
          assert_equal(false, @normal_tag.first_version.is_deprecated)
          assert_equal(true, @normal_tag.last_version.is_deprecated)
        end

        should "allow admins to undeprecate a tag" do
          put_auth tag_path(@deprecated_tag), @admin, params: { tag: { is_deprecated: false }}

          assert_redirected_to @deprecated_tag
          assert_equal(false, @deprecated_tag.reload.is_deprecated?)

          assert_equal(2, @deprecated_tag.versions.count)
          assert_nil(@deprecated_tag.first_version.updater)
          assert_equal(@admin, @deprecated_tag.last_version.updater)
          assert_equal(true, @deprecated_tag.first_version.is_deprecated)
          assert_equal(false, @deprecated_tag.last_version.is_deprecated)
        end

        should "not allow normal users to deprecate a tag" do
          put_auth tag_path(@nondeprecated_tag), @normal_user, params: { tag: { is_deprecated: true }}

          assert_response 403
          assert_equal(false, @nondeprecated_tag.reload.is_deprecated?)
        end

        should "not allow normal users to undeprecate a tag" do
          put_auth tag_path(@deprecated_tag), @normal_user, params: { tag: { is_deprecated: false }}

          assert_response 403
          assert_equal(true, @deprecated_tag.reload.is_deprecated?)
        end

        should "not allow deprecation of a tag with no wiki" do
          @tag_without_wiki = create(:tag, name: "no_wiki", category: Tag.categories.general, post_count: 0)
          put_auth tag_path(@tag_without_wiki), @user, params: { tag: { is_deprecated: true }}

          assert_response 403
          assert_equal(false, @tag_without_wiki.reload.is_deprecated?)
          assert_equal(0, @tag_without_wiki.versions.count)
        end

        should "not allow deprecation of a tag with a deleted wiki" do
          @tag_with_deleted_wiki = create(:tag, name: "deleted_wiki", category: Tag.categories.general, post_count: 0)
          create(:wiki_page, title: "no_wiki", body: "[[no_wiki]]", is_deleted: true)

          put_auth tag_path(@tag_with_deleted_wiki), @user, params: { tag: { is_deprecated: true }}

          assert_response 403
          assert_equal(false, @tag_with_deleted_wiki.reload.is_deprecated?)
          assert_equal(0, @tag_with_deleted_wiki.versions.count)
        end
      end
    end

    # THE FLAGGED-TAG REVIEW QUEUE (TagQuarantine, operator rulings
    # 2026-10-12), on the existing routes: PATCH /tags/:id and POST /tags with
    # tag[quarantine], and GET /tags?search[quarantine]=flagged.
    context "the review quarantine" do
      setup do
        @admin = create(:admin_user)
        @owner = create(:owner_user)
        @moderator = create(:moderator_user)
        @secret = create(:tag, name: "secret_(thing)", post_count: 0)
      end

      should "let an admin flag a tag from the edit page, with a note, in the mod log" do
        put_auth tag_path(@secret), @admin, params: { tag: { quarantine: "flag", quarantine_note: "looks wrong" }}

        assert_redirected_to tags_path(search: { quarantine: "flagged" })
        row = TagQuarantine.find_by!(tag: @secret)
        assert row.flagged?
        assert_equal @admin, row.flagged_by
        assert_equal "looks wrong", row.note
        assert_equal "tag_flag", ModAction.last.category
        assert_equal 0, @secret.versions.count, "a flag is not a tag edit: no tag version"
      end

      should "let an owner flag one over JSON" do
        put_auth tag_path(@secret, format: :json), @owner, params: { tag: { quarantine: "flag" }}

        assert_response 204
        assert TagQuarantine.find_by!(tag: @secret).flagged?
      end

      should "refuse a moderator, a builder and a member, saying who may" do
        [@moderator, @user, create(:user)].each do |user|
          put_auth tag_path(@secret, format: :json), user, params: { tag: { quarantine: "flag" }}
          assert_response 403, user.level_string
          assert_match(/only an admin/, response.parsed_body["message"].to_s + response.body)
        end
        assert_not TagQuarantine.exists?
      end

      should "release a flagged tag back to normal" do
        TagQuarantine.flag!(@secret, by: @admin)

        put_auth tag_path(@secret), @admin, params: { tag: { quarantine: "release", quarantine_note: "fine" }}

        assert_not TagQuarantine.exists?(tag_id: @secret.id)
        assert_equal "tag_flag_release", ModAction.last.category
      end

      should "banish a flagged tag in one click, after which even the admin gets a 404 for it" do
        TagQuarantine.flag!(@secret, by: @admin)

        assert_enqueued_with(job: BanishTagJob) do
          put_auth tag_path(@secret), @admin, params: { tag: { quarantine: "banish", quarantine_note: "confirmed" }}
        end

        assert TagQuarantine.find_by!(tag: @secret).banished?
        assert_equal "tag_banish", ModAction.last.category
        get_auth tag_path(@secret), @admin
        assert_response 404
      end

      should "refuse an unknown verb, and a verb mixed with another attribute" do
        put_auth tag_path(@secret, format: :json), @admin, params: { tag: { quarantine: "hide" }}
        assert_response 422
        assert_match(/flag, release, banish/, response.parsed_body["error"])

        put_auth tag_path(@secret, format: :json), @admin, params: { tag: { quarantine: "flag", category: Tag.categories.character }}
        assert_response 422
        assert_not TagQuarantine.exists?
      end

      should "refuse to release a tag that is not flagged" do
        put_auth tag_path(@secret, format: :json), @admin, params: { tag: { quarantine: "release" }}
        assert_response 422
        assert_match(/not flagged/, response.parsed_body["error"])
      end

      should "pre-flag a name nobody has used, so the first post carrying it is hidden from the start" do
        post_auth tags_path, @admin, params: { tag: { name: "never_used_(yet)", quarantine: "flag" }}

        assert_redirected_to tags_path(search: { quarantine: "flagged" })
        tag = Tag.find_by!(name: "never_used_(yet)")
        assert TagQuarantine.find_by!(tag: tag).flagged?

        # Only the bots post (operator ruling 2026-10-07); the tunnel's upload
        # is hidden from a member the moment it lands.
        tunnel = create(:approver_user, name: "tunnel")
        post = as(tunnel) { create(:post, tag_string: "landscape never_used_(yet)", uploader: tunnel, md5: SecureRandom.hex(16)) }
        get_auth post_path(post), create(:user)
        assert_response 404
        get_auth post_path(post), tunnel
        assert_response :success, "the bot keeps its own post"
      end

      should "refuse a pre-flag from a non-admin, and a POST /tags that is not a flag" do
        post_auth tags_path(format: :json), @moderator, params: { tag: { name: "whatever", quarantine: "flag" }}
        assert_response 403

        post_auth tags_path(format: :json), @admin, params: { tag: { name: "whatever" }}
        assert_response 422
        assert_nil Tag.find_by(name: "whatever")
      end

      should "list the flagged tags in the queue for an admin, with who, when, count and note" do
        TagQuarantine.flag!(@secret, by: @admin, note: "check the source")

        get_auth tags_path, @admin, params: { search: { quarantine: "flagged" }}

        assert_response :success
        assert_select "h2", text: "Flagged tags"
        assert_select "td", text: "secret_(thing)"
        assert_select "td", text: "check the source"
        assert_select "button[value=release]", 1
        assert_select "button[value=banish]", 1
      end

      should "list nothing in the queue for anyone below admin" do
        TagQuarantine.flag!(@secret, by: @admin)

        get_auth tags_path(format: :json), @moderator, params: { search: { quarantine: "flagged" }}

        assert_response :success
        assert_equal [], response.parsed_body
      end

      should "show the Flagged count in the admin navbar while something waits" do
        TagQuarantine.flag!(@secret, by: @admin)

        get_auth posts_path(preset: "modulation"), @admin
        assert_select "#top.modnav .modnav-pill", text: /Flagged\s*1/, count: 1
        get_auth site_map_path, @admin
        assert_select "a[href='#{tags_path(search: { quarantine: "flagged" })}']", text: "Flagged Tags", count: 1
        get_auth posts_path(preset: "modulation"), @moderator
        assert_select "#top.modnav .modnav-pill", text: /Flagged/, count: 0
      end

      should "offer the switch on the edit page to an admin only" do
        get_auth edit_tag_path(@secret), @admin
        assert_select "#tag-quarantine button[value=flag]", 1

        get_auth edit_tag_path(@tag), @user
        assert_select "#tag-quarantine", 0
      end

      should "answer a flagged tag's page with 404 for everyone below admin" do
        TagQuarantine.flag!(@secret, by: @admin)

        get_auth tag_path(@secret), @moderator
        assert_response 404
        get_auth tag_path(@secret), @admin
        assert_response :success
      end
    end
  end
end
