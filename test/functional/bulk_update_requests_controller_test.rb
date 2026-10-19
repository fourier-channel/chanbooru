require "test_helper"

class BulkUpdateRequestsControllerTest < ActionDispatch::IntegrationTest
  include TagQuarantineTestHelper

  context "BulkUpdateRequestsController" do
    setup do
      @user = create(:user)
      @builder = create(:builder_user)
      @mod = create(:mod_user)
      @admin = create(:admin_user)
      as(@admin) { @forum_topic = create(:forum_topic, category_id: 0) }
      as(@user) { @bulk_update_request = create(:bulk_update_request, user: @user, forum_topic: @forum_topic, script: "create alias aaa -> bbb") }
    end

    context "#new" do
      should "render" do
        get_auth new_bulk_update_request_path, @user
        assert_response :success
      end
    end

    context "#edit" do
      should "render" do
        get_auth edit_bulk_update_request_path(@bulk_update_request), @user
        assert_response :success
      end
    end

    context "#create" do
      should "succeed" do
        assert_difference("BulkUpdateRequest.count", 1) do
          post_auth bulk_update_requests_path, @user, params: { bulk_update_request: attributes_for(:bulk_update_request) }
          assert_response :redirect
        end
      end

      should "fail for an invalid script" do
        assert_difference("BulkUpdateRequest.count", 0) do
          post_auth bulk_update_requests_path, @user, params: { bulk_update_request: attributes_for(:bulk_update_request).merge(script: "create alis gray -> grey") }
          assert_response :success
        end
      end

      should "fail for a blank reason" do
        assert_difference("BulkUpdateRequest.count", 0) do
          post_auth bulk_update_requests_path, @user, params: { bulk_update_request: attributes_for(:bulk_update_request).merge(reason: "") }
          assert_response :success
        end
      end

      # Fork: a refused filing answers an API caller as a refused approval
      # does -- 422, a sentence, and one entry per failing script line --
      # which the bot relays into the room (technetium-81, 2026-10-19).
      context "refused, for an API caller" do
        should "answer 422 with the sentence and each failing line, blank lines counted" do
          script = "create alias aaa -> 000\ncreate alis bbb -> 111\n\nalias ccc"
          assert_no_difference("BulkUpdateRequest.count") do
            post_auth bulk_update_requests_path(format: :json), @user, params: { bulk_update_request: attributes_for(:bulk_update_request).merge(script: script) }
          end

          assert_response 422
          body = response.parsed_body
          assert_equal(false, body["success"])
          assert_equal("BulkUpdateRequest::Processor::Error", body["error"])
          assert_equal("Invalid line: create alis bbb -> 111; Invalid line: alias ccc", body["message"])
          assert_equal([
            { "line" => 2, "text" => "create alis bbb -> 111", "reason" => "Invalid line: create alis bbb -> 111" },
            { "line" => 4, "text" => "alias ccc", "reason" => "Invalid line: alias ccc" },
          ], body["errors"])
        end

        should "name each repeat of a duplicated line" do
          post_auth bulk_update_requests_path(format: :json), @user, params: { bulk_update_request: attributes_for(:bulk_update_request).merge(script: "imply a -> b\nimply c -> d\nimply a -> b") }

          assert_response 422
          assert_equal("Duplicate line found: create implication [[a]] -> [[b]]", response.parsed_body["message"])
          assert_equal([{ "line" => 3, "text" => "imply a -> b", "reason" => "This line repeats line 1" }], response.parsed_body["errors"])
        end

        should "carry an empty list of lines when no line is at fault" do
          post_auth bulk_update_requests_path(format: :json), @user, params: { bulk_update_request: attributes_for(:bulk_update_request).merge(reason: "") }

          assert_response 422
          assert_match(/Reason/, response.parsed_body["message"])
          assert_equal([], response.parsed_body["errors"])

          post_auth bulk_update_requests_path(format: :json), @user, params: { bulk_update_request: attributes_for(:bulk_update_request).merge(script: "nuke touhou\n" * 101) }
          assert_response 422
          assert_match(/too long/, response.parsed_body["message"])
          assert_equal([], response.parsed_body["errors"])
        end
      end

      # Fork: a posting bot files for a person and itself sees every
      # quarantined name, so what it files may name only what a signed-out
      # visitor may (operator, 2026-10-19). Neru-chan files over Basic auth.
      context "by a posting bot" do
        setup do
          @tunnel = create(:approver_user, name: "tunnel")
          @key = create(:api_key, user: @tunnel)
          banish_tags!("gore_thing")
        end

        should "refuse a script naming a banished tag with 422, the sentence and the line, and file nothing" do
          script = "update sword -> blade\nupdate gore_thing -> -gore_thing"
          assert_no_difference(["BulkUpdateRequest.count", "ForumTopic.count"]) do
            post bulk_update_requests_path(format: :json), params: { bulk_update_request: { script: script, title: "t", reason: "r" }},
                                                           headers: { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials(@tunnel.name, @key.key) }
          end

          assert_response 422
          body = response.parsed_body
          assert_equal("This request names a tag only an admin may change. Ask an admin to make it", body["message"])
          assert_equal([{ "line" => 2, "text" => "update gore_thing -> -gore_thing", "reason" => "This line names a tag only an admin may change" }], body["errors"])
        end

        should "refuse a script a check would refuse in a hidden tag's name without naming it" do
          create(:tag_alias, antecedent_name: "spoiler_x", consequent_name: "gore_thing")
          post bulk_update_requests_path(format: :json), params: { bulk_update_request: { script: "create alias foo -> spoiler_x", reason: "r" }},
                                                         headers: { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials(@tunnel.name, @key.key) }

          assert_response 422
          assert_no_match(/gore_thing/, response.body)
          assert_equal([{ "line" => 1, "text" => "create alias foo -> spoiler_x", "reason" => "This line conflicts with a tag only an admin may change" }], response.parsed_body["errors"])
        end

        should "file an ordinary script" do
          assert_difference("BulkUpdateRequest.count", 1) do
            post bulk_update_requests_path(format: :json), params: { bulk_update_request: { script: "update sword -> blade", title: "t", reason: "r" }},
                                                           headers: { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials(@tunnel.name, @key.key) }
          end
          assert_response 201
        end

        # Characterisation of why a bot must not file such a script: no
        # one, the Owner included, could even open the request.
        should "leave a request naming a banished tag a 404 to the owner" do
          @bulk_update_request.update_columns(script: "update gore_thing -> -gore_thing", tags: ["gore_thing"]) # rubocop:disable Rails/SkipsModelValidations
          get_auth bulk_update_request_path(@bulk_update_request, format: :json), create(:owner_user)

          assert_response 404
        end
      end
    end

    context "#update" do
      should "allow admins to update other people's requests" do
        put_auth bulk_update_request_path(@bulk_update_request.id), create(:admin_user), params: { bulk_update_request: { script: "create alias zzz -> 222" }}
        assert_redirected_to bulk_update_request_path(@bulk_update_request)
        assert_equal("create alias zzz -> 222", @bulk_update_request.reload.script)
      end

      should "not allow builders to update other people's requests" do
        put_auth bulk_update_request_path(@bulk_update_request.id), create(:builder_user), params: { bulk_update_request: { script: "create alias zzz -> 222" }}
        assert_response 403
        assert_equal("create alias aaa -> bbb", @bulk_update_request.reload.script)
      end

      should "not allow members to update other people's requests" do
        put_auth bulk_update_request_path(@bulk_update_request.id), create(:user), params: { bulk_update_request: { script: "create alias zzz -> 222" }}
        assert_response 403
        assert_equal("create alias aaa -> bbb", @bulk_update_request.reload.script)
      end

      should "allow users to update their own request when it has <5 votes" do
        4.times { create(:forum_post_vote, forum_post: @bulk_update_request.forum_post, creator: build(:user), score: 1) }
        put_auth bulk_update_request_path(@bulk_update_request.id), @user, params: { bulk_update_request: { script: "create alias zzz -> 222" }}
        assert_redirected_to bulk_update_request_path(@bulk_update_request)
        assert_equal("create alias zzz -> 222", @bulk_update_request.reload.script)
      end

      should "not allow users to update their own request when it has 5 votes or more" do
        5.times { create(:forum_post_vote, forum_post: @bulk_update_request.forum_post, creator: build(:user), score: 1) }
        put_auth bulk_update_request_path(@bulk_update_request.id), @user, params: { bulk_update_request: { script: "create alias zzz -> 222" }}
        assert_response 403
        assert_equal("create alias aaa -> bbb", @bulk_update_request.reload.script)
      end

      should "allow users to reject their own request when it has 5 votes or more" do
        5.times { create(:forum_post_vote, forum_post: @bulk_update_request.forum_post, creator: build(:user), score: 1) }
        delete_auth bulk_update_request_path(@bulk_update_request.id), @user
        assert_redirected_to bulk_update_request_path(@bulk_update_request)
        assert_equal("rejected", @bulk_update_request.reload.status)
      end

      should "fail for an invalid script" do
        put_auth bulk_update_request_path(@bulk_update_request.id), @user, params: { bulk_update_request: { script: "create alis gray -> grey" }}
        assert_response :success
        assert_equal("create alias aaa -> bbb", @bulk_update_request.reload.script)
      end
    end

    context "#index" do
      setup do
        @other_bur = create(:bulk_update_request, user: @builder, script: "create alias cirno -> 9")
        @rejected_bur = create(:bulk_update_request, status: "rejected")
        @approved_bur = create(:bulk_update_request, status: "approved", approver: @admin)
      end

      should "render" do
        get bulk_update_requests_path
        assert_response :success
      end

      # Fork: a request that skipped posts reads "partial" with its count, a
      # failed one names its line, and the search offers partial.
      should "list a partial request with its skip count and a failed one with its line" do
        partial = create(:bulk_update_request, status: "partial", results: [{ line: 1, state: "skipped_some", skipped: 2 }].as_json)
        failed = create(:bulk_update_request, status: "failed", results: [{ line: 1, state: "done", skipped: 0 }, { line: 3, state: "failed", skipped: nil }].as_json)
        get bulk_update_requests_path

        assert_response :success
        assert_select "#bulk-update-request-#{partial.id} td.status-column", text: /partial \(2 post edits skipped\)/
        assert_select "#bulk-update-request-#{failed.id} td.status-column", text: /failed at line 3/
        assert_select "select#search_status option[value=partial]", 1
      end

      # Fork: search[can_approve] judges the statuses asked for by the same
      # policy as the can_approve field, so a partial or rejected request an
      # admin may approve again is found by it; with no status it stays
      # upstream's queue, the pending requests.
      should "find approvable requests among the statuses asked for, and only pending ones when none is" do
        partial = create(:bulk_update_request, status: "partial")

        get_auth bulk_update_requests_path(format: :json, search: { status: "partial", can_approve: "true" }), @admin
        assert_equal([partial.id], response.parsed_body.pluck("id"))

        get_auth bulk_update_requests_path(format: :json, search: { status: "rejected,approved", can_approve: "true" }), @admin
        assert_equal([@rejected_bur.id], response.parsed_body.pluck("id"))

        get_auth bulk_update_requests_path(format: :json, search: { status: "partial", can_approve: "false" }), @admin
        assert_equal([], response.parsed_body.pluck("id"))

        get_auth bulk_update_requests_path(format: :json, search: { can_approve: "true" }), @admin
        assert_equal([@other_bur.id, @bulk_update_request.id].sort, response.parsed_body.pluck("id").sort)
      end

      # Fork: can_approve is served on every row. Where the viewer's level
      # alone decides it (an admin passes every approval level, a member
      # none), a page of requests is serialised without asking each line's
      # tags (Command#approval_level) row by row.
      should "serialise a page for an admin or a member without querying each row's lines" do
        aliases = ->(n) { (1..3).map { |j| "create alias q#{n}x#{j} -> q#{n}y#{j}" }.join("\n") }
        # The sign-in is left out of the count: only the listing's queries.
        queries = lambda do |user|
          login_as(user)
          count = 0
          counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" }
          ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get bulk_update_requests_path(format: :json, limit: 50) }
          assert_response :success
          count
        end

        create(:bulk_update_request, script: aliases.call(0))
        before = { admin: queries.call(@admin), member: queries.call(@user) }
        (1..4).each { |n| create(:bulk_update_request, script: aliases.call(n)) }

        assert_operator(queries.call(@admin), :<=, before[:admin] + 4)
        assert_operator(queries.call(@user), :<=, before[:member] + 4)
      end

      should respond_to_search.with { [@approved_bur, @rejected_bur, @other_bur, @bulk_update_request] }
      should respond_to_search(order: "id_desc").with { [@approved_bur, @rejected_bur, @other_bur, @bulk_update_request] }
      should respond_to_search(status: "pending").with { [@other_bur, @bulk_update_request] }
      should respond_to_search(script_matches: "cirno -> 9").with { @other_bur }
      should respond_to_search(tags_include_any: "cirno").with { @other_bur }

      context "using includes" do
        should respond_to_search(forum_topic_id: -> { @forum_topic.id }).with { @bulk_update_request }
        should respond_to_search(forum_topic: { category_id: 0 }).with { @bulk_update_request }
        should respond_to_search(user_id: -> { @user.id }).with { @bulk_update_request }
        should respond_to_search(user: { level: User::Levels::BUILDER }).with { @other_bur }
        should respond_to_search(has_approver: "true").with { @approved_bur }
        should respond_to_search(has_approver: "false").with { [@rejected_bur, @other_bur, @bulk_update_request] }
      end
    end

    context "#show" do
      should "render" do
        get bulk_update_request_path(@bulk_update_request)
        assert_response :success
      end

      # Fork: the record of a run (results) is served as `lines`, each line's
      # skipped post ids held to the posts the viewer may see, with
      # skipped_count and failed_line. The raw column, which holds every id,
      # is never served.
      context "the record of a run" do
        setup do
          @failed_run = [
            { line: 1, command: "create alias [[aaa]] -> [[bbb]]", state: "done", matched: nil, skipped: 0, skipped_post_ids: [], skipped_reasons: [], error: nil, remedy: nil },
            { line: 2, command: "mass update [[foo]] -> [[bar]]", state: "failed", matched: nil, skipped: nil, skipped_post_ids: [], skipped_reasons: [], error: "Line 2 stopped on an unexpected error.", remedy: "Nothing was rolled back. Fix it, then approve this request again." },
            { line: 3, command: "create implication [[ccc]] -> [[ddd]]", state: "not_run", matched: nil, skipped: nil, skipped_post_ids: [], skipped_reasons: [], error: nil, remedy: nil },
          ].as_json
        end

        should "serve a failed request's lines and failed_line, and never the raw results column" do
          @bulk_update_request.update_columns(status: "failed", results: @failed_run) # rubocop:disable Rails/SkipsModelValidations
          get bulk_update_request_path(@bulk_update_request, format: :json)

          assert_response :success
          body = response.parsed_body
          assert_equal(2, body["failed_line"])
          assert_equal(0, body["skipped_count"])
          assert_equal(%w[done failed not_run], body["lines"].pluck("state"))
          assert_equal("Line 2 stopped on an unexpected error.", body["lines"][1]["error"])
          assert_match(/approve this request again/, body["lines"][1]["remedy"])
          assert_not(body.key?("results"))

          get bulk_update_request_path(@bulk_update_request, format: :json, only: "id,results")
          assert_equal({ "id" => @bulk_update_request.id }, response.parsed_body)
        end

        should "show a signed-out viewer the skip count and reasons, but no id of a post hidden from them" do
          Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
          post = create(:post, is_deleted: true)
          bur = create_bur!("update id:#{post.id} -> parent:#{post.id}", @admin)
          assert_equal("partial", bur.reload.status)

          get bulk_update_request_path(bur, format: :json)
          body = response.parsed_body
          assert_equal(1, body["skipped_count"])
          assert_equal(1, body["lines"][0]["skipped"])
          assert_equal([{ "message" => "Post cannot have itself as a parent", "count" => 1 }], body["lines"][0]["skipped_reasons"])
          assert_equal([], body["lines"][0]["skipped_post_ids"])

          get_auth bulk_update_request_path(bur, format: :json), @admin
          assert_equal([post.id], response.parsed_body["lines"][0]["skipped_post_ids"])
        end

        should "show at most 100 skipped post ids a line" do
          run = [{ line: 1, command: "mass update [[foo]] -> [[bar]]", state: "skipped_some", matched: 150, skipped: 150, skipped_post_ids: (1..150).to_a, skipped_reasons: [{ message: "x", count: 150 }], error: nil, remedy: "r" }].as_json
          @bulk_update_request.update_columns(status: "partial", results: run) # rubocop:disable Rails/SkipsModelValidations
          get bulk_update_request_path(@bulk_update_request, format: :json)

          assert_equal((1..100).to_a, response.parsed_body["lines"][0]["skipped_post_ids"])
          assert_equal(150, response.parsed_body["skipped_count"])
        end

        should "serve and render a request that has not run with no lines" do
          get bulk_update_request_path(@bulk_update_request, format: :json)
          body = response.parsed_body
          assert_equal([[], 0, nil], body.values_at("lines", "skipped_count", "failed_line"))

          get bulk_update_request_path(@bulk_update_request)
          assert_response :success
          assert_select "#bulk-update-request-result", 0
        end

        should "name the failed line and its remedy on the page" do
          @bulk_update_request.update_columns(status: "failed", results: @failed_run) # rubocop:disable Rails/SkipsModelValidations
          get bulk_update_request_path(@bulk_update_request)

          assert_response :success
          assert_select "#bulk-update-request-status", text: "failed at line 2"
          assert_select "#bulk-update-request-result tr[data-state=failed]" do
            assert_select "td", text: /Line 2 stopped on an unexpected error\./
            assert_select "td", text: /approve this request again/
          end
          assert_select "#bulk-update-request-result tr[data-state=not_run]", 1
        end

        should "say a processed request with no record has none, rather than look clean" do
          @bulk_update_request.update_columns(status: "approved") # rubocop:disable Rails/SkipsModelValidations
          get bulk_update_request_path(@bulk_update_request)

          assert_response :success
          assert_select "#bulk-update-request-result", text: /No record of this run was kept/
        end

        should "name a partial request's skip count and link the skipped posts the viewer may see" do
          Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
          shown = create(:post, tag_string: "foo")
          hidden = create(:post, tag_string: "foo", is_deleted: true)
          bur = create_bur!("update foo -> parent:#{shown.id}\nupdate id:#{hidden.id} -> parent:#{hidden.id}", @admin)

          get bulk_update_request_path(bur)
          assert_response :success
          assert_select "#bulk-update-request-status", text: "partial: 2 post edits skipped"
          assert_select "#bulk-update-request-result a[href='#{post_path(shown)}']", 1
          assert_select "#bulk-update-request-result a[href='#{post_path(hidden)}']", 0
          assert_select "#bulk-update-request-result td", text: /Post cannot have itself as a parent \(1\)/

          get_auth bulk_update_request_path(bur), @admin
          assert_select "#bulk-update-request-result a[href='#{post_path(hidden)}']", 1
        end

        # skipped_count sums each line's skips: one post refused by two
        # lines is two skipped edits, never "2 posts".
        should "count a post two lines skipped as two skipped edits, not two posts" do
          post = create(:post, tag_string: "foo")
          bur = create_bur!("update id:#{post.id} -> parent:#{post.id}\nupdate id:#{post.id} -> parent:#{post.id} bar", @admin)
          assert_equal(2, bur.reload.skipped_count)

          get bulk_update_request_path(bur)
          assert_select "#bulk-update-request-status", text: "partial: 2 post edits skipped"
          assert_no_match(/2 posts/, response.body)
        end

        # The record describes the script that ran: editing the script
        # clears it, so line 2 of the new script is never called the line
        # the old one stopped at.
        should "drop the old run's record once the script is edited" do
          @bulk_update_request.update_columns(status: "failed", results: @failed_run) # rubocop:disable Rails/SkipsModelValidations
          put_auth bulk_update_request_path(@bulk_update_request, format: :json), @admin, params: { bulk_update_request: { script: "create alias aaa -> ccc\ncreate alias eee -> fff" }}
          assert_response :success

          get bulk_update_request_path(@bulk_update_request, format: :json)
          assert_equal([[], 0, nil, "failed"], response.parsed_body.values_at("lines", "skipped_count", "failed_line", "status"))

          get bulk_update_request_path(@bulk_update_request)
          assert_select "#bulk-update-request-status", text: "failed"
          assert_select "#bulk-update-request-result", text: /No record of this run was kept/
        end

        should "read a partial request with no record as partial, with no count" do
          @bulk_update_request.update_columns(status: "partial") # rubocop:disable Rails/SkipsModelValidations

          get bulk_update_request_path(@bulk_update_request)
          assert_select "#bulk-update-request-status", text: "partial"

          get bulk_update_requests_path
          assert_select "#bulk-update-request-#{@bulk_update_request.id} td.status-column", text: /partial/
          assert_select "#bulk-update-request-#{@bulk_update_request.id} td.status-column", text: /skipped/, count: 0
        end
      end
    end

    context "#destroy" do
      context "for the creator" do
        should "succeed" do
          delete_auth bulk_update_request_path(@bulk_update_request), @user
          assert_response :redirect
          assert_equal("rejected", @bulk_update_request.reload.status)
        end
      end

      context "for another Builder" do
        should "fail" do
          assert_difference("BulkUpdateRequest.count", 0) do
            delete_auth bulk_update_request_path(@bulk_update_request), create(:builder_user)
            assert_response 403
          end
        end
      end

      context "for an admin" do
        should "succeed" do
          delete_auth bulk_update_request_path(@bulk_update_request), @admin
          assert_response :redirect
          assert_equal("rejected", @bulk_update_request.reload.status)
        end
      end
    end

    context "#approve" do
      context "for a member" do
        should "fail" do
          post_auth approve_bulk_update_request_path(@bulk_update_request), @user
          assert_response 403
          assert_equal("pending", @bulk_update_request.reload.status)
        end
      end

      context "for a builder" do
        should "succeed for a small artist move" do
          create(:tag, name: "artist1a", category: Tag.categories.artist, post_count: 10)
          create(:tag, name: "artist1b", category: Tag.categories.general, post_count: 0)
          create(:tag, name: "artist2a", category: Tag.categories.artist, post_count: 20)
          @bulk_update_request = create(:bulk_update_request, script: "rename artist1a -> artist1b\ncreate alias artist2a -> artist2b")

          perform_enqueued_jobs do
            post_auth approve_bulk_update_request_path(@bulk_update_request), @builder
          end

          assert_redirected_to bulk_update_request_path(@bulk_update_request)
          assert_equal("approved", @bulk_update_request.reload.status)
          assert_equal(@builder, @bulk_update_request.approver)
          assert_equal(true, TagAlias.exists?(antecedent_name: "artist2a", consequent_name: "artist2b", status: "active"))
        end

        should "fail when approving a BUR with a mix of allowed and disallowed lines" do
          create(:tag, name: "artist1a", category: Tag.categories.artist, post_count: 10)
          create(:tag, name: "artist1b", category: Tag.categories.general, post_count: 0)
          create(:tag, name: "artist1c", category: Tag.categories.artist, post_count: 101)
          create(:tag, name: "artist1d", category: Tag.categories.general, post_count: 300)
          @bulk_update_request = create(:bulk_update_request, script: "rename artist1a -> artist1b\ncreate alias artist1c -> artist1d")

          post_auth approve_bulk_update_request_path(@bulk_update_request), @builder

          assert_response 403
          assert_equal("pending", @bulk_update_request.reload.status)
          assert_equal(false, TagAlias.exists?(antecedent_name: "test1", consequent_name: "test2"))
        end

        should "fail when moving a non-artist tag" do
          create(:tag, name: "foo", post_count: 0)
          @bulk_update_request = create(:bulk_update_request, script: "alias foo -> bar")

          post_auth approve_bulk_update_request_path(@bulk_update_request), @builder

          assert_response 403
          assert_equal("pending", @bulk_update_request.reload.status)
          assert_equal(false, TagAlias.exists?(antecedent_name: "foo", consequent_name: "bar"))
        end

        should "fail for a large artist move" do
          create(:tag, name: "artist1", category: Tag.categories.artist, post_count: 1000)
          @bulk_update_request = create(:bulk_update_request, script: "create alias artist1 -> artist2")

          post_auth approve_bulk_update_request_path(@bulk_update_request), @builder

          assert_response 403
          assert_equal("pending", @bulk_update_request.reload.status)
          assert_equal(false, TagAlias.exists?(antecedent_name: "artist1", consequent_name: "artist2"))
        end
      end

      context "for a mod" do
        should "succeed when approving small character implications" do
          create(:tag, name: "foo_(summer)", category: Tag.categories.character, post_count: 10)
          create(:tag, name: "foo", category: Tag.categories.character, post_count: 200)
          create(:wiki_page, title: "foo_(summer)", body: "asd")
          create(:wiki_page, title: "foo", body: "asd")
          @bulk_update_request = create(:bulk_update_request, script: "imply foo_(summer) -> foo")

          perform_enqueued_jobs do
            post_auth approve_bulk_update_request_path(@bulk_update_request), @mod
          end

          assert_redirected_to bulk_update_request_path(@bulk_update_request)
          assert_equal("approved", @bulk_update_request.reload.status)
          assert_equal(@mod, @bulk_update_request.approver)
          assert_equal(true, TagImplication.exists?(antecedent_name: "foo_(summer)", consequent_name: "foo", status: "active"))
        end

        should "fail for large tags" do
          create(:tag, name: "foo_(summer)", category: Tag.categories.character, post_count: 10)
          create(:tag, name: "foo", category: Tag.categories.character, post_count: 201)
          create(:wiki_page, title: "foo_(summer)", body: "asd")
          create(:wiki_page, title: "foo", body: "asd")
          @bulk_update_request = create(:bulk_update_request, script: "imply foo_(summer) -> foo")

          post_auth approve_bulk_update_request_path(@bulk_update_request), @mod

          assert_response 403
          assert_equal("pending", @bulk_update_request.reload.status)
          assert_equal(false, TagImplication.exists?(antecedent_name: "foo_(summer)", consequent_name: "foo", status: "active"))
        end
      end

      context "for an admin" do
        should "succeed" do
          post_auth approve_bulk_update_request_path(@bulk_update_request), @admin

          assert_response :redirect
          assert_equal("processing", @bulk_update_request.reload.status)
          perform_enqueued_jobs
          assert_equal("approved", @bulk_update_request.reload.status)
        end

        # Fork: a BUR whose script went stale between filing and approval
        # (another alias now conflicts) is refused 422 with the reason and
        # each failing line, and is left as it was -- not a 500 with no
        # words (BulkUpdateRequest::Processor::Error, technetium-81 2026-10-19).
        context "whose script no longer passes its checks" do
          setup do
            as(@admin) { create(:tag_alias, antecedent_name: "bbb", consequent_name: "ccc") }
          end

          should "refuse with 422, the reason and the failing line (json)" do
            assert_no_enqueued_jobs(only: ProcessBulkUpdateRequestJob) do
              assert_no_difference("ForumPost.count") do
                post_auth approve_bulk_update_request_path(@bulk_update_request, format: :json), @admin
              end
            end

            assert_response 422
            body = response.parsed_body
            assert_equal(false, body["success"])
            assert_equal("BulkUpdateRequest::Processor::Error", body["error"])
            assert_includes(body["message"], "BUR ##{@bulk_update_request.id} was not approved and is unchanged")
            assert_includes(body["message"], "Can't create alias [[aaa]] -> [[bbb]] (bbb is already aliased to ccc)")
            assert_includes(body["message"], "Fix:")
            assert_equal([{ "line" => 1, "text" => "create alias aaa -> bbb", "reason" => "Can't create alias [[aaa]] -> [[bbb]] (bbb is already aliased to ccc)" }], body["errors"])
            assert_equal("pending", @bulk_update_request.reload.status)
            assert_nil(@bulk_update_request.approver_id)
          end

          should "number the failing line as the script has it, blank lines counted" do
            @bulk_update_request.update_columns(script: "create alias ddd -> eee\n\ncreate alias aaa -> bbb") # rubocop:disable Rails/SkipsModelValidations
            post_auth approve_bulk_update_request_path(@bulk_update_request, format: :json), @admin

            assert_response 422
            assert_equal([[3, "create alias aaa -> bbb"]], response.parsed_body["errors"].map { |e| [e["line"], e["text"]] })
          end

          should "refuse with 422 and the reason (html)" do
            post_auth approve_bulk_update_request_path(@bulk_update_request), @admin

            assert_response 422
            assert_match(/bbb is already aliased to ccc/, response.body)
            assert_no_match(/Unexpected error/, response.body)
            assert_equal("pending", @bulk_update_request.reload.status)
          end

          should "show the reason in the js notice and never emit raw markup from a tag name" do
            @bulk_update_request.update!(script: "create alias aaa -> bbb<i>x")
            as(@admin) { create(:tag_alias, antecedent_name: "bbb<i>x", consequent_name: "ccc") }
            post_auth approve_bulk_update_request_path(@bulk_update_request, format: :js), @admin, xhr: true

            assert_response 422
            assert_match(/Danbooru\.Notice\.error\(/, response.body)
            assert_match(/bbb&lt;i&gt;x is already aliased to ccc/, response.body)
            assert_no_match(/<i>/, response.body)
          end

          should "name rejecting as a remedy for a pending request, and the admin's reject works" do
            post_auth approve_bulk_update_request_path(@bulk_update_request, format: :json), @admin
            assert_response 422
            assert_includes(response.parsed_body["message"], "or reject it")

            delete_auth bulk_update_request_path(@bulk_update_request, format: :json), @admin
            assert_response :success
            assert_equal("rejected", @bulk_update_request.reload.status)
          end

          # Only an admin or the requester may reject (destroy?), so the
          # refusal offers it only to an approver who may.
          should "not offer rejecting to an approver who may not reject" do
            create(:tag, name: "artist2a", category: Tag.categories.artist, post_count: 20)
            bur = create(:bulk_update_request, script: "create alias artist2a -> artist2b")
            as(@admin) { create(:tag_alias, antecedent_name: "artist2b", consequent_name: "artist2c") }

            post_auth approve_bulk_update_request_path(bur, format: :json), @builder
            assert_response 422
            assert_includes(response.parsed_body["message"], "artist2b is already aliased to artist2c")
            assert_not_includes(response.parsed_body["message"], "reject it")

            delete_auth bulk_update_request_path(bur, format: :json), @builder
            assert_response 403
          end

          should "leave a failed request failed, name only the edit as its remedy, and approve once edited" do
            @bulk_update_request.update!(status: "failed")
            post_auth approve_bulk_update_request_path(@bulk_update_request, format: :json), @admin

            assert_response 422
            assert_equal("failed", @bulk_update_request.reload.status)
            assert_includes(response.parsed_body["message"], "edit its script on the booru")
            assert_not_includes(response.parsed_body["message"], "reject it")

            put_auth bulk_update_request_path(@bulk_update_request, format: :json), @admin, params: { bulk_update_request: { script: "create alias aaa -> ccc" }}
            assert_response :success
            post_auth approve_bulk_update_request_path(@bulk_update_request, format: :json), @admin
            assert_response 201
            assert_equal("processing", @bulk_update_request.reload.status)
          end
        end

        # Fork: a refusal's words reach the card and the room. A move whose
        # ownership cannot be checked because the creator-prefix list is
        # broken says so in words; what is wrong with the list (a server
        # path, an errno, the fix's command) stays in the log.
        should "refuse a move while the creator-prefix list is broken without naming the server's files" do
          @bulk_update_request.update_columns(script: "create alias oc_aaa -> aaa_(bbb)", tags: %w[aaa_(bbb) oc_aaa]) # rubocop:disable Rails/SkipsModelValidations
          broken = "the creator-prefix list /srv/booru/config/creator_prefixes.yml cannot be read (EACCES). Fix: chmod 644 /srv/booru/config/creator_prefixes.yml " \
                   "(the canon copy is fourier-basis ops/hetzner/danbooru/creator_prefixes.yml)"
          CreatorPrefixes.stubs(:config).raises(CreatorPrefixes::ConfigError, broken)
          post_auth approve_bulk_update_request_path(@bulk_update_request, format: :json), @admin

          assert_response 422
          words = response.parsed_body.slice("message", "errors").to_json
          assert_match(/ownership cannot be checked while the creator-prefix list is broken/, words)
          assert_no_match(%r{/srv|EACCES|chmod|hetzner|fourier-basis}, words)
          assert_equal("pending", @bulk_update_request.reload.status)
        end

        # Characterisation: only the typed refusal is a 422. A request that
        # cannot be saved is a fault and stays a loud 500.
        should "keep a failure to save the request a 500" do
          BulkUpdateRequest.any_instance.stubs(:update!).raises(ActiveRecord::RecordInvalid.new(BulkUpdateRequest.new))
          post_auth approve_bulk_update_request_path(@bulk_update_request, format: :json), @admin

          assert_response 500
          assert_equal("ActiveRecord::RecordInvalid", response.parsed_body["error"])
        end

        # Characterisation of approve.js.erb's live branch.
        should "answer approve.js with the reload/queued script on success" do
          post_auth approve_bulk_update_request_path(@bulk_update_request, format: :js), @admin, xhr: true

          assert_response :success
          assert_match(/location\.reload\(\)/, response.body)
          assert_match(/\.html\("queued"\)/, response.body)
          assert_no_match(/Notice\.error/, response.body)
        end
      end
    end
  end
end
