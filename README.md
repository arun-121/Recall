# Recall

Recall is a native macOS app for searching your documents by **meaning**, not just
keywords. Ask things like *"how does PostgreSQL detect deadlocks"* or *"my notes
about Redis persistence"* and Recall finds the relevant document even if those
exact words never appear in it.

It is **local-first and privacy-focused**: your documents, extracted text, and
embeddings never leave your machine. There is no account, no backend server, and
no cloud API in the search path.

---

## Highlights

- **Semantic + keyword hybrid search.** Combines local embedding similarity with
  SQLite FTS5 full-text search, fused with Reciprocal Rank Fusion (RRF).
- **Keyboard-first UI.** Type to search (debounced), arrow keys to move, Return to
  open, Escape to clear.
- **Local embeddings via Ollama.** Uses the dedicated `nomic-embed-text` embedding
  model — not a generative LLM.
- **Incremental indexing.** Content hashes avoid re-embedding unchanged files;
  deletions and modifications are reconciled.
- **PDF, Markdown, and plain text** supported out of the box, with page numbers
  preserved for PDFs.
- **Only indexes folders you choose.** Never scans your whole disk.

---

## Requirements

- macOS 14 or later (the app).
- Swift toolchain (Swift 5.9+). Works with **Command Line Tools only** — full Xcode
  is not required.
- [Ollama](https://ollama.com) for embeddings (local inference runtime).

> Recall is built and bundled with Swift Package Manager because it is designed to
> work on machines that have only the Command Line Tools installed. See
> [Toolchain notes](#toolchain-notes-why-two-packages) for why the project is split
> into two packages.

---

## Setup

### 1. Install and start Ollama

```bash
# Install (if you don't have it)
brew install --cask ollama      # or download from https://ollama.com

# Start the runtime (leave running)
ollama serve
```

### 2. Pull the embedding model

Recall uses `nomic-embed-text` (a 768-dimension embedding model, ~274 MB):

```bash
ollama pull nomic-embed-text
```

> Your installed generative models (e.g. `gemma3`, `llama3`) are **not** usable for
> embeddings. Recall requires a dedicated embedding model. If the model is missing,
> Recall shows an actionable message rather than falling back to anything cloud-based.

### 3. Build and run

```bash
# From the project root
swift build                      # builds the app
swift run Recall                 # runs it directly

# …or assemble a double-clickable .app bundle:
Scripts/build_app.sh release
open dist/Recall.app
```

### 4. Index a folder

Click the folder button in the search bar (or use the folder manager) and choose a
folder. Recall indexes supported files in the background and shows progress in the
status bar.

### 5. (Optional) Global hotkey with Hammerspoon

See [`Hammerspoon/init.lua`](Hammerspoon/init.lua) for a ready-to-use snippet that
binds **Cmd+Alt+Space** to summon Recall. Hammerspoon is entirely optional.

---

## Embedding visualization

Recall ships a small, dependency-free tool to **visualize the embedding space** of
your indexed documents. It reads the chunk vectors from the Recall database,
projects the 768-dimension embeddings down to 2D with PCA (implemented in Swift, no
Python or external libraries), and writes a self-contained interactive HTML scatter
plot.

```bash
cd Tools/EmbeddingVisualizer
swift run EmbeddingVisualizer                 # uses the default app database
# or point at a specific DB and output file:
swift run EmbeddingVisualizer "$HOME/Library/Application Support/Recall/recall.sqlite" embeddings.html
open embeddings.html
```

In the plot:
- Each dot is a chunk; **color = source document**.
- **Hover** a dot to see its document name and a text snippet.
- **Scroll** to zoom, **drag** to pan.

Nearby dots are semantically similar; tight single-color clusters are chunks from the
same document. The tool lives in its own package (depending on `RecallCore`) so the
core package stays free of executable targets.

---

## Running the tests

Tests live in the `Core` package and use the **swift-testing** framework. They use a
deterministic fake embedding provider, so **no model download is needed** to run them.

```bash
cd Core
swift test
```

All 43 tests cover chunking/overlap, content-hash change detection, document↔chunk
relationships, SQLite persistence and cascade cleanup, vector similarity, RRF
ranking, result grouping, modified/deleted file handling, embedding-provider errors,
and empty-query / no-result states.

---

## Architecture

Recall is split into a UI layer (the app) and a dependency-free core library.

```
Recall/                      ← app package (RecallApp, macOS 14)
├── Package.swift
├── Sources/Recall/          ← SwiftUI app
│   ├── RecallApp.swift          @main entry + startup error handling
│   ├── RecallEnvironment.swift  composition root (wires concrete types)
│   ├── ContentView.swift        search UI, states, keyboard navigation
│   ├── FolderManagerView.swift  add/remove/rescan indexed folders
│   ├── SearchViewModel.swift    query/debounce/results/error state
│   ├── IndexingViewModel.swift  folder picker, progress, file monitoring
│   └── FileOpener.swift         opens the real indexed file
├── Scripts/build_app.sh     ← assembles Recall.app
├── Hammerspoon/init.lua     ← optional global hotkey
└── Core/                    ← RecallCore package (library + tests, macOS 13)
    ├── Package.swift
    ├── Sources/CSQLite/         system library module map for libsqlite3 (FTS5)
    ├── Sources/RecallCore/
    │   ├── Models/              Document, Chunk, SearchResult, errors
    │   ├── Storage/             SQLiteDatabase, schema/migrations, repository, vector blob
    │   ├── Extraction/          DocumentExtractor (PDF/MD/TXT), TextChunker, ContentHasher
    │   ├── Embeddings/          EmbeddingProvider, LocalEmbeddingProvider (Ollama), Fake, VectorMath
    │   ├── Indexing/            DocumentIndexer (actor), FileChangeMonitor
    │   └── Search/              HybridSearchService, Fusion (RRF), grouping
    └── Tests/RecallCoreTests/
```

### Dependency injection

The UI depends only on protocols (`SearchService`, `EmbeddingProvider`) and value
types. `RecallEnvironment` is the single place that knows about Ollama, SQLite, and
the filesystem. This keeps the embedding model, database, and indexing internals
swappable and testable.

### Search pipeline

For a query, `HybridSearchService`:

1. Validates/normalizes the query (empty → no results, never an error).
2. Generates a query embedding (via `EmbeddingProvider`).
3. Retrieves nearest chunk vectors by **exact cosine similarity** over all stored
   vectors (chosen deliberately — see below).
3. Retrieves nearest chunk vectors by **exact cosine similarity**, keeping only
   those at or above a **minimum similarity floor** (default `0.5`) — see below.
4. Retrieves keyword matches via **SQLite FTS5** (`bm25`).
5. Adds a lightweight **filename** matching signal.
6. Fuses the three ranked lists with **Reciprocal Rank Fusion** (semantic weighted
   1.0, keyword 0.9, filename 0.5).
7. Groups chunk hits by document (summing contributions, keeping the best chunk as
   the snippet) and returns document-level results.

**Why a relevance floor?** Semantic (vector) search always returns the *nearest*
chunks, even when nothing is actually relevant — so without a floor, an off-topic
query like *"umbrella"* against a resume would still surface the resume simply
because it is the closest (or only) vector. The floor discards chunks whose cosine
similarity is below `minSemanticSimilarity`. Measured on `nomic-embed-text`,
off-topic queries score ~0.33–0.47 against unrelated text while genuine matches
score ~0.65+, so `0.5` cleanly separates them. A query with no semantic match above
the floor and no keyword/filename hit correctly returns **no results**.

**Why RRF?** Cosine similarity (roughly −1…1) and FTS5 `bm25` scores live on
different, incomparable scales. Naively adding them is meaningless. RRF fuses
*rankings* instead of raw scores: each list contributes `weight / (k + rank)`
(k = 60). This is robust, parameter-light, and well established in IR literature.

**Why exact cosine (not ANN)?** The dataset is scoped to the user's selected
folders, which is small. Exact similarity is simple, correct, and fast enough. An
approximate-nearest-neighbor index would only be justified by measured performance
problems on much larger corpora.

### Database schema (SQLite)

- **`documents`** — `id`, `path` (unique), `filename`, `file_type`, `modified_at`,
  `content_hash`, `index_status`, `last_indexed_at`, `error_message`. The absolute
  path is stored **once** here.
- **`chunks`** — `id`, `document_id` (FK, `ON DELETE CASCADE`), `chunk_index`,
  `text`, `page_number`, `embedding_model`, `embedding` (Float32 BLOB), `dimensions`.
  Unique on `(document_id, chunk_index)`.
- **`chunks_fts`** — FTS5 virtual table over chunk text (`porter unicode61`), kept in
  sync with `chunks` via triggers.
- **`folders`** — selected folders with optional security-scoped bookmarks.

Replacing a document's content runs in a **single transaction** (delete old chunks →
insert new → mark indexed), so searches never observe a half-updated document.
Deleting a document cascades to its chunks, FTS entries, and vectors.

### Incremental indexing

- **New file** → extract, chunk, embed, persist.
- **Modified file** → content hash differs → re-index, atomically replacing chunks.
- **Unchanged file** → content hash matches → skipped (no re-embedding).
- **Deleted file** → removed from the index during reconciliation.
- **On launch / rescan** → the indexer reconciles stale metadata and resumes.

Filesystem events (`FileChangeMonitor`, debounced) trigger rescans, but the app does
not rely on events alone — it always reconciles on launch and on manual rescan.
Heavy extraction and embedding run off the main thread inside a `DocumentIndexer`
actor with **bounded concurrency** to cap memory and CPU.

---

## Privacy

- Document contents, embeddings, and metadata stay local (SQLite in
  `~/Library/Application Support/Recall/recall.sqlite`).
- Recall requests access only to folders you explicitly select.
- You can remove a folder and all of its indexed data at any time.
- Embedding requests go only to your local Ollama runtime — never to a third party.

---

## Limitations

- **Scanned PDFs are not supported.** Recall extracts selectable text only; it does
  **not** perform OCR. A scanned/image-only PDF is reported as having no extractable
  text and is skipped. (OCR could be added later via Vision.)
- **PDF "open to page" is best-effort.** Opening a result opens the real file in its
  default app; the matching page number is shown in the UI but Recall does not force
  the viewer to that page (reliable cross-app page navigation is not available).
- **Not guaranteed fully offline.** The app itself runs locally, but embedding
  requires the Ollama runtime and the embedding model to be installed. If Ollama was
  installed via a method that needs network access, that is outside Recall's control.
- **Supported formats:** PDF, Markdown (`.md`/`.markdown`), and plain text (`.txt`).
  Other formats are ignored (the extractor layer is extensible to add more).
- **Exact vector scan** loads chunk vectors to score a query. This is intentional for
  folder-scoped corpora and is not optimized for very large (100k+ chunk) datasets.

---

## Troubleshooting

**"Can't reach the local embedding runtime."**
Ollama isn't running. Start it with `ollama serve` and try again.

**"The embedding model 'nomic-embed-text' isn't installed."**
Run `ollama pull nomic-embed-text`, then retry.

**Search returns only keyword matches / semantic results seem missing.**
If embedding fails but keyword search still works, Recall degrades gracefully and
returns keyword results. Check that Ollama is running and the model is installed.

**A result won't open.**
The underlying file may have been moved or deleted. Recall never opens a stale path;
rescan the folder to reconcile the index.

**Gatekeeper blocks the `.app` on first launch.**
The bundle is unsigned. Right-click the app and choose **Open**, or clear the
quarantine attribute:
```bash
xattr -dr com.apple.quarantine dist/Recall.app
```

---

## Toolchain notes (why two packages)

Recall is intentionally structured as an **app package** (`Recall/`) that depends on a
nested **core library package** (`Core/`). This layout works around real constraints
of building a modern SwiftUI app with the **Command Line Tools only** (no full Xcode):

1. **`@State` needs a macro plugin that ships with Xcode.** The CLT toolchain lacks
   the `SwiftUIMacros` plugin, so `@State` fails to compile. Recall uses
   `@StateObject`/`@ObservedObject`/`@Published` (which work) and a small observable
   for view-local flags.
2. **Tests use swift-testing, not XCTest.** XCTest proper isn't in the CLT SDK, but
   the `Testing` framework and its macro plugin are. All tests use `@Suite`/`@Test`/
   `#expect`.
3. **An executable target in the same package breaks swift-testing macro resolution**
   under this toolchain. Keeping the executable in a separate package from the test
   target lets `swift test` resolve the testing macros cleanly.
4. **The testing macros resolve at the macOS 13 deployment target.** The core package
   targets macOS 13 (tests pass); the app package targets macOS 14 (for `onKeyPress`
   and the two-parameter `onChange`), with availability guards so the core stays
   buildable at 13.

Commands:

```bash
swift build                 # build the app   (run from project root)
swift run Recall            # run the app
cd Core && swift test       # run the tests
Scripts/build_app.sh release   # produce dist/Recall.app
```
