require "test_helper"

class DanbooruTempdirTest < ActiveSupport::TestCase
  context "Danbooru::Tempdir" do
    should "delete the directory when it's closed" do
      dir = Danbooru::Tempdir.create
      dir.close

      assert_equal(false, File.exist?(dir.path))
    end

    should "not be deleted by a forked process" do
      # In a forked process, only the thread that forked keeps running, so a directory that another thread is using can be
      # garbage collected in the forked process.
      #
      # Fork: the same rule bites the test itself. A finalizer that needs one
      # of the parent's other threads never returns in the child: a libvips
      # HEIF/AVIF image left as garbage finalizes into heif_context_free,
      # which joins dav1d worker threads only the parent has, so the child
      # hung forever with the parent in Process.wait. It did whenever this
      # test ran in a worker that had decoded an AVIF and not yet collected
      # it, which is test order, so the gate either passed or ran out of
      # time. Decoding one here makes that the state every run; the parent
      # collects its garbage before forking, and the wait has a deadline,
      # so a regression fails instead of hanging.
      MediaFile.open("test/files/avif/hdr_cosmos01000_cicp9-16-9_yuv420_limited_qp40.avif").preview!(150, 150)
      paths = Queue.new
      done = Queue.new
      thread = Thread.new do
        dir = Danbooru::Tempdir.create
        paths << dir.path
        done.pop
        dir.close
      end
      path = paths.pop
      3.times { GC.start(full_mark: true, immediate_sweep: true) }

      pid = Process.fork do
        3.times { GC.start(full_mark: true, immediate_sweep: true) }
        sleep 0.1 # Let the finalizers run.
        exit!(0)
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
      reaped = nil
      sleep 0.1 until (reaped = Process.waitpid(pid, Process::WNOHANG)) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      if reaped.nil?
        Process.kill(:KILL, pid)
        Process.waitpid(pid)
        flunk("the forked child did not exit within 30 s: a finalizer in it waited on a thread only the parent has. fix: collect the parent's garbage before forking (GC.start), and find what was left uncollected")
      end

      assert_equal(true, File.exist?(path))
    ensure
      done << true
      thread&.join
    end
  end
end
