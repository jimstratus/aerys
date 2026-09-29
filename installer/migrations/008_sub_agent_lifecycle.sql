\c aerys

-- Migration 008: Sub-agent lifecycle state + dependency declarations
-- Source: p6-sub-agent-lifecycle-state.md + p6-sub-agent-dependency-declarations.md
-- Purpose: Add state column (ready/failed/disabled) for health-aware tool routing
--          Add dependencies JSONB column for service dependency declarations

ALTER TABLE sub_agents ADD COLUMN IF NOT EXISTS state TEXT NOT NULL DEFAULT 'ready';
ALTER TABLE sub_agents ADD COLUMN IF NOT EXISTS dependencies JSONB DEFAULT '[]';

-- Add check constraint (idempotent via DO block)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'sub_agents_state_check'
  ) THEN
    ALTER TABLE sub_agents ADD CONSTRAINT sub_agents_state_check
      CHECK (state IN ('ready', 'failed', 'disabled'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_sub_agents_state ON sub_agents(state);

-- NOTE: The live migration 008 on the original Aerys instance populated
-- `sub_agents.dependencies` with JSONB arrays referencing the original
-- deploy's real n8n credential IDs (e.g. "1UB6LFvh3qKCfdbJ"). Those IDs
-- are meaningless on any other n8n instance (every deploy gets its own
-- credential IDs).
--
-- For the installer, dependencies default to `'[]'` (set by the ALTER
-- TABLE above). The workflow import engine (Task 5) creates n8n
-- credentials during install and could populate this column with the
-- real IDs post-import — that's a followup (see CRUISE-LOG). Leaving
-- empty for now is correct: `dependencies` is a V2-facing column for
-- health-aware routing, not required by any current Phase 5/6 workflow.
