CREATE TABLE IF NOT EXISTS repositories (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  url TEXT NOT NULL,
  default_branch TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS branches (
  id BIGSERIAL PRIMARY KEY,
  repository_id BIGINT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  head_sha TEXT,
  is_stale BOOLEAN NOT NULL DEFAULT false,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(repository_id, name)
);

CREATE TABLE IF NOT EXISTS commits (
  id BIGSERIAL PRIMARY KEY,
  repository_id BIGINT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
  sha TEXT NOT NULL,
  message TEXT NOT NULL,
  author_name TEXT NOT NULL,
  author_email TEXT NOT NULL,
  author_time TIMESTAMPTZ NOT NULL,
  committer_name TEXT NOT NULL,
  committer_email TEXT NOT NULL,
  committer_time TIMESTAMPTZ NOT NULL,
  indexed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(repository_id, sha)
);

CREATE TABLE IF NOT EXISTS commit_parents (
  repository_id BIGINT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
  commit_sha TEXT NOT NULL,
  parent_sha TEXT NOT NULL,
  PRIMARY KEY(repository_id, commit_sha, parent_sha)
);

CREATE TABLE IF NOT EXISTS branch_commits (
  repository_id BIGINT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
  branch_name TEXT NOT NULL,
  commit_sha TEXT NOT NULL,
  PRIMARY KEY(repository_id, branch_name, commit_sha)
);

CREATE TABLE IF NOT EXISTS file_revisions (
  id BIGSERIAL PRIMARY KEY,
  repository_id BIGINT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
  commit_sha TEXT NOT NULL,
  path TEXT NOT NULL,
  language TEXT,
  content_hash TEXT NOT NULL,
  size_bytes BIGINT NOT NULL,
  status TEXT NOT NULL,
  error TEXT,
  content TEXT,
  indexed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(repository_id, commit_sha, path)
);

CREATE TABLE IF NOT EXISTS parse_results (
  id BIGSERIAL PRIMARY KEY,
  content_hash TEXT NOT NULL,
  language TEXT NOT NULL,
  parser_name TEXT NOT NULL,
  parser_version TEXT NOT NULL,
  status TEXT NOT NULL,
  error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(content_hash, language, parser_name, parser_version)
);

CREATE TABLE IF NOT EXISTS symbols (
  id BIGSERIAL PRIMARY KEY,
  parse_result_id BIGINT NOT NULL REFERENCES parse_results(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  kind TEXT NOT NULL,
  container TEXT,
  start_line INT NOT NULL,
  start_column INT NOT NULL,
  end_line INT NOT NULL,
  end_column INT NOT NULL,
  snippet TEXT
);

CREATE TABLE IF NOT EXISTS symbol_occurrences (
  id BIGSERIAL PRIMARY KEY,
  repository_id BIGINT NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
  commit_sha TEXT NOT NULL,
  file_revision_id BIGINT NOT NULL REFERENCES file_revisions(id) ON DELETE CASCADE,
  symbol_id BIGINT NOT NULL REFERENCES symbols(id) ON DELETE CASCADE,
  role TEXT NOT NULL,
  name TEXT NOT NULL,
  kind TEXT NOT NULL,
  container TEXT,
  start_line INT NOT NULL,
  start_column INT NOT NULL,
  end_line INT NOT NULL,
  end_column INT NOT NULL,
  snippet TEXT
);

CREATE TABLE IF NOT EXISTS indexing_jobs (
  id BIGSERIAL PRIMARY KEY,
  repository_id BIGINT REFERENCES repositories(id) ON DELETE SET NULL,
  status TEXT NOT NULL,
  message TEXT,
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_branches_repository ON branches(repository_id);
CREATE INDEX IF NOT EXISTS idx_commits_repository_time ON commits(repository_id, committer_time DESC);
CREATE INDEX IF NOT EXISTS idx_files_lookup ON file_revisions(repository_id, commit_sha, path);
CREATE INDEX IF NOT EXISTS idx_files_hash ON file_revisions(content_hash);
CREATE INDEX IF NOT EXISTS idx_parse_results_hash ON parse_results(content_hash, language, parser_name, parser_version);
CREATE INDEX IF NOT EXISTS idx_symbols_name ON symbols(name);
CREATE INDEX IF NOT EXISTS idx_symbols_kind ON symbols(kind);
CREATE INDEX IF NOT EXISTS idx_occurrences_lookup ON symbol_occurrences(repository_id, commit_sha, name);
CREATE INDEX IF NOT EXISTS idx_occurrences_file ON symbol_occurrences(file_revision_id);

