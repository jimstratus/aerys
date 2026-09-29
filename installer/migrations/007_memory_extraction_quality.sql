\c aerys

-- Migration 007: Memory Extraction Quality Overhaul
-- Adds context, event_date, and key_label columns to memories table
-- Backfills key_label from existing content format (key: value)
-- Creates dedup index for write-time duplicate detection

ALTER TABLE memories
  ADD COLUMN IF NOT EXISTS context    TEXT,
  ADD COLUMN IF NOT EXISTS event_date TEXT,
  ADD COLUMN IF NOT EXISTS key_label  TEXT;

-- Backfill key_label from existing content (format is "key_label: value_text")
UPDATE memories
SET key_label = TRIM(SPLIT_PART(content, ':', 1))
WHERE key_label IS NULL
  AND content LIKE '%:%';

-- Index for dedup lookups: person_id + key_label, excluding soft-deleted
CREATE INDEX IF NOT EXISTS idx_memories_dedup
  ON memories (person_id, key_label)
  WHERE deleted_at IS NULL AND key_label IS NOT NULL;
