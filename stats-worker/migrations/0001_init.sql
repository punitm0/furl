-- Furl community totals.
--
-- What is stored, and nothing more: a random install UUID (made by the app, not tied to hardware or
-- the user), the app version, the event kind and category, byte/file counts and a coarse UTC day
-- assigned by the server. No paths, file names, usernames, hostnames or IP addresses.
--
-- All counting happens in the triggers below, so a single INSERT OR IGNORE per event is the whole
-- write path. A retried event hits the (install_id, event_id) primary key, is ignored, and its
-- trigger never fires: retries can never double count.

-- One row per event an install reported.
CREATE TABLE events (
  install_id    TEXT    NOT NULL,
  event_id      TEXT    NOT NULL,
  day           TEXT    NOT NULL,                      -- server UTC day, YYYY-MM-DD
  app_version   TEXT    NOT NULL,
  kind          TEXT    NOT NULL CHECK (kind IN ('disk', 'memory', 'compress', 'reversal')),
  category      TEXT    NOT NULL,
  bytes         INTEGER NOT NULL DEFAULT 0 CHECK (bytes >= 0),
  files         INTEGER NOT NULL DEFAULT 0 CHECK (files >= 0),
  reverses      TEXT,                                  -- reversal events: the event_id they undo
  counted_bytes INTEGER NOT NULL DEFAULT 0,            -- what actually went into totals (after the daily cap)
  counted_files INTEGER NOT NULL DEFAULT 0,
  reversed      INTEGER NOT NULL DEFAULT 0,            -- 1 once a reversal has taken this event back out
  PRIMARY KEY (install_id, event_id)
) WITHOUT ROWID;

CREATE INDEX events_by_reverses ON events (install_id, reverses) WHERE reverses IS NOT NULL;

-- Per-install, per-day running sums, used only for the outlier cap.
CREATE TABLE daily_usage (
  install_id TEXT    NOT NULL,
  day        TEXT    NOT NULL,
  disk       INTEGER NOT NULL DEFAULT 0,
  memory     INTEGER NOT NULL DEFAULT 0,
  compress   INTEGER NOT NULL DEFAULT 0,
  files      INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (install_id, day)
) WITHOUT ROWID;

-- Distinct installs that ever reported a counted event (for the bucketed install count).
CREATE TABLE installs (
  install_id TEXT NOT NULL PRIMARY KEY,
  first_day  TEXT NOT NULL
) WITHOUT ROWID;

-- The only table GET /v1/totals reads.
CREATE TABLE totals (
  metric TEXT    NOT NULL PRIMARY KEY,
  value  INTEGER NOT NULL DEFAULT 0
) WITHOUT ROWID;

INSERT INTO totals (metric, value) VALUES
  ('disk', 0),      -- bytes removed from disk by cleanups
  ('compress', 0),  -- bytes saved by Compress / Shrink (after minus before)
  ('memory', 0),    -- bytes of memory freed by stopping processes (never added to disk)
  ('files', 0),     -- files compressed or shrunk
  ('installs', 0);

-- Counting. Daily caps per install (outlier protection, on top of the per-event ceilings the
-- Worker enforces): disk 4 TiB, compress 4 TiB, memory 1 TiB, files 1,000,000. Anything over the
-- cap that day is stored but contributes nothing. Keep these in sync with src/limits.ts.
CREATE TRIGGER events_count AFTER INSERT ON events
WHEN NEW.kind IN ('disk', 'memory', 'compress')
BEGIN
  UPDATE totals SET value = value + 1
   WHERE metric = 'installs'
     AND NOT EXISTS (SELECT 1 FROM installs WHERE install_id = NEW.install_id);
  INSERT OR IGNORE INTO installs (install_id, first_day) VALUES (NEW.install_id, NEW.day);
  INSERT OR IGNORE INTO daily_usage (install_id, day) VALUES (NEW.install_id, NEW.day);

  -- A reversal for this event arrived first (out-of-order delivery): it cancels the event outright.
  UPDATE events SET reversed = 1
   WHERE install_id = NEW.install_id AND event_id = NEW.event_id
     AND EXISTS (SELECT 1 FROM events r
                  WHERE r.install_id = NEW.install_id AND r.reverses = NEW.event_id AND r.kind = 'reversal');

  UPDATE events SET
    counted_bytes = MIN(NEW.bytes, MAX(0,
      (CASE NEW.kind WHEN 'memory' THEN 1099511627776 ELSE 4398046511104 END)
      - (SELECT CASE NEW.kind WHEN 'disk' THEN d.disk WHEN 'memory' THEN d.memory ELSE d.compress END
           FROM daily_usage d WHERE d.install_id = NEW.install_id AND d.day = NEW.day))),
    counted_files = MIN(NEW.files, MAX(0,
      1000000 - (SELECT d.files FROM daily_usage d WHERE d.install_id = NEW.install_id AND d.day = NEW.day)))
   WHERE install_id = NEW.install_id AND event_id = NEW.event_id AND reversed = 0;

  UPDATE daily_usage SET
    disk     = disk     + (CASE NEW.kind WHEN 'disk'     THEN (SELECT counted_bytes FROM events WHERE install_id = NEW.install_id AND event_id = NEW.event_id) ELSE 0 END),
    memory   = memory   + (CASE NEW.kind WHEN 'memory'   THEN (SELECT counted_bytes FROM events WHERE install_id = NEW.install_id AND event_id = NEW.event_id) ELSE 0 END),
    compress = compress + (CASE NEW.kind WHEN 'compress' THEN (SELECT counted_bytes FROM events WHERE install_id = NEW.install_id AND event_id = NEW.event_id) ELSE 0 END),
    files    = files    + (SELECT counted_files FROM events WHERE install_id = NEW.install_id AND event_id = NEW.event_id)
   WHERE install_id = NEW.install_id AND day = NEW.day;

  UPDATE totals SET value = value + (SELECT counted_bytes FROM events WHERE install_id = NEW.install_id AND event_id = NEW.event_id)
   WHERE metric = NEW.kind;
  UPDATE totals SET value = value + (SELECT counted_files FROM events WHERE install_id = NEW.install_id AND event_id = NEW.event_id)
   WHERE metric = 'files';
END;

-- Undo / restore. Subtracts exactly what the original contributed, only if the original was
-- counted and has not been reversed already. A reversal can't target another reversal or an
-- event from a different install. The daily cap allowance is not given back (no farming).
CREATE TRIGGER events_reverse AFTER INSERT ON events
WHEN NEW.kind = 'reversal'
BEGIN
  UPDATE totals SET value = value - (SELECT o.counted_bytes FROM events o
                                      WHERE o.install_id = NEW.install_id AND o.event_id = NEW.reverses
                                        AND o.kind <> 'reversal' AND o.reversed = 0)
   WHERE metric = (SELECT o.kind FROM events o
                    WHERE o.install_id = NEW.install_id AND o.event_id = NEW.reverses
                      AND o.kind <> 'reversal' AND o.reversed = 0);

  UPDATE totals SET value = value - (SELECT o.counted_files FROM events o
                                      WHERE o.install_id = NEW.install_id AND o.event_id = NEW.reverses
                                        AND o.kind <> 'reversal' AND o.reversed = 0)
   WHERE metric = 'files'
     AND EXISTS (SELECT 1 FROM events o
                  WHERE o.install_id = NEW.install_id AND o.event_id = NEW.reverses
                    AND o.kind <> 'reversal' AND o.reversed = 0);

  -- Keep a record of what this reversal took back.
  UPDATE events SET
    counted_bytes = COALESCE((SELECT o.counted_bytes FROM events o
                               WHERE o.install_id = NEW.install_id AND o.event_id = NEW.reverses
                                 AND o.kind <> 'reversal' AND o.reversed = 0), 0),
    counted_files = COALESCE((SELECT o.counted_files FROM events o
                               WHERE o.install_id = NEW.install_id AND o.event_id = NEW.reverses
                                 AND o.kind <> 'reversal' AND o.reversed = 0), 0)
   WHERE install_id = NEW.install_id AND event_id = NEW.event_id;

  UPDATE events SET reversed = 1
   WHERE install_id = NEW.install_id AND event_id = NEW.reverses
     AND kind <> 'reversal' AND reversed = 0;
END;
