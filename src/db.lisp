(in-package #:link-smasher.db)

(defvar *connection* nil)

;;; Connection
(defun connect (database-path)
  (setf *connection*
        (dbi:connect :sqlite3
                     :database-name database-path))
  (dbi:do-sql *connection* "PRAGMA journal_mode=WAL")
  (dbi:do-sql *connection* "PRAGMA busy_timeout=5000")
  *connection*)

(defun disconnect ()
  (when *connection*
    (dbi:disconnect *connection*)
    (setf *connection* nil)))


;;; Schema
(defun schema-exists-p ()
  (not (null (dbi:fetch-all
              (dbi:execute
               (dbi:prepare *connection*
                            "SELECT name FROM sqlite_master WHERE type='table' AND name='links'")
               nil)))))

(defun ensure-accesses-table ()
  (dbi:do-sql *connection*
    "
CREATE TABLE IF NOT EXISTS link_accesses (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  link_id INTEGER NOT NULL,
  accessed_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  referrer_host TEXT,
  user_agent TEXT,
  is_bot INTEGER NOT NULL DEFAULT 0,
  country TEXT
)
")
  (dbi:do-sql *connection*
    "CREATE INDEX IF NOT EXISTS idx_link_accesses_link
     ON link_accesses (link_id, accessed_at DESC)"))

(defun reset-schema ()
  (dbi:do-sql *connection* "DROP TABLE IF EXISTS links")
  (dbi:do-sql *connection* "DROP TABLE IF EXISTS link_accesses")
  (dbi:do-sql *connection*
    "
CREATE TABLE links (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  original_url TEXT NOT NULL,
  short_code TEXT UNIQUE,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  accesses INTEGER NOT NULL DEFAULT 0
)
")
  (ensure-accesses-table))

(defun column-exists-p (table column)
  (some (lambda (row) (string= (getf row :|name|) column))
        (dbi:fetch-all
         (dbi:execute
          (dbi:prepare *connection*
                       (format nil "PRAGMA table_info(~A)" table))
          nil))))

(defun migrate-schema ()
  "Bring an existing table up to the current schema. Idempotent."
  (unless (column-exists-p "links" "accesses")
    (dbi:do-sql *connection*
      "ALTER TABLE links ADD COLUMN accesses INTEGER NOT NULL DEFAULT 0"))
  (ensure-accesses-table))

(defun ensure-schema ()
  (if (schema-exists-p)
      (migrate-schema)
      (reset-schema)))


;;; Helpers
(defun find-by-id (id)
  (dbi:fetch-all
   (dbi:execute
    (dbi:prepare *connection*
                 "SELECT * FROM links WHERE id = ?")
    (list id))))

(defun find-by-short-code (code)
  (dbi:fetch-all
   (dbi:execute
    (dbi:prepare *connection*
                 "SELECT * FROM links WHERE short_code = ?")
    (list code))))

(defun find-by-original-url (url)
  (dbi:fetch-all
   (dbi:execute
    (dbi:prepare *connection*
                 "SELECT * FROM links WHERE original_url = ?")
    (list url))))

(defun find-all-links (&key sort-by-accesses)
  (dbi:fetch-all
   (dbi:execute
    (dbi:prepare *connection*
                 (if sort-by-accesses
                     "SELECT * FROM links ORDER BY accesses DESC, id DESC LIMIT 50"
                     "SELECT * FROM links ORDER BY id DESC LIMIT 50")))))

(defun create-link (url &key (max-tries 5))
  "Insert URL with a random, unpredictable short code.
The short_code column is UNIQUE; on collision we retry with a fresh code.
The numeric id stays internal and is never exposed, so codes are not
enumerable."
  (loop repeat max-tries
        for short = (link-smasher.utils:random-base62)
        do (handler-case
               (progn
                 (dbi:do-sql *connection*
                   "INSERT INTO links (original_url, short_code) VALUES (?, ?)"
                   (list url short))
                 (return short))
             (dbi:<dbi-database-error> ()
               ;; UNIQUE collision on short_code -> loop and try a new code
               nil))
        finally
        (error "Could not generate a unique short code after ~A tries"
               max-tries)))

(defun increment-accesses (code)
  (dbi:do-sql *connection*
    "UPDATE links SET accesses = accesses + 1 WHERE short_code = ?"
    (list code)))

(defun record-access (link-id &key referrer-host user-agent (is-bot 0) country)
  (dbi:do-sql *connection*
    "INSERT INTO link_accesses (link_id, referrer_host, user_agent, is_bot, country)
     VALUES (?, ?, ?, ?, ?)"
    (list link-id referrer-host user-agent is-bot country)))

(defun find-accesses (link-id &key (limit 100))
  (dbi:fetch-all
   (dbi:execute
    (dbi:prepare *connection*
                 "SELECT * FROM link_accesses WHERE link_id = ?
                  ORDER BY accessed_at DESC, id DESC LIMIT ?")
    (list link-id limit))))

(defun access-totals (link-id)
  (first
   (dbi:fetch-all
    (dbi:execute
     (dbi:prepare *connection*
                  "SELECT COUNT(*) AS total,
                          COALESCE(SUM(is_bot), 0) AS bots
                   FROM link_accesses WHERE link_id = ?")
     (list link-id)))))

(defun access-counts-by (column link-id &key (limit 20))
  "COLUMN is matched against fixed literals, never interpolated from user input."
  (multiple-value-bind (col unknown-label)
      (cond ((string= column "referrer_host") (values "referrer_host" "(direct)"))
            ((string= column "country") (values "country" "(unknown)"))
            (t (error "Unsupported grouping column: ~A" column)))
    (dbi:fetch-all
     (dbi:execute
      (dbi:prepare *connection*
                   (format nil "SELECT COALESCE(~A, ?) AS label,
                                       COUNT(*) AS hits
                                FROM link_accesses WHERE link_id = ?
                                GROUP BY label ORDER BY hits DESC LIMIT ?" col))
      (list unknown-label link-id limit)))))

(defun prune-accesses (days)
  "Delete access events older than DAYS; 0 or less keeps everything."
  (if (and (integerp days) (plusp days))
      (dbi:do-sql *connection*
        "DELETE FROM link_accesses WHERE accessed_at < datetime('now', ?)"
        (list (format nil "-~D days" days)))
      0))

(defun delete-by-short-code (code)
  "Children go first: ON DELETE CASCADE needs the per-connection foreign_keys pragma."
  (dbi:do-sql *connection*
    "DELETE FROM link_accesses
     WHERE link_id IN (SELECT id FROM links WHERE short_code = ?)"
    (list code))
  (dbi:do-sql *connection*
    "DELETE FROM links WHERE short_code = ?"
    (list code)))

(defun get-original-link (short)
  (getf (first (find-by-short-code short))
        :|original_url|))
