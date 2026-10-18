-- script/anonymize_for_dev_verify.sql
--
-- The proof for script/anonymize_for_dev.sql, in three phases (-v phase=...):
--
--   before  on the armed restored copy, BEFORE anonymizing. Records the
--           production shape, plants canaries (fake identities in every
--           identity column, every inet column, a tag, a post, a dmail...),
--           and snapshots a ledger of every original identity string.
--           Commits; prints the canary token.
--   after   on the same copy, AFTER anonymizing. Plants a second set of
--           canaries, runs ONE scan of every text-like column of every table,
--           and requires that it finds exactly the second canaries and
--           nothing else (so the copy is clean AND the scan is not blind);
--           rolls the second canaries back, deletes the first ones, compares
--           shape with 'before', drops the ledger. Any failure rolls back.
--   final   on the fresh dev cluster the dump was restored into. No ledger
--           exists there: the pattern and closed-world rules only, plus the
--           canary tokens (-v tokens=<before token>,<after token>).
--
-- Findings name table, column, rule and a ctid; never a real value (a
-- canary is fake and is printed).
--
-- What a pass proves: no canary, no e-mail, Matrix id, IP literal, bcrypt hash
-- or creator-prefixed name that the anonymizer did not produce, and no
-- ledger value (original names, Matrix ids, creator tags, e-mail addresses,
-- IPs, secrets, 2FA seeds, Discord ids, media ids, room ids, banished names),
-- in any text-like column. What it does NOT prove: that free text holds no
-- personal fact the ledger does not know -- which is why all free text is
-- replaced wholesale rather than scanned and kept.

\set ON_ERROR_STOP on
\timing on
SELECT :'phase' IN ('before', 'after', 'final') AS phase_ok,
       :'phase' = 'before' AS is_before, :'phase' = 'after' AS is_after, :'phase' = 'final' AS is_final \gset
\if :phase_ok
\else
  DO $$ BEGIN RAISE EXCEPTION 'set -v phase=before, after or final'; END $$;
\endif

BEGIN;
SET LOCAL search_path = public;
CREATE TEMP TABLE anon_v_input ON COMMIT DROP AS SELECT :'cfg'::jsonb AS cfg;
CREATE TEMP TABLE anon_v_keep ON COMMIT DROP AS
  SELECT DISTINCT lower(btrim(x)) AS name FROM anon_v_input, jsonb_array_elements_text(cfg -> 'keep_names') x WHERE btrim(x) <> '';
CREATE TEMP TABLE anon_v_re ON COMMIT DROP AS
  SELECT '^(' || string_agg(e ->> 'prefix', '|' ORDER BY length(e ->> 'prefix') DESC) || ')' AS pseud_any,
         '(^|[^a-z0-9_])(' || string_agg(e ->> 'prefix', '|' ORDER BY length(e ->> 'prefix') DESC) || ')([a-z0-9._=/-]+)' AS ctag
    FROM anon_v_input, jsonb_array_elements(cfg -> 'prefixes') e WHERE e ->> 'action' = 'pseudonymize';

-- ===========================================================================
-- THE SCAN, shared by 'after' and 'final'
-- ===========================================================================
CREATE FUNCTION pg_temp.anon_scan_cols() RETURNS TABLE (tbl text, col text, kind text, is_array boolean) LANGUAGE sql STABLE AS
$$ SELECT c.table_name::text, c.column_name::text,
          CASE WHEN c.data_type IN ('inet', 'cidr') OR c.udt_name IN ('_inet', '_cidr') THEN 'inet' ELSE 'text' END,
          c.data_type = 'ARRAY'
     FROM information_schema.columns c
     JOIN information_schema.tables t ON t.table_schema = c.table_schema AND t.table_name = c.table_name AND t.table_type = 'BASE TABLE'
    WHERE c.table_schema = 'public'
      AND (c.data_type IN ('text', 'character varying', 'character', 'json', 'jsonb', 'inet', 'cidr', 'xml')
           OR (c.data_type = 'USER-DEFINED' AND c.udt_name = 'citext')
           OR (c.data_type = 'ARRAY' AND c.udt_name IN ('_text', '_varchar', '_bpchar', '_json', '_jsonb', '_citext', '_inet', '_cidr')))
    ORDER BY pg_relation_size(format('public.%I', c.table_name)::regclass), 1, 2 $$;

-- Each column is scanned over its DISTINCT values (min(ctid) as the sample),
-- so a finding's n counts distinct values, not rows: fourier_tag_sources.tag is
-- ~105M rows of ~30k values and took 5.5 h row by row (2026-10-18). A banished
-- name is a whole tag, so it counts only as a WHOLE token: as a word it matched
-- different tags that contain it (death_(personification), 4chan_death).
-- And not at all in tags.words: that column is tags.name split into words
-- (death_(puss_in_boots) stores "death" whole), and tags.name itself is
-- scanned for banished names in full.
CREATE FUNCTION pg_temp.anon_scan(use_ledger boolean, tokens text[])
RETURNS TABLE (tbl text, col text, rule text, n bigint, sample text) LANGUAGE plpgsql AS
$fn$
DECLARE
  c record;
  lr record;
  i int := 0;
  total int;
  t0 timestamptz;
  cnt bigint[];
  smp text[];
  rules text[] := ARRAY['canary', 'email', 'mxid', 'ipv4', 'ipv6', 'bcrypt', 'creator_tag'];
  keep text[] := ARRAY(SELECT name FROM anon_v_keep);
  ctag_re text := (SELECT ctag FROM anon_v_re);
  canary_re text := coalesce(array_to_string(tokens, '|'), '');
  email_re text := '[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}';
  mxid_re text := '@([a-z0-9._=/+-]+):([a-z0-9-]+(\.[a-z0-9-]+)+)';
  ipv4_re text := '(^|[^0-9.])(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}([^0-9.]|$)';
  ipv6_re text := '(^|[^0-9a-z:])(([0-9a-f]{1,4}:){7}[0-9a-f]{1,4}|[0-9a-f]{1,4}(:[0-9a-f]{1,4})*::[0-9a-f]{1,4}(:[0-9a-f]{1,4})*)([^0-9a-z:]|$)';
  bcrypt_re text := '\$2[abxy]\$[0-9]{2}\$[./A-Za-z0-9]{53}';
  -- What the anonymizer produces in an identity position, and nothing else.
  ok_re text := '^((user|creator)_[0-9]+|unknown_[0-9a-f]{8,12})$';
BEGIN
  SELECT count(*) INTO total FROM pg_temp.anon_scan_cols();
  FOR c IN SELECT * FROM pg_temp.anon_scan_cols() LOOP
    i := i + 1;
    t0 := clock_timestamp();
    IF c.kind = 'inet' THEN
      -- The anonymizer empties every address column, so any value is a finding.
      EXECUTE format('SELECT count(*), min(ctid::text) FROM public.%I WHERE %I IS NOT NULL%s', c.tbl, c.col,
                     CASE WHEN c.is_array THEN format(' AND cardinality(%I) > 0', c.col) ELSE '' END) INTO n, sample;
      IF n > 0 THEN tbl := c.tbl; col := c.col; rule := 'inet_value'; RETURN NEXT; END IF;
    ELSE
      EXECUTE format($q$
        SELECT ARRAY[count(*) FILTER (WHERE f1), count(*) FILTER (WHERE f2), count(*) FILTER (WHERE f3), count(*) FILTER (WHERE f4),
                     count(*) FILTER (WHERE f5), count(*) FILTER (WHERE f6), count(*) FILTER (WHERE f7)],
               ARRAY[min(loc) FILTER (WHERE f1), min(loc) FILTER (WHERE f2), min(loc) FILTER (WHERE f3), min(loc) FILTER (WHERE f4),
                     min(loc) FILTER (WHERE f5), min(loc) FILTER (WHERE f6), min(loc) FILTER (WHERE f7)]
          FROM (SELECT loc,
                       ($1 <> '' AND v ~* $1) AS f1,
                       (strpos(v, '@') > 0 AND regexp_replace(v, 'u[0-9]+@example\.invalid', '', 'gi') ~* $3) AS f2,
                       (strpos(v, '@') > 0 AND v ~* $4
                        AND EXISTS (SELECT 1 FROM regexp_matches(v, $4, 'gi') m
                                     WHERE NOT (lower(m[1]) ~ $9 OR lower(m[1]) = ANY ($2)))) AS f3,
                       (v ~ $5) AS f4,
                       (strpos(v, '::') > 0 OR v ~* '([0-9a-f]{1,4}:){7}') AND v ~* $6 AS f5,
                       (%L AND strpos(v, '$2') > 0 AND v ~ $7) AS f6,
                       (v ~* $8
                        AND EXISTS (SELECT 1 FROM regexp_matches(v, $8, 'gi') m
                                     CROSS JOIN LATERAL (SELECT regexp_replace(rtrim(lower(m[3]), '._=/-'), '_(tier|group)_[0-9]+$', '') AS s) z
                                     WHERE NOT (z.s ~ $9 OR z.s = ANY ($2) OR m[3] LIKE '*%%'))) AS f7
                  FROM (SELECT min(x.ctid::text) AS loc, x.%I::text AS v FROM public.%I x WHERE x.%I IS NOT NULL GROUP BY x.%I::text) s0) s1 $q$,
        NOT (c.tbl = 'users' AND c.col = 'bcrypt_password_hash'), c.col, c.tbl, c.col, c.col)
      INTO cnt, smp USING canary_re, keep, email_re, mxid_re, ipv4_re, ipv6_re, bcrypt_re, ctag_re, ok_re;
      FOR k IN 1 .. 7 LOOP
        IF cnt[k] > 0 THEN tbl := c.tbl; col := c.col; rule := rules[k]; n := cnt[k]; sample := smp[k]; RETURN NEXT; END IF;
      END LOOP;
      IF use_ledger THEN
        FOR lr IN EXECUTE format($q$
          SELECT l.kind, count(DISTINCT s.loc) AS n, min(s.loc) AS sample
            FROM (SELECT min(x.ctid::text) AS loc, lower(x.%I::text) AS v FROM public.%I x WHERE x.%I IS NOT NULL GROUP BY lower(x.%I::text)) s
           CROSS JOIN LATERAL (
                  SELECT btrim(w, '-~.:!?/=+\') AS tok, true AS whole FROM regexp_split_to_table(s.v, '[][(){}<>|,;"''[:space:]]+') w
                  UNION
                  SELECT w, false FROM regexp_split_to_table(s.v, '[^a-z0-9]+') w) t
            JOIN anon_snapshot.ledger_scan l ON l.value = t.tok AND (t.whole OR l.kind <> 'banished')
                                             AND NOT (%L AND l.kind = 'banished')
           GROUP BY l.kind $q$, c.col, c.tbl, c.col, c.col, (c.tbl = 'tags' AND c.col = 'words'))
        LOOP
          tbl := c.tbl; col := c.col; rule := 'ledger:' || lr.kind; n := lr.n; sample := lr.sample; RETURN NEXT;
        END LOOP;
      END IF;
    END IF;
    RAISE NOTICE '[scan %/%] %.% (% s)', i, total, c.tbl, c.col, round(extract(epoch FROM clock_timestamp() - t0)::numeric, 1);
  END LOOP;
END
$fn$;

-- ===========================================================================
\if :is_before
-- ===========================================================================
\echo '[verify before] guards'
DO $g$
DECLARE armed boolean;
BEGIN
  IF to_regclass('anon_guard.armed') IS NULL THEN RAISE EXCEPTION 'refusing: database not armed' USING HINT = 'Same arming step as script/anonymize_for_dev.sql.'; END IF;
  EXECUTE 'SELECT EXISTS (SELECT 1 FROM anon_guard.armed)' INTO armed;
  IF NOT armed THEN RAISE EXCEPTION 'refusing: anon_guard.armed is empty'; END IF;
  IF current_setting('listen_addresses') <> '' THEN RAISE EXCEPTION 'refusing: the server listens on TCP' USING HINT = 'Start it with --network none -c listen_addresses='''''; END IF;
  IF to_regnamespace('anon_snapshot') IS NOT NULL THEN RAISE EXCEPTION 'refusing: anon_snapshot already exists' USING HINT = 'The before phase ran already. Run the anonymizer, or restore a fresh copy to start over.'; END IF;
  IF EXISTS (SELECT 1 FROM ar_internal_metadata WHERE key = 'anonymized_for_dev') THEN RAISE EXCEPTION 'refusing: this copy is already anonymized'; END IF;
END
$g$;

CREATE SCHEMA anon_snapshot;
CREATE TABLE anon_snapshot.meta (k text PRIMARY KEY, v text NOT NULL);
INSERT INTO anon_snapshot.meta VALUES ('token', 'cnry' || encode(gen_random_bytes(5), 'hex')), ('cfg', (SELECT cfg::text FROM anon_v_input));

-- Shape: numbers that anonymizing must not change (computed with the same
-- code before and after; counts only, no values).
CREATE FUNCTION anon_snapshot.shape() RETURNS TABLE (metric text, val text) LANGUAGE plpgsql AS
$fn$
DECLARE
  cfg jsonb := (SELECT v::jsonb FROM anon_snapshot.meta WHERE k = 'cfg');
  srv text := lower(cfg ->> 'matrix_server');
  jail text[] := ARRAY(SELECT lower(x) FROM jsonb_array_elements_text(cfg -> 'jail_names') x);
  jtag text := cfg ->> 'jail_tag';
  pse text := (SELECT '^(' || string_agg(e ->> 'prefix', '|' ORDER BY length(e ->> 'prefix') DESC) || ')'
                 FROM jsonb_array_elements(cfg -> 'prefixes') e WHERE e ->> 'action' = 'pseudonymize');
  mst text[] := ARRAY(SELECT e ->> 'prefix' FROM jsonb_array_elements(cfg -> 'prefixes') e WHERE lower(e ->> 'provenance') = 'matrix');
  tname text;
BEGIN
  FOREACH tname IN ARRAY ARRAY['posts', 'post_versions', 'tags', 'tag_versions', 'tag_aliases', 'tag_implications', 'artists',
                           'artist_versions', 'artist_urls', 'wiki_pages', 'wiki_page_versions', 'users', 'user_name_change_requests',
                           'email_addresses', 'dmails', 'comments', 'comment_votes', 'forum_topics', 'forum_posts', 'forum_post_votes',
                           'forum_topic_visits', 'pools', 'pool_versions', 'favorite_groups', 'favorites', 'post_votes', 'post_flags',
                           'post_appeals', 'post_approvals', 'post_disapprovals', 'post_replacements', 'notes', 'note_versions',
                           'mod_actions', 'bans', 'user_feedback', 'saved_searches', 'creator_galleries', 'creator_groups',
                           'creator_group_memberships', 'creator_gallery_posts', 'creator_post_audiences', 'creator_user_rules',
                           'creator_join_requests', 'creator_audience_groups', 'creator_gallery_messages', 'creator_tag_releases',
                           'artist_claims', 'character_claims', 'tag_grants', 'tag_quarantines', 'landing_categories', 'landing_settings',
                           'modulation_settings', 'fourier_post_creators', 'post_mxcs', 'artist_commentaries', 'artist_commentary_versions',
                           'bulk_update_requests', 'news_updates', 'moderation_reports', 'reactions', 'matrix_placement_cursors'] LOOP
    metric := 'rows:' || tname;
    EXECUTE format('SELECT count(*)::text FROM public.%I', tname) INTO val;
    RETURN NEXT;
  END LOOP;

  -- Reduced tables: the rows the anonymizer's rule keeps.
  CREATE TEMP TABLE IF NOT EXISTS anon_v_pinned AS
    SELECT media_asset_id AS id FROM post_replacements WHERE media_asset_id IS NOT NULL
    UNION SELECT old_media_asset_id FROM post_replacements WHERE old_media_asset_id IS NOT NULL;
  CREATE TEMP TABLE IF NOT EXISTS anon_v_kept_assets AS
    SELECT ma.id FROM media_assets ma WHERE EXISTS (SELECT 1 FROM posts p WHERE p.md5 = ma.md5) OR ma.id IN (SELECT id FROM anon_v_pinned);
  metric := 'kept:media_assets'; SELECT count(*)::text INTO val FROM anon_v_kept_assets; RETURN NEXT;
  metric := 'kept:media_metadata'; SELECT count(*)::text INTO val FROM media_metadata WHERE media_asset_id IN (SELECT id FROM anon_v_kept_assets); RETURN NEXT;
  metric := 'kept:upload_media_assets'; SELECT count(*)::text INTO val FROM upload_media_assets WHERE media_asset_id IS NULL OR media_asset_id IN (SELECT id FROM anon_v_kept_assets); RETURN NEXT;
  metric := 'kept:ai_tags'; SELECT count(*)::text INTO val FROM ai_tags WHERE media_asset_id IN (SELECT id FROM anon_v_kept_assets); RETURN NEXT;
  metric := 'kept:uploads'; SELECT count(*)::text INTO val FROM uploads u
    WHERE NOT EXISTS (SELECT 1 FROM upload_media_assets x WHERE x.upload_id = u.id)
       OR EXISTS (SELECT 1 FROM upload_media_assets x WHERE x.upload_id = u.id AND (x.media_asset_id IS NULL OR x.media_asset_id IN (SELECT id FROM anon_v_kept_assets))); RETURN NEXT;
  metric := 'kept:matrix_media'; SELECT count(*)::text INTO val FROM matrix_media mm WHERE EXISTS (SELECT 1 FROM post_mxcs pm WHERE pm.mxc = mm.mxc); RETURN NEXT;
  metric := 'kept:matrix_rooms'; SELECT count(*)::text INTO val FROM matrix_rooms WHERE id IN (
      SELECT unnest(room_ids) FROM posts UNION SELECT unnest(mm.room_ids) FROM matrix_media mm WHERE EXISTS (SELECT 1 FROM post_mxcs pm WHERE pm.mxc = mm.mxc)); RETURN NEXT;
  metric := 'kept:fourier_generation_metadata'; SELECT count(*)::text INTO val FROM fourier_generation_metadata g
    WHERE EXISTS (SELECT 1 FROM posts p WHERE p.md5 = g.md5) OR EXISTS (SELECT 1 FROM posts p WHERE p.md5 = g.raw_md5); RETURN NEXT;
  metric := 'kept:fourier_tag_sources'; SELECT count(*)::text INTO val FROM fourier_tag_sources WHERE public; RETURN NEXT;
  DROP TABLE anon_v_kept_assets;
  DROP TABLE anon_v_pinned;

  -- Tags keep their counts; creator tags keep their size distribution.
  metric := 'tags:post_count_sum'; SELECT sum(post_count)::text INTO val FROM tags; RETURN NEXT;
  metric := 'tags:by_category'; SELECT string_agg(category || '=' || n, ',' ORDER BY category) INTO val FROM (SELECT category, count(*) AS n FROM tags GROUP BY category) s; RETURN NEXT;
  metric := 'tags:creator_tag_sizes'; SELECT md5(coalesce(string_agg(post_count::text, ',' ORDER BY post_count), '')) INTO val FROM tags
    WHERE lower(name) ~ pse AND id NOT IN (SELECT tag_id FROM tag_quarantines WHERE state = 'banished'); RETURN NEXT;
  metric := 'posts:tag_counts'; SELECT sum(tag_count) || '/' || sum(tag_count_artist) || '/' || sum(tag_count_character) INTO val FROM posts; RETURN NEXT;

  -- The jail (Post.jail_deletions, legal_hold?, post_jail rows, the jail tag).
  metric := 'jail:deletions'; SELECT count(*)::text INTO val FROM mod_actions ma
    WHERE ma.category = 42 AND ma.subject_type = 'Post'
      AND ma.description LIKE ('deleted post #' || ma.subject_id || ', reason: troll jail: %')
      AND (lower(coalesce((SELECT r.original_name FROM user_name_change_requests r WHERE r.user_id = ma.creator_id AND r.created_at > ma.created_at ORDER BY r.created_at, r.id LIMIT 1),
                          (SELECT u.name FROM users u WHERE u.id = ma.creator_id))) = ANY (jail)
           OR (SELECT lower(u.name) FROM users u WHERE u.id = ma.creator_id) = ANY (jail)); RETURN NEXT;
  metric := 'jail:legal_holds'; SELECT count(*)::text INTO val FROM mod_actions ma
    WHERE ma.category = 42 AND ma.subject_type = 'Post'
      AND ma.description LIKE ('deleted post #' || ma.subject_id || ', reason: troll jail: radioactive%')
      AND (lower(coalesce((SELECT r.original_name FROM user_name_change_requests r WHERE r.user_id = ma.creator_id AND r.created_at > ma.created_at ORDER BY r.created_at, r.id LIMIT 1),
                          (SELECT u.name FROM users u WHERE u.id = ma.creator_id))) = ANY (jail)
           OR (SELECT lower(u.name) FROM users u WHERE u.id = ma.creator_id) = ANY (jail)); RETURN NEXT;
  metric := 'jail:post_jail_rows'; SELECT count(*)::text INTO val FROM mod_actions WHERE category = 1114 AND description LIKE 'jailed post #%, reason: troll jail%'; RETURN NEXT;
  metric := 'jail:deleted_with_tag'; SELECT count(*)::text INTO val FROM posts WHERE is_deleted AND string_to_array(tag_string, ' ') @> ARRAY[jtag]; RETURN NEXT;
  metric := 'flags:categories'; SELECT count(*) FILTER (WHERE reason = 'Unapproved in three days') || '/'
                                     || count(*) FILTER (WHERE reason LIKE 'Unapproved in three days after returning to moderation queue%') || '/'
                                     || count(*) FILTER (WHERE reason LIKE 'troll jail%') INTO val FROM post_flags; RETURN NEXT;

  -- Cross-kind equalities the code relies on.
  metric := 'claims:artist_standing'; SELECT count(*)::text INTO val FROM artist_claims c JOIN creator_galleries g ON g.id = c.creator_gallery_id
    WHERE c.status = 'approved' AND lower(c.tag_name) ~ pse
      AND NOT EXISTS (SELECT 1 FROM tags t JOIN tag_quarantines q ON q.tag_id = t.id WHERE t.name = c.tag_name AND q.state = 'banished')
      AND (EXISTS (SELECT 1 FROM unnest(mst) p WHERE starts_with(lower(c.tag_name), p))
           OR regexp_replace(lower(c.tag_name), pse, '') = lower(substring(g.matrix_id FROM '^@([^:]+):'))); RETURN NEXT;
  metric := 'claims:character_qualifier'; SELECT count(*)::text INTO val FROM character_claims c LEFT JOIN creator_galleries g ON g.id = c.creator_gallery_id
    WHERE lower(substring(c.tag_name FROM '_\(([^()]+)\)$')) = lower(coalesce(g.slug, c.creator_slug))
      AND NOT EXISTS (SELECT 1 FROM tags t JOIN tag_quarantines q ON q.tag_id = t.id WHERE t.name = c.tag_name AND q.state = 'banished'); RETURN NEXT;
  metric := 'groups:named_for_creator'; SELECT count(*)::text INTO val FROM creator_groups cg JOIN creator_galleries g ON g.id = cg.creator_gallery_id
    WHERE lower(substring(g.matrix_id FROM '^@[^:]+:(.+)$')) = srv
      AND EXISTS (SELECT 1 FROM unnest(mst) p WHERE starts_with(cg.name, p || lower(substring(g.matrix_id FROM '^@([^:]+):')) || '_')); RETURN NEXT;
  metric := 'creators:recorded_with_gallery'; SELECT count(*)::text INTO val FROM fourier_post_creators f WHERE lower(f.mxid) IN (SELECT lower(matrix_id) FROM creator_galleries); RETURN NEXT;
  metric := 'creators:gallery_has_master_tag'; SELECT count(*)::text INTO val FROM creator_galleries g
    WHERE lower(substring(g.matrix_id FROM '^@[^:]+:(.+)$')) = srv
      AND EXISTS (SELECT 1 FROM tags t WHERE t.name = ANY (ARRAY(SELECT p || lower(substring(g.matrix_id FROM '^@([^:]+):')) FROM unnest(mst) p))
                     AND NOT EXISTS (SELECT 1 FROM tag_quarantines q WHERE q.tag_id = t.id AND q.state = 'banished')); RETURN NEXT;
  metric := 'creators:account_named_as_master_tag'; SELECT count(*)::text INTO val FROM users u
    WHERE EXISTS (SELECT 1 FROM tags t WHERE t.name = ANY (ARRAY(SELECT p || lower(u.name) FROM unnest(mst) p))
                    AND NOT EXISTS (SELECT 1 FROM tag_quarantines q WHERE q.tag_id = t.id AND q.state = 'banished')); RETURN NEXT;
  metric := 'creators:generation_owned_by_creator'; SELECT count(*)::text INTO val FROM fourier_generation_metadata g
    JOIN posts p ON p.md5 = g.md5 JOIN fourier_post_creators f ON f.post_id = p.id WHERE lower(f.mxid) = lower(g.poster); RETURN NEXT;
  metric := 'mxc:post_source_matches'; SELECT count(*)::text INTO val FROM post_mxcs pm JOIN posts p ON p.id = pm.post_id
    WHERE pm.source = 'post_source' AND pm.mxc = p.source; RETURN NEXT;
  metric := 'joins:alias_consequent_exists'; SELECT count(*)::text INTO val FROM tag_aliases a WHERE a.status = 'active' AND EXISTS (SELECT 1 FROM tags t WHERE t.name = a.consequent_name); RETURN NEXT;
  metric := 'joins:wiki_title_is_tag'; SELECT count(*)::text INTO val FROM wiki_pages w WHERE EXISTS (SELECT 1 FROM tags t WHERE t.name = w.title); RETURN NEXT;
  metric := 'joins:artist_name_is_tag'; SELECT count(*)::text INTO val FROM artists a WHERE EXISTS (SELECT 1 FROM tags t WHERE t.name = a.name); RETURN NEXT;
END
$fn$;

\echo '[verify before] shape'
CREATE TABLE anon_snapshot.shape_before AS SELECT * FROM anon_snapshot.shape();

\echo '[verify before] plant canaries'
CREATE TABLE anon_snapshot.canary_rows (ord serial PRIMARY KEY, tbl text NOT NULL, keycol text NOT NULL, val text NOT NULL);
DO $plant$
DECLARE
  tok text := (SELECT v FROM anon_snapshot.meta WHERE k = 'token');
  nm text := 'canary_' || (SELECT v FROM anon_snapshot.meta WHERE k = 'token');
  mx text := '@canary_' || (SELECT v FROM anon_snapshot.meta WHERE k = 'token') || ':example.invalid';
  mail text := 'canary_' || (SELECT v FROM anon_snapshot.meta WHERE k = 'token') || '@mail-canary.test';
  disc text := 'discord:' || (('x' || left(md5(tok), 15))::bit(60)::bigint)::text;
  uid int; gid bigint; rid int; pid int; aid bigint; uaid bigint; upid int; tid int; xid bigint;
  md5p text := md5('canary-post-' || tok);
  -- Creator prefixes from cfg, never spelled here: p1 the Matrix one, p2 another pseudonymized one.
  p1 text := (SELECT e ->> 'prefix' FROM jsonb_array_elements((SELECT cfg FROM anon_v_input) -> 'prefixes') e
               WHERE e ->> 'action' = 'pseudonymize' ORDER BY (lower(e ->> 'provenance') = 'matrix') DESC, e ->> 'prefix' LIMIT 1);
  p2 text := coalesce((SELECT e ->> 'prefix' FROM jsonb_array_elements((SELECT cfg FROM anon_v_input) -> 'prefixes') e
                        WHERE e ->> 'action' = 'pseudonymize' AND e ->> 'prefix' <> p1 ORDER BY e ->> 'prefix' LIMIT 1), p1);
  jt text := (SELECT cfg ->> 'jail_tag' FROM anon_v_input);
  t1 text;
  t2 text;
  oc text;
BEGIN
  t1 := p1 || nm;
  t2 := p2 || nm || '_alt';
  oc := 'kayla_(' || nm || ')';
  INSERT INTO users (created_at, updated_at, name, level, last_logged_in_at, post_upload_count, post_update_count, note_update_count,
                     favorite_count, comment_threshold, default_image_size, favorite_tags, blacklisted_tags, time_zone,
                     bcrypt_password_hash, per_page, custom_style, bit_prefs, last_ip_addr, unread_dmail_count, theme, upload_points,
                     totp_secret, backup_codes)
  VALUES (now(), now(), nm, 20, now(), 0, 0, 0, 0, -8, 'large', t1, t2 || E'\nuser:' || nm, 'UTC',
          crypt('canary-' || tok, gen_salt('bf', 4)), 20, 'body{background:url(https://css.example.invalid/' || nm || ')}', 0,
          '192.0.2.77', 0, 0, 0, 'CNRY' || upper(tok), '{12345678}')
  RETURNING id INTO uid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('users', 'id', uid);

  INSERT INTO email_addresses (created_at, updated_at, user_id, address, normalized_address, is_verified, is_deliverable)
  VALUES (now(), now(), uid, mail, mail, true, true) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('email_addresses', 'id', xid);
  INSERT INTO dmails (owner_id, from_id, to_id, title, body, created_at, updated_at)
  VALUES (uid, uid, uid, 'canary ' || tok, 'write to ' || mail || ' or ' || mx || ' from 192.0.2.82', now(), now()) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('dmails', 'id', xid);
  INSERT INTO user_name_change_requests (user_id, original_name, desired_name, created_at, updated_at)
  VALUES (uid, 'old' || nm, nm, now(), now()) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('user_name_change_requests', 'id', xid);

  INSERT INTO creator_galleries (slug, matrix_id, user_id, title, bio, matrix_contact, settings, created_at, updated_at)
  VALUES (nm, mx, uid, 'Canary ' || tok, 'bio ' || nm, mx, jsonb_build_object('contact', mail), now(), now()) RETURNING id INTO gid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('creator_galleries', 'id', gid);
  INSERT INTO creator_groups (creator_gallery_id, name, tier, created_at, updated_at)
  VALUES (gid, p1 || nm || '_tier_1', 1, now(), now()) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('creator_groups', 'id', xid);
  INSERT INTO character_claims (creator_gallery_id, tag_name, status, note, creator_slug, created_at, updated_at)
  VALUES (NULL, oc, 'held', 'held for ' || nm, nm, now(), now()) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('character_claims', 'id', xid);

  INSERT INTO matrix_rooms (room_id, created_at, updated_at) VALUES ('!canary' || tok || ':example.invalid', now(), now()) RETURNING id INTO rid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('matrix_rooms', 'id', rid);
  INSERT INTO posts (created_at, updated_at, source, md5, rating, uploader_id, tag_string, tag_count, tag_count_general, tag_count_artist,
                     tag_count_character, tag_count_copyright, file_ext, file_size, image_width, image_height, tag_count_meta, room_ids)
  VALUES (now(), now(), 'mxc://example.invalid/canary' || tok, md5p, 's', uid,
          (SELECT string_agg(x, ' ' ORDER BY x COLLATE "C") FROM unnest(ARRAY[t1, t2, oc]) x), 3, 0, 2, 1, 0, 'png', 1, 1, 1, 0, ARRAY[rid])
  RETURNING id INTO pid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('posts', 'id', pid);
  INSERT INTO tags (name, post_count, category, created_at, updated_at, words) VALUES (t1, 1, 1, now(), now(), ARRAY['canary', tok]) RETURNING id INTO tid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('tags', 'id', tid);
  INSERT INTO tags (name, post_count, category, created_at, updated_at, words) VALUES (t2, 1, 1, now(), now(), ARRAY['canary', tok, 'alt']) RETURNING id INTO tid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('tags', 'id', tid);
  INSERT INTO tags (name, post_count, category, created_at, updated_at, words) VALUES (oc, 1, 4, now(), now(), ARRAY['kayla', 'canary', tok]) RETURNING id INTO tid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('tags', 'id', tid);
  INSERT INTO tags (name, post_count, category, created_at, updated_at, words) VALUES ('canaryprompt_' || tok, 0, 0, now(), now(), ARRAY['canaryprompt', tok]) RETURNING id INTO tid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('tags', 'id', tid);

  INSERT INTO fourier_post_creators (post_id, mxid, recorded_by, created_at, updated_at) VALUES (pid, mx, uid, now(), now()) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('fourier_post_creators', 'id', xid);
  INSERT INTO post_mxcs (post_id, mxc, source, created_at, updated_at) VALUES (pid, 'mxc://example.invalid/canary' || tok, 'post_source', now(), now()) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('post_mxcs', 'id', xid);
  INSERT INTO matrix_media (mxc, uploader, site_asset, room_ids, snapshot_head, snapshot_at, created_at, updated_at)
  VALUES ('mxc://example.invalid/canary' || tok, mx, false, ARRAY[rid], 0, now(), now(), now()) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('matrix_media', 'id', xid);
  INSERT INTO matrix_media (mxc, uploader, site_asset, room_ids, snapshot_head, snapshot_at, created_at, updated_at)
  VALUES ('mxc://example.invalid/canarydm' || tok, mx, false, '{}', 0, now(), now(), now()) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('matrix_media', 'id', xid);
  INSERT INTO fourier_generation_metadata (md5, source, poster, fields, created_at, updated_at, raw_md5)
  VALUES (md5p, 'matrix', mx, jsonb_build_object('png:parameters', 'prompt ' || nm, 'png:' || nm, 'secret'), now(), now(), md5('canary-raw-' || tok)) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('fourier_generation_metadata', 'id', xid);
  INSERT INTO fourier_generation_metadata (md5, source, poster, fields, created_at, updated_at, raw_md5)
  VALUES (md5('canary-gen2-' || tok), 'discord', disc, jsonb_build_object('exif:UserComment', 'canary ' || tok), now(), now(), md5p) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('fourier_generation_metadata', 'id', xid);
  INSERT INTO fourier_tag_sources (post_id, tag, source, status, added_by, created_at, public) VALUES (pid, t1, 1, 0, uid, now(), true) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('fourier_tag_sources', 'id', xid);
  INSERT INTO fourier_tag_sources (post_id, tag, source, status, added_by, created_at, public) VALUES (pid, 'canaryprompt_' || tok, 1, 0, uid, now(), false) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('fourier_tag_sources', 'id', xid);
  INSERT INTO post_versions (updated_at, post_id, updater_id, version, rating, source, tags, added_tags, removed_tags)
  VALUES (now(), pid, uid, 1, 's', 'https://cdn.discordapp.example.invalid/attachments/1/2/' || nm || '.png?ex=1&hm=2',
          (SELECT string_agg(x, ' ' ORDER BY x COLLATE "C") FROM unnest(ARRAY[t1, t2, 'canaryprompt_' || tok, oc]) x),
          ARRAY[t1, t2, 'canaryprompt_' || tok, oc], '{}') RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('post_versions', 'id', xid);

  INSERT INTO media_assets (created_at, updated_at, md5, file_ext, file_size, image_width, image_height, status, file_key, is_public, pixel_hash)
  VALUES (now(), now(), md5p, 'png', 1, 1, 1, 200, 'c' || left(tok, 8), true, gen_random_uuid()) RETURNING id INTO aid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('media_assets', 'id', aid);
  INSERT INTO media_metadata (created_at, updated_at, media_asset_id, metadata)
  VALUES (now(), now(), aid, jsonb_build_object('File:ImageWidth', 1, 'IFD0:Artist', nm, 'GPS:GPSLatitude', '12.34 ' || tok, 'PNG:Parameters', 'prompt ' || nm)) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('media_metadata', 'id', xid);
  INSERT INTO media_assets (created_at, updated_at, md5, file_ext, file_size, image_width, image_height, status, file_key, is_public, pixel_hash)
  VALUES (now(), now(), md5('canary-unposted-' || tok), 'png', 1, 1, 1, 200, 'u' || left(tok, 8), true, gen_random_uuid()) RETURNING id INTO uaid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('media_assets', 'id', uaid);
  INSERT INTO media_metadata (created_at, updated_at, media_asset_id, metadata)
  VALUES (now(), now(), uaid, jsonb_build_object('GPS:GPSLatitude', nm)) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('media_metadata', 'id', xid);
  INSERT INTO uploads (source, uploader_id, status, created_at, updated_at, referer_url, media_asset_count)
  VALUES ('https://discord.example.invalid/' || nm, uid, 'completed', now(), now(), 'https://discord.example.invalid/channels/' || tok, 1) RETURNING id INTO upid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('uploads', 'id', upid);
  INSERT INTO upload_media_assets (created_at, updated_at, upload_id, media_asset_id, status, source_url, page_url, user_id)
  VALUES (now(), now(), upid, uaid, 0, 'https://discord.example.invalid/' || nm || '.png', 'https://discord.example.invalid/p/' || tok, uid) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('upload_media_assets', 'id', xid);
  INSERT INTO ai_tags (media_asset_id, tag_id, score) VALUES (uaid, tid, 50);
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('ai_tags', 'media_asset_id', uaid);

  INSERT INTO mod_actions (creator_id, description, created_at, updated_at, category, subject_type, subject_id)
  VALUES (uid, 'changed user #' || uid || '''s email from ' || mail || ' to x', now(), now(), 501, 'User', uid) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('mod_actions', 'id', xid);
  INSERT INTO mod_actions (creator_id, description, created_at, updated_at, category, subject_type, subject_id)
  VALUES (uid, 'jailed post #' || pid || ', reason: troll jail: ' || nm || ' tagged a deleted post ' || jt, now(), now(), 1114, 'Post', pid) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('mod_actions', 'id', xid);
  INSERT INTO mod_actions (creator_id, description, created_at, updated_at, category, subject_type, subject_id)
  VALUES (uid, 'created ip ban for 192.0.2.83', now(), now(), 160, NULL, NULL) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('mod_actions', 'id', xid);
  INSERT INTO post_flags (post_id, creator_id, reason, is_resolved, created_at, updated_at, status)
  VALUES (pid, uid, 'troll jail: moderator ' || nm || ', from the post page', false, now(), now(), 1) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('post_flags', 'id', xid);

  -- One fake address in every inet column, a fake user agent, session ids, secrets.
  INSERT INTO user_events (created_at, updated_at, user_id, category, ip_addr, session_id, user_agent, metadata)
  VALUES (now(), now(), uid, 0, '192.0.2.77', gen_random_uuid(), 'CanaryAgent/' || tok, jsonb_build_object('ip', '192.0.2.84')) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('user_events', 'id', xid);
  INSERT INTO user_sessions (created_at, updated_at, ip_addr, session_id, user_agent) VALUES (now(), now(), '3fff::77', 'canary' || tok, 'CanaryAgent/' || tok) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('user_sessions', 'id', xid);
  INSERT INTO login_sessions (created_at, updated_at, user_id, login_id, session_id, status) VALUES (now(), now(), uid, gen_random_uuid(), gen_random_uuid(), 0) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('login_sessions', 'id', xid);
  INSERT INTO ip_bans (creator_id, ip_addr, reason, created_at, updated_at) VALUES (uid, '192.0.2.79', 'canary ' || tok, now(), now()) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('ip_bans', 'id', xid);
  INSERT INTO ip_geolocations (created_at, updated_at, ip_addr, network, is_proxy, city) VALUES (now(), now(), '192.0.2.80', '192.0.2.0/24', false, 'canary ' || tok) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('ip_geolocations', 'id', xid);
  INSERT INTO api_keys (user_id, key, created_at, updated_at, name, permitted_ip_addresses, last_ip_address)
  VALUES (uid, 'canarykey' || tok, now(), now(), 'canary ' || tok, '{192.0.2.81}', '3fff::81') RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('api_keys', 'id', xid);
  INSERT INTO signup_tokens (token, note, creator_id, created_at, updated_at) VALUES ('canarytok' || tok, 'invite for ' || nm, uid, now(), now()) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('signup_tokens', 'id', xid);
  INSERT INTO site_credentials (created_at, updated_at, site, creator_id, credential) VALUES (now(), now(), 0, uid, jsonb_build_object('password', 'canary' || tok)) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('site_credentials', 'id', xid);
  INSERT INTO good_jobs (queue_name, serialized_params, created_at, updated_at) VALUES (nm, jsonb_build_object('arguments', jsonb_build_array(mail)), now(), now());
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('good_jobs', 'queue_name', nm);

  INSERT INTO saved_searches (user_id, query, created_at, updated_at, labels) VALUES (uid, 'user:' || nm || ' ' || t1, now(), now(), ARRAY[nm]) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('saved_searches', 'id', xid);
  INSERT INTO tag_aliases (antecedent_name, consequent_name, creator_id, status, created_at, updated_at, reason)
  VALUES (t2, t1, uid, 'deleted', now(), now(), 'per ' || nm) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('tag_aliases', 'id', xid);
  INSERT INTO wiki_pages (title, body, created_at, updated_at, other_names) VALUES (t1, 'about ' || mx, now(), now(), ARRAY[nm]) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('wiki_pages', 'id', xid);
  INSERT INTO artists (name, created_at, updated_at, other_names) VALUES (t1, now(), now(), ARRAY[nm]) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('artists', 'id', xid);
  INSERT INTO artist_urls (artist_id, url, created_at, updated_at) VALUES (xid, 'https://social.example.invalid/' || nm, now(), now()) RETURNING id INTO xid;
  INSERT INTO anon_snapshot.canary_rows (tbl, keycol, val) VALUES ('artist_urls', 'id', xid);
END
$plant$;

\echo '[verify before] ledger of original identity strings (stays in this throwaway database)'
CREATE TABLE anon_snapshot.ledger (kind text NOT NULL, value text NOT NULL, user_id int);
INSERT INTO anon_snapshot.ledger (kind, value)
SELECT 'name', n FROM (
        SELECT lower(name) AS n FROM users
  UNION SELECT lower(original_name) FROM user_name_change_requests UNION SELECT lower(desired_name) FROM user_name_change_requests
  UNION SELECT lower(slug) FROM creator_galleries UNION SELECT lower(creator_slug) FROM character_claims
  UNION SELECT lower(substring(v FROM '^@([^:]+):')) FROM (SELECT matrix_id AS v FROM creator_galleries UNION SELECT matrix_contact FROM creator_galleries
                                                      UNION SELECT mxid FROM fourier_post_creators UNION SELECT uploader FROM matrix_media
                                                      UNION SELECT poster FROM fourier_generation_metadata) m
  UNION SELECT regexp_replace(lower(t), (SELECT pseud_any FROM anon_v_re), '') FROM (
          SELECT name AS t FROM tags UNION SELECT name FROM tag_versions UNION SELECT antecedent_name FROM tag_aliases
          UNION SELECT consequent_name FROM tag_aliases UNION SELECT name FROM artists UNION SELECT title FROM wiki_pages
          UNION SELECT tag_name FROM artist_claims UNION SELECT tag_name FROM creator_tag_releases UNION SELECT tag FROM tag_grants
          UNION SELECT unnest(tags) FROM landing_categories) tt
         WHERE lower(t) ~ (SELECT pseud_any FROM anon_v_re)
) s
WHERE n IS NOT NULL AND n <> '' AND n !~ '^user_[0-9]+$' AND n NOT IN (SELECT name FROM anon_v_keep);
INSERT INTO anon_snapshot.ledger (kind, value)
SELECT 'mxid', lower(v) FROM (SELECT matrix_id AS v FROM creator_galleries UNION SELECT matrix_contact FROM creator_galleries
                              UNION SELECT mxid FROM fourier_post_creators UNION SELECT uploader FROM matrix_media
                              UNION SELECT poster FROM fourier_generation_metadata) m
 WHERE v ~ '^@[^:]+:' AND lower(substring(v FROM '^@([^:]+):')) NOT IN (SELECT name FROM anon_v_keep);
INSERT INTO anon_snapshot.ledger (kind, value)
SELECT DISTINCT 'creator_tag', lower(t) FROM (
        SELECT name AS t FROM tags UNION SELECT name FROM tag_versions UNION SELECT antecedent_name FROM tag_aliases
  UNION SELECT consequent_name FROM tag_aliases UNION SELECT name FROM artists UNION SELECT title FROM wiki_pages
  UNION SELECT tag_name FROM artist_claims UNION SELECT tag_name FROM creator_tag_releases UNION SELECT tag FROM tag_grants
  UNION SELECT unnest(tags) FROM landing_categories) tt
 WHERE lower(t) ~ (SELECT pseud_any FROM anon_v_re)
   AND regexp_replace(lower(t), (SELECT pseud_any FROM anon_v_re), '') NOT IN (SELECT name FROM anon_v_keep);
INSERT INTO anon_snapshot.ledger (kind, value) SELECT 'oc_tag', lower(tag_name) FROM character_claims;
INSERT INTO anon_snapshot.ledger (kind, value)
SELECT 'email', lower(address) FROM email_addresses UNION SELECT 'email', lower(normalized_address) FROM email_addresses
UNION SELECT 'email_local', lower(split_part(address, '@', 1)) FROM email_addresses WHERE length(split_part(address, '@', 1)) >= 4;
INSERT INTO anon_snapshot.ledger (kind, value)
SELECT 'ip', host(a) FROM (
        SELECT last_ip_addr AS a FROM users UNION SELECT ip_addr FROM user_events UNION SELECT ip_addr FROM user_sessions
  UNION SELECT ip_addr FROM ip_bans UNION SELECT ip_addr FROM ip_geolocations UNION SELECT network FROM ip_geolocations
  UNION SELECT last_ip_address FROM api_keys UNION SELECT unnest(permitted_ip_addresses) FROM api_keys) s WHERE a IS NOT NULL;
INSERT INTO anon_snapshot.ledger (kind, value)
SELECT 'secret', lower(v) FROM (
        SELECT key AS v FROM api_keys UNION SELECT token FROM signup_tokens UNION SELECT code FROM upgrade_codes
  UNION SELECT login_id::text FROM login_sessions UNION SELECT session_id::text FROM login_sessions
  UNION SELECT session_id::text FROM user_events UNION SELECT session_id FROM user_sessions UNION SELECT transaction_id FROM user_upgrades) s
 WHERE v IS NOT NULL AND v <> '';
INSERT INTO anon_snapshot.ledger (kind, value) SELECT 'totp', lower(totp_secret) FROM users WHERE totp_secret IS NOT NULL;
INSERT INTO anon_snapshot.ledger (kind, value, user_id) SELECT 'bcrypt', bcrypt_password_hash, id FROM users;
INSERT INTO anon_snapshot.ledger (kind, value) SELECT DISTINCT 'discord_id', substring(poster FROM 9) FROM fourier_generation_metadata WHERE poster ~ '^discord:[0-9]+$';
INSERT INTO anon_snapshot.ledger (kind, value)
SELECT DISTINCT 'mxc_id', lower(substring(m FROM '^mxc://[^/]+/(.+)$')) FROM (
  SELECT mxc AS m FROM post_mxcs UNION SELECT mxc FROM matrix_media UNION SELECT source FROM posts WHERE source LIKE 'mxc://%') s
 WHERE m ~ '^mxc://[^/]+/.+$';
INSERT INTO anon_snapshot.ledger (kind, value) SELECT 'room', lower(btrim(room_id, '!')) FROM matrix_rooms;
INSERT INTO anon_snapshot.ledger (kind, value)
SELECT 'banished', t.name FROM tags t JOIN tag_quarantines q ON q.tag_id = t.id WHERE q.state = 'banished';
CREATE TABLE anon_snapshot.private_pairs AS SELECT post_id, tag FROM fourier_tag_sources WHERE NOT public;

-- Bare names that are also words of kept vocabulary (tags no rule renames,
-- the filler and mod-log words the anonymizer writes) cannot be told from
-- that vocabulary by a token scan; they stay covered by the Matrix-id,
-- creator-tag and closed-world rules, and are counted, not scanned bare.
CREATE TABLE anon_snapshot.collision (value text PRIMARY KEY);
INSERT INTO anon_snapshot.collision
SELECT DISTINCT w FROM (
  SELECT regexp_split_to_table(lower(t.name), '[^a-z0-9]+') AS w FROM tags t
   WHERE lower(t.name) !~ (SELECT pseud_any FROM anon_v_re)
     AND NOT EXISTS (SELECT 1 FROM tag_quarantines q WHERE q.tag_id = t.id AND q.state = 'banished')
     AND NOT (t.name ~ '_\([^()]+\)$' AND (t.category = 4 OR EXISTS (SELECT 1 FROM character_claims c WHERE c.tag_name = t.name)))
  UNION SELECT lower(t.name) FROM tags t WHERE lower(t.name) !~ (SELECT pseud_any FROM anon_v_re)
     AND NOT (t.name ~ '_\([^()]+\)$' AND (t.category = 4 OR EXISTS (SELECT 1 FROM character_claims c WHERE c.tag_name = t.name)))
  -- the words the anonymizer itself writes (filler, regenerated mod log, labels),
  -- then the app's own enum and file vocabulary, which is kept verbatim
  UNION SELECT unnest(string_to_array(
    'lorem ipsum dolor sit amet redacted reason flag message body comment topic forum post note pool group commentary title '
    'wiki page gallery creator bio claim join request release alias implication quarantine ban feedback report news appeal '
    'disapproval label unknown source invalid example artist record category user users troll jail moderator from the a an '
    'tagged deleted account banished private tag tier key x row alt '
    'delete undelete unban name change level approval privilege upload account upgrade update permanent move favorites '
    'regenerate iqdb lock create rating vote media asset expunge topic handled rejected moderation deprecate undeprecate ip '
    'site credential enable disable email address backup code send mass visibility approve reject unlink audience member '
    'add remove hidden view unjail character hold unbanish '
    'tagalias tagimplication forumtopic forumpost ipban newsupdate sitecredential moderationreport commentvote postvote dmail '
    'pending approved processing completed error failed active retired queued grid masonry filmstrip spotlight public groups '
    'inherit allow block automation live sweep flagged fit unitag large original edit positive neutral negative series '
    'collection breaks rules poor quality disinterest new promoted featured blog board tags galleries favcount score random '
    'development environment schema sha1 anonymized for dev png jpg jpeg gif webp avif mp4 webm swf zip ugoira image video '
    'grayscale with alpha rgb rotate cw infinite inf novelai masterpiece monochrome avis isom matroska', ' '))
) s WHERE w <> '';

CREATE TABLE anon_snapshot.ledger_scan AS
  SELECT DISTINCT kind, value FROM anon_snapshot.ledger
   WHERE kind <> 'bcrypt' AND length(value) >= 3
     AND NOT (kind IN ('name', 'email_local') AND value IN (SELECT value FROM anon_snapshot.collision));
CREATE INDEX ON anon_snapshot.ledger_scan (value);
ANALYZE anon_snapshot.ledger_scan;

DO $report$
BEGIN
  RAISE NOTICE '[verify before] ledger: % entries; % bare names also vocabulary words (covered by the Matrix-id, creator-tag and closed-world rules only); % names of 2 characters or fewer (not scanned bare)',
    (SELECT count(*) FROM anon_snapshot.ledger_scan),
    (SELECT count(DISTINCT value) FROM anon_snapshot.ledger WHERE kind = 'name' AND value IN (SELECT value FROM anon_snapshot.collision)),
    (SELECT count(DISTINCT value) FROM anon_snapshot.ledger WHERE kind = 'name' AND length(value) < 3);
END
$report$;

COMMIT;
SELECT v AS canary_token FROM anon_snapshot.meta WHERE k = 'token' \gset
\echo '[verify before] committed. Canary token (fake, safe to note down):' :canary_token

-- ===========================================================================
\elif :is_after
-- ===========================================================================
\echo '[verify after] guards'
DO $g$
DECLARE armed boolean;
BEGIN
  IF to_regclass('anon_guard.armed') IS NULL THEN RAISE EXCEPTION 'refusing: database not armed'; END IF;
  EXECUTE 'SELECT EXISTS (SELECT 1 FROM anon_guard.armed)' INTO armed;
  IF NOT armed THEN RAISE EXCEPTION 'refusing: anon_guard.armed is empty'; END IF;
  IF current_setting('listen_addresses') <> '' THEN RAISE EXCEPTION 'refusing: the server listens on TCP'; END IF;
  IF to_regnamespace('anon_snapshot') IS NULL THEN RAISE EXCEPTION 'refusing: no anon_snapshot' USING HINT = 'Run phase=before on the restored copy before anonymizing it.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM ar_internal_metadata WHERE key = 'anonymized_for_dev') THEN RAISE EXCEPTION 'refusing: the copy is not anonymized yet' USING HINT = 'Run script/anonymize_for_dev.sql first.'; END IF;
END
$g$;

\echo '[verify after] column-level checks'
DO $hard$
DECLARE
  n bigint;
  t text;
BEGIN
  IF EXISTS (SELECT 1 FROM users WHERE totp_secret IS NOT NULL OR backup_codes IS NOT NULL OR last_ip_addr IS NOT NULL OR custom_style IS NOT NULL) THEN
    RAISE EXCEPTION 'users: a 2FA secret, address or custom style survived';
  END IF;
  SELECT count(*) INTO n FROM users u JOIN anon_snapshot.ledger l ON l.kind = 'bcrypt' AND l.user_id = u.id AND l.value = u.bcrypt_password_hash;
  IF n > 0 THEN RAISE EXCEPTION 'users: % accounts kept their original password hash', n; END IF;
  IF EXISTS (SELECT 1 FROM email_addresses WHERE address !~ '^u[0-9]+@example\.invalid$' OR normalized_address <> address OR is_deliverable) THEN
    RAISE EXCEPTION 'email_addresses: an address is not u<id>@example.invalid, or is deliverable';
  END IF;
  FOREACH t IN ARRAY ARRAY['api_keys', 'good_jobs', 'good_job_executions', 'good_job_batches', 'good_job_processes', 'good_job_settings',
                           'ip_bans', 'ip_geolocations', 'login_sessions', 'rate_limits', 'signup_tokens', 'site_credentials',
                           'upgrade_codes', 'user_events', 'user_sessions', 'user_upgrades', 'dtext_links'] LOOP
    EXECUTE format('SELECT count(*) FROM public.%I', t) INTO n;
    IF n > 0 THEN RAISE EXCEPTION '%: % rows survived the purge', t, n; END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM fourier_tag_sources WHERE NOT public) THEN RAISE EXCEPTION 'fourier_tag_sources: a private row survived'; END IF;
  SELECT count(*) INTO n FROM anon_snapshot.private_pairs p JOIN post_versions pv ON pv.post_id = p.post_id
   WHERE p.tag = ANY (string_to_array(pv.tags, ' ')) OR p.tag = ANY (pv.added_tags) OR p.tag = ANY (pv.removed_tags);
  IF n > 0 THEN RAISE EXCEPTION 'post_versions: % versions still carry a creator-private tag of their post', n; END IF;
  IF EXISTS (SELECT 1 FROM media_assets ma WHERE NOT EXISTS (SELECT 1 FROM posts p WHERE p.md5 = ma.md5)
                AND NOT EXISTS (SELECT 1 FROM post_replacements r WHERE r.media_asset_id = ma.id)
                AND NOT EXISTS (SELECT 1 FROM post_replacements r WHERE r.old_media_asset_id = ma.id)) THEN
    RAISE EXCEPTION 'media_assets: an unposted asset survived';
  END IF;
  IF EXISTS (SELECT 1 FROM matrix_media mm WHERE NOT EXISTS (SELECT 1 FROM post_mxcs pm WHERE pm.mxc = mm.mxc)) THEN RAISE EXCEPTION 'matrix_media: a row no post carries survived'; END IF;
  IF EXISTS (SELECT 1 FROM ai_tags a WHERE NOT EXISTS (SELECT 1 FROM media_assets ma WHERE ma.id = a.media_asset_id)) THEN RAISE EXCEPTION 'ai_tags: orphan rows survived'; END IF;
  IF NOT EXISTS (SELECT 1 FROM ar_internal_metadata WHERE key = 'environment' AND value = 'development') THEN RAISE EXCEPTION 'ar_internal_metadata: environment is not development'; END IF;
END
$hard$;

\echo '[verify after] the scan: plant fresh canaries, scan everything once, roll the canaries back'
DO $scan$
DECLARE
  toka text := (SELECT v FROM anon_snapshot.meta WHERE k = 'token');
  tokp text := 'cnry' || encode(gen_random_bytes(5), 'hex');
  uid int := (SELECT min(id) FROM users);
  p1 text := (SELECT e ->> 'prefix' FROM jsonb_array_elements((SELECT cfg FROM anon_v_input) -> 'prefixes') e
               WHERE e ->> 'action' = 'pseudonymize' ORDER BY (lower(e ->> 'provenance') = 'matrix') DESC, e ->> 'prefix' LIMIT 1);
  hits jsonb;
  missing text;
  extra text;
  n bigint;
BEGIN
  BEGIN
    INSERT INTO news_updates (message, creator_id, updater_id, created_at, updated_at)
    VALUES (format('post canary %s @canary_%s:example.invalid canary_%s@mail-canary.test 192.0.2.99 3fff::99 $2a$10$%s canary_%s @canary_%s:example.invalid',
                   tokp, tokp, tokp, repeat('C', 53), toka, toka), uid, uid, now(), now());
    INSERT INTO tags (name, post_count, category, created_at, updated_at, words) VALUES (p1 || 'canarypost_' || tokp, 0, 1, now(), now(), '{}');
    UPDATE post_versions SET added_tags = added_tags || (p1 || 'canarypost2_' || tokp) WHERE id = (SELECT min(id) FROM post_versions);
    UPDATE media_metadata SET metadata = metadata || jsonb_build_object('Canary', 'canary ' || tokp) WHERE id = (SELECT min(id) FROM media_metadata);
    UPDATE users SET last_ip_addr = '192.0.2.98' WHERE id = uid;
    SELECT coalesce(jsonb_agg(to_jsonb(f)), '[]'::jsonb) INTO hits FROM pg_temp.anon_scan(true, ARRAY[toka, tokp]) f;
    RAISE EXCEPTION 'anon_rollback_sentinel';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'anon_rollback_sentinel' THEN RAISE; END IF;
  END;

  WITH f AS (SELECT x ->> 'tbl' AS tbl, x ->> 'col' AS col, x ->> 'rule' AS rule, (x ->> 'n')::bigint AS n FROM jsonb_array_elements(hits) x),
       want(tbl, col, rule) AS (VALUES
         ('news_updates', 'message', 'canary'), ('news_updates', 'message', 'email'), ('news_updates', 'message', 'mxid'),
         ('news_updates', 'message', 'ipv4'), ('news_updates', 'message', 'ipv6'), ('news_updates', 'message', 'bcrypt'),
         ('news_updates', 'message', 'ledger:mxid'), ('news_updates', 'message', 'ledger:name'),
         ('tags', 'name', 'canary'), ('tags', 'name', 'creator_tag'),
         ('post_versions', 'added_tags', 'canary'), ('post_versions', 'added_tags', 'creator_tag'),
         ('media_metadata', 'metadata', 'canary'), ('users', 'last_ip_addr', 'inet_value'))
  SELECT (SELECT string_agg(w.tbl || '.' || w.col || ' ' || w.rule, '; ') FROM want w
           WHERE NOT EXISTS (SELECT 1 FROM f WHERE f.tbl = w.tbl AND f.col = w.col AND f.rule = w.rule)),
         (SELECT string_agg(f.tbl || '.' || f.col || ' ' || f.rule || ' x' || f.n || ' (first at ctid ' || coalesce(fx.sample, '?') || ')', '; ')
            FROM f LEFT JOIN LATERAL (SELECT x ->> 'sample' AS sample FROM jsonb_array_elements(hits) x
                                       WHERE x ->> 'tbl' = f.tbl AND x ->> 'col' = f.col AND x ->> 'rule' = f.rule LIMIT 1) fx ON true
           WHERE f.n <> 1
              OR NOT (EXISTS (SELECT 1 FROM want w WHERE w.tbl = f.tbl AND w.col = f.col AND w.rule = f.rule)
                      OR (f.tbl = 'news_updates' AND f.col = 'message' AND f.rule LIKE 'ledger:%')))
    INTO missing, extra;
  IF extra IS NOT NULL THEN
    RAISE EXCEPTION 'LEAK: the scan found real data (or more than the planted canary): %', extra
      USING HINT = 'Inspect each table.column at the ctid given, in this throwaway database only. Fix script/anonymize_for_dev.sql, restore a fresh copy and run all phases again. Do not dump this copy.';
  END IF;
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'BLIND SCAN: canaries planted after anonymizing were not found: %', missing
      USING HINT = 'The scan cannot see that rule or that column type, so its clean result proves nothing. Fix pg_temp.anon_scan.';
  END IF;

  SELECT (SELECT count(*) FROM news_updates WHERE message LIKE '%' || tokp || '%') + (SELECT count(*) FROM tags WHERE name LIKE '%' || tokp || '%')
       + (SELECT count(*) FROM post_versions WHERE array_to_string(added_tags, ' ') LIKE '%' || tokp || '%')
       + (SELECT count(*) FROM media_metadata WHERE metadata::text LIKE '%' || tokp || '%')
       + (SELECT count(*) FROM users WHERE last_ip_addr IS NOT NULL) INTO n;
  IF n > 0 THEN RAISE EXCEPTION 'the after-canaries were not rolled back (% rows)', n; END IF;
  RAISE NOTICE '[verify after] scan clean; it found each of the % planted canary findings and nothing else. After-canary token (fake): %', jsonb_array_length(hits), tokp;
END
$scan$;

\echo '[verify after] remove the before-canaries'
DO $clean$
DECLARE
  r record;
  n bigint;
BEGIN
  FOR r IN SELECT * FROM anon_snapshot.canary_rows ORDER BY ord DESC LOOP
    EXECUTE format('DELETE FROM public.%I WHERE %I::text = $1', r.tbl, r.keycol) USING r.val;
  END LOOP;
  FOR r IN SELECT * FROM anon_snapshot.canary_rows LOOP
    EXECUTE format('SELECT count(*) FROM public.%I WHERE %I::text = $1', r.tbl, r.keycol) INTO n USING r.val;
    IF n > 0 THEN RAISE EXCEPTION 'canary row %.%=% was not removed', r.tbl, r.keycol, r.val; END IF;
  END LOOP;
END
$clean$;

\echo '[verify after] shape'
DO $shape$
DECLARE
  diff text;
  claims4 bigint;
BEGIN
  SELECT string_agg(coalesce(b.metric, a.metric) || ' before=' || coalesce(b.val, 'none') || ' after=' || coalesce(a.val, 'none'), '; ')
    INTO diff
    FROM anon_snapshot.shape_before b FULL JOIN anon_snapshot.shape() a ON a.metric = b.metric
   WHERE b.val IS DISTINCT FROM a.val;
  IF diff IS NOT NULL THEN
    RAISE EXCEPTION 'SHAPE: anonymizing changed what the code reads: %', diff
      USING HINT = 'Each metric is a count the app depends on (jail, claims, groups, joins). Fix the rule that broke it, restore a fresh copy and run again.';
  END IF;
  -- Open question, reported: approved claims on a KEPT prefix whose suffix was a creator's localpart.
  SELECT count(*) INTO claims4 FROM artist_claims c
   WHERE c.status = 'approved'
     AND lower(c.tag_name) !~ (SELECT pseud_any FROM anon_v_re)
     AND EXISTS (SELECT 1 FROM jsonb_array_elements((SELECT cfg FROM anon_v_input) -> 'prefixes') e
                  WHERE e ->> 'action' = 'keep' AND starts_with(lower(c.tag_name), e ->> 'prefix'));
  RAISE NOTICE '[verify after] shape equal. Approved claims on kept prefixes (link a pseudonymized gallery to a public handle): %', claims4;
END
$shape$;

DROP SCHEMA anon_snapshot CASCADE;
DROP SCHEMA anon_guard CASCADE;
COMMIT;
\echo '[verify after] committed: canaries removed, ledger and guard dropped. Next: dump, restore into a fresh cluster, phase=final.'

-- ===========================================================================
\elif :is_final
-- ===========================================================================
\echo '[verify final] on the restored dev cluster'
\if :{?tokens}
\else
  \set tokens ''
\endif
SELECT :'tokens' AS tokens_in \gset
DO $f$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM ar_internal_metadata WHERE key = 'anonymized_for_dev') THEN
    RAISE EXCEPTION 'refusing: this database carries no anonymized_for_dev marker' USING HINT = 'phase=final runs only on the dev cluster restored from the verified dump.';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname LIKE 'anon\_%') THEN
    RAISE EXCEPTION 'an anon_* schema reached the dev cluster' USING HINT = 'The ledger or guard was dumped; drop this database and dump again after phase=after succeeds.';
  END IF;
END
$f$;
CREATE TEMP TABLE anon_v_tokens ON COMMIT DROP AS SELECT array_remove(string_to_array(:'tokens_in', ','), '') AS t;
DO $final$
DECLARE
  leaks text;
BEGIN
  SELECT string_agg(f.tbl || '.' || f.col || ' ' || f.rule || ' x' || f.n || ' (first at ctid ' || coalesce(f.sample, '?') || ')', '; ')
    INTO leaks
    FROM pg_temp.anon_scan(false, (SELECT t FROM anon_v_tokens)) f;
  IF leaks IS NOT NULL THEN
    RAISE EXCEPTION 'LEAK in the dev cluster: %', leaks USING HINT = 'Drop this database. Do not use it.';
  END IF;
  RAISE NOTICE '[verify final] clean: no canary, address, Matrix id, e-mail, bcrypt hash or unmapped creator name in any text-like column.';
END
$final$;
COMMIT;
\endif
