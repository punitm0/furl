-- Adds item counts and per-install environment to report format v1 (changed before any release).
--
-- 1. Cleanup item counts: disk events may carry `items` (things removed: a cache folder, an app, a
--    worktree each count as one). They go into their own `items` metric with their own daily cap, never
--    into `files`, which stays "files compressed" only.
-- 2. install_env: the latest macOS major version, CPU architecture and Full Disk Access state each
--    install reported. One row per install, overwritten on each report; no history is kept.
--
-- Both counting triggers are dropped and recreated (rather than adding new ones next to them) because
-- SQLite doesn't guarantee the order triggers on the same event run in, and these read each other's
-- writes (counted_*, reversed). Keep the caps in sync with src/limits.ts.

ALTER TABLE events ADD COLUMN items INTEGER NOT NULL DEFAULT 0 CHECK (items >= 0);
ALTER TABLE events ADD COLUMN counted_items INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_usage ADD COLUMN items INTEGER NOT NULL DEFAULT 0;

INSERT OR IGNORE INTO totals (metric, value) VALUES ('items', 0);  -- items removed by cleanups

CREATE TABLE install_env (
  install_id TEXT    NOT NULL PRIMARY KEY,
  os_major   INTEGER NOT NULL CHECK (os_major BETWEEN 14 AND 99),
  arch       TEXT    NOT NULL CHECK (arch IN ('arm64', 'x86_64')),
  fda        INTEGER NOT NULL CHECK (fda IN (0, 1)),
  day        TEXT    NOT NULL                                     -- server UTC day of the latest report
) WITHOUT ROWID;

DROP TRIGGER events_count;
DROP TRIGGER events_reverse;

-- Daily caps per install: disk 4 TiB, compress 4 TiB, memory 1 TiB, files 1,000,000 (compress only),
-- items 1,000,000 (disk only). Anything over the cap that day is stored but contributes nothing.
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
    counted_files = CASE WHEN NEW.kind = 'compress' THEN MIN(NEW.files, MAX(0,
      1000000 - (SELECT d.files FROM daily_usage d WHERE d.install_id = NEW.install_id AND d.day = NEW.day)))
      ELSE 0 END,
    counted_items = CASE WHEN NEW.kind = 'disk' THEN MIN(NEW.items, MAX(0,
      1000000 - (SELECT d.items FROM daily_usage d WHERE d.install_id = NEW.install_id AND d.day = NEW.day)))
      ELSE 0 END
   WHERE install_id = NEW.install_id AND event_id = NEW.event_id AND reversed = 0;

  UPDATE daily_usage SET
    disk     = disk     + (CASE NEW.kind WHEN 'disk'     THEN (SELECT counted_bytes FROM events WHERE install_id = NEW.install_id AND event_id = NEW.event_id) ELSE 0 END),
    memory   = memory   + (CASE NEW.kind WHEN 'memory'   THEN (SELECT counted_bytes FROM events WHERE install_id = NEW.install_id AND event_id = NEW.event_id) ELSE 0 END),
    compress = compress + (CASE NEW.kind WHEN 'compress' THEN (SELECT counted_bytes FROM events WHERE install_id = NEW.install_id AND event_id = NEW.event_id) ELSE 0 END),
    files    = files    + (SELECT counted_files FROM events WHERE install_id = NEW.install_id AND event_id = NEW.event_id),
    items    = items    + (SELECT counted_items FROM events WHERE install_id = NEW.install_id AND event_id = NEW.event_id)
   WHERE install_id = NEW.install_id AND day = NEW.day;

  UPDATE totals SET value = value + (SELECT counted_bytes FROM events WHERE install_id = NEW.install_id AND event_id = NEW.event_id)
   WHERE metric = NEW.kind;
  UPDATE totals SET value = value + (SELECT counted_files FROM events WHERE install_id = NEW.install_id AND event_id = NEW.event_id)
   WHERE metric = 'files';
  UPDATE totals SET value = value + (SELECT counted_items FROM events WHERE install_id = NEW.install_id AND event_id = NEW.event_id)
   WHERE metric = 'items';
END;

-- Undo / restore. Subtracts exactly what the original contributed (bytes, files and items), only if the
-- original was counted and has not been reversed already. A reversal can't target another reversal or an
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

  UPDATE totals SET value = value - (SELECT o.counted_items FROM events o
                                      WHERE o.install_id = NEW.install_id AND o.event_id = NEW.reverses
                                        AND o.kind <> 'reversal' AND o.reversed = 0)
   WHERE metric = 'items'
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
                                 AND o.kind <> 'reversal' AND o.reversed = 0), 0),
    counted_items = COALESCE((SELECT o.counted_items FROM events o
                               WHERE o.install_id = NEW.install_id AND o.event_id = NEW.reverses
                                 AND o.kind <> 'reversal' AND o.reversed = 0), 0)
   WHERE install_id = NEW.install_id AND event_id = NEW.event_id;

  UPDATE events SET reversed = 1
   WHERE install_id = NEW.install_id AND event_id = NEW.reverses
     AND kind <> 'reversal' AND reversed = 0;
END;
