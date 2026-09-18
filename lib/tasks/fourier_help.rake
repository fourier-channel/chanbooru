# The help corpus this deployment ships, declared in the repo and seeded from it.
#
# WHY FILES AND A TASK. help:* pages are WIKI PAGES: rows in the database, not
# views. Sixty-four links across this fork pointed at them and every one 404d,
# because upstream's help describes upstream and nobody had written this
# fork's. Writing them by hand in the wiki editor would put them in one
# database and nowhere else -- no rebuild, restore or second environment would
# have them, and nothing would record what they were meant to say. That is the
# standing ruling that a database change has to live in a repo to persist
# through the normal cycle, and fourier_aliases.rake is the precedent.
#
# So each page is a file under db/help/<name>.dtext, titled help:<name>, and
# this task upserts them. The files are the source; the rows are a rendering.
# Edit the file and re-run; never edit the row.
#
# IDEMPOTENT, AND QUIET WHEN NOTHING CHANGED. A page whose body already
# matches its file is left alone, so re-running does not spam wiki versions.
# A page that was deleted is undeleted. A page that was edited in the wiki
# editor to something other than its file is OVERWRITTEN, and says so, because
# the file is the record and the row is not -- the edit belongs in the file.
#
# WHO WRITES THEM. User.system, inside CurrentUser.scoped, because WikiPage's
# after_save version hook records CurrentUser.id and a rake task has none.
#
# Run on the serving box, after a deploy that carries the files:
#   sudo docker compose run --rm -T danbooru bin/rails fourier:help
#   sudo docker compose run --rm -T danbooru bin/rails fourier:help_status

namespace :fourier do
  HELP_DIR = Rails.root.join("db/help")

  def help_files
    Dir.glob(HELP_DIR.join("*.dtext")).sort.map do |path|
      ["help:#{File.basename(path, '.dtext')}", File.read(path).strip]
    end
  end

  # The row and the file must be compared on the same line endings. The wiki
  # editor submits CRLF and the model keeps what it is given, so a body seeded
  # from an LF file reads back as CRLF; compared raw, every multi-line page
  # looked changed on every run and only the single-line notices ever read
  # "current". Measured on the first dev seed: 9 of 40. The fix is to compare
  # normalised, not to store CRLF, because the file is the record.
  def same_body?(row, body)
    row.body.to_s.gsub("\r\n", "\n").strip == body.gsub("\r\n", "\n").strip
  end

  desc "Seed the help:* wiki pages from db/help/*.dtext (idempotent)"
  task help: :environment do
    files = help_files
    abort "no files under #{HELP_DIR}" if files.empty?

    CurrentUser.scoped(User.system) do
      files.each do |title, body|
        page = WikiPage.find_by(title: title)
        if page.nil?
          WikiPage.create!(title: title, body: body)
          puts "created   #{title}"
        elsif same_body?(page, body) && !page.is_deleted?
          puts "current   #{title}"
        else
          note = page.is_deleted? ? "undeleted" : "OVERWROTE a row that differed from its file"
          page.update!(body: body, is_deleted: false)
          puts "updated   #{title}  (#{note})"
        end
      end
    end
  end

  desc "Report the state of every help:* page this deployment declares, changing nothing"
  task help_status: :environment do
    files = help_files
    rows = WikiPage.where(title: files.map(&:first)).index_by(&:title)
    files.each do |title, body|
      row = rows[title]
      state =
        if row.nil? then "ABSENT"
        elsif row.is_deleted? then "DELETED"
        elsif same_body?(row, body) then "current"
        else "DIFFERS from file"
        end
      puts format("%-32s %s", title, state)
    end
    extra = WikiPage.where("title LIKE 'help:%'").where.not(title: files.map(&:first)).pluck(:title)
    puts "\nhelp:* rows with no file (left alone): #{extra.sort.join(', ')}" if extra.any?
  end
end
