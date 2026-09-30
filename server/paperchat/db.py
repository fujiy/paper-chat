from __future__ import annotations

import hashlib
import json
import sqlite3
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from uuid import uuid4

SCHEMA = """
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS papers (
  id TEXT PRIMARY KEY, title TEXT NOT NULL, authors_json TEXT NOT NULL DEFAULT '[]',
  year TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, last_opened_at TEXT
);
CREATE TABLE IF NOT EXISTS paper_identifiers (
  paper_id TEXT NOT NULL, kind TEXT NOT NULL, library_type TEXT, library_id TEXT,
  value TEXT NOT NULL, created_at TEXT NOT NULL,
  PRIMARY KEY(kind, library_type, library_id, value),
  FOREIGN KEY(paper_id) REFERENCES papers(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS reading_states (
  paper_id TEXT NOT NULL, device_id TEXT NOT NULL, page_index INTEGER NOT NULL DEFAULT 0,
  scroll_offset REAL NOT NULL DEFAULT 0, zoom_scale REAL NOT NULL DEFAULT 1,
  display_mode TEXT NOT NULL DEFAULT 'singlePageContinuous', active_thread_id TEXT,
  updated_at TEXT NOT NULL, PRIMARY KEY(paper_id, device_id),
  FOREIGN KEY(paper_id) REFERENCES papers(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS threads (
  id TEXT PRIMARY KEY, paper_id TEXT, title TEXT NOT NULL,
  backend_type TEXT NOT NULL, backend_thread_id TEXT, backend_status TEXT NOT NULL DEFAULT 'ready',
  summary TEXT, is_primary INTEGER NOT NULL DEFAULT 0, last_used_at TEXT NOT NULL,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
  FOREIGN KEY(paper_id) REFERENCES papers(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS messages (
  id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL,
  page_refs_json TEXT NOT NULL DEFAULT '[]', selected_text TEXT, client_request_id TEXT,
  backend_turn_id TEXT, status TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
  FOREIGN KEY(thread_id) REFERENCES threads(id) ON DELETE CASCADE,
  UNIQUE(thread_id, client_request_id)
);
CREATE TABLE IF NOT EXISTS message_progress (
  message_id TEXT PRIMARY KEY, items_json TEXT NOT NULL DEFAULT '{}',
  FOREIGN KEY(message_id) REFERENCES messages(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS device_sessions (
  id TEXT PRIMARY KEY, device_id TEXT NOT NULL, device_name TEXT NOT NULL,
  access_hash TEXT NOT NULL UNIQUE, access_expires_at INTEGER NOT NULL,
  refresh_hash TEXT NOT NULL UNIQUE, refresh_expires_at INTEGER NOT NULL,
  revoked_at TEXT, created_at TEXT NOT NULL, last_used_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS paper_stars (
  paper_id TEXT PRIMARY KEY, starred_at TEXT NOT NULL,
  FOREIGN KEY(paper_id) REFERENCES papers(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS bookmarks (
  id TEXT PRIMARY KEY, paper_id TEXT NOT NULL, kind TEXT NOT NULL,
  page_index INTEGER NOT NULL, scroll_offset REAL NOT NULL DEFAULT 0,
  selected_text TEXT, selection_rects_json TEXT NOT NULL DEFAULT '[]',
  note TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
  FOREIGN KEY(paper_id) REFERENCES papers(id) ON DELETE CASCADE,
  CHECK(kind IN ('page', 'selection'))
);
CREATE TABLE IF NOT EXISTS page_views (
  paper_id TEXT NOT NULL, page_index INTEGER NOT NULL,
  total_active_seconds REAL NOT NULL DEFAULT 0,
  visit_count INTEGER NOT NULL DEFAULT 0, last_viewed_at TEXT NOT NULL,
  PRIMARY KEY(paper_id, page_index),
  FOREIGN KEY(paper_id) REFERENCES papers(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_papers_recent ON papers(last_opened_at DESC);
CREATE INDEX IF NOT EXISTS idx_threads_paper ON threads(paper_id, last_used_at DESC);
CREATE INDEX IF NOT EXISTS idx_messages_thread ON messages(thread_id, created_at);
CREATE INDEX IF NOT EXISTS idx_paper_stars_at ON paper_stars(starred_at DESC);
CREATE INDEX IF NOT EXISTS idx_bookmarks_paper ON bookmarks(paper_id, created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS idx_bookmarks_page_unique
  ON bookmarks(paper_id, page_index) WHERE kind = 'page';
CREATE INDEX IF NOT EXISTS idx_page_views_suggestions
  ON page_views(paper_id, total_active_seconds DESC);
"""


def now() -> str:
    return datetime.now(UTC).isoformat()


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def connect(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def init(path: Path) -> None:
    with connect(path) as conn:
        conn.executescript(SCHEMA)
        columns = conn.execute("PRAGMA table_info(threads)").fetchall()
        if any(row["name"] == "paper_id" and row["notnull"] for row in columns):
            # SQLite cannot drop NOT NULL in place. Keep the table name and IDs so
            # messages/reading states and backend conversation references survive.
            conn.execute("PRAGMA foreign_keys = OFF")
            try:
                conn.execute("BEGIN IMMEDIATE")
                table_sql = SCHEMA.split("CREATE TABLE IF NOT EXISTS threads (", 1)[1]
                table_sql = table_sql.split(";", 1)[0]
                conn.execute("CREATE TABLE threads_new (" + table_sql)
                conn.execute("INSERT INTO threads_new SELECT * FROM threads")
                conn.execute("DROP TABLE threads")
                conn.execute("ALTER TABLE threads_new RENAME TO threads")
                conn.execute(
                    "CREATE INDEX idx_threads_paper ON threads(paper_id, last_used_at DESC)"
                )
                if conn.execute("PRAGMA foreign_key_check").fetchall():
                    raise RuntimeError("Thread migration violated foreign keys")
                conn.commit()
            except Exception:
                conn.rollback()
                raise
            finally:
                conn.execute("PRAGMA foreign_keys = ON")


def as_dict(row: sqlite3.Row | None) -> dict[str, Any] | None:
    if row is None:
        return None
    result = dict(row)
    for key in list(result):
        if key.endswith("_json"):
            result[key.removesuffix("_json")] = json.loads(result.pop(key) or "null")
    return result


def new_id() -> str:
    return str(uuid4())
