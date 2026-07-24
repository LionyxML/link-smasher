(in-package #:link-smasher.cli)

(defparameter *options*
  '(("-p"                         . :port)
    ("--port"                     . :port)
    ("-d"                         . :db)
    ("--db"                       . :db)
    ("-b"                         . :base-url)
    ("--base"                     . :base-url)
    ("-s"                         . :seconds)
    ("--seconds"                  . :seconds)
    ("--direct"                   . :direct)
    ("--no-rate-limit"            . :no-rate-limit)
    ("--rate-limit-max"           . :rate-limit-max)
    ("--rate-limit-window"        . :rate-limit-window)
    ("--max-body"                 . :max-body)
    ("--trust-proxy"              . :trust-proxy)
    ("--analytics-retention-days" . :analytics-retention-days)
    ("--list-page-size"           . :list-page-size)
    ("-h"                         . :help)
    ("--help"                     . :help)
    ("-v"                         . :version)
    ("--version"                  . :version)))

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
  -b, --base                Set app base URL
  -d, --db                  Set SQLite database file
  -h, --help                Show help
  -p, --port                Set web server port
  -s, --seconds             Seconds before redirect
      --direct              Auto-redirect on /r/ (meta-refresh,
                            honors --seconds).
                            Default is a safe click-through interstitial.
      --no-rate-limit       Disable per-IP rate limiting (on by default).
      --rate-limit-max N    Max POST /register per IP per window (default: 10).
      --rate-limit-window S Rate-limit window in seconds (default: 60).
      --max-body BYTES      Max request body size (default: 8192).
      --trust-proxy         Read client IP from X-Forwarded-For. Enable ONLY
                            behind a trusted reverse proxy (e.g. Caddy/nginx).
      --analytics-retention-days N
                            Delete /list analytics events older than N days
                            (default: 90). 0 keeps them forever.
      --list-page-size N    Links shown per page on /list (default: 50).
  -v, --version             Show version

Environment (env-only):
  ADMIN_USER        Username for the protected /list page (default: admin)
  ADMIN_PASSWORD    Password for /list. If unset, /list stays closed (401).
                    Basic Auth is unencrypted; serve it only behind HTTPS.

Environment (switch alternatives):
  DIRECT_REDIRECT   Same as --direct when set to 1/true/yes/on.
  RATE_LIMIT        Set to 0/false/no/off to disable rate limiting (default: on).
  RATE_LIMIT_MAX    Same as --rate-limit-max.
  RATE_LIMIT_WINDOW Same as --rate-limit-window.
  MAX_BODY          Same as --max-body.
  TRUST_PROXY       Same as --trust-proxy when set to 1/true/yes/on.
  ANALYTICS_RETENTION_DAYS
                    Same as --analytics-retention-days.
  LIST_PAGE_SIZE    Same as --list-page-size.

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

               ((:direct :no-rate-limit :trust-proxy)
                (push (cons option t) result))

               ((:port :db :base-url :seconds
                       :rate-limit-max :rate-limit-window :max-body
                       :analytics-retention-days :list-page-size)
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
