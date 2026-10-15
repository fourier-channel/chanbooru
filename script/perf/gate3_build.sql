-- GATE 3 SCALE TEST BED (fourier-basis docs/design/GATE3_MATRIX_POSTS.md):
-- 1,136,000 ordinary posts (production's count, 2026-10-15) plus 1,000,000
-- Matrix posts across 10,000 rooms, tags and rooms both long-tailed
-- (log-uniform, so P(rank k) ~ 1/k). Synthetic only: no production data.
-- Run against a SCRATCH database (danbooru_gate3_perf), never a real one.
DROP TABLE IF EXISTS posts;
CREATE TABLE posts (
  id bigserial PRIMARY KEY,
  tag_string text NOT NULL,
  is_deleted boolean NOT NULL DEFAULT false,
  room_ids integer[] NOT NULL   -- {0} for a non-Matrix post; the rooms it was placed in otherwise
);
-- 25 draws per post from 50,000 tags; t1 is "1girl"-common, t40000 rare.
INSERT INTO posts (tag_string, room_ids)
SELECT (SELECT string_agg(DISTINCT 't' || ceil(exp(random() * ln(50000)))::int, ' ')
          FROM generate_series(1, 25) WHERE g > 0),
       '{0}'
  FROM generate_series(1, 1136000) g;
-- Matrix posts, interleaved in id order with nothing: they arrive after, as
-- Matrix uploads are the newest. 10% were forwarded into a second room.
INSERT INTO posts (tag_string, room_ids)
SELECT (SELECT string_agg(DISTINCT 't' || ceil(exp(random() * ln(50000)))::int, ' ')
          FROM generate_series(1, 25) WHERE g > 0),
       CASE WHEN random() < 0.1
            THEN ARRAY[ceil(exp(random() * ln(10000)))::int, ceil(exp(random() * ln(10000)))::int]
            ELSE ARRAY[ceil(exp(random() * ln(10000)))::int] END
  FROM generate_series(1, 1000000) g;
UPDATE posts SET is_deleted = true WHERE id % 97 = 0;
CREATE INDEX posts_tags_gin ON posts USING gin (string_to_array(tag_string, ' '));
CREATE INDEX posts_rooms_gin ON posts USING gin (room_ids);
ANALYZE posts;
SELECT count(*) AS posts, count(*) FILTER (WHERE room_ids <> '{0}') AS matrix_posts,
       pg_size_pretty(pg_total_relation_size('posts')) AS size FROM posts;
-- Postgres's per-element statistics must resemble production's, or a rare
-- tag is misestimated and the plan walks the primary key (measured: 2,492
-- rows estimated for a 133-post tag at the default target; production
-- estimates a 39-post tag at 104). Raise the target on the tag index.
ALTER INDEX posts_tags_gin ALTER COLUMN 1 SET STATISTICS 2000;
ANALYZE posts;
