(in-package #:link-smasher.cli)

(defparameter *options*
  '(("-p"        . :port)
    ("--port"    . :port)
    ("-d"        . :db)
    ("--db"      . :db)
    ("-b"        . :base-url)
    ("--base"    . :base-url)
    ("-s"        . :seconds)
    ("--seconds" . :seconds)
    ("-h"        . :help)
    ("--help"    . :help)
    ("-v"        . :version)
    ("--version" . :version)))

(defun app-prop (key)
  (getf link-smasher:*app* key))

(defun option-keyword (arg)
  (cdr (assoc arg *options* :test #'string=)))

(defun print-app-version ()
  (write-line (app-prop :version)))

(defun print-app-help ()
  (format t
          "~2%
~A [version: ~A]

~A

Usage:
  ~A [options]

Examples:
  ~A --base http://short.ner --port 6969 --db db.sqlite3 --seconds 4

  BASE_URL=http://short.ner PORT=6969 DB=db.sqlite3 SECONDS=4 ~A

Options:
  -b, --base      Set app base URL
  -d, --db        Set SQLite database file
  -h, --help      Show help
  -p, --port      Set web server port
  -s, --seconds   Seconds before redirect
  -v, --version   Show version

"
          (app-prop :name)
          (app-prop :version)
          (app-prop :description)
          (app-prop :bin-name)
          (app-prop :bin-name)
          (app-prop :bin-name)))

(defun parse-args (args)
  (let ((result '()))
    (loop while args
          for arg = (pop args)
          for option = (option-keyword arg)
          do (case option
               (:help
                (return-from parse-args
                  (values :help nil)))

               (:version
                (return-from parse-args
                  (values :version nil)))

               ((:port :db :base-url :seconds)
                (if args
                    (push (cons option (pop args)) result)
                    (return-from parse-args
                      (values :error
                              (format nil "Missing value for ~A" arg)))))

               (otherwise
                (return-from parse-args
                  (values :error
                          (format nil "Unknown option: ~A" arg))))))

    (values :ok (nreverse result))))
