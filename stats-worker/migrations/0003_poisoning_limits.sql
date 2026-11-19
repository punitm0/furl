-- Limits against inflating the public totals now that the app's HMAC key is public.
--
-- 1. Per-IP daily budget (ip_daily): how many reports and how many first-seen installs one client network
--    may send per UTC day. Keyed on SHA-256(daily salt + IP), never the IP itself (IPv6 by /64). The salt is
--    random, made fresh each UTC day (ip_salts), and both tables are cleared of earlier days when the next
--    day's salt is made, so hashes can't be linked across days. The Worker enforces the caps (src/limits.ts).
-- 2. Maturity: an install adds nothing to the public totals until it reports on a second UTC day (and that
--    day's install ceiling has room). Its earlier, still-standing events are then added in one go and it
--    counts as one install.
-- 3. Global daily growth ceiling (public_ceilings / public_growth): each public metric can grow by at most
--    a fixed amount per UTC day, whatever the installs report. A single event is clipped to what's left;
--    the backlog an install brings when it matures is added whole if it fits that day, otherwise dropped.
--    The ceilings are rows, not constants, so they can be changed with `wrangler d1 execute` without a
--    migration. Keep the seeded values in sync with DAILY_PUBLIC_CEILING in src/limits.ts.
--
-- events.public_* records exactly what each event put into the totals (after the per-install daily cap,
-- maturity and the global ceiling), so a reversal takes back that and nothing more: an attacker can't
-- reverse a clipped event to push the totals down.
--
-- Both counting triggers are dropped and recreated, as in 0002 (SQLite doesn't order triggers). Updates to
-- totals and public_growth only touch metrics that actually change, since D1 bills every row written.

ALTER TABLE events ADD COLUMN public_bytes INTEGER NOT NULL DEFAULT 0;
ALTER TABLE events ADD COLUMN public_files INTEGER NOT NULL DEFAULT 0;
ALTER TABLE events ADD COLUMN public_items INTEGER NOT NULL DEFAULT 0;
-- Everything already stored was counted under the old rules.
UPDATE events SET public_bytes = counted_bytes, public_files = counted_files, public_items = counted_items;

-- 0 = not yet, 1 = counted. 2 exists only inside events_count, while an install is maturing.
ALTER TABLE installs ADD COLUMN matured INTEGER NOT NULL DEFAULT 0 CHECK (matured IN (0, 1, 2));
UPDATE installs SET matured = 1;  -- already in the install count

CREATE TABLE ip_salts (
  day  TEXT NOT NULL PRIMARY KEY,  -- UTC day, YYYY-MM-DD
  salt TEXT NOT NULL               -- 32 random bytes, hex
) WITHOUT ROWID;

CREATE TABLE ip_daily (
  ip_hash      TEXT    NOT NULL,   -- hex SHA-256 of salt + IP (IPv6: its /64); never the IP
  day          TEXT    NOT NULL,
  reports      INTEGER NOT NULL DEFAULT 0,
  new_installs INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (ip_hash, day)
) WITHOUT ROWID;

CREATE TABLE public_ceilings (
  metric TEXT    NOT NULL PRIMARY KEY,
  value  INTEGER NOT NULL CHECK (value >= 0)
) WITHOUT ROWID;

INSERT INTO public_ceilings (metric, value) VALUES
  ('disk',     5497558138880),  -- 5 TiB
  ('compress', 2199023255552),  -- 2 TiB
  ('memory',   5497558138880),  -- 5 TiB
  ('files',    5000000),
  ('items',    2000000),
  ('installs', 200);

-- How much each public metric has grown on a UTC day (rows are tiny: 6 per day).
CREATE TABLE public_growth (
  day    TEXT    NOT NULL,
  metric TEXT    NOT NULL,
  value  INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, metric)
) WITHOUT ROWID;

DROP TRIGGER events_count;
DROP TRIGGER events_reverse;

-- Per-install daily caps, lowered from 0002 to at most 5% of the public ceilings so two installs can't use up
-- a day's growth: disk 256 GiB, compress 64 GiB, memory 256 GiB, files 100,000 (compress only), items 50,000
-- (disk only). They go into counted_*; public_* is what actually reaches the totals. Keep them in sync with
-- DAILY_CAP in src/limits.ts.
CREATE TRIGGER events_count AFTER INSERT ON events
WHEN NEW.kind IN ('disk', 'memory', 'compress')
BEGIN
  INSERT OR IGNORE INTO installs (install_id, first_day) VALUES (NEW.install_id, NEW.day);
  INSERT OR IGNORE INTO daily_usage (install_id, day) VALUES (NEW.install_id, NEW.day);
  INSERT OR IGNORE INTO public_growth (day, metric) VALUES
    (NEW.day, 'disk'), (NEW.day, 'compress'), (NEW.day, 'memory'),
    (NEW.day, 'files'), (NEW.day, 'items'), (NEW.day, 'installs');

  -- Maturity: the first counted event on a later day than the install's first. The backlog is every
  -- earlier event that still stands; each metric's backlog is added whole if it fits under what's left of
  -- today's ceiling, otherwise not at all. Steps read public_growth before it's updated, so order matters.
  -- Maturity happens only when today's install ceiling has room; otherwise the install stays as it is and
  -- tries again with its next report. matured = 2 marks "maturing in this trigger" for the steps below.
  UPDATE installs SET matured = 2
   WHERE install_id = NEW.install_id AND matured = 0 AND first_day < NEW.day
     AND (SELECT g.value FROM public_growth g WHERE g.day = NEW.day AND g.metric = 'installs')
         < COALESCE((SELECT c.value FROM public_ceilings c WHERE c.metric = 'installs'), 0);

  -- Every subquery below refers only to NEW, never to the row being updated, so SQLite runs each once per
  -- statement: maturity costs one pass over the backlog, not one per backlog row (which was quadratic).
  UPDATE events SET
    public_bytes = CASE kind
      WHEN 'disk'     THEN CASE WHEN ((SELECT COALESCE(SUM(b.counted_bytes), 0) FROM events b
          WHERE b.install_id = NEW.install_id AND b.kind = 'disk' AND b.reversed = 0 AND b.event_id <> NEW.event_id)
        <= COALESCE((SELECT c.value FROM public_ceilings c WHERE c.metric = 'disk'), 0)
         - (SELECT g.value FROM public_growth g WHERE g.day = NEW.day AND g.metric = 'disk')) THEN counted_bytes ELSE 0 END
      WHEN 'memory'   THEN CASE WHEN ((SELECT COALESCE(SUM(b.counted_bytes), 0) FROM events b
          WHERE b.install_id = NEW.install_id AND b.kind = 'memory' AND b.reversed = 0 AND b.event_id <> NEW.event_id)
        <= COALESCE((SELECT c.value FROM public_ceilings c WHERE c.metric = 'memory'), 0)
         - (SELECT g.value FROM public_growth g WHERE g.day = NEW.day AND g.metric = 'memory')) THEN counted_bytes ELSE 0 END
      WHEN 'compress' THEN CASE WHEN ((SELECT COALESCE(SUM(b.counted_bytes), 0) FROM events b
          WHERE b.install_id = NEW.install_id AND b.kind = 'compress' AND b.reversed = 0 AND b.event_id <> NEW.event_id)
        <= COALESCE((SELECT c.value FROM public_ceilings c WHERE c.metric = 'compress'), 0)
         - (SELECT g.value FROM public_growth g WHERE g.day = NEW.day AND g.metric = 'compress')) THEN counted_bytes ELSE 0 END
      ELSE 0 END,
    public_files = CASE WHEN ((SELECT COALESCE(SUM(b.counted_files), 0) FROM events b
          WHERE b.install_id = NEW.install_id AND b.kind <> 'reversal' AND b.reversed = 0 AND b.event_id <> NEW.event_id)
        <= COALESCE((SELECT c.value FROM public_ceilings c WHERE c.metric = 'files'), 0)
         - (SELECT g.value FROM public_growth g WHERE g.day = NEW.day AND g.metric = 'files')) THEN counted_files ELSE 0 END,
    public_items = CASE WHEN ((SELECT COALESCE(SUM(b.counted_items), 0) FROM events b
          WHERE b.install_id = NEW.install_id AND b.kind <> 'reversal' AND b.reversed = 0 AND b.event_id <> NEW.event_id)
        <= COALESCE((SELECT c.value FROM public_ceilings c WHERE c.metric = 'items'), 0)
         - (SELECT g.value FROM public_growth g WHERE g.day = NEW.day AND g.metric = 'items')) THEN counted_items ELSE 0 END
   WHERE install_id = NEW.install_id AND kind <> 'reversal' AND reversed = 0 AND event_id <> NEW.event_id
     AND EXISTS (SELECT 1 FROM installs i WHERE i.install_id = NEW.install_id AND i.matured = 2);

  UPDATE totals SET value = value + (
      SELECT COALESCE(SUM(CASE totals.metric
                            WHEN 'files' THEN e.public_files
                            WHEN 'items' THEN e.public_items
                            ELSE CASE WHEN e.kind = totals.metric THEN e.public_bytes ELSE 0 END END), 0)
        FROM events e
       WHERE e.install_id = NEW.install_id AND e.kind <> 'reversal' AND e.reversed = 0 AND e.event_id <> NEW.event_id)
   WHERE metric IN ('disk', 'compress', 'memory', 'files', 'items')
     AND (SELECT COALESCE(SUM(CASE totals.metric
                                WHEN 'files' THEN e.public_files
                                WHEN 'items' THEN e.public_items
                                ELSE CASE WHEN e.kind = totals.metric THEN e.public_bytes ELSE 0 END END), 0)
            FROM events e
           WHERE e.install_id = NEW.install_id AND e.kind <> 'reversal' AND e.reversed = 0 AND e.event_id <> NEW.event_id) > 0
     AND EXISTS (SELECT 1 FROM installs i WHERE i.install_id = NEW.install_id AND i.matured = 2);

  UPDATE public_growth SET value = value + (
      SELECT COALESCE(SUM(CASE public_growth.metric
                            WHEN 'files' THEN e.public_files
                            WHEN 'items' THEN e.public_items
                            ELSE CASE WHEN e.kind = public_growth.metric THEN e.public_bytes ELSE 0 END END), 0)
        FROM events e
       WHERE e.install_id = NEW.install_id AND e.kind <> 'reversal' AND e.reversed = 0 AND e.event_id <> NEW.event_id)
   WHERE day = NEW.day AND metric IN ('disk', 'compress', 'memory', 'files', 'items')
     AND (SELECT COALESCE(SUM(CASE public_growth.metric
                                WHEN 'files' THEN e.public_files
                                WHEN 'items' THEN e.public_items
                                ELSE CASE WHEN e.kind = public_growth.metric THEN e.public_bytes ELSE 0 END END), 0)
            FROM events e
           WHERE e.install_id = NEW.install_id AND e.kind <> 'reversal' AND e.reversed = 0 AND e.event_id <> NEW.event_id) > 0
     AND EXISTS (SELECT 1 FROM installs i WHERE i.install_id = NEW.install_id AND i.matured = 2);

  UPDATE totals SET value = value + 1
   WHERE metric = 'installs'
     AND EXISTS (SELECT 1 FROM installs i WHERE i.install_id = NEW.install_id AND i.matured = 2);

  UPDATE public_growth SET value = value + 1
   WHERE day = NEW.day AND metric = 'installs'
     AND EXISTS (SELECT 1 FROM installs i WHERE i.install_id = NEW.install_id AND i.matured = 2);

  UPDATE installs SET matured = 1 WHERE install_id = NEW.install_id AND matured = 2;

  -- A reversal for this event arrived first (out-of-order delivery): it cancels the event outright.
  UPDATE events SET reversed = 1
   WHERE install_id = NEW.install_id AND event_id = NEW.event_id
     AND EXISTS (SELECT 1 FROM events r
                  WHERE r.install_id = NEW.install_id AND r.reverses = NEW.event_id AND r.kind = 'reversal');

  -- Per-install daily cap (lowered from 0002; values in the comment above this trigger).
  UPDATE events SET
    counted_bytes = MIN(NEW.bytes, MAX(0,
      (CASE NEW.kind WHEN 'compress' THEN 68719476736 ELSE 274877906944 END)
      - (SELECT CASE NEW.kind WHEN 'disk' THEN d.disk WHEN 'memory' THEN d.memory ELSE d.compress END
           FROM daily_usage d WHERE d.install_id = NEW.install_id AND d.day = NEW.day))),
    counted_files = CASE WHEN NEW.kind = 'compress' THEN MIN(NEW.files, MAX(0,
      100000 - (SELECT d.files FROM daily_usage d WHERE d.install_id = NEW.install_id AND d.day = NEW.day)))
      ELSE 0 END,
    counted_items = CASE WHEN NEW.kind = 'disk' THEN MIN(NEW.items, MAX(0,
      50000 - (SELECT d.items FROM daily_usage d WHERE d.install_id = NEW.install_id AND d.day = NEW.day)))
      ELSE 0 END
   WHERE install_id = NEW.install_id AND event_id = NEW.event_id AND reversed = 0;

  UPDATE daily_usage SET
    disk     = disk     + (CASE NEW.kind WHEN 'disk'     THEN (SELECT counted_bytes FROM events WHERE install_id = NEW.install_id AND event_id = NEW.event_id) ELSE 0 END),
    memory   = memory   + (CASE NEW.kind WHEN 'memory'   THEN (SELECT counted_bytes FROM events WHERE install_id = NEW.install_id AND event_id = NEW.event_id) ELSE 0 END),
    compress = compress + (CASE NEW.kind WHEN 'compress' THEN (SELECT counted_bytes FROM events WHERE install_id = NEW.install_id AND event_id = NEW.event_id) ELSE 0 END),
    files    = files    + (SELECT counted_files FROM events WHERE install_id = NEW.install_id AND event_id = NEW.event_id),
    items    = items    + (SELECT counted_items FROM events WHERE install_id = NEW.install_id AND event_id = NEW.event_id)
   WHERE install_id = NEW.install_id AND day = NEW.day;

  -- A matured install's event goes public right away, clipped to what's left of today's ceiling. An
  -- immature install's event stays at public_* = 0 until maturity picks it up.
  UPDATE events SET
    public_bytes = MIN(counted_bytes, MAX(0,
      COALESCE((SELECT c.value FROM public_ceilings c WHERE c.metric = NEW.kind), 0)
      - (SELECT g.value FROM public_growth g WHERE g.day = NEW.day AND g.metric = NEW.kind))),
    public_files = MIN(counted_files, MAX(0,
      COALESCE((SELECT c.value FROM public_ceilings c WHERE c.metric = 'files'), 0)
      - (SELECT g.value FROM public_growth g WHERE g.day = NEW.day AND g.metric = 'files'))),
    public_items = MIN(counted_items, MAX(0,
      COALESCE((SELECT c.value FROM public_ceilings c WHERE c.metric = 'items'), 0)
      - (SELECT g.value FROM public_growth g WHERE g.day = NEW.day AND g.metric = 'items')))
   WHERE install_id = NEW.install_id AND event_id = NEW.event_id AND reversed = 0
     AND EXISTS (SELECT 1 FROM installs i WHERE i.install_id = NEW.install_id AND i.matured = 1);

  UPDATE totals SET value = value + (
      SELECT CASE totals.metric WHEN 'files' THEN e.public_files WHEN 'items' THEN e.public_items ELSE e.public_bytes END
        FROM events e WHERE e.install_id = NEW.install_id AND e.event_id = NEW.event_id)
   WHERE metric IN (NEW.kind, 'files', 'items')
     AND (SELECT CASE totals.metric WHEN 'files' THEN e.public_files WHEN 'items' THEN e.public_items ELSE e.public_bytes END
            FROM events e WHERE e.install_id = NEW.install_id AND e.event_id = NEW.event_id) > 0;

  UPDATE public_growth SET value = value + (
      SELECT CASE public_growth.metric WHEN 'files' THEN e.public_files WHEN 'items' THEN e.public_items ELSE e.public_bytes END
        FROM events e WHERE e.install_id = NEW.install_id AND e.event_id = NEW.event_id)
   WHERE day = NEW.day AND metric IN (NEW.kind, 'files', 'items')
     AND (SELECT CASE public_growth.metric WHEN 'files' THEN e.public_files WHEN 'items' THEN e.public_items ELSE e.public_bytes END
            FROM events e WHERE e.install_id = NEW.install_id AND e.event_id = NEW.event_id) > 0;
END;

-- Undo / restore. Takes back exactly what the original put into the totals (public_*), once. An event
-- reversed before its install matured never went public, and maturity skips it. Neither the per-install
-- cap nor the global ceiling is given back (no farming).
CREATE TRIGGER events_reverse AFTER INSERT ON events
WHEN NEW.kind = 'reversal'
BEGIN
  UPDATE totals SET value = value - (
      SELECT CASE totals.metric WHEN 'files' THEN o.public_files WHEN 'items' THEN o.public_items ELSE o.public_bytes END
        FROM events o
       WHERE o.install_id = NEW.install_id AND o.event_id = NEW.reverses AND o.kind <> 'reversal' AND o.reversed = 0)
   WHERE metric IN ('files', 'items', (SELECT o.kind FROM events o
                                        WHERE o.install_id = NEW.install_id AND o.event_id = NEW.reverses
                                          AND o.kind <> 'reversal' AND o.reversed = 0))
     AND (SELECT CASE totals.metric WHEN 'files' THEN o.public_files WHEN 'items' THEN o.public_items ELSE o.public_bytes END
            FROM events o
           WHERE o.install_id = NEW.install_id AND o.event_id = NEW.reverses AND o.kind <> 'reversal' AND o.reversed = 0) > 0;

  -- Keep a record of what this reversal took back.
  UPDATE events SET
    counted_bytes = COALESCE(o.counted_bytes, 0), counted_files = COALESCE(o.counted_files, 0), counted_items = COALESCE(o.counted_items, 0),
    public_bytes  = COALESCE(o.public_bytes, 0),  public_files  = COALESCE(o.public_files, 0),  public_items  = COALESCE(o.public_items, 0)
    FROM (SELECT counted_bytes, counted_files, counted_items, public_bytes, public_files, public_items FROM events
           WHERE install_id = NEW.install_id AND event_id = NEW.reverses AND kind <> 'reversal' AND reversed = 0) AS o
   WHERE events.install_id = NEW.install_id AND events.event_id = NEW.event_id;

  UPDATE events SET reversed = 1
   WHERE install_id = NEW.install_id AND event_id = NEW.reverses
     AND kind <> 'reversal' AND reversed = 0;
END;
