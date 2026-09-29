\c aerys

-- Migration 005: Fix core_claim visibility default
-- Guardian-promoted personal facts should be visible in all contexts (DM + server),
-- not just server. The schema default of 'server' was too restrictive.
-- Guardian upsert now explicitly sets visibility = 'all', but existing rows need fixing.

UPDATE core_claim
SET visibility = 'all'
WHERE visibility = 'server'
  AND NOT locked;

-- Also update the column default so any future manual inserts are less surprising
ALTER TABLE core_claim ALTER COLUMN visibility SET DEFAULT 'all';
