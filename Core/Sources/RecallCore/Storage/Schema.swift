import Foundation
import CSQLite

/// Owns the database schema and forward-only migrations. The schema version is
/// tracked via SQLite's `user_version` pragma.
public enum SchemaMigrator {
    /// The current target schema version.
    public static let currentVersion: Int32 = 1

    /// Applies any pending migrations to reach `currentVersion`.
    public static func migrate(_ db: SQLiteDatabase) throws {
        let version = try userVersion(db)
        if version < 1 {
            try applyV1(db)
            try setUserVersion(db, 1)
        }
        // Future migrations: `if version < 2 { ... }`.
    }

    private static func userVersion(_ db: SQLiteDatabase) throws -> Int32 {
        try db.perform { handle in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else {
                throw StorageError.migrationFailed("read user_version")
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int32(sqlite3_column_int(stmt, 0))
        }
    }

    private static func setUserVersion(_ db: SQLiteDatabase, _ v: Int32) throws {
        try db.exec("PRAGMA user_version=\(v);")
    }

    /// Initial schema: documents, chunks, FTS5 index, folders, supporting indexes.
    private static func applyV1(_ db: SQLiteDatabase) throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS documents (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            path            TEXT NOT NULL UNIQUE,
            filename        TEXT NOT NULL,
            file_type       TEXT NOT NULL,
            modified_at     REAL NOT NULL,
            content_hash    TEXT NOT NULL,
            index_status    TEXT NOT NULL DEFAULT 'pending',
            last_indexed_at REAL,
            error_message   TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_documents_status ON documents(index_status);

        -- Each chunk belongs to exactly one document. The absolute path lives
        -- only in `documents`; chunks reference it via document_id. Deleting a
        -- document cascades to its chunks.
        CREATE TABLE IF NOT EXISTS chunks (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            document_id     INTEGER NOT NULL,
            chunk_index     INTEGER NOT NULL,
            text            TEXT NOT NULL,
            page_number     INTEGER,
            embedding_model TEXT NOT NULL,
            embedding       BLOB NOT NULL,
            dimensions      INTEGER NOT NULL,
            UNIQUE(document_id, chunk_index),
            FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE
        );

        CREATE INDEX IF NOT EXISTS idx_chunks_document ON chunks(document_id);

        -- FTS5 full-text index over chunk text. `content_rowid` is tied to the
        -- chunks table so we can join matches back to chunk metadata.
        CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
            text,
            content='chunks',
            content_rowid='id',
            tokenize='porter unicode61'
        );

        -- Triggers keep the FTS index in sync with the chunks table.
        CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
            INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text);
        END;
        CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
            INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES ('delete', old.id, old.text);
        END;
        CREATE TRIGGER IF NOT EXISTS chunks_au AFTER UPDATE ON chunks BEGIN
            INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES ('delete', old.id, old.text);
            INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text);
        END;

        -- User-selected folders that define the indexing scope.
        CREATE TABLE IF NOT EXISTS folders (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            path        TEXT NOT NULL UNIQUE,
            bookmark    BLOB,
            added_at    REAL NOT NULL
        );
        """)
    }
}
