CREATE TABLE recordings (sid TEXT PRIMARY KEY, value TEXT NOT NULL, status TEXT NOT NULL, updated INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, lease TEXT);
CREATE INDEX recording_work ON recordings(status,updated);
