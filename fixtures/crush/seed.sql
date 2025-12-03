CREATE TABLE sessions (
    id TEXT PRIMARY KEY,
    updated_at INTEGER,
    prompt_tokens INTEGER,
    completion_tokens INTEGER
);

CREATE TABLE messages (
    id TEXT PRIMARY KEY,
    session_id TEXT,
    model TEXT
);

-- 2024-01-01T12:00:00Z is 1704110400
INSERT INTO sessions (id, updated_at, prompt_tokens, completion_tokens) VALUES ('session-1', 1704110400, 100, 50);
INSERT INTO messages (id, session_id, model) VALUES ('msg-1', 'session-1', 'gpt-4');

-- 2024-01-02T15:30:00Z is 1704209400
-- Adding non-zero tokens so it is picked up by the query
INSERT INTO sessions (id, updated_at, prompt_tokens, completion_tokens) VALUES ('session-2', 1704209400, 10, 20);
INSERT INTO messages (id, session_id, model) VALUES ('msg-2', 'session-2', 'gpt-3.5-turbo');
