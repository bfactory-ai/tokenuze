CREATE TABLE threads (
    id TEXT PRIMARY KEY,
    updated_at TEXT,
    data_type TEXT,
    data BLOB
);

INSERT INTO threads (id, updated_at, data_type, data) VALUES 
('thread-1', '2024-01-01T12:00:00Z', 'json', '{"model":"claude-3-opus","request_token_usage":{"req-1":{"input_tokens":100,"output_tokens":50}}}');
