-- Core Aerys schema: Phase 1 minimal tables
-- Run in /aerys database context after 000_extensions.sql

\c aerys

-- Persons: rich profiles for cross-channel identity
CREATE TABLE persons (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    display_name        TEXT NOT NULL,
    discord_id          TEXT UNIQUE,
    telegram_id         TEXT UNIQUE,
    email               TEXT UNIQUE,
    timezone            TEXT,
    preferences         JSONB DEFAULT '{}',
    relationship_notes  TEXT,
    interaction_notes   TEXT,
    important_dates     JSONB DEFAULT '{}',
    custom_fields       JSONB DEFAULT '{}',
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW(),
    deleted_at          TIMESTAMPTZ
);

-- Conversations: thread/session grouping per channel
CREATE TABLE conversations (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    person_id         UUID REFERENCES persons(id) ON DELETE SET NULL,
    channel           TEXT NOT NULL,
    channel_thread_id TEXT,
    summary           TEXT,
    started_at        TIMESTAMPTZ DEFAULT NOW(),
    last_message_at   TIMESTAMPTZ DEFAULT NOW(),
    ended_at          TIMESTAMPTZ,
    deleted_at        TIMESTAMPTZ
);

-- Messages: individual message rows (granular, searchable)
CREATE TABLE messages (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    person_id       UUID REFERENCES persons(id) ON DELETE SET NULL,
    channel         TEXT NOT NULL,
    role            TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
    content         TEXT NOT NULL,
    content_type    TEXT DEFAULT 'text',
    raw_metadata    JSONB DEFAULT '{}',
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ
);

-- Memories: long-term with embeddings + tags for hybrid retrieval
CREATE TABLE memories (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    person_id         UUID REFERENCES persons(id) ON DELETE SET NULL,
    source_message_id UUID REFERENCES messages(id) ON DELETE SET NULL,
    content           TEXT NOT NULL,
    summary           TEXT,
    category          TEXT[],
    embedding         vector(1536),
    channel           TEXT,
    created_at        TIMESTAMPTZ DEFAULT NOW(),
    updated_at        TIMESTAMPTZ DEFAULT NOW(),
    deleted_at        TIMESTAMPTZ
);

-- Indexes: persons platform IDs (partial, only non-null)
CREATE INDEX idx_persons_discord  ON persons (discord_id)  WHERE discord_id  IS NOT NULL;
CREATE INDEX idx_persons_telegram ON persons (telegram_id) WHERE telegram_id IS NOT NULL;
CREATE INDEX idx_persons_email    ON persons (email)        WHERE email        IS NOT NULL;

-- Indexes: conversations
CREATE INDEX idx_conversations_person  ON conversations (person_id);
CREATE INDEX idx_conversations_channel ON conversations (channel);

-- Indexes: messages
CREATE INDEX idx_messages_conversation ON messages (conversation_id);
CREATE INDEX idx_messages_person       ON messages (person_id);
CREATE INDEX idx_messages_channel      ON messages (channel);
CREATE INDEX idx_messages_created      ON messages (created_at DESC);

-- Indexes: memories
CREATE INDEX idx_memories_person    ON memories (person_id);
CREATE INDEX idx_memories_category  ON memories USING GIN (category);
CREATE INDEX idx_memories_active    ON memories (deleted_at) WHERE deleted_at IS NULL;

-- HNSW index for vector similarity search (cosine distance, standard for text embeddings)
CREATE INDEX idx_memories_embedding ON memories USING hnsw (embedding vector_cosine_ops);
