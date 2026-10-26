CREATE TABLE forward_screens (
 parent_sid TEXT PRIMARY KEY,
 child_sid TEXT,
 target TEXT NOT NULL,
 state TEXT NOT NULL DEFAULT 'pending',
 wait_seconds INTEGER NOT NULL,
 service_language TEXT NOT NULL DEFAULT 'en',
 expires INTEGER NOT NULL,
 updated INTEGER NOT NULL,
 finished INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX forward_screens_updated ON forward_screens(updated);
