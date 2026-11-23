# frozen_string_literal: true

# The original-date backfill (SourceDateBackfill). Run in this order, so each
# post is written once:
#
#   bin/rails fourier:source_dates:import FILE=export.csv   (FILE=- reads stdin)
#   bin/rails fourier:source_dates:discord
#   bin/rails fourier:source_dates:rest
#   bin/rails fourier:source_dates:report
#
# Every pass only raises what is known about a post's date, so any of them
# can be re-run.
namespace :fourier do
  namespace :source_dates do
    desc "Date posts from a source,time,precision CSV (FILE=path, or FILE=- for stdin)"
    task import: :environment do
      file = ENV.fetch("FILE") { abort "FAIL: no FILE. Fix: FILE=export.csv, or FILE=- to read stdin" }
      io = (file == "-") ? $stdin : File.open(file)
      SourceDateBackfill.new.import(io)
    rescue SourceDateBackfill::Refused => e
      abort "FAIL: #{e.message}"
    end

    desc "Date posts whose source is a Discord message permalink, from its snowflake"
    task discord: :environment do
      SourceDateBackfill.new.discord
    end

    desc "Date every post still undated with its created_at, marked added"
    task rest: :environment do
      SourceDateBackfill.new.rest
    end

    desc "Count posts per source date precision"
    task report: :environment do
      SourceDateBackfill.new.report
    end
  end
end
