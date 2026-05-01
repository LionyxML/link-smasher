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


;;; Core insert
(defun insert-url (url)
  (dbi:do-sql *connection*
    "INSERT INTO links (original_url) VALUES (?)"
    (list url)))


;;; Last insert id
(defun last-insert-id ()
  (getf (first
         (dbi:fetch-all
          (dbi:execute
           (dbi:prepare *connection*
                        "SELECT last_insert_rowid() AS id")
           nil)))
        :|id|))


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

(defun create-link (url)
  ;; 1. insert row
  (insert-url url)

  ;; 2. get numeric id
  (let* ((id (last-insert-id))
         (short (link-smasher.utils:encode-base62 id)))

    ;; 3. store short code
    (dbi:do-sql *connection*
      "UPDATE links SET short_code = ? WHERE id = ?"
      (list short id))

    ;; 4. return short code
    short))

(defun get-original-link (short)
  (getf (first (find-by-short-code short))
        :|original_url|))
