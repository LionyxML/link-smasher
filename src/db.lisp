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

(defun reset-schema ()
  (dbi:do-sql *connection* "DROP TABLE IF EXISTS links")
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
"))

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
      "ALTER TABLE links ADD COLUMN accesses INTEGER NOT NULL DEFAULT 0")))

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

(defun find-all-links ()
  (dbi:fetch-all
   (dbi:execute
    (dbi:prepare *connection*
                 "SELECT * FROM links ORDER BY id DESC LIMIT 50"))))

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

(defun delete-by-short-code (code)
  (dbi:do-sql *connection*
    "DELETE FROM links WHERE short_code = ?"
    (list code)))

(defun get-original-link (short)
  (getf (first (find-by-short-code short))
        :|original_url|))
