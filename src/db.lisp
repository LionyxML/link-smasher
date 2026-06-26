(in-package #:link-smasher.db)

(defvar *connection* nil)

;;; Connection
(defun connect (database-path)
  (setf *connection*
        (dbi:connect :sqlite3
                     :database-name database-path)))

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
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
)
"))

(defun ensure-schema ()
  (unless (schema-exists-p)
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

(defun get-original-link (short)
  (getf (first (find-by-short-code short))
        :|original_url|))
