ALTER TABLE jobs ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0;
ALTER TABLE events ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0;
CREATE INDEX visible_jobs ON jobs(hidden,created);
CREATE INDEX visible_events ON events(kind,hidden,created);
