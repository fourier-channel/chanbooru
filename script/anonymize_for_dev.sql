-- script/anonymize_for_dev.sql
--
-- Turns a RESTORED COPY of the production booru database into a development
-- database that holds no personal data, keeping production's shape: row
-- counts, tag counts, the creator <-> tag <-> Matrix-id joins, jailings and
-- legal holds, claims and groups.
--
-- ONE TRANSACTION. It finishes, or it leaves the copy exactly as restored.
-- It names no real person, account or value: every real string it replaces is
-- read from the database at run time, and every pseudonym is drawn from a key
-- generated per run, held in a temp table and dropped at COMMIT. Re-running on
-- a fresh restore gives different pseudonyms; nothing can invert them.
--
-- psql variables (see the run procedure):
--   cfg            JSON from script/anonymize_for_dev_config.rb (service-account
--                  names, jail-account names, Matrix server name, creator
--                  prefixes with an explicit keep|pseudonymize rule each)
--   expected_head  newest migration version in this checkout's db/migrate
--
-- VACUUM (ANALYZE) A FRESH RESTORE FIRST: the throwaway container runs with
-- autovacuum off (an autovacuum of the rewritten posts table was OOM-killed at
-- a 3 GB cap, 2026-10-18). On a fresh pg_restore the visibility map is unset,
-- so an index-only scan pays a heap fetch per entry; with a temp table's
-- missing statistics (now ANALYZEd where each is made) the verifier's shape()
-- planned a nested loop over 31M ai_tags entries and ran an hour on a fresh
-- copy, 11 s on a vacuumed one (measured by the drill's hook, 2026-10-18).
--
-- REFUSES TO RUN unless: anon_guard.armed has a row (created by hand after the
-- restore, never present on production), the server listens on no TCP address,
-- the copy is not already anonymized, its migration head equals expected_head,
-- every text-like column of every table is classified below, and no
-- replication, subscription, foreign-data or trigger hook exists.
--
-- Proof that it worked is NOT this file's job: script/anonymize_for_dev_verify.sql
-- plants canaries before, scans every column after, and compares shape.

\set ON_ERROR_STOP on
\timing on
\echo '[anon] 0/9 guards'
BEGIN;
SET LOCAL search_path = public;
SET LOCAL lock_timeout = '30s';
SET LOCAL work_mem = '256MB';

CREATE TEMP TABLE anon_input ON COMMIT DROP AS
  SELECT :'cfg'::jsonb AS cfg, :'expected_head'::text AS expected_head;

DO $guard$
DECLARE
  armed boolean;
  head text;
BEGIN
  IF to_regclass('anon_guard.armed') IS NULL THEN
    RAISE EXCEPTION 'refusing to run: this database is not armed for anonymization'
      USING HINT = 'This runs only on a restored throwaway copy. After restoring it, run: CREATE SCHEMA anon_guard; CREATE TABLE anon_guard.armed (at timestamptz NOT NULL DEFAULT now()); INSERT INTO anon_guard.armed DEFAULT VALUES;';
  END IF;
  EXECUTE 'SELECT EXISTS (SELECT 1 FROM anon_guard.armed)' INTO armed;
  IF NOT armed THEN
    RAISE EXCEPTION 'refusing to run: anon_guard.armed is empty' USING HINT = 'INSERT INTO anon_guard.armed DEFAULT VALUES; on the throwaway copy only.';
  END IF;
  IF current_setting('listen_addresses') <> '' THEN
    RAISE EXCEPTION 'refusing to run: the server listens on TCP'
      USING HINT = 'Start the throwaway container with --network none and -c listen_addresses='''' and connect over its unix socket (docker exec ... psql).';
  END IF;
  IF EXISTS (SELECT 1 FROM ar_internal_metadata WHERE key = 'anonymized_for_dev') THEN
    RAISE EXCEPTION 'refusing to run: this copy is already anonymized'
      USING HINT = 'A second run would re-pseudonymize pseudonyms. Restore a fresh copy and start over.';
  END IF;
  SELECT max(version) INTO head FROM schema_migrations;
  IF head IS DISTINCT FROM (SELECT expected_head FROM anon_input) THEN
    RAISE EXCEPTION 'refusing to run: the copy is at migration %, this checkout expects %', head, (SELECT expected_head FROM anon_input)
      USING HINT = 'Restore a copy taken at the same migration as this checkout, or check out the commit that matches it; the classification below is only valid for one schema.';
  END IF;
END
$guard$;

-- Catalog hooks that act outside the tables. structure.sql has none of these;
-- anything here is drift or a physical-restore leftover that could reach production.
DO $hooks$
DECLARE
  bad text;
BEGIN
  SELECT string_agg(extname, ', ') INTO bad FROM pg_extension
   WHERE extname NOT IN ('plpgsql', 'btree_gin', 'fuzzystrmatch', 'pg_trgm', 'pgcrypto', 'pgstattuple');
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'refusing to run: unexpected extensions: %', bad USING HINT = 'structure.sql installs only btree_gin, fuzzystrmatch, pg_trgm, pgcrypto, pgstattuple. Find out why the copy has more before anonymizing it.'; END IF;
  IF EXISTS (SELECT 1 FROM pg_subscription) THEN RAISE EXCEPTION 'refusing to run: the copy has a logical-replication subscription' USING HINT = 'DROP SUBSCRIPTION (after ALTER SUBSCRIPTION ... DISABLE; SET (slot_name = NONE)) before anything else.'; END IF;
  IF EXISTS (SELECT 1 FROM pg_replication_slots) THEN RAISE EXCEPTION 'refusing to run: the copy has replication slots' USING HINT = 'SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots;'; END IF;
  IF EXISTS (SELECT 1 FROM pg_foreign_server) OR EXISTS (SELECT 1 FROM pg_user_mapping) THEN RAISE EXCEPTION 'refusing to run: the copy has foreign servers or user mappings' USING HINT = 'Drop them; a dev copy reaches no other server.'; END IF;
  IF EXISTS (SELECT 1 FROM pg_event_trigger) THEN RAISE EXCEPTION 'refusing to run: the copy has event triggers' USING HINT = 'Drop them; structure.sql defines none.'; END IF;
  SELECT string_agg(c.relname || '.' || t.tgname, ', ') INTO bad
    FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND NOT t.tgisinternal;
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'refusing to run: user triggers on public tables: %', bad USING HINT = 'structure.sql defines none; a trigger would fire on every UPDATE below.'; END IF;
  IF current_setting('archive_mode') <> 'off' THEN RAISE EXCEPTION 'refusing to run: archive_mode is on' USING HINT = 'Start the throwaway server with -c archive_mode=off; WAL of this run must go nowhere.'; END IF;
END
$hooks$;

-- ---------------------------------------------------------------------------
-- Every text-like column (text, varchar, char, json/jsonb, inet/cidr, uuid,
-- bytea, arrays, user-defined) of every public table, with what happens to it.
-- A column missing here, or listed here and missing from the copy, aborts the
-- run: a migration that adds a column must classify it first.
--   keep   system or public data, untouched     map    pseudonymized
--   fill   replaced by generated filler           blank  reset to empty
--   null   set NULL                               derive rebuilt from mapped data
--   purge  the whole table is emptied
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE anon_class (tbl text, col text, action text, PRIMARY KEY (tbl, col)) ON COMMIT DROP;
INSERT INTO anon_class (tbl, col, action)
SELECT btrim(split_part(l, ':', 1)), split_part(e, '=', 1), split_part(e, '=', 2)
  FROM regexp_split_to_table($cls$
api_keys: key=purge name=purge permissions=purge permitted_ip_addresses=purge last_ip_address=purge
ar_internal_metadata: key=keep value=derive
artist_claims: status=keep note=fill tag_name=map
artist_commentaries: original_title=fill original_description=fill translated_title=fill translated_description=fill
artist_commentary_versions: original_title=fill original_description=fill translated_title=fill translated_description=fill
artist_urls: url=fill
artist_versions: name=map group_name=map other_names=blank urls=blank
artists: name=map group_name=map other_names=blank
bans: reason=fill
bulk_update_requests: script=map status=keep tags=derive
character_claims: tag_name=map status=keep note=fill creator_slug=map
comments: body=fill
creator_galleries: slug=map matrix_id=map title=fill bio=fill style=keep matrix_contact=map settings=blank default_audience=keep
creator_gallery_messages: body=fill
creator_group_memberships: source=keep
creator_groups: name=derive
creator_join_requests: status=keep note=fill
creator_post_audiences: audience=keep
creator_tag_releases: tag_name=map note=fill
creator_user_rules: rule=keep
dmails: title=fill body=fill
dtext_links: model_type=purge link_target=purge
email_addresses: address=map normalized_address=map
favorite_groups: name=fill post_ids=keep
forum_posts: body=fill
forum_topics: title=fill
fourier_generation_metadata: md5=keep source=keep poster=map fields=fill raw_md5=keep
fourier_post_creators: mxid=map
fourier_tag_sources: tag=map
good_job_batches: id=purge description=purge serialized_properties=purge on_finish=purge on_success=purge on_discard=purge callback_queue_name=purge
good_job_executions: id=purge active_job_id=purge job_class=purge queue_name=purge serialized_params=purge error=purge error_backtrace=purge process_id=purge
good_job_processes: id=purge state=purge
good_job_settings: id=purge key=purge value=purge
good_jobs: id=purge queue_name=purge serialized_params=purge error=purge active_job_id=purge concurrency_key=purge cron_key=purge retried_good_job_id=purge batch_id=purge batch_callback_id=purge job_class=purge labels=purge locked_by_id=purge
ip_bans: ip_addr=purge reason=purge
ip_geolocations: ip_addr=purge network=purge organization=purge time_zone=purge continent=purge country=purge region=purge city=purge carrier=purge
landing_categories: key=keep label=map kind=keep board=keep tags=map ordering=keep
landing_settings: board=keep label=map error_page_post_ids=keep
login_sessions: login_id=purge session_id=purge
matrix_media: mxc=map uploader=map room_ids=keep
matrix_placement_cursors: stream=keep
matrix_rooms: room_id=map
media_assets: md5=keep file_ext=keep file_key=keep pixel_hash=keep
media_metadata: metadata=derive
mod_actions: description=derive subject_type=keep
moderation_reports: model_type=keep reason=fill
modulation_settings: image_cap=keep gallery_sort=keep gallery_view=keep random_trails=blank
news_updates: message=fill
note_versions: body=fill
notes: body=fill
pool_versions: name=fill description=fill category=keep post_ids=keep added_post_ids=keep removed_post_ids=keep
pools: name=fill description=fill post_ids=keep category=keep
post_appeals: reason=fill
post_disapprovals: reason=keep message=fill
post_flags: reason=derive
post_replacements: original_url=map replacement_url=map old_file_ext=keep old_md5=keep file_ext=keep md5=keep
posts: source=map md5=keep rating=keep tag_string=map file_ext=keep room_ids=keep
post_mxcs: mxc=map source=keep
post_versions: rating=keep source=map tags=map added_tags=map removed_tags=map
rate_limits: action=purge key=purge
reactions: model_type=keep
saved_searches: query=map labels=map
schema_migrations: version=keep
signup_tokens: token=purge note=purge
site_credentials: credential=purge metadata=purge
tag_aliases: antecedent_name=map consequent_name=map status=keep reason=fill
tag_grants: tag=map ability=keep
tag_implications: antecedent_name=map consequent_name=map status=keep reason=fill
tag_quarantines: state=keep note=fill
tag_versions: name=map
tags: name=map words=derive
upgrade_codes: code=purge
upload_media_assets: source_url=map error=null page_url=map
uploads: source=map status=keep referer_url=map error=null
user_events: ip_addr=purge session_id=purge user_agent=purge metadata=purge login_session_id=purge
user_feedback: category=keep body=fill
user_name_change_requests: original_name=map desired_name=map
user_upgrades: transaction_id=purge
users: name=map default_image_size=keep favorite_tags=map blacklisted_tags=map time_zone=blank bcrypt_password_hash=derive custom_style=null last_ip_addr=null totp_secret=null backup_codes=null
wiki_page_versions: title=map body=fill other_names=blank
user_sessions: ip_addr=purge session_id=purge user_agent=purge
wiki_pages: title=map body=fill other_names=blank
$cls$, '\n') AS l
CROSS JOIN LATERAL regexp_split_to_table(btrim(split_part(l, ':', 2)), '\s+') AS e
 WHERE btrim(l) <> '';

DO $drift$
DECLARE
  missing text;
  stale text;
BEGIN
  WITH live AS (
    SELECT c.table_name::text AS tbl, c.column_name::text AS col
      FROM information_schema.columns c
      JOIN information_schema.tables t
        ON t.table_schema = c.table_schema AND t.table_name = c.table_name AND t.table_type = 'BASE TABLE'
     WHERE c.table_schema = 'public'
       AND c.data_type IN ('text', 'character varying', 'character', 'json', 'jsonb', 'inet', 'cidr',
                           'uuid', 'bytea', 'ARRAY', 'USER-DEFINED', 'xml', 'tsvector', 'macaddr', 'macaddr8'))
  SELECT (SELECT string_agg(tbl || '.' || col, ', ' ORDER BY tbl, col) FROM (SELECT tbl, col FROM live EXCEPT SELECT tbl, col FROM anon_class) m),
         (SELECT string_agg(tbl || '.' || col, ', ' ORDER BY tbl, col) FROM (SELECT tbl, col FROM anon_class EXCEPT SELECT tbl, col FROM live) s)
    INTO missing, stale;
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'refusing to run: unclassified columns: %', missing
      USING HINT = 'Add each to the classification block in script/anonymize_for_dev.sql with keep|map|fill|blank|null|derive|purge, handle it below, and add it to the verify plan.';
  END IF;
  IF stale IS NOT NULL THEN
    RAISE EXCEPTION 'refusing to run: classified columns missing from the copy: %', stale
      USING HINT = 'The copy is not at the schema this file was written for. Check the migration head and structure.sql.';
  END IF;
END
$drift$;

-- ---------------------------------------------------------------------------
\echo '[anon] 1/9 configuration and key'
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE anon_keep ON COMMIT DROP AS
  SELECT DISTINCT lower(btrim(x)) AS name
    FROM anon_input, jsonb_array_elements_text(cfg -> 'keep_names') x
   WHERE btrim(x) <> '';
CREATE TEMP TABLE anon_prefix ON COMMIT DROP AS
  SELECT e ->> 'prefix' AS prefix, e ->> 'provenance' AS provenance, e ->> 'action' AS action
    FROM anon_input, jsonb_array_elements(cfg -> 'prefixes') e;

DO $cfg$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM anon_keep) THEN
    RAISE EXCEPTION 'cfg.keep_names is empty' USING HINT = 'Generate cfg with script/anonymize_for_dev_config.rb; it lists the system user, posting bots, jail and quarantine accounts and prefix editors.';
  END IF;
  IF coalesce((SELECT cfg ->> 'matrix_server' FROM anon_input), '') = '' THEN
    RAISE EXCEPTION 'cfg.matrix_server is empty' USING HINT = 'It is Danbooru.config.fourier_matrix_server_name; regenerate cfg.';
  END IF;
  IF EXISTS (SELECT 1 FROM anon_prefix WHERE action IS NULL OR action NOT IN ('keep', 'pseudonymize') OR prefix !~ '^[a-z0-9]{1,16}_$') THEN
    RAISE EXCEPTION 'cfg.prefixes has a prefix with no valid rule' USING HINT = 'Every creator prefix needs action keep or pseudonymize in script/anonymize_for_dev_config.rb RULES.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM anon_prefix WHERE action = 'pseudonymize') THEN
    RAISE EXCEPTION 'cfg.prefixes pseudonymizes nothing' USING HINT = 'The operator ruling pseudonymizes the Matrix and Discord prefixes; check RULES.';
  END IF;
END
$cfg$;

CREATE TEMP TABLE anon_re ON COMMIT DROP AS
  SELECT '^(' || string_agg(prefix, '|' ORDER BY length(prefix) DESC, prefix) || ')(.+)$' AS pseud,
         '^(' || string_agg(prefix, '|' ORDER BY length(prefix) DESC, prefix) || ')' AS pseud_any
    FROM anon_prefix WHERE action = 'pseudonymize';

CREATE TEMP TABLE anon_key ON COMMIT DROP AS SELECT gen_random_bytes(32) AS k;

CREATE FUNCTION pg_temp.h(p text) RETURNS text LANGUAGE sql STABLE AS
$$ SELECT encode(hmac(convert_to(p, 'UTF8'), (SELECT k FROM anon_key), 'sha256'), 'hex') $$;

CREATE FUNCTION pg_temp.b64(p text, n int) RETURNS text LANGUAGE sql STABLE AS
$$ SELECT translate(left(encode(hmac(convert_to(p, 'UTF8'), (SELECT k FROM anon_key), 'sha256'), 'base64'), n), '+/', '-_') $$;

-- Filler of about the original length; never derived from the original text.
CREATE FUNCTION pg_temp.fill(p text, label text) RETURNS text LANGUAGE sql IMMUTABLE AS
$$ SELECT CASE WHEN p IS NULL THEN NULL WHEN p = '' THEN ''
               ELSE rpad(label, greatest(length(label), least(length(p), 100000)), ' lorem ipsum dolor sit amet') END $$;

-- A Matrix server name: the configured homeserver stays (CreatorControl and
-- FourierCreatorPrivacy build @<localpart>:<it>); any other host becomes an
-- opaque per-host .invalid name, so @x:a and @x:b stay different accounts.
CREATE FUNCTION pg_temp.host(p text) RETURNS text LANGUAGE sql STABLE AS
$$ SELECT CASE WHEN lower(p) = lower((SELECT cfg ->> 'matrix_server' FROM anon_input)) THEN lower(p)
               ELSE 'h' || left(pg_temp.h('host:' || lower(p)), 12) || '.invalid' END $$;

-- Tag.parse_words (app/models/tag.rb), for renamed tags.
CREATE FUNCTION pg_temp.words(p text) RETURNS varchar[] LANGUAGE sql IMMUTABLE AS
$$ SELECT CASE WHEN p !~ '[a-zA-Z0-9]{2}' THEN ARRAY[p]::varchar[]
               ELSE coalesce((SELECT array_agg(w ORDER BY o)::varchar[]
                                FROM (SELECT regexp_replace(s, '^[^a-zA-Z0-9]+|[^a-zA-Z0-9]+$', '', 'g') AS w, o
                                        FROM unnest(regexp_split_to_array(p, '[ _+:;!./()-]+')) WITH ORDINALITY x(s, o)) y
                               WHERE w <> ''), '{}'::varchar[]) END $$;

-- ---------------------------------------------------------------------------
\echo '[anon] 2/9 harvest: every person-name string, from the untouched data'
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE anon_mxid_src ON COMMIT DROP AS
  SELECT matrix_id AS v FROM creator_galleries
  UNION SELECT matrix_contact FROM creator_galleries WHERE matrix_contact ~ '^@[^:[:space:]]+:[^[:space:]]+$'
  UNION SELECT mxid FROM fourier_post_creators
  UNION SELECT DISTINCT uploader FROM matrix_media WHERE uploader <> ''
  UNION SELECT poster FROM fourier_generation_metadata WHERE poster LIKE '@%';

-- Every string that names a tag, from every column that carries tag names.
-- Big columns contribute only creator-prefixed tokens.
CREATE TEMP TABLE anon_tagname_src (name text PRIMARY KEY) ON COMMIT DROP;
CREATE FUNCTION pg_temp.qtokens(p text) RETURNS SETOF text LANGUAGE sql IMMUTABLE AS
$$ SELECT regexp_replace(w, '^[-~]+', '') FROM regexp_split_to_table(coalesce(p, ''), '\s+') w WHERE w <> '' AND w !~ '[*?]' $$;

INSERT INTO anon_tagname_src
SELECT DISTINCT n FROM (
        SELECT name AS n FROM tags
  UNION SELECT name FROM tag_versions
  UNION SELECT antecedent_name FROM tag_aliases UNION SELECT consequent_name FROM tag_aliases
  UNION SELECT antecedent_name FROM tag_implications UNION SELECT consequent_name FROM tag_implications
  UNION SELECT name FROM artists UNION SELECT group_name FROM artists UNION SELECT unnest(other_names) FROM artists
  UNION SELECT name FROM artist_versions UNION SELECT group_name FROM artist_versions UNION SELECT unnest(other_names) FROM artist_versions
  UNION SELECT title FROM wiki_pages UNION SELECT unnest(other_names) FROM wiki_pages
  UNION SELECT title FROM wiki_page_versions UNION SELECT unnest(other_names) FROM wiki_page_versions
  UNION SELECT tag_name FROM artist_claims UNION SELECT tag_name FROM character_claims
  UNION SELECT tag_name FROM creator_tag_releases UNION SELECT tag FROM tag_grants
  UNION SELECT unnest(tags) FROM landing_categories UNION SELECT unnest(tags) FROM bulk_update_requests
  UNION SELECT pg_temp.qtokens(script) FROM bulk_update_requests
  UNION SELECT pg_temp.qtokens(query) FROM saved_searches
  UNION SELECT pg_temp.qtokens(favorite_tags) FROM users UNION SELECT pg_temp.qtokens(blacklisted_tags) FROM users
) s WHERE n IS NOT NULL AND n <> ''
ON CONFLICT DO NOTHING;

INSERT INTO anon_tagname_src
SELECT DISTINCT tag FROM fourier_tag_sources WHERE lower(tag) ~ (SELECT pseud_any FROM anon_re)
ON CONFLICT DO NOTHING;
INSERT INTO anon_tagname_src
SELECT DISTINCT t FROM posts, unnest(string_to_array(tag_string, ' ')) t WHERE lower(t) ~ (SELECT pseud_any FROM anon_re)
ON CONFLICT DO NOTHING;
INSERT INTO anon_tagname_src
SELECT DISTINCT t FROM post_versions, unnest(added_tags || removed_tags) t WHERE lower(t) ~ (SELECT pseud_any FROM anon_re)
ON CONFLICT DO NOTHING;

CREATE TEMP TABLE anon_name_src (name text, src text) ON COMMIT DROP;
INSERT INTO anon_name_src SELECT lower(name), 'user' FROM users;
INSERT INTO anon_name_src SELECT lower(original_name), 'rename' FROM user_name_change_requests
                    UNION ALL SELECT lower(desired_name), 'rename' FROM user_name_change_requests;
INSERT INTO anon_name_src SELECT lower(slug), 'slug' FROM creator_galleries;
INSERT INTO anon_name_src SELECT lower(creator_slug), 'slug' FROM character_claims WHERE creator_slug IS NOT NULL;
INSERT INTO anon_name_src SELECT lower(substring(v FROM '^@([^:]+):')), 'mxid' FROM anon_mxid_src WHERE v ~ '^@[^:]+:';
INSERT INTO anon_name_src
SELECT lower(m[2]), 'tag' FROM anon_tagname_src s, regexp_match(lower(s.name), (SELECT pseud FROM anon_re)) m WHERE m IS NOT NULL;
-- Booru names baked into the jail's reason templates (Post#report_jailing_entered,
-- the post-page pill, the review-queue banish): mapped so the templates survive.
INSERT INTO anon_name_src
SELECT lower(coalesce(m[1], m[2], m[3])), 'jail'
  FROM (SELECT substring(description FROM '^(?:deleted|jailed) post #[0-9]+, reason: (.*)$') AS r
          FROM mod_actions WHERE category IN (42, 1114)
        UNION ALL
        SELECT reason FROM post_flags WHERE reason LIKE 'troll jail: %') s,
       regexp_match(r, '^troll jail: (?:moderator (\S+), from the post page|(\S+) banished a tag, from the review queue|(\S+) (?:tagged a deleted post|deleted a post tagged) \S+)$') m
 WHERE m IS NOT NULL;

DO $harvest$
BEGIN
  IF EXISTS (SELECT 1 FROM anon_name_src WHERE src NOT IN ('user', 'rename') AND name ~ '^user_[0-9]+$') THEN
    RAISE EXCEPTION 'a Matrix localpart, gallery slug or creator tag suffix has the deleted-user shape user_<n>, which the pseudonyms use'
      USING HINT = 'Find it with: SELECT src, count(*) FROM anon_name_src WHERE name ~ ''^user_[0-9]+$'' GROUP BY 1 (in a session of your own, never in a log you keep). Rename the pseudonym scheme before running.';
  END IF;
  IF EXISTS (SELECT lower(matrix_id) FROM creator_galleries GROUP BY 1 HAVING count(*) > 1)
     OR EXISTS (SELECT lower(slug) FROM creator_galleries GROUP BY 1 HAVING count(*) > 1) THEN
    RAISE EXCEPTION 'two creator galleries differ only by letter case in matrix_id or slug'
      USING HINT = 'The Matrix-id map is case-insensitive (the code compares lower(mxid)), so both would map to one value and break the unique index. Merge or fix them on production first.';
  END IF;
END
$harvest$;

-- NAMEMAP: one table, lower(real) -> pseudonym, for every person-name kind,
-- because the code joins them by equality (CreatorActivity: uploader name ==
-- Matrix-prefix tag suffix; ArtistClaim.refusal: other-prefix suffix == Matrix localpart;
-- CreatorControl: tag suffix == @localpart; CharacterClaim: <name>_(<slug>)).
-- A current booru account becomes user_<id>; every other name creator_<n>,
-- numbered in keyed-HMAC order, so the numbering says nothing.
CREATE TEMP TABLE anon_namemap (real text PRIMARY KEY, fake text NOT NULL UNIQUE) ON COMMIT DROP;
INSERT INTO anon_namemap (real, fake)
SELECT lower(u.name), 'user_' || u.id FROM users u
 WHERE lower(u.name) NOT IN (SELECT name FROM anon_keep) AND u.name !~* '^user_[0-9]+$';
INSERT INTO anon_namemap (real, fake)
SELECT real, 'creator_' || row_number() OVER (ORDER BY pg_temp.h('name:' || real))
  FROM (SELECT DISTINCT name AS real FROM anon_name_src WHERE name IS NOT NULL AND name <> '') s
 WHERE real NOT IN (SELECT name FROM anon_keep)
   AND real !~ '^user_[0-9]+$'
   AND real NOT IN (SELECT real FROM anon_namemap);

DO $namemap$
BEGIN
  IF EXISTS (SELECT 1 FROM anon_namemap a JOIN anon_namemap b ON a.fake = b.real) THEN
    RAISE EXCEPTION 'a real name already has the shape of a pseudonym (creator_<n> or user_<n>)'
      USING HINT = 'Renaming would merge two people. Change the creator_ pseudonym prefix in this file and run again.';
  END IF;
  IF EXISTS (SELECT 1 FROM anon_namemap WHERE fake IN (SELECT name FROM anon_keep)) THEN
    RAISE EXCEPTION 'a pseudonym equals a kept service-account name' USING HINT = 'Change the pseudonym prefix.';
  END IF;
  IF EXISTS (SELECT 1 FROM users a JOIN users b ON lower(b.name) = 'user_' || a.id AND b.id <> a.id
              WHERE lower(a.name) IN (SELECT real FROM anon_namemap)) THEN
    RAISE EXCEPTION 'an account already holds the name user_<id> of another account' USING HINT = 'Inspect users whose name matches user_<n> with a different id.';
  END IF;
END
$namemap$;

-- ---------------------------------------------------------------------------
\echo '[anon] 3/9 tag map'
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE anon_localpart ON COMMIT DROP AS
  SELECT DISTINCT lower(slug) AS lp FROM creator_galleries
  UNION SELECT lower(creator_slug) FROM character_claims WHERE creator_slug IS NOT NULL
  UNION SELECT lower(substring(v FROM '^@([^:]+):')) FROM anon_mxid_src WHERE v ~ '^@[^:]+:';

CREATE TEMP TABLE anon_tagmap (real text PRIMARY KEY, fake text NOT NULL UNIQUE, kind text NOT NULL) ON COMMIT DROP;

-- (a) Banished names: production shows them to no admin, so neither does dev.
INSERT INTO anon_tagmap (real, fake, kind)
SELECT t.name, 'banished_' || row_number() OVER (ORDER BY pg_temp.h('banished:' || t.name)), 'banished'
  FROM tags t JOIN tag_quarantines q ON q.tag_id = t.id
 WHERE q.state = 'banished';

-- (b) Names known ONLY as creator-private prompt tags (on no post, in no
-- public provenance row, alias, implication or wiki): the name itself came
-- from a prompt. Private names that are shared vocabulary stay; their (post,
-- tag) pairs are deleted below instead.
INSERT INTO anon_tagmap (real, fake, kind)
-- As set differences, each table read once: fourier_tag_sources holds ~105M
-- rows, and a NOT EXISTS per private name (29,617 of them; no index covers a
-- public row by tag) scanned it once per name -- days, measured 2026-10-18.
SELECT p.tag, 'private_tag_' || row_number() OVER (ORDER BY pg_temp.h('private:' || p.tag)), 'private'
  FROM (SELECT tag FROM fourier_tag_sources WHERE public = false
        EXCEPT SELECT tag FROM fourier_tag_sources WHERE public
        EXCEPT SELECT name FROM tags WHERE coalesce(post_count, 0) <> 0
        EXCEPT SELECT antecedent_name FROM tag_aliases
        EXCEPT SELECT consequent_name FROM tag_aliases
        EXCEPT SELECT antecedent_name FROM tag_implications
        EXCEPT SELECT consequent_name FROM tag_implications
        EXCEPT SELECT title FROM wiki_pages
        EXCEPT SELECT real FROM anon_tagmap) p;

-- (c) Creator tags under a pseudonymized prefix: prefix + NAMEMAP(suffix).
-- A suffix that is a kept service name has no NAMEMAP row and stays.
INSERT INTO anon_tagmap (real, fake, kind)
SELECT s.name, m[1] || n.fake, 'prefixed'
  FROM anon_tagname_src s
 CROSS JOIN LATERAL regexp_match(lower(s.name), (SELECT pseud FROM anon_re)) m
  JOIN anon_namemap n ON n.real = m[2]
 WHERE m IS NOT NULL AND s.name NOT IN (SELECT real FROM anon_tagmap);

-- (d) Original-character tags <name>_(<localpart>) (FourierTagSource::ORIGINAL_CHARACTER),
-- on evidence only: the qualifier is a creator's localpart AND the tag is
-- claimed or filed as a character. A general <x>_(<word>) is never touched.
INSERT INTO anon_tagmap (real, fake, kind)
SELECT s.name, m[1] || '_(' || n.fake || ')', 'oc'
  FROM anon_tagname_src s
 CROSS JOIN LATERAL regexp_match(s.name, '^([a-z0-9][^()]*)_\(([^()]+)\)$') m
  JOIN anon_namemap n ON n.real = lower(m[2])
 WHERE m IS NOT NULL
   AND lower(m[2]) IN (SELECT lp FROM anon_localpart)
   AND (EXISTS (SELECT 1 FROM character_claims c WHERE c.tag_name = s.name)
        OR EXISTS (SELECT 1 FROM tags t WHERE t.name = s.name AND t.category = 4))
   AND s.name NOT IN (SELECT real FROM anon_tagmap);

DO $tagmap$
DECLARE
  r record;
BEGIN
  IF EXISTS (SELECT 1 FROM anon_tagmap m JOIN anon_tagname_src s ON s.name = m.fake) THEN
    RAISE EXCEPTION 'a pseudonymized tag name equals an existing tag name'
      USING HINT = 'Renaming would merge two tags (and could break the unique index mid-update). Change the pseudonym prefixes in this file.';
  END IF;
  FOR r IN SELECT kind, count(*) AS n FROM anon_tagmap GROUP BY kind ORDER BY kind LOOP
    RAISE NOTICE '[anon] tag map: % %', r.n, r.kind;
  END LOOP;
  RAISE NOTICE '[anon] names: % mapped (% current accounts)', (SELECT count(*) FROM anon_namemap), (SELECT count(*) FROM anon_namemap WHERE fake LIKE 'user\_%');
  RAISE NOTICE '[anon] kept OC-shaped tags whose qualifier is a creator localpart (general, unclaimed): %',
    (SELECT count(*) FROM tags t, regexp_match(t.name, '^[a-z0-9][^()]*_\(([^()]+)\)$') m
      WHERE m IS NOT NULL AND lower(m[1]) IN (SELECT lp FROM anon_localpart) AND t.name NOT IN (SELECT real FROM anon_tagmap));
  RAISE NOTICE '[anon] artist-tag prefix families (>= 20 tags) with no creator-prefix rule: %',
    (SELECT count(*) FROM (SELECT p FROM (SELECT substring(name FROM '^([a-z0-9]{1,16}_)') AS p FROM tags WHERE category = 1) s
                             WHERE p IS NOT NULL AND p NOT IN (SELECT prefix FROM anon_prefix) GROUP BY p HAVING count(*) >= 20) z);
END
$tagmap$;

-- Pool, favourite-group and saved-search label names referenced from queries.
CREATE TEMP TABLE anon_poolmap ON COMMIT DROP AS
  SELECT DISTINCT ON (lower(name)) lower(name) AS real, 'pool_' || id AS fake FROM pools ORDER BY lower(name), id;
CREATE TEMP TABLE anon_favgroupmap ON COMMIT DROP AS
  SELECT DISTINCT ON (lower(name)) lower(name) AS real, 'group_' || id AS fake FROM favorite_groups ORDER BY lower(name), id;
CREATE TEMP TABLE anon_labelmap ON COMMIT DROP AS
  SELECT real, 'label_' || row_number() OVER (ORDER BY pg_temp.h('label:' || real)) AS fake
    FROM (SELECT DISTINCT lower(l) AS real FROM saved_searches, unnest(labels) l) s;

-- Private (creator-only) provenance, per post, captured before it is deleted.
CREATE TEMP TABLE anon_private ON COMMIT DROP AS
  SELECT post_id, array_agg(tag) AS tags FROM fourier_tag_sources WHERE public = false GROUP BY post_id;
CREATE UNIQUE INDEX ON anon_private (post_id);
ANALYZE anon_private;
ANALYZE anon_tagmap;
ANALYZE anon_namemap;

-- ---------------------------------------------------------------------------
\echo '[anon] 4/9 mapping functions'
-- ---------------------------------------------------------------------------
-- A person name. Kept service names and deleted-user names stay; an unknown
-- name (typed into a query, say) becomes an opaque token, never itself.
CREATE FUNCTION pg_temp.nm(p text) RETURNS text LANGUAGE sql STABLE AS
$$ SELECT CASE WHEN p IS NULL THEN NULL WHEN p = '' THEN ''
               WHEN lower(p) IN (SELECT name FROM anon_keep) OR p ~* '^user_[0-9]+$' THEN p
               ELSE coalesce((SELECT fake FROM anon_namemap WHERE real = lower(p)),
                             'unknown_' || left(pg_temp.h('unknown:' || lower(p)), 8)) END $$;

CREATE FUNCTION pg_temp.tm(p text) RETURNS text LANGUAGE sql STABLE AS
$$ SELECT coalesce((SELECT fake FROM anon_tagmap WHERE real = p), p) $$;

-- Element-wise, order kept, optionally dropping some names first.
CREATE FUNCTION pg_temp.tm_arr(p text[], p_drop text[] DEFAULT '{}') RETURNS text[] LANGUAGE sql STABLE AS
$$ SELECT CASE WHEN p IS NULL THEN NULL ELSE
     coalesce((SELECT array_agg(coalesce(m.fake, x.e) ORDER BY x.o)
                 FROM unnest(p) WITH ORDINALITY x(e, o)
                 LEFT JOIN anon_tagmap m ON m.real = x.e
                WHERE NOT (x.e = ANY (coalesce(p_drop, '{}')))), '{}') END $$;

-- A space-separated tag string, re-sorted byte-wise and de-duplicated as
-- Post#normalize_tags stores it (uniq.sort).
CREATE FUNCTION pg_temp.tm_tagstr(p text, p_drop text[] DEFAULT '{}') RETURNS text LANGUAGE sql STABLE AS
$$ SELECT CASE WHEN p IS NULL THEN NULL ELSE
     coalesce((SELECT string_agg(t, ' ' ORDER BY t COLLATE "C")
                 FROM (SELECT DISTINCT coalesce(m.fake, x.e) AS t
                         FROM unnest(string_to_array(p, ' ')) x(e)
                         LEFT JOIN anon_tagmap m ON m.real = x.e
                        WHERE x.e <> '' AND NOT (x.e = ANY (coalesce(p_drop, '{}')))) y), '') END $$;

CREATE FUNCTION pg_temp.mx(p text) RETURNS text LANGUAGE sql STABLE AS
$$ SELECT CASE WHEN p IS NULL THEN NULL WHEN p = '' THEN ''
               WHEN p ~ '^@[^:]+:.+$' THEN '@' || pg_temp.nm(lower(substring(p FROM '^@([^:]+):'))) || ':' || pg_temp.host(substring(p FROM '^@[^:]+:(.+)$'))
               ELSE '@unknown_' || left(pg_temp.h('mxid:' || lower(p)), 12) || ':invalid.invalid' END $$;

CREATE FUNCTION pg_temp.poster(p text) RETURNS text LANGUAGE sql STABLE AS
$$ SELECT CASE WHEN p IS NULL THEN NULL
               WHEN p ~ '^discord:[0-9]+$' THEN 'discord:1' || lpad(((('x' || left(pg_temp.h('discord:' || substring(p FROM 9)), 15))::bit(60)::bigint) % 1000000000000000000)::text, 18, '0')
               ELSE pg_temp.mx(p) END $$;

CREATE FUNCTION pg_temp.mxc(p text) RETURNS text LANGUAGE sql STABLE AS
$$ SELECT CASE WHEN p IS NULL THEN NULL
               WHEN p ~ '^mxc://[^/]+/.+$' THEN 'mxc://' || pg_temp.host(substring(p FROM '^mxc://([^/]+)/')) || '/' || pg_temp.b64('mxc:' || p, 24)
               ELSE 'mxc://invalid.invalid/' || left(pg_temp.h('mxc:' || p), 24) END $$;

CREATE FUNCTION pg_temp.room(p text) RETURNS text LANGUAGE sql STABLE AS
$$ SELECT CASE WHEN p ~ '^![^:]+:.+$' THEN '!' || pg_temp.b64('room:' || p, 18) || ':' || pg_temp.host(substring(p FROM '^![^:]+:(.+)$'))
               ELSE '!' || left(pg_temp.h('room:' || p), 18) || ':invalid.invalid' END $$;

-- URLRULE: mxc:// through the mxc map; public 4chan URLs stay (operator
-- ruling: 4chan names are public, and the front page's source: query keys on
-- them); every other URL becomes an opaque one, query and fragment dropped
-- (Discord links carry guild/channel/message ids and signed CDN tokens).
CREATE FUNCTION pg_temp.url(p text) RETURNS text LANGUAGE sql STABLE AS
$$ SELECT CASE WHEN p IS NULL THEN NULL WHEN btrim(p) = '' THEN p
               WHEN p ~* '^mxc://' THEN pg_temp.mxc(p)
               WHEN p ~* '^https?://(boards\.4chan(nel)?\.org|i\.4cdn\.org|is2?\.4chan\.org)(/|$)' AND p !~ '@' THEN p
               ELSE 'https://source.invalid/' || left(pg_temp.h('url:' || p), 20) END $$;

-- One term of a tag query / blocklist rule / BUR line (PostQueryBuilder grammar).
CREATE FUNCTION pg_temp.tagq(p text) RETURNS text LANGUAGE sql STABLE AS
$$ SELECT CASE WHEN p IS NULL OR p = '' THEN p
               WHEN EXISTS (SELECT 1 FROM anon_tagmap WHERE real = p) THEN (SELECT fake FROM anon_tagmap WHERE real = p)
               WHEN lower(p) ~ (SELECT pseud FROM anon_re) THEN
                 (SELECT CASE WHEN m[2] ~ '[*?]' THEN m[1] || '*'
                              WHEN m[2] IN (SELECT name FROM anon_keep) THEN lower(p)
                              ELSE m[1] || pg_temp.nm(m[2]) END
                    FROM regexp_match(lower(p), (SELECT pseud FROM anon_re)) m)
               ELSE p END $$;

CREATE FUNCTION pg_temp.qtok(p text) RETURNS text LANGUAGE sql STABLE AS
$$ WITH a AS (SELECT substring(p FROM '^[-~]*') AS pre, substring(p FROM '^[-~]*(.*)$') AS body),
        b AS (SELECT pre, body, lower(substring(body FROM '^([a-z_]+):')) AS mt, substring(body FROM '^[a-z_]+:(.*)$') AS val FROM a)
   SELECT CASE
     WHEN p IS NULL OR p = '' THEN p
     WHEN mt IN ('user', 'approver', 'commenter', 'comm', 'noter', 'noteupdater', 'artcomm', 'commentaryupdater',
                 'flagger', 'appealer', 'upvote', 'downvote', 'fav', 'ordvote', 'ordfav', 'reacted')
       THEN pre || split_part(body, ':', 1) || ':' || CASE WHEN val ~* '^(any|none|!?[0-9]+)?$' THEN val ELSE pg_temp.nm(val) END
     WHEN mt IN ('pool', 'ordpool')
       THEN pre || split_part(body, ':', 1) || ':' || CASE WHEN val ~* '^(any|none|series|collection|[0-9]+)?$' THEN val
                                                           ELSE coalesce((SELECT fake FROM anon_poolmap WHERE real = lower(val)), 'pool_0') END
     WHEN mt IN ('favgroup', 'ordfavgroup')
       THEN pre || split_part(body, ':', 1) || ':' || CASE WHEN val ~* '^(any|none|[0-9]+)?$' THEN val
                                                           ELSE coalesce((SELECT fake FROM anon_favgroupmap WHERE real = lower(val)), 'group_0') END
     WHEN mt = 'search'
       THEN pre || split_part(body, ':', 1) || ':' || CASE WHEN val ~* '^(all)?$' THEN val
                                                           ELSE coalesce((SELECT fake FROM anon_labelmap WHERE real = lower(val)), 'label_0') END
     WHEN mt = 'source' THEN pre || split_part(body, ':', 1) || ':' || pg_temp.url(val)
     WHEN mt IN ('ai', 'unaliased') THEN pre || split_part(body, ':', 1) || ':' || pg_temp.tagq(val)
     ELSE pre || pg_temp.tagq(body)
   END FROM b $$;

-- A whole query text: lines and spacing kept, every term mapped.
CREATE FUNCTION pg_temp.qstr(p text) RETURNS text LANGUAGE sql STABLE AS
$$ SELECT CASE WHEN p IS NULL THEN NULL WHEN p = '' THEN '' ELSE
     (SELECT string_agg(coalesce((SELECT string_agg(pg_temp.qtok(w), ' ' ORDER BY wo)
                                    FROM unnest(string_to_array(l, ' ')) WITH ORDINALITY y(w, wo)), ''), E'\n' ORDER BY lo)
        FROM unnest(string_to_array(replace(p, E'\r', ''), E'\n')) WITH ORDINALITY x(l, lo)) END $$;

-- A "troll jail: ..." reason. The prefix and the closed templates are code
-- the app parses (Post.jail_deletions, legal_hold?, released_from_jail?,
-- FourierJailController#index): kept, with the booru name inside mapped.
-- Free words survive only when none of them is a mapped name or tag.
CREATE FUNCTION pg_temp.jail_reason(p text) RETURNS text LANGUAGE sql STABLE AS
$$ WITH x AS (SELECT substring(p FROM 13) AS rest)
   SELECT CASE
     WHEN p IS NULL THEN NULL
     WHEN p = 'troll jail' THEN p
     WHEN p NOT LIKE 'troll jail: %' THEN 'troll jail: redacted'
     WHEN rest ~ '^moderator \S+, from the post page$'
       THEN 'troll jail: moderator ' || pg_temp.nm(substring(rest FROM '^moderator (\S+),')) || ', from the post page'
     WHEN rest ~ '^\S+ banished a tag, from the review queue$'
       THEN 'troll jail: ' || pg_temp.nm(substring(rest FROM '^(\S+) ')) || ' banished a tag, from the review queue'
     WHEN rest ~ '^an unknown account (tagged a deleted post|deleted a post tagged) \S+$'
       THEN 'troll jail: an unknown account ' || substring(rest FROM '^an unknown account (tagged a deleted post|deleted a post tagged) ')
            || ' ' || pg_temp.tm(substring(rest FROM ' (\S+)$'))
     WHEN rest ~ '^\S+ (tagged a deleted post|deleted a post tagged) \S+$'
       THEN 'troll jail: ' || pg_temp.nm(substring(rest FROM '^(\S+) ')) || ' '
            || substring(rest FROM '^\S+ (tagged a deleted post|deleted a post tagged) ') || ' ' || pg_temp.tm(substring(rest FROM ' (\S+)$'))
     WHEN rest ~ '^[a-z][a-z0-9_ ,.''-]{0,100}$'
          AND NOT EXISTS (SELECT 1 FROM regexp_split_to_table(rest, '[^a-z0-9_.=-]+') w JOIN anon_namemap n ON n.real = w)
          AND NOT EXISTS (SELECT 1 FROM regexp_split_to_table(rest, '[ ,]+') w JOIN anon_tagmap m ON m.real = w)
       THEN p
     ELSE 'troll jail: redacted'
   END FROM x $$;

CREATE FUNCTION pg_temp.del_reason(p text) RETURNS text LANGUAGE sql STABLE AS
$$ SELECT CASE WHEN p LIKE 'troll jail%' THEN pg_temp.jail_reason(p) ELSE 'reason redacted' END $$;

-- ExifTool output rebuilt from an allowlist of the keys the app reads
-- (app/logical/exif_tool.rb, media_file/*, video_component.rb). Generation
-- keys keep their key with a stub value so is_ai_generated? keeps its answer.
-- Everything else (GPS, camera make/model/serial, author, copyright, XMP,
-- IPTC, maker notes, ICC, prompts) is dropped.
CREATE FUNCTION pg_temp.meta(p jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS
$$ SELECT CASE
     WHEN p IS NULL THEN NULL
     WHEN jsonb_typeof(p) <> 'object' THEN CASE WHEN p = '"{}"'::jsonb THEN p ELSE '"{}"'::jsonb END
     ELSE coalesce((SELECT jsonb_object_agg(k, v) FROM (
         SELECT e.key AS k, e.value AS v FROM jsonb_each(p) e
          WHERE e.key ~ '^(File|PNG|GIF|RIFF|Flash|Track[0-9]+):Image(Width|Height)$'
             OR e.key IN ('File:FileType', 'File:FileTypeExtension', 'File:MIMEType', 'File:ColorComponents', 'File:BitsPerSample',
                          'IFD0:Orientation', 'PNG:ColorType', 'PNG:BitDepth', 'PNG:AnimationFrames', 'PNG:AnimationPlays',
                          'GIF:GIFVersion', 'GIF:FrameCount', 'GIF:AnimationIterations', 'GIF:Duration',
                          'RIFF:Duration', 'RIFF:AnimationLoopCount', 'RIFF:FrameCount', 'RIFF:VP8Version',
                          'QuickTime:Rotation', 'QuickTime:Mirroring', 'QuickTime:CompatibleBrands', 'QuickTime:MajorBrand',
                          'QuickTime:ChromaFormat', 'QuickTime:CleanAperture', 'QuickTime:AuxiliaryImageType',
                          'QuickTime:MovieHeaderVersion', 'QuickTime:Duration', 'Meta:PrimaryItemReference',
                          'Matroska:DocType', 'Matroska:Duration', 'Flash:FlashVersion', 'ZIP:ZipCompression',
                          'FFmpeg:AudioPeakLoudness', 'Ugoira:FrameDelays', 'Ugoira:FrameOffsets')
         UNION ALL
         SELECT e.key, to_jsonb('redacted'::text) FROM jsonb_each(p) e WHERE e.key IN ('PNG:Parameters', 'PNG:Sd-metadata', 'PNG:Dream')
         UNION ALL
         SELECT e.key, e.value FROM jsonb_each(p) e
          WHERE (e.key = 'PNG:Software' AND e.value = '"NovelAI"'::jsonb) OR (e.key = 'PNG:Title' AND e.value = '"AI generated image"'::jsonb)
         UNION ALL
         SELECT e.key, to_jsonb('masterpiece'::text) FROM jsonb_each_text(p) e
          WHERE e.key = 'PNG:Description' AND e.value ~ 'masterpiece|best quality') s), '{}'::jsonb)
   END $$;

-- Creator-private generation data: every value replaced by filler of its
-- length; a generator-chosen PNG keyword not on the known list is renamed.
CREATE FUNCTION pg_temp.genfields(p jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS
$$ SELECT CASE WHEN p IS NULL OR jsonb_typeof(p) <> 'object' THEN '{}'::jsonb ELSE
     coalesce((SELECT jsonb_object_agg(nk, to_jsonb(rpad('redacted', greatest(8, least(vlen, 100000)), ' x')))
                 FROM (SELECT CASE WHEN e.key ~ '^(exif:[A-Za-z][A-Za-z0-9]{0,63}|iptc:[A-Za-z][A-Za-z0-9-]{0,63}|xmp|webp:xmp|jpeg:COM|gif:Comment|png:exif:[A-Za-z][A-Za-z0-9]{0,63})$'
                                     OR lower(e.key) IN ('png:parameters', 'png:prompt', 'png:workflow', 'png:comment', 'png:description',
                                                         'png:software', 'png:title', 'png:source', 'png:generation time', 'png:invokeai_metadata',
                                                         'png:invokeai_graph', 'png:sd-metadata', 'png:dream', 'png:negative_prompt', 'png:stealth')
                                   THEN e.key ELSE 'png:key' || row_number() OVER (ORDER BY e.key) END AS nk,
                              CASE WHEN jsonb_typeof(e.value) = 'string' THEN length(e.value #>> '{}') ELSE length(e.value::text) END AS vlen
                         FROM jsonb_each(p) e) f), '{}'::jsonb) END $$;

-- ---------------------------------------------------------------------------
\echo '[anon] 5/9 purge runtime state and secrets'
-- ---------------------------------------------------------------------------
-- Job queue (a dev worker would replay production's mail, Discord and upload
-- jobs), throttles, geolocation cache, third-party credentials, API keys,
-- invites, upgrade codes, IP bans, sessions and session events, and the
-- derived link table (every text it indexed is replaced below).
TRUNCATE good_job_executions, good_jobs, good_job_batches, good_job_processes, good_job_settings,
         rate_limits, ip_geolocations, site_credentials, api_keys, signup_tokens, ip_bans, dtext_links,
         user_events, login_sessions, user_sessions, upgrade_codes, user_upgrades;

-- ---------------------------------------------------------------------------
\echo '[anon] 6/9 delete what is not a booru post'
-- ---------------------------------------------------------------------------
-- Media assets carried by no post: unposted ingests, Matrix DM pictures,
-- unjudged and jailed uploads (~163,000 per danbooru_default_config.rb). With
-- an md5-addressed read key their rows would let dev fetch private pictures.
-- A post_replacements row pins its assets (non-deferrable foreign keys).
CREATE TEMP TABLE anon_pinned ON COMMIT DROP AS
  SELECT media_asset_id AS id FROM post_replacements WHERE media_asset_id IS NOT NULL
  UNION SELECT old_media_asset_id FROM post_replacements WHERE old_media_asset_id IS NOT NULL;
-- A temp table never gets statistics on its own: without ANALYZE the planner
-- takes ~200 rows and picks a nested loop per row against tables of tens of
-- millions (2026-10-18: an hour in the verifier's twin of this set).
ANALYZE anon_pinned;
CREATE TEMP TABLE anon_dead_assets ON COMMIT DROP AS
  SELECT ma.id FROM media_assets ma
   WHERE NOT EXISTS (SELECT 1 FROM posts p WHERE p.md5 = ma.md5)
     AND ma.id NOT IN (SELECT id FROM anon_pinned);
CREATE UNIQUE INDEX ON anon_dead_assets (id);
ANALYZE anon_dead_assets;
CREATE TEMP TABLE anon_dead_uploads ON COMMIT DROP AS
  SELECT DISTINCT upload_id FROM upload_media_assets WHERE media_asset_id IN (SELECT id FROM anon_dead_assets);
ANALYZE anon_dead_uploads;
DELETE FROM media_metadata WHERE media_asset_id IN (SELECT id FROM anon_dead_assets);
DELETE FROM upload_media_assets WHERE media_asset_id IN (SELECT id FROM anon_dead_assets);
-- ai_tags has no foreign key: orphans would survive silently.
DELETE FROM ai_tags WHERE media_asset_id IN (SELECT id FROM anon_dead_assets)
                       OR NOT EXISTS (SELECT 1 FROM media_assets ma WHERE ma.id = ai_tags.media_asset_id);
DELETE FROM media_assets WHERE id IN (SELECT id FROM anon_dead_assets);
DELETE FROM uploads u WHERE u.id IN (SELECT upload_id FROM anon_dead_uploads)
                        AND NOT EXISTS (SELECT 1 FROM upload_media_assets x WHERE x.upload_id = u.id);

-- The Synapse placement cache for images no post carries (DMs, private rooms,
-- avatars): same population as the unposted assets, under the mxc key.
DELETE FROM matrix_media mm WHERE NOT EXISTS (SELECT 1 FROM post_mxcs pm WHERE pm.mxc = mm.mxc);
CREATE TEMP TABLE anon_live_rooms ON COMMIT DROP AS
  SELECT DISTINCT unnest(room_ids) AS id FROM posts
  UNION SELECT DISTINCT unnest(room_ids) FROM matrix_media;
ANALYZE anon_live_rooms;
DELETE FROM matrix_rooms WHERE id NOT IN (SELECT id FROM anon_live_rooms WHERE id IS NOT NULL);
UPDATE matrix_placement_cursors SET "position" = 0, lap_started_at = NULL;

-- Generation records whose image is on no post are served to nobody.
DELETE FROM fourier_generation_metadata g
 WHERE NOT EXISTS (SELECT 1 FROM posts p WHERE p.md5 = g.md5)
   AND (g.raw_md5 IS NULL OR NOT EXISTS (SELECT 1 FROM posts p WHERE p.md5 = g.raw_md5));

-- Creator-private (post, tag) pairs. Stripped from post history in step 7
-- (from anon_private), deleted here.
DELETE FROM fourier_tag_sources WHERE public = false;

-- ---------------------------------------------------------------------------
\echo '[anon] 7/9 rewrite (the big tables are post_versions, fourier_tag_sources, posts)'
-- ---------------------------------------------------------------------------
-- Groups first: their names are rebuilt from the gallery's REAL localpart.
UPDATE creator_groups cg
   SET name = s.new_name
  FROM (SELECT cg2.id,
               CASE WHEN mp.prefix IS NOT NULL AND l.lp IS NOT NULL
                    THEN mp.prefix || pg_temp.nm(l.lp) || '_' ||
                         CASE WHEN left(cg2.name, length(mp.prefix || l.lp) + 1) = mp.prefix || l.lp || '_'
                                   AND substr(cg2.name, length(mp.prefix || l.lp) + 2) ~ '^tier_[0-9]+$'
                              THEN substr(cg2.name, length(mp.prefix || l.lp) + 2)
                              ELSE 'group_' || cg2.id END
                    ELSE 'group_' || cg2.id END AS new_name
          FROM creator_groups cg2
          JOIN creator_galleries g ON g.id = cg2.creator_gallery_id
          LEFT JOIN LATERAL (SELECT lower(substring(g.matrix_id FROM '^@([^:]+):')) AS lp
                              WHERE lower(substring(g.matrix_id FROM '^@[^:]+:(.+)$')) = lower((SELECT cfg ->> 'matrix_server' FROM anon_input))) l ON true
          LEFT JOIN LATERAL (SELECT p.prefix FROM anon_prefix p
                              WHERE lower(p.provenance) = 'matrix' AND left(cg2.name, length(p.prefix)) = p.prefix
                              LIMIT 1) mp ON true) s
 WHERE s.id = cg.id;

UPDATE creator_galleries g
   SET slug = pg_temp.nm(g.slug),
       matrix_id = pg_temp.mx(g.matrix_id),
       matrix_contact = CASE WHEN g.matrix_contact = '' THEN ''
                             WHEN lower(g.matrix_contact) = lower(g.matrix_id) THEN pg_temp.mx(g.matrix_id)
                             WHEN g.matrix_contact ~ '^@[^:[:space:]]+:[^[:space:]]+$' THEN pg_temp.mx(g.matrix_contact)
                             ELSE '' END,
       title = CASE WHEN g.title = '' THEN '' ELSE 'Gallery ' || pg_temp.nm(g.slug) END,
       bio = pg_temp.fill(g.bio, 'Creator bio ' || g.id),
       settings = '{}'::jsonb;
UPDATE creator_gallery_messages SET body = pg_temp.fill(body, 'Gallery message ' || id);
UPDATE creator_join_requests SET note = pg_temp.fill(note, 'Join request note ' || id);
UPDATE character_claims SET tag_name = pg_temp.tm(tag_name), creator_slug = pg_temp.nm(creator_slug), note = pg_temp.fill(note, 'Claim note ' || id);
UPDATE artist_claims SET tag_name = pg_temp.tm(tag_name), note = pg_temp.fill(note, 'Claim note ' || id);
UPDATE creator_tag_releases SET tag_name = pg_temp.tm(tag_name), note = pg_temp.fill(note, 'Release note ' || id);
UPDATE tag_grants SET tag = pg_temp.tm(tag);
UPDATE landing_categories SET tags = pg_temp.tm_arr(tags);
-- Row headings are operator copy and kept, unless a word of one is a mapped name.
UPDATE landing_categories SET label = 'Row ' || id
 WHERE EXISTS (SELECT 1 FROM regexp_split_to_table(lower(label), '[^a-z0-9_.=-]+') w JOIN anon_namemap n ON n.real = w);
UPDATE landing_settings SET label = 'Row ' || id
 WHERE EXISTS (SELECT 1 FROM regexp_split_to_table(lower(label), '[^a-z0-9_.=-]+') w JOIN anon_namemap n ON n.real = w);
UPDATE fourier_post_creators SET mxid = pg_temp.mx(mxid);
UPDATE fourier_generation_metadata SET poster = pg_temp.poster(poster), fields = pg_temp.genfields(fields);
UPDATE matrix_media SET mxc = pg_temp.mxc(mxc), uploader = pg_temp.mx(uploader);
UPDATE post_mxcs SET mxc = pg_temp.mxc(mxc);
UPDATE matrix_rooms SET room_id = pg_temp.room(room_id);

-- Tags: renamed in place, so ids, post_count and category survive.
UPDATE tags t SET name = m.fake, words = pg_temp.words(m.fake) FROM anon_tagmap m WHERE t.name = m.real;
UPDATE tag_versions v SET name = m.fake FROM anon_tagmap m WHERE v.name = m.real;
UPDATE tag_aliases SET antecedent_name = pg_temp.tm(antecedent_name), consequent_name = pg_temp.tm(consequent_name),
                       reason = pg_temp.fill(reason, 'Alias reason ' || id);
UPDATE tag_implications SET antecedent_name = pg_temp.tm(antecedent_name), consequent_name = pg_temp.tm(consequent_name),
                            reason = pg_temp.fill(reason, 'Implication reason ' || id);
UPDATE tag_quarantines SET note = pg_temp.fill(note, 'Quarantine note ' || id);
UPDATE bulk_update_requests
   SET script = pg_temp.qstr(script),
       tags = coalesce((SELECT array_agg(t ORDER BY t COLLATE "C") FROM (SELECT DISTINCT pg_temp.tm(x) AS t FROM unnest(tags) x) y), '{}');
UPDATE fourier_tag_sources f SET tag = m.fake FROM anon_tagmap m WHERE f.tag = m.real;

UPDATE artists a
   SET name = pg_temp.tm(a.name),
       group_name = CASE WHEN a.group_name IN (SELECT real FROM anon_tagmap) THEN pg_temp.tm(a.group_name)
                         WHEN a.name IN (SELECT real FROM anon_tagmap) THEN '' ELSE a.group_name END,
       other_names = '{}';
UPDATE artist_versions a
   SET name = pg_temp.tm(a.name),
       group_name = CASE WHEN a.group_name IN (SELECT real FROM anon_tagmap) THEN pg_temp.tm(a.group_name)
                         WHEN a.name IN (SELECT real FROM anon_tagmap) THEN '' ELSE a.group_name END,
       other_names = '{}', urls = '{}';
UPDATE artist_urls SET url = 'https://source.invalid/artist/' || artist_id || '/' || id;
UPDATE wiki_pages SET title = pg_temp.tm(title), body = pg_temp.fill(body, 'Wiki page ' || id), other_names = '{}';
UPDATE wiki_page_versions SET title = pg_temp.tm(title), body = pg_temp.fill(body, 'Wiki page ' || wiki_page_id), other_names = '{}';

UPDATE posts SET tag_string = pg_temp.tm_tagstr(tag_string), source = pg_temp.url(source);
UPDATE post_versions pv
   SET tags = pg_temp.tm_tagstr(pv.tags, (SELECT a.tags FROM anon_private a WHERE a.post_id = pv.post_id)),
       added_tags = pg_temp.tm_arr(pv.added_tags, (SELECT a.tags FROM anon_private a WHERE a.post_id = pv.post_id)),
       removed_tags = pg_temp.tm_arr(pv.removed_tags, (SELECT a.tags FROM anon_private a WHERE a.post_id = pv.post_id)),
       source = pg_temp.url(pv.source);
UPDATE post_replacements SET original_url = pg_temp.url(original_url), replacement_url = pg_temp.url(replacement_url);
UPDATE uploads SET source = pg_temp.url(source), referer_url = pg_temp.url(referer_url), error = NULL;
UPDATE upload_media_assets SET source_url = pg_temp.url(source_url), page_url = pg_temp.url(page_url), error = NULL;
UPDATE media_metadata SET metadata = pg_temp.meta(metadata);
UPDATE saved_searches s
   SET query = pg_temp.qstr(s.query),
       labels = coalesce((SELECT array_agg(coalesce(l.fake, 'label_0') ORDER BY x.o)
                            FROM unnest(s.labels) WITH ORDINALITY x(v, o) LEFT JOIN anon_labelmap l ON l.real = lower(x.v)), '{}');
UPDATE modulation_settings SET random_trails = '{}'::jsonb;

-- People. Kept: service accounts (by config) and deleted users (user_<id>).
CREATE TEMP TABLE anon_devpw ON COMMIT DROP AS
  SELECT translate(encode(gen_random_bytes(15), 'base64'), '+/=', 'xyz') AS pw;
CREATE TEMP TABLE anon_devusers ON COMMIT DROP AS
  SELECT id FROM (SELECT id FROM users
                   WHERE NOT is_deleted AND lower(name) NOT IN (SELECT name FROM anon_keep)
                   ORDER BY level DESC, id LIMIT 1) top
  UNION
  SELECT id FROM users WHERE NOT is_deleted AND lower(name) IN (SELECT name FROM anon_keep);
UPDATE users u
   SET name = CASE WHEN lower(u.name) IN (SELECT name FROM anon_keep) OR u.name ~* '^user_[0-9]+$' THEN u.name ELSE 'user_' || u.id END,
       -- User#hash_password: bcrypt over SHA1("choujin-steiner--<pw>--") (upstream's public constant).
       bcrypt_password_hash = crypt(encode(digest('choujin-steiner--' ||
                                CASE WHEN u.id IN (SELECT id FROM anon_devusers) THEN (SELECT pw FROM anon_devpw)
                                     ELSE encode(gen_random_bytes(24), 'hex') END || '--', 'sha1'), 'hex'), gen_salt('bf', 10)),
       totp_secret = NULL,
       backup_codes = NULL,
       last_ip_addr = NULL,
       custom_style = NULL,
       time_zone = 'Eastern Time (US & Canada)',
       favorite_tags = pg_temp.qstr(u.favorite_tags),
       blacklisted_tags = pg_temp.qstr(u.blacklisted_tags);
UPDATE user_name_change_requests SET original_name = pg_temp.nm(original_name), desired_name = pg_temp.nm(desired_name);
-- is_deliverable = false is what turns every UserMailer path off and skips
-- login verification (User#can_receive_email?, SessionLoader#login).
UPDATE email_addresses
   SET address = 'u' || user_id || '@example.invalid', normalized_address = 'u' || user_id || '@example.invalid',
       is_deliverable = false, is_verified = false;

-- Human-written text: replaced, never scrubbed (scrubbing cannot be proved complete).
UPDATE dmails SET title = pg_temp.fill(title, 'Message ' || id), body = pg_temp.fill(body, 'Message body ' || id);
UPDATE comments SET body = pg_temp.fill(body, 'Comment ' || id);
UPDATE forum_topics SET title = CASE WHEN title = 'Retired tag aliases & implications' THEN title ELSE 'Topic ' || id END;  -- TagRelationshipRetirementService finds that one by title
UPDATE forum_posts SET body = CASE WHEN body ~ '^\[bur:[0-9]+\]'
                                   THEN substring(body FROM '^\[bur:[0-9]+\]') || E'\n\n' || pg_temp.fill(body, 'Forum post ' || id)
                                   ELSE pg_temp.fill(body, 'Forum post ' || id) END;
UPDATE notes SET body = pg_temp.fill(body, 'Note ' || id);
UPDATE note_versions SET body = pg_temp.fill(body, 'Note ' || note_id);
UPDATE pools SET name = 'pool_' || id, description = pg_temp.fill(description, 'Pool ' || id);
UPDATE pool_versions SET name = CASE WHEN name IS NULL THEN NULL ELSE 'pool_' || pool_id END, description = pg_temp.fill(description, 'Pool ' || pool_id);
UPDATE favorite_groups SET name = 'group_' || id;
UPDATE artist_commentaries
   SET original_title = pg_temp.fill(original_title, 'Commentary title ' || post_id), original_description = pg_temp.fill(original_description, 'Commentary ' || post_id),
       translated_title = pg_temp.fill(translated_title, 'Commentary title ' || post_id), translated_description = pg_temp.fill(translated_description, 'Commentary ' || post_id);
UPDATE artist_commentary_versions
   SET original_title = pg_temp.fill(original_title, 'Commentary title ' || post_id), original_description = pg_temp.fill(original_description, 'Commentary ' || post_id),
       translated_title = pg_temp.fill(translated_title, 'Commentary title ' || post_id), translated_description = pg_temp.fill(translated_description, 'Commentary ' || post_id);
UPDATE bans SET reason = pg_temp.fill(reason, 'Ban reason ' || id);
UPDATE user_feedback SET body = pg_temp.fill(body, 'Feedback ' || id);
UPDATE moderation_reports SET reason = pg_temp.fill(reason, 'Report reason ' || id);
UPDATE news_updates SET message = pg_temp.fill(message, 'News ' || id);
UPDATE post_appeals SET reason = pg_temp.fill(reason, 'Appeal reason ' || id);
UPDATE post_disapprovals SET message = pg_temp.fill(message, 'Disapproval message ' || id);

-- Flags: the two upstream constants and the jail's templates are state the
-- code matches (PostFlag.category_matches, Post#released_from_jail?,
-- Post#jail_deletion_flag?); everything else is member-typed and replaced.
UPDATE post_flags
   SET reason = CASE WHEN reason = 'Unapproved in three days'
                       OR reason LIKE 'Unapproved in three days after returning to moderation queue%' THEN reason
                     WHEN reason LIKE 'troll jail%' THEN pg_temp.jail_reason(reason)
                     ELSE 'flag reason redacted' END;

-- Mod log: post_delete and post_jail keep their template (Post.jail_deletions
-- matches 'deleted post #<subject_id>, reason: troll jail: %'); every other
-- category is regenerated from category and subject alone, because its text
-- embeds names, e-mail addresses, IPs, Matrix ids and reasons.
CREATE TEMP TABLE anon_modcat (id int PRIMARY KEY, name text) ON COMMIT DROP;
INSERT INTO anon_modcat VALUES
 (2,'user_delete'),(3,'user_undelete'),(4,'user_ban'),(5,'user_unban'),(6,'user_name_change'),(7,'user_level_change'),
 (8,'user_approval_privilege'),(9,'user_upload_privilege'),(10,'user_ban_update'),(19,'user_account_upgrade'),
 (21,'user_feedback_update'),(22,'user_feedback_delete'),(42,'post_delete'),(43,'post_undelete'),(44,'post_ban'),
 (45,'post_unban'),(46,'post_permanent_delete'),(47,'post_move_favorites'),(48,'post_regenerate'),(49,'post_regenerate_iqdb'),
 (210,'post_note_lock_create'),(212,'post_note_lock_delete'),(220,'post_rating_lock_create'),(222,'post_rating_lock_delete'),
 (232,'post_vote_delete'),(233,'post_vote_undelete'),(62,'pool_delete'),(63,'pool_undelete'),(72,'media_asset_delete'),
 (76,'media_asset_expunge'),(184,'artist_ban'),(185,'artist_unban'),(81,'comment_update'),(82,'comment_delete'),
 (92,'comment_vote_delete'),(93,'comment_vote_undelete'),(202,'forum_topic_delete'),(203,'forum_topic_undelete'),
 (206,'forum_topic_lock'),(101,'forum_post_update'),(102,'forum_post_delete'),(306,'moderation_report_handled'),
 (307,'moderation_report_rejected'),(120,'tag_alias_create'),(121,'tag_alias_update'),(122,'tag_alias_delete'),
 (140,'tag_implication_create'),(141,'tag_implication_update'),(142,'tag_implication_delete'),(240,'tag_deprecate'),
 (242,'tag_undeprecate'),(160,'ip_ban_create'),(162,'ip_ban_delete'),(163,'ip_ban_undelete'),(300,'news_update_create'),
 (301,'news_update_update'),(302,'news_update_delete'),(303,'news_update_undelete'),(400,'site_credential_create'),
 (402,'site_credential_delete'),(406,'site_credential_enable'),(407,'site_credential_disable'),(501,'email_address_update'),
 (606,'backup_code_send'),(1000,'mass_update'),(1100,'creator_visibility_update'),(1101,'artist_claim_approve'),
 (1102,'artist_claim_reject'),(1103,'creator_gallery_unlink'),(1104,'creator_audience_update'),(1105,'creator_group_create'),
 (1106,'creator_group_delete'),(1107,'creator_group_member_add'),(1108,'creator_group_member_remove'),
 (1109,'creator_join_request_approve'),(1110,'creator_join_request_reject'),(1111,'creator_user_rule_update'),
 (1112,'creator_hidden_post_view'),(1113,'creator_group_update'),(1114,'post_jail'),(1115,'post_unjail'),
 (1116,'character_claim_approve'),(1117,'character_claim_reject'),(1118,'character_claim_release'),(1119,'character_claim_hold'),
 (1120,'tag_flag'),(1121,'tag_flag_release'),(1122,'tag_banish'),(1123,'tag_unbanish');
UPDATE mod_actions ma
   SET description = CASE
         WHEN ma.category = 42 AND ma.description ~ '^deleted post #[0-9]+, reason: '
           THEN 'deleted post #' || substring(ma.description FROM '^deleted post #([0-9]+)') || ', reason: '
                || pg_temp.del_reason(substring(ma.description FROM '^deleted post #[0-9]+, reason: (.*)$'))
         WHEN ma.category = 1114 AND ma.description ~ '^jailed post #[0-9]+, reason: '
           THEN 'jailed post #' || substring(ma.description FROM '^jailed post #([0-9]+)') || ', reason: '
                || pg_temp.del_reason(substring(ma.description FROM '^jailed post #[0-9]+, reason: (.*)$'))
         ELSE coalesce((SELECT c.name FROM anon_modcat c WHERE c.id = ma.category), 'category ' || ma.category)
              || CASE WHEN ma.subject_id IS NOT NULL THEN ' ' || coalesce(ma.subject_type, 'record') || ' #' || ma.subject_id ELSE '' END
       END;

-- ---------------------------------------------------------------------------
\echo '[anon] 8/9 post-conditions'
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  n bigint;
BEGIN
  FOR r IN SELECT DISTINCT tbl FROM anon_class WHERE action = 'purge' LOOP
    EXECUTE format('SELECT count(*) FROM public.%I', r.tbl) INTO n;
    IF n > 0 THEN RAISE EXCEPTION 'post-condition: % still has % rows', r.tbl, n; END IF;
  END LOOP;
  FOR r IN SELECT c.table_name::text AS tbl, c.column_name::text AS col, c.data_type = 'ARRAY' AS arr
             FROM information_schema.columns c
             JOIN information_schema.tables t ON t.table_schema = c.table_schema AND t.table_name = c.table_name AND t.table_type = 'BASE TABLE'
            WHERE c.table_schema = 'public' AND (c.data_type IN ('inet', 'cidr') OR c.udt_name IN ('_inet', '_cidr')) LOOP
    EXECUTE format('SELECT count(*) FROM public.%I WHERE %I IS NOT NULL%s', r.tbl, r.col,
                   CASE WHEN r.arr THEN format(' AND cardinality(%I) > 0', r.col) ELSE '' END) INTO n;
    IF n > 0 THEN RAISE EXCEPTION 'post-condition: %.% still holds % addresses', r.tbl, r.col, n; END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM users WHERE totp_secret IS NOT NULL OR backup_codes IS NOT NULL) THEN RAISE EXCEPTION 'post-condition: a 2FA secret survived'; END IF;
  IF EXISTS (SELECT 1 FROM users WHERE lower(name) IN (SELECT real FROM anon_namemap)) THEN RAISE EXCEPTION 'post-condition: an account kept its real name'; END IF;
  IF EXISTS (SELECT 1 FROM email_addresses WHERE address !~ '^u[0-9]+@example\.invalid$' OR is_deliverable) THEN RAISE EXCEPTION 'post-condition: a real e-mail address survived'; END IF;
  IF EXISTS (SELECT 1 FROM tags t JOIN anon_tagmap m ON m.real = t.name) THEN RAISE EXCEPTION 'post-condition: tags still holds a mapped name'; END IF;
  IF EXISTS (SELECT 1 FROM fourier_tag_sources f JOIN anon_tagmap m ON m.real = f.tag) THEN RAISE EXCEPTION 'post-condition: fourier_tag_sources still holds a mapped name'; END IF;
  IF EXISTS (SELECT 1 FROM fourier_tag_sources WHERE NOT public) THEN RAISE EXCEPTION 'post-condition: a private tag source survived'; END IF;
  IF EXISTS (SELECT 1 FROM wiki_pages w JOIN anon_tagmap m ON m.real = w.title)
     OR EXISTS (SELECT 1 FROM artists a JOIN anon_tagmap m ON m.real = a.name) THEN RAISE EXCEPTION 'post-condition: a wiki or artist name kept a mapped name'; END IF;
  IF EXISTS (SELECT 1 FROM media_assets ma WHERE NOT EXISTS (SELECT 1 FROM posts p WHERE p.md5 = ma.md5)
                AND ma.id NOT IN (SELECT id FROM anon_pinned)) THEN
    RAISE EXCEPTION 'post-condition: an unposted media asset survived';
  END IF;
  IF EXISTS (SELECT 1 FROM matrix_media mm WHERE NOT EXISTS (SELECT 1 FROM post_mxcs pm WHERE pm.mxc = mm.mxc)) THEN RAISE EXCEPTION 'post-condition: matrix_media and post_mxcs disagree after the mxc map'; END IF;
  IF EXISTS (SELECT 1 FROM post_mxcs pm JOIN posts p ON p.id = pm.post_id WHERE pm.source = 'post_source' AND pm.mxc <> p.source) THEN
    RAISE EXCEPTION 'post-condition: a post_source mxc no longer equals its post''s source';
  END IF;
  IF EXISTS (SELECT 1 FROM creator_galleries
              WHERE substring(matrix_id FROM '^@([^:]+):') !~ '^(user|creator)_[0-9]+$'
                AND substring(matrix_id FROM '^@([^:]+):') NOT IN (SELECT name FROM anon_keep)) THEN
    RAISE EXCEPTION 'post-condition: a gallery Matrix id kept a real localpart';
  END IF;
END
$post$;

-- ---------------------------------------------------------------------------
\echo '[anon] 9/9 mark and commit'
-- ---------------------------------------------------------------------------
UPDATE ar_internal_metadata SET value = 'development', updated_at = now() WHERE key = 'environment';
INSERT INTO ar_internal_metadata (key, value, created_at, updated_at)
VALUES ('anonymized_for_dev', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), now(), now());

DO $devpw$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT u.name, u.level FROM users u WHERE u.id IN (SELECT id FROM anon_devusers) ORDER BY u.level DESC, u.id LOOP
    RAISE NOTICE '[anon] dev login: % (level %)', r.name, r.level;
  END LOOP;
  RAISE NOTICE '[anon] dev password for those logins (stored nowhere in the database): %', (SELECT pw FROM anon_devpw);
END
$devpw$;

COMMIT;
\echo '[anon] committed. Next: script/anonymize_for_dev_verify.sql with -v phase=after'
