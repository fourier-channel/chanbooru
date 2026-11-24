require "test_helper"

# ROOM LINKS GRANT NO ACCESS (operator, 2026-11-24): "So long as the room ID
# doesn't get conflated with the room ID for determining access to Matrix
# posts." A PostRoomLink only lets a post's withheld/jailed 404 reach a member
# of a linked room (MediaDoorAsk#withheld?). It never opens, closes or widens
# anything: not for the linked post, not for any Matrix post placed in the
# linked room. The last context fails if any code but the answer's body reads
# the links.
class PostRoomLinksGrantNoAccessTest < ActiveSupport::TestCase
  setup do
    Danbooru.config.stubs(:gate3_matrix_posts_enforced?).returns(true)
    Danbooru.config.stubs(:deleted_post_visibility_level).returns(User::Levels::ADMIN)
    CreatorVisibility.forget!
    @uploader = create(:approver_user)
    @linked = MatrixRoom.create!(room_id: "!linked:41chan.net")
    @member = create(:user)
    @outsider = create(:user)
  end

  teardown { CreatorVisibility.forget! }

  def in_room!(*rooms)
    MatrixViewerRooms.stubs(:ids).returns([MatrixViewerRooms::NOT_MATRIX, *rooms.map(&:id)].sort)
  end

  def outside!
    MatrixViewerRooms.stubs(:ids).returns([MatrixViewerRooms::NOT_MATRIX])
  end

  # Both ways the booru decides: the post's own check (pages, the media door)
  # and the SQL one (searches, galleries). Each is asserted on its own, so a
  # link read on either path alone is caught.
  def shown_by(post, user)
    CreatorVisibility.forget!
    own = !post.reload.hidden_from?(user)
    CreatorVisibility.forget!
    sql = Post.hidden_ids_among([post.id], user).exclude?(post.id)
    CreatorVisibility.forget!
    { own: own, sql: sql }
  end

  def assert_shown(post, user, msg = nil)
    assert_equal({ own: true, sql: true }, shown_by(post, user), msg)
  end

  def assert_hidden(post, user, msg = nil)
    assert_equal({ own: false, sql: false }, shown_by(post, user), msg)
  end

  context "a linked post that is not a Matrix post" do
    setup do
      @post = create(:post, tag_string: "a", uploader: @uploader)
      PostRoomLink.record!(@post, @linked.room_id)
    end

    should "keep room_ids {0}" do
      assert_equal [MatrixViewerRooms::NOT_MATRIX], @post.reload.room_ids
    end

    should "stay visible to a non-member and to anonymous" do
      outside!
      assert_shown(@post, @outsider, "a non-member")
      assert_shown(@post, User.anonymous, "anonymous")
    end

    should "stay visible to a member, as to everyone" do
      in_room!(@linked)
      assert_shown(@post, @member)
    end
  end

  context "a linked post hidden by another gate" do
    setup do
      @post = create(:post, tag_string: "a child", uploader: @uploader) # a real restricted tag
      PostRoomLink.record!(@post, @linked.room_id)
    end

    should "stay hidden from a member of the linked room: the link opens nothing" do
      in_room!(@linked)
      assert_hidden(@post, @member)
    end

    should "stay hidden from a non-member and from anonymous" do
      outside!
      assert_hidden(@post, @outsider)
      assert_hidden(@post, User.anonymous)
    end
  end

  context "a Matrix post placed in another room" do
    setup do
      @placed_in = MatrixRoom.create!(room_id: "!placed:41chan.net")
      @post = create(:post, tag_string: "a", uploader: @uploader)
      @post.update_columns(room_ids: [@placed_in.id]) # rubocop:disable Rails/SkipsModelValidations -- PostMxc's answer
    end

    should "stay hidden from a member of a room it is only linked into" do
      PostRoomLink.record!(@post, @linked.room_id)
      in_room!(@linked)
      assert_hidden(@post, @member)
      assert_equal [@placed_in.id], @post.reload.room_ids, "a link is not a placement"
    end

    should "stay shown to a member of its own room, links or not" do
      PostRoomLink.record!(@post, @linked.room_id)
      in_room!(@placed_in)
      assert_shown(@post, @member)
    end
  end

  context "a Matrix post placed in the linked room" do
    setup do
      @post = create(:post, tag_string: "a", uploader: @uploader)
      @post.update_columns(room_ids: [@linked.id]) # rubocop:disable Rails/SkipsModelValidations -- PostMxc's answer
      other = create(:post, tag_string: "a", uploader: @uploader)
      PostRoomLink.record!(other, @linked.room_id)
      PostRoomLink.record!(@post, @linked.room_id)
    end

    should "stay hidden from a non-member and from anonymous, whatever links the room holds" do
      outside!
      assert_hidden(@post, @outsider)
      assert_hidden(@post, User.anonymous)
    end
  end

  # THE STRUCTURAL GUARD. Every line of code (not a comment) under app/,
  # lib/ and config/ that names the links must be in the model itself, the
  # bot's writer, or MediaDoorAsk#withheld? -- the 404's body. An access
  # decision that starts reading them fails here, before any behaviour test
  # has to think of it.
  context "the code that reads room links" do
    should "be only the model, the writer, and the withheld answer" do
      allowed = {
        "app/models/post_room_link.rb" => nil,
        "app/controllers/fourier_tag_sources_controller.rb" => nil,
        "app/logical/media_door_ask.rb" => "withheld?",
      }
      offenders = []
      Dir.glob(Rails.root.join("{app,lib,config}/**/*.{rb,erb,rake}")).each do |file|
        rel = Pathname.new(file).relative_path_from(Rails.root).to_s
        current_def = nil
        File.foreach(file).with_index(1) do |line, n|
          current_def = Regexp.last_match(1) if line =~ /^\s*def\s+(?:self\.)?([\w?!]+)/
          next if line.strip.start_with?("#")
          next unless line =~ /PostRoomLink|post_room_links|room_links/

          if !allowed.key?(rel)
            offenders << "#{rel}:#{n}"
          elsif allowed[rel] && current_def != allowed[rel]
            offenders << "#{rel}:#{n} (in #{current_def}, not #{allowed[rel]})"
          end
        end
      end
      assert_empty offenders, "room links read where access is decided. Fix: links change only the withheld 404 (MediaDoorAsk#withheld?); never read them in an access decision"
    end
  end
end
