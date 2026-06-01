# Source Code Explorer Requirements

## 1. Purpose

Source Code Explorer indexes Git repositories into PostgreSQL and exposes the indexed source graph through an HTTP API, an MCP server, and a React frontend.

The system should make it easy to answer questions such as:

- Which files define or reference a function, method, class, interface, type, or exported symbol?
- Where is a symbol introduced, changed, or removed across commits?
- Which branches and commits contain a specific source element?
- How can an external AI/MCP client inspect repository structure and source relationships without reading the entire repository directly?

## 2. Scope

### In Scope

- Index one or more configured Git repositories.
- Track repository metadata, branches, commits, files, and parsed language symbols.
- Parse source code for C#, JavaScript, and TypeScript.
- Store enough structural information to support symbol search, definition lookup, reference lookup, and file-level navigation.
- Expose indexed data through:
  - HTTP API
  - MCP tools/resources
  - React frontend
- Run PostgreSQL, server, and indexer as separate Docker Compose services.
- Support future language parsers without redesigning the database or indexing pipeline.

### Out of Scope for Initial Version

- Full semantic type checking across entire projects.
- IDE-grade refactoring.
- Multi-tenant authorization and user management.
- Hosted SaaS deployment.
- Real-time indexing of every filesystem change.

## 3. System Components

### 3.1 PostgreSQL Database

PostgreSQL stores all indexed repository data.

Required data categories:

- Repositories
- Branches
- Commits
- Parent commit relationships
- Files and file revisions
- Parsed symbols
- Symbol definitions
- Symbol references/usages
- Language parser metadata
- Indexing jobs, status, logs, and errors

The schema should preserve commit history and allow queries by repository, branch, commit, file path, language, symbol kind, and symbol name.

### 3.2 Server

The server is implemented in Haskell.

Responsibilities:

- Provide an HTTP API for the frontend and external clients.
- Provide MCP tools and resources for AI clients from the same Haskell server process as the HTTP API.
- Enforce the same configured access token for HTTP API and MCP requests.
- Read from PostgreSQL.
- Expose index status and errors.
- Validate requests and return structured errors.
- Keep business/query logic separate from transport-specific HTTP and MCP code.

### 3.3 Frontend

The frontend is implemented in React.

Responsibilities:

- Browse configured repositories, branches, commits, and files.
- Search for symbols by name, kind, language, repository, branch, and path.
- Show symbol definitions and references.
- Show index status, last indexed commit, and indexing errors.
- Provide a practical source exploration workflow rather than only a status dashboard.

### 3.4 Indexer

The indexer is implemented in Haskell.

Responsibilities:

- Clone or fetch configured Git repositories.
- Discover configured branches.
- Walk commits and file trees.
- Detect changed files per commit where possible.
- Hash file contents before parsing so identical content can reuse previous parse results.
- Parse supported source files.
- Persist commit, file, and symbol data into PostgreSQL.
- Record failed parse/index operations without aborting the entire repository index.
- Support resumable indexing after interruption.
- Support continuous operation that periodically fetches configured repositories and indexes newly discovered commits.

The indexer should be able to run forever as a long-lived service. It should pull or fetch target repositories on a configurable interval, such as every 5 minutes, and incrementally index whatever changed since the previous run. A repeatable batch mode may also be provided for local development, maintenance tasks, and CI fixtures.

## 4. Indexing Requirements

### 4.1 Repository Configuration

The system must allow configuration of repositories to index.

Each repository configuration should include:

- Repository name or identifier
- Git remote URL or local path
- Default branch
- Included branches
- Excluded branches
- Optional include path patterns
- Optional exclude path patterns
- Polling interval, for example 5 minutes
- Optional manual trigger setting

Configuration must be loaded from YAML files for the first version. Environment variables may be used for deployment-specific overrides such as the config file path, but repository configuration should live in YAML.

For the first version, repository configuration is file-based YAML. Editing repository configuration through the frontend is not required initially.

### 4.2 Git Data

The indexer must store:

- Commit SHA
- Commit message
- Author name and email
- Author timestamp
- Committer name and email
- Commit timestamp
- Parent commit SHAs
- Branch membership
- File paths present at indexed commits
- File content hash or equivalent deduplication key

### 4.3 File Data

For each indexed file revision, the system must store:

- Repository
- Commit
- Path
- Language, when detected
- Content hash used to identify identical file contents across commits, branches, and repositories
- File size
- Whether the file was parsed, skipped, or failed
- Parse/index error details when applicable

The system should skip binary files and files excluded by configuration.

### 4.4 Language Parsing

The initial supported languages are:

- C#
- JavaScript
- TypeScript

For each supported language, the parser should extract:

- Symbol name
- Symbol kind, such as function, method, class, interface, enum, type alias, variable, constant, module, or export
- Definition location: file path, start line, start column, end line, end column
- Reference or usage locations where practical
- Parent/container symbol where available
- Import/export relationships where available

Parser implementations must be isolated behind a language parser interface so that additional languages can be added later.

Recommended parser approach:

- Prefer Tree-sitter or another structured parser over ad hoc regular expressions.
- Store parser version or parser metadata so indexed output can be invalidated or rebuilt after parser changes.

### 4.5 Hash-Based Parse Reuse

The indexer must use deterministic hashing to avoid reparsing source content that has already been parsed.

Required behavior:

- Compute a stable content hash before invoking a language parser.
- Store parse results keyed by content hash, language, parser name, and parser version.
- Reuse existing parse results when the same content hash has already been parsed with the same parser version.
- Reparse content when the parser implementation or parser version changes.
- Allow identical file contents to share parse results across commits, branches, and repositories.
- Preserve file-specific locations and repository/commit relationships when reused parse results are attached to a new file revision.

### 4.6 Incremental and Resumable Indexing

The indexer should avoid reprocessing unchanged file content when possible.

Required behavior:

- Resume after process interruption.
- Track indexing job state.
- Periodically fetch configured repositories while running as a long-lived service.
- Use a configurable polling interval per repository or globally, with a practical default such as 5 minutes.
- Detect new commits, moved branches, and removed branches after each fetch.
- Re-index changed files when a repository updates.
- Reuse hash-based parse results for unchanged or previously seen file contents.
- Mark stale data when branches move or commits are no longer reachable from configured branches.
- Record per-repository and per-branch progress.

## 5. Query Requirements

The system must support queries for:

- Repositories
- Branches for a repository
- Commits for a branch
- Files at a commit or branch head
- File content or source snippets
- Symbols by exact name
- Symbols by partial or fuzzy name
- Symbols by kind
- Symbols by language
- Symbol definitions
- Symbol references/usages
- Symbols within a file
- Files that reference a symbol
- Indexing status and errors

Search results should include enough context for navigation:

- Repository
- Branch or commit
- File path
- Symbol kind
- Symbol name
- Line and column range
- Short surrounding source snippet when available

## 6. MCP Requirements

The MCP server should expose source exploration capabilities to MCP clients.

MCP requests must use the same configured access token as the HTTP API.

Initial MCP capabilities should include:

- List repositories
- List branches
- List files
- Read file or file snippet
- Search symbols
- Get symbol definition
- Find symbol references
- Get indexing status

MCP responses should be concise by default and support pagination or result limits to avoid returning excessive source content.

## 7. HTTP API Requirements

The HTTP API should expose the same core capabilities used by the frontend and MCP layer.

Required API characteristics:

- JSON request and response bodies
- Stable error response format
- Bearer-token authentication using the configured access token
- Pagination for list/search endpoints
- Filtering by repository, branch, commit, language, symbol kind, and path
- Health endpoint
- Readiness endpoint that checks database connectivity

## 8. Frontend Requirements

The React frontend should provide:

- Repository selector
- Branch selector
- Commit selector or commit history view for indexed commits
- File browser
- Source file viewer
- Symbol search
- Definition/reference views
- Index status view
- Error details for failed indexing jobs

The first version should prioritize source exploration workflows over visual polish. The primary workflow should use the selected branch head, but users must also be able to inspect indexed historical commits.

## 9. Configuration

The application must support configuration for:

- PostgreSQL connection
- Server host and port
- Shared HTTP API and MCP access token
- Repository list in YAML
- Included and excluded branches
- Included and excluded paths
- Indexer mode, such as continuous polling or one-shot batch indexing
- Repository polling interval, with support for values such as 5 minutes
- Local clone/cache directory
- Log level

Configuration should be documented with example values.

## 10. Deployment

The project must include a Docker Compose setup with separate services for:

- PostgreSQL database
- Haskell server
- Haskell indexer
- React frontend, either served by the Haskell server or as its own service

The Compose setup must include:

- Persistent database volume
- Environment variable configuration
- Health checks where practical
- Database migration execution path

## 11. Testing

The project must include automated tests.

Required test coverage:

- Database schema/migration tests
- Repository configuration parsing tests
- Access token authentication tests for HTTP API and MCP requests
- Git indexing tests using small fixture repositories
- Parser tests for C#, JavaScript, and TypeScript fixtures
- Query/API tests for core search and lookup behavior
- MCP tool tests for response shape and limits
- Frontend component or integration tests for key workflows

GitHub Actions must run the automated test suite on pull requests and pushes to the main branch.

## 12. Observability and Operations

The system should provide:

- Structured logs for server and indexer
- Indexing job status
- Per-repository progress
- Parse/index failure counts
- Health and readiness checks
- Clear failure messages for invalid repository configuration or inaccessible Git remotes

## 13. Extensibility Requirements

The architecture must allow adding new language support with minimal changes outside the parser implementation.

A new language parser should be able to define:

- File extensions or detection rules
- Symbol extraction logic
- Reference extraction logic
- Supported symbol kinds
- Parser version/metadata

The database model should store generic symbol data while allowing language-specific metadata when needed.

## 14. Security Requirements

Initial security requirements:

- Do not expose arbitrary filesystem reads through HTTP or MCP.
- Restrict file access to configured repositories and clone/cache directories.
- Avoid logging secrets from repository URLs or database connection strings.
- Validate repository URLs and paths before indexing.
- Treat indexed source code as sensitive data.
- Authentication is required for the first usable release.
- HTTP API and MCP requests must authenticate with a configured access token.
- The access token must be read from configuration and must not be logged.
- The first version should bind to localhost by default unless explicitly configured otherwise.

## 15. Performance Requirements

The initial version should be designed and tested against repositories with at least 10,000 files and 50,000 commits.

Expected behavior:

- Search endpoints should paginate results.
- Common search fields should be indexed in PostgreSQL.
- Indexing should avoid re-parsing identical file content where possible.
- Large files should have a configurable skip limit.
- API responses should enforce practical result size limits.

## 16. Acceptance Criteria

The first complete version is acceptable when:

- Docker Compose starts PostgreSQL, server, indexer, and frontend successfully.
- A configured Git repository can be indexed from a clean database.
- Repository configuration is loaded from a YAML file.
- HTTP API and MCP requests require the configured access token.
- Branch include/exclude configuration is respected.
- Commits, files, and parsed symbols are persisted.
- C#, JavaScript, and TypeScript fixture projects produce searchable definitions.
- The HTTP API can list repositories, files, symbols, definitions, references, and index status.
- The MCP server exposes equivalent source exploration tools with bounded responses.
- The React frontend supports repository browsing, file viewing, symbol search, and index status inspection.
- The React frontend supports inspecting indexed historical commits.
- Unit/integration tests run in GitHub Actions.

## 17. Project Decisions

- The HTTP API and MCP endpoint run in the same Haskell server process for the first version. The query/business logic should remain transport-independent so the MCP endpoint can be split into a separate process later if needed.
- Repository configuration is YAML-file-based for the first version. UI-based repository configuration is deferred.
- Authentication is required for the first usable release. HTTP API and MCP requests use the same access token loaded from configuration. The application should bind to localhost by default and avoid exposing indexed source remotely unless explicitly configured.
- The frontend should support both branch-head browsing and indexed historical commit inspection. Branch-head browsing is the primary workflow.
- Performance testing should use fixture or real repositories with at least 10,000 files and 50,000 commits.
- Parser implementations should use Tree-sitter by default where a mature grammar exists. Language-specific compiler APIs may be introduced later only when Tree-sitter output is insufficient for required symbol or reference extraction.
