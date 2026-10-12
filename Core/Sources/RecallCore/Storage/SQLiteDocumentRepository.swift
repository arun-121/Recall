import Foundation
import CSQLite

/// A folder registered as part of the indexing scope.
public struct IndexedFolder: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var path: String
    public var bookmark: Data?
    public var addedAt: Date

    public init(id: Int64 = 0, path: String, bookmark: Data? = nil, addedAt: Date = Date()) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.addedAt = addedAt
    }
}

/// Persists documents, chunks (with vectors) and the FTS index. All writes that
/// replace a document's content run in a single transaction so searches never
/// observe a half-updated document.
public final class SQLiteDocumentRepository: @unchecked Sendable {
    public let db: SQLiteDatabase

    public init(db: SQLiteDatabase) throws {
        self.db = db
        try SchemaMigrator.migrate(db)
    }

    /// Convenience initializer that opens/creates the database at `path`.
    public convenience init(path: String) throws {
        try self.init(db: try SQLiteDatabase(path: path))
    }

    // MARK: - Documents

    /// Returns the document with the given path, if present.
    public func document(withPath path: String) throws -> Document? {
        try db.perform { handle in
            let sql = "SELECT id, path, filename, file_type, modified_at, content_hash, index_status, last_indexed_at, error_message FROM documents WHERE path = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw StorageError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
            defer { sqlite3_finalize(stmt) }
            stmt.bindText(1, path)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Self.readDocument(stmt)
        }
    }

    /// Returns all documents.
    public func allDocuments() throws -> [Document] {
        try db.perform { handle in
            let sql = "SELECT id, path, filename, file_type, modified_at, content_hash, index_status, last_indexed_at, error_message FROM documents ORDER BY id;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw StorageError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
            defer { sqlite3_finalize(stmt) }
            var docs: [Document] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                docs.append(Self.readDocument(stmt))
            }
            return docs
        }
    }

    /// Inserts or updates a document row (by unique path) and returns its id.
    @discardableResult
    public func upsertDocument(_ doc: Document) throws -> Int64 {
        try db.perform { handle in
            let sql = """
            INSERT INTO documents (path, filename, file_type, modified_at, content_hash, index_status, last_indexed_at, error_message)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                filename=excluded.filename,
                file_type=excluded.file_type,
                modified_at=excluded.modified_at,
                content_hash=excluded.content_hash,
                index_status=excluded.index_status,
                last_indexed_at=excluded.last_indexed_at,
                error_message=excluded.error_message
            RETURNING id;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw StorageError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
            defer { sqlite3_finalize(stmt) }
            stmt.bindText(1, doc.path)
            stmt.bindText(2, doc.filename)
            stmt.bindText(3, doc.fileType.rawValue)
            stmt.bindDouble(4, doc.modifiedAt.timeIntervalSince1970)
            stmt.bindText(5, doc.contentHash)
            stmt.bindText(6, doc.indexStatus.rawValue)
            if let last = doc.lastIndexedAt { stmt.bindDouble(7, last.timeIntervalSince1970) }
            else { sqlite3_bind_null(stmt, 7) }
            stmt.bindOptionalText(8, doc.errorMessage)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                throw StorageError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
            return sqlite3_column_int64(stmt, 0)
        }
    }

    /// Updates only the status/error/last-indexed fields for a document.
    public func updateStatus(documentID: Int64, status: IndexStatus, error: String? = nil, lastIndexedAt: Date? = nil) throws {
        try db.perform { handle in
            let sql = "UPDATE documents SET index_status=?, error_message=?, last_indexed_at=? WHERE id=?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw StorageError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
            defer { sqlite3_finalize(stmt) }
            stmt.bindText(1, status.rawValue)
            stmt.bindOptionalText(2, error)
            if let last = lastIndexedAt { stmt.bindDouble(3, last.timeIntervalSince1970) }
            else { sqlite3_bind_null(stmt, 3) }
            stmt.bindInt(4, documentID)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw StorageError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    /// Deletes a document and (via cascade + triggers) its chunks and FTS entries.
    public func deleteDocument(id: Int64) throws {
        try db.perform { handle in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "DELETE FROM documents WHERE id=?;", -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw StorageError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
            defer { sqlite3_finalize(stmt) }
            stmt.bindInt(1, id)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw StorageError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    public func deleteDocument(withPath path: String) throws {
        guard let doc = try document(withPath: path) else { return }
        try deleteDocument(id: doc.id)
    }

    // MARK: - Chunks (atomic replacement)

    /// Atomically replaces all chunks for a document and marks it indexed.
    /// Old chunks (and their FTS/vector entries) are removed first, then new
    /// chunks inserted, all within one transaction.
    public func replaceChunks(documentID: Int64, chunks: [Chunk], markIndexedAt: Date = Date()) throws {
        try db.transaction { handle in
            // Delete existing chunks (triggers clean FTS).
            var del: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "DELETE FROM chunks WHERE document_id=?;", -1, &del, nil) == SQLITE_OK, let del else {
                throw StorageError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
            del.bindInt(1, documentID)
            guard sqlite3_step(del) == SQLITE_DONE else {
                sqlite3_finalize(del)
                throw StorageError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
            sqlite3_finalize(del)

            let insertSQL = """
            INSERT INTO chunks (document_id, chunk_index, text, page_number, embedding_model, embedding, dimensions)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
            var ins: OpaquePointer?
            guard sqlite3_prepare_v2(handle, insertSQL, -1, &ins, nil) == SQLITE_OK, let ins else {
                throw StorageError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
            defer { sqlite3_finalize(ins) }
            for chunk in chunks {
                sqlite3_reset(ins)
                sqlite3_clear_bindings(ins)
                ins.bindInt(1, documentID)
                ins.bindInt(2, Int64(chunk.chunkIndex))
                ins.bindText(3, chunk.text)
                ins.bindOptionalInt(4, chunk.pageNumber)
                ins.bindText(5, chunk.embeddingModel)
                ins.bindBlob(6, VectorBlob.encode(chunk.embedding))
                ins.bindInt(7, Int64(chunk.embedding.count))
                guard sqlite3_step(ins) == SQLITE_DONE else {
                    throw StorageError.queryFailed(String(cString: sqlite3_errmsg(handle)))
                }
            }

            // Mark the document indexed.
            var upd: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "UPDATE documents SET index_status='indexed', error_message=NULL, last_indexed_at=? WHERE id=?;", -1, &upd, nil) == SQLITE_OK, let upd else {
                throw StorageError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
            defer { sqlite3_finalize(upd) }
            upd.bindDouble(1, markIndexedAt.timeIntervalSince1970)
            upd.bindInt(2, documentID)
            guard sqlite3_step(upd) == SQLITE_DONE else {
                throw StorageError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    /// Returns the number of chunks for a document.
    public func chunkCount(documentID: Int64) throws -> Int {
        try db.perform { handle in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM chunks WHERE document_id=?;", -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw StorageError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
            defer { sqlite3_finalize(stmt) }
            stmt.bindInt(1, documentID)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    // MARK: - Vector store

    /// Loads all chunk vectors (with metadata) for exact similarity scanning.
    /// For the expected dataset size (user-selected folders), a full scan with
    /// exact cosine similarity is simple and fast enough.
    public func loadAllVectors() throws -> [(ScoredChunk, [Float])] {
        try db.perform { handle in
            let sql = "SELECT id, document_id, chunk_index, text, page_number, embedding, dimensions FROM chunks;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw StorageError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
            defer { sqlite3_finalize(stmt) }
            var out: [(ScoredChunk, [Float])] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let dims = Int(stmt.columnInt(6))
                let vec = VectorBlob.decode(stmt.columnBlob(5), dimensions: dims)
                let sc = ScoredChunk(
                    chunkID: stmt.columnInt(0),
                    documentID: stmt.columnInt(1),
                    chunkIndex: Int(stmt.columnInt(2)),
                    text: stmt.columnText(3),
                    pageNumber: stmt.columnOptionalInt(4),
                    score: 0
                )
                out.append((sc, vec))
            }
            return out
        }
    }

    // MARK: - FTS5 keyword search

    /// Runs an FTS5 MATCH query, returning scored chunks ranked by bm25 (lower
    /// bm25 is better, so we negate it to make higher = better).
    public func keywordSearch(_ ftsQuery: String, limit: Int) throws -> [ScoredChunk] {
        try db.perform { handle in
            let sql = """
            SELECT c.id, c.document_id, c.chunk_index, c.text, c.page_number, bm25(chunks_fts) AS rank
            FROM chunks_fts
            JOIN chunks c ON c.id = chunks_fts.rowid
            WHERE chunks_fts MATCH ?
            ORDER BY rank
            LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw StorageError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
            defer { sqlite3_finalize(stmt) }
            stmt.bindText(1, ftsQuery)
            stmt.bindInt(2, Int64(limit))
            var out: [ScoredChunk] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let bm25 = stmt.columnDouble(5)
                out.append(ScoredChunk(
                    chunkID: stmt.columnInt(0),
                    documentID: stmt.columnInt(1),
                    chunkIndex: Int(stmt.columnInt(2)),
                    text: stmt.columnText(3),
                    pageNumber: stmt.columnOptionalInt(4),
                    score: -bm25
                ))
            }
            return out
        }
    }

    // MARK: - Document lookup for results

    public func document(id: Int64) throws -> Document? {
        try db.perform { handle in
            let sql = "SELECT id, path, filename, file_type, modified_at, content_hash, index_status, last_indexed_at, error_message FROM documents WHERE id=?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw StorageError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
            defer { sqlite3_finalize(stmt) }
            stmt.bindInt(1, id)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Self.readDocument(stmt)
        }
    }

    // MARK: - Folders

    @discardableResult
    public func addFolder(path: String, bookmark: Data?) throws -> Int64 {
        try db.perform { handle in
            let sql = "INSERT INTO folders (path, bookmark, added_at) VALUES (?, ?, ?) ON CONFLICT(path) DO UPDATE SET bookmark=excluded.bookmark RETURNING id;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw StorageError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
            defer { sqlite3_finalize(stmt) }
            stmt.bindText(1, path)
            if let bookmark { stmt.bindBlob(2, bookmark) } else { sqlite3_bind_null(stmt, 2) }
            stmt.bindDouble(3, Date().timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                throw StorageError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
            return sqlite3_column_int64(stmt, 0)
        }
    }

    public func allFolders() throws -> [IndexedFolder] {
        try db.perform { handle in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT id, path, bookmark, added_at FROM folders ORDER BY added_at;", -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw StorageError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
            defer { sqlite3_finalize(stmt) }
            var out: [IndexedFolder] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let bookmark = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : stmt.columnBlob(2)
                out.append(IndexedFolder(
                    id: stmt.columnInt(0),
                    path: stmt.columnText(1),
                    bookmark: bookmark,
                    addedAt: Date(timeIntervalSince1970: stmt.columnDouble(3))
                ))
            }
            return out
        }
    }

    /// Removes a folder and all documents (with chunks/FTS/vectors) underneath it.
    public func removeFolder(path: String) throws {
        try db.transaction { handle in
            // Delete documents whose path is within the folder.
            let prefix = path.hasSuffix("/") ? path : path + "/"
            var del: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "DELETE FROM documents WHERE path = ? OR path LIKE ? ESCAPE '\\';", -1, &del, nil) == SQLITE_OK, let del else {
                throw StorageError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
            del.bindText(1, path)
            let likePattern = escapeLike(prefix) + "%"
            del.bindText(2, likePattern)
            guard sqlite3_step(del) == SQLITE_DONE else {
                sqlite3_finalize(del)
                throw StorageError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
            sqlite3_finalize(del)

            var delF: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "DELETE FROM folders WHERE path=?;", -1, &delF, nil) == SQLITE_OK, let delF else {
                throw StorageError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
            defer { sqlite3_finalize(delF) }
            delF.bindText(1, path)
            guard sqlite3_step(delF) == SQLITE_DONE else {
                throw StorageError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    // MARK: - Helpers

    private static func readDocument(_ stmt: OpaquePointer) -> Document {
        Document(
            id: stmt.columnInt(0),
            path: stmt.columnText(1),
            filename: stmt.columnText(2),
            fileType: FileType(rawValue: stmt.columnText(3)) ?? .text,
            modifiedAt: Date(timeIntervalSince1970: stmt.columnDouble(4)),
            contentHash: stmt.columnText(5),
            indexStatus: IndexStatus(rawValue: stmt.columnText(6)) ?? .pending,
            lastIndexedAt: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: stmt.columnDouble(7)),
            errorMessage: stmt.columnOptionalText(8)
        )
    }
}

/// Escapes `%` and `_` in a LIKE pattern prefix (using `\` as the escape char).
private func escapeLike(_ s: String) -> String {
    var out = ""
    for ch in s {
        if ch == "%" || ch == "_" || ch == "\\" { out.append("\\") }
        out.append(ch)
    }
    return out
}
