# Source Explorer MCP

Source Explorer indexes configured Git repositories into PostgreSQL and exposes repository, file, commit, and symbol data through one Haskell HTTP/MCP server plus a React frontend.

## Local Configuration

Copy `config/source-explorer.example.yaml` and adjust:

- `server.accessToken`
- `database`
- `indexer.cloneDir`
- `repositories`

Repository configuration is YAML-file based for the first version.

## Backend

```sh
stack build
stack run source-explorer-server -- --config config/source-explorer.example.yaml
stack run source-explorer-indexer -- --config config/source-explorer.example.yaml
```

HTTP and MCP requests use the same bearer token:

```sh
curl -H "Authorization: Bearer change-me" http://127.0.0.1:8080/api/repositories
```

## Frontend

```sh
cd frontend
npm install
npm run dev
```

The frontend stores the access token in browser local storage.

## Docker Compose

```sh
docker compose up --build
```

Services:

- PostgreSQL on `5432`
- Haskell HTTP/MCP server on `8080`
- Haskell continuous indexer
- React frontend on `5173`

