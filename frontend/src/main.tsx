import React, { useEffect, useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import { Database, FileCode2, GitBranch, History, KeyRound, RefreshCw, Search } from "lucide-react";
import "./styles.css";

type Repository = { id: number; name: string; url: string; defaultBranch: string };
type Branch = { name: string; headSha: string | null; isStale: boolean };
type Commit = { sha: string; message: string; authorName: string; authorEmail: string; authorTime: string; committerTime: string };
type FileSummary = { path: string; language: string | null; contentHash: string; sizeBytes: number; status: string; error: string | null };
type FileContent = { path: string; language: string | null; content: string };
type SymbolResult = {
  repository: string;
  commitSha: string;
  filePath: string;
  name: string;
  kind: string;
  container: string | null;
  startLine: number;
  startColumn: number;
  endLine: number;
  endColumn: number;
  snippet: string | null;
};
type IndexStatus = { repository: string | null; status: string; message: string | null; startedAt: string; finishedAt: string | null };

const apiBase = import.meta.env.VITE_API_BASE ?? "http://127.0.0.1:8080";

function App() {
  const [token, setToken] = useState(localStorage.getItem("sourceExplorerToken") ?? "change-me");
  const [repositories, setRepositories] = useState<Repository[]>([]);
  const [branches, setBranches] = useState<Branch[]>([]);
  const [commits, setCommits] = useState<Commit[]>([]);
  const [files, setFiles] = useState<FileSummary[]>([]);
  const [symbols, setSymbols] = useState<SymbolResult[]>([]);
  const [status, setStatus] = useState<IndexStatus[]>([]);
  const [selectedRepo, setSelectedRepo] = useState("");
  const [selectedBranch, setSelectedBranch] = useState("");
  const [selectedCommit, setSelectedCommit] = useState("");
  const [selectedFile, setSelectedFile] = useState<FileContent | null>(null);
  const [query, setQuery] = useState("");
  const [error, setError] = useState("");

  const authHeaders = useMemo(() => ({ Authorization: `Bearer ${token}` }), [token]);

  async function api<T>(path: string): Promise<T> {
    const response = await fetch(`${apiBase}${path}`, { headers: authHeaders });
    if (!response.ok) throw new Error(`${response.status} ${await response.text()}`);
    return response.json() as Promise<T>;
  }

  async function refreshRepositories() {
    setError("");
    try {
      const repos = await api<Repository[]>("/api/repositories");
      setRepositories(repos);
      if (!selectedRepo && repos[0]) setSelectedRepo(repos[0].name);
    } catch (err) {
      setError(String(err));
    }
  }

  useEffect(() => {
    localStorage.setItem("sourceExplorerToken", token);
  }, [token]);

  useEffect(() => {
    refreshRepositories();
  }, []);

  useEffect(() => {
    if (!selectedRepo) return;
    setSelectedBranch("");
    setSelectedCommit("");
    setSelectedFile(null);
    Promise.all([
      api<Branch[]>(`/api/repositories/${encodeURIComponent(selectedRepo)}/branches`),
      api<IndexStatus[]>(`/api/index-status?repository=${encodeURIComponent(selectedRepo)}`)
    ])
      .then(([nextBranches, nextStatus]) => {
        setBranches(nextBranches);
        setStatus(nextStatus);
        const defaultBranch = repositories.find((repo) => repo.name === selectedRepo)?.defaultBranch;
        setSelectedBranch(nextBranches.find((branch) => branch.name === defaultBranch)?.name ?? nextBranches[0]?.name ?? "");
      })
      .catch((err) => setError(String(err)));
  }, [selectedRepo]);

  useEffect(() => {
    if (!selectedRepo || !selectedBranch) return;
    api<Commit[]>(`/api/repositories/${encodeURIComponent(selectedRepo)}/commits?branch=${encodeURIComponent(selectedBranch)}&limit=100`)
      .then((nextCommits) => {
        setCommits(nextCommits);
        setSelectedCommit(nextCommits[0]?.sha ?? "");
      })
      .catch((err) => setError(String(err)));
  }, [selectedRepo, selectedBranch]);

  useEffect(() => {
    if (!selectedRepo || !selectedCommit) return;
    api<FileSummary[]>(`/api/repositories/${encodeURIComponent(selectedRepo)}/commits/${selectedCommit}/files?limit=1000`)
      .then(setFiles)
      .catch((err) => setError(String(err)));
  }, [selectedRepo, selectedCommit]);

  async function searchSymbols() {
    if (!selectedRepo) return;
    const params = new URLSearchParams({ repository: selectedRepo, q: query, limit: "100" });
    setSymbols(await api<SymbolResult[]>(`/api/symbols?${params.toString()}`));
  }

  async function openFile(path: string) {
    if (!selectedRepo || !selectedCommit) return;
    const params = new URLSearchParams({ path });
    setSelectedFile(await api<FileContent>(`/api/repositories/${encodeURIComponent(selectedRepo)}/commits/${selectedCommit}/files/content?${params.toString()}`));
  }

  return (
    <main>
      <header className="topbar">
        <div className="brand">
          <Database size={22} />
          <span>Source Explorer</span>
        </div>
        <label className="token">
          <KeyRound size={16} />
          <input value={token} onChange={(event) => setToken(event.target.value)} aria-label="Access token" />
        </label>
        <button onClick={refreshRepositories} title="Refresh repositories">
          <RefreshCw size={17} />
        </button>
      </header>

      {error && <div className="error">{error}</div>}

      <section className="selectors">
        <label>
          Repository
          <select value={selectedRepo} onChange={(event) => setSelectedRepo(event.target.value)}>
            {repositories.map((repo) => <option key={repo.id} value={repo.name}>{repo.name}</option>)}
          </select>
        </label>
        <label>
          Branch
          <select value={selectedBranch} onChange={(event) => setSelectedBranch(event.target.value)}>
            {branches.map((branch) => <option key={branch.name} value={branch.name}>{branch.name}</option>)}
          </select>
        </label>
        <label>
          Commit
          <select value={selectedCommit} onChange={(event) => setSelectedCommit(event.target.value)}>
            {commits.map((commit) => <option key={commit.sha} value={commit.sha}>{commit.sha.slice(0, 12)} {commit.message.split("\n")[0]}</option>)}
          </select>
        </label>
      </section>

      <section className="workspace">
        <aside>
          <h2><FileCode2 size={18} /> Files</h2>
          <div className="list">
            {files.map((file) => (
              <button key={file.path} onClick={() => openFile(file.path)} className={selectedFile?.path === file.path ? "active" : ""}>
                <span>{file.path}</span>
                <small>{file.language ?? file.status}</small>
              </button>
            ))}
          </div>
        </aside>

        <section className="viewer">
          <div className="searchbar">
            <Search size={17} />
            <input value={query} onChange={(event) => setQuery(event.target.value)} onKeyDown={(event) => event.key === "Enter" && searchSymbols()} placeholder="Search symbols" />
            <button onClick={searchSymbols}>Search</button>
          </div>

          <div className="symbolResults">
            {symbols.map((symbol) => (
              <button key={`${symbol.commitSha}-${symbol.filePath}-${symbol.name}-${symbol.startLine}`} onClick={() => openFile(symbol.filePath)}>
                <strong>{symbol.name}</strong>
                <span>{symbol.kind} · {symbol.filePath}:{symbol.startLine}</span>
                {symbol.snippet && <small>{symbol.snippet}</small>}
              </button>
            ))}
          </div>

          <pre className="code">{selectedFile ? selectedFile.content : "Select a file to inspect indexed source."}</pre>
        </section>

        <aside>
          <h2><History size={18} /> Status</h2>
          <div className="statusList">
            {status.map((entry, index) => (
              <div key={`${entry.startedAt}-${index}`} className="statusItem">
                <strong>{entry.status}</strong>
                <span>{entry.repository ?? "system"}</span>
                <small>{entry.message ?? ""}</small>
              </div>
            ))}
          </div>
          <h2><GitBranch size={18} /> Branches</h2>
          <div className="statusList">
            {branches.map((branch) => (
              <div key={branch.name} className="statusItem">
                <strong>{branch.name}</strong>
                <small>{branch.headSha?.slice(0, 12) ?? "no head"}</small>
              </div>
            ))}
          </div>
        </aside>
      </section>
    </main>
  );
}

createRoot(document.getElementById("root")!).render(<App />);

