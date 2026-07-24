(in-package #:link-smasher)

(defparameter *app*
  (list :name        "LinkSmasher"
        :bin-name    "link-smasher"
        :version     (asdf:component-version (asdf:find-system :link-smasher))
        :description "Register long URLs and generate smashed (shorter) links."
        :repository  "https://github.com/LionyxML/link-smasher"))

(defun option-value (key options)
  (cdr (assoc key options)))

(defun env-truthy-p (name)
  "True when environment variable NAME is set to a truthy string."
  (let ((v (uiop:getenv name)))
    (and v (member (string-downcase v)
                   '("1" "true" "yes" "on")
                   :test #'string=))))

(defun env-falsy-p (name)
  "True when environment variable NAME is set to a falsy string.
Used for opt-out of behaviour that is on by default."
  (let ((v (uiop:getenv name)))
    (and v (member (string-downcase v)
                   '("0" "false" "no" "off")
                   :test #'string=))))

(defun print-banner (port db base-url)
  (format t "
>>>                      Ready to SMASH!
>>>           0 _____     /
>>>            X_____\\
>>>    .-^-.  ||_| |_||  .-^-.
>>>   /_\\_/_\\_|  |_|  |_/_\\_/_\\
>>>   ||(_)| __\\_____/__ |(_)||
>>>   \\/| | |::|\\```/|::| | |\\/
>>>   /`---_|::|-+-+-|::|_---'\\
>>>  / /  \\ |::|-|-|-|::| /  \\ \\
>>> /_/   /|`--'-+-+-`--'|\\   \\_\\
>>>
>>>
>>> Port     : ~A
>>> Database : ~A
>>> Domain   : ~A

" port db base-url))

(defun main ()
  (let ((args (uiop:command-line-arguments)))
    (multiple-value-bind (status data)
        (link-smasher.cli:parse-args args)

      (case status
        (:version
         (link-smasher.cli:print-app-version)
         (finish-output)
         (sb-ext:exit :code 0))

        (:help
         (link-smasher.cli:print-app-help)
         (finish-output)
         (sb-ext:exit :code 0))

        (:error
         (format *error-output*
                 "~%Error: ~A~2%Use --help for usage information.~%"
                 data)
         (finish-output *error-output*)
         (sb-ext:exit :code 1))

        (:ok
         (handler-case
             (let ((port (or (option-value :port data)
                             (uiop:getenv "PORT")
                             3800))
                   (db   (or (option-value :db data)
                             (uiop:getenv "DB")
                             "db.sqlite3"))
                   (base-url (or (option-value :base-url data)
                                 (uiop:getenv "BASE_URL")
                                 "http://localhost:3800/"))
                   (seconds  (or (option-value :seconds data)
                                 (uiop:getenv "SECONDS")
                                 3))
                   (admin-user (or (uiop:getenv "ADMIN_USER")
                                   "admin"))
                   (admin-password (uiop:getenv "ADMIN_PASSWORD"))
                   (direct-redirect (or (option-value :direct data)
                                        (env-truthy-p "DIRECT_REDIRECT")))
                   (rate-limit-enabled (not (or (option-value :no-rate-limit data)
                                                (env-falsy-p "RATE_LIMIT"))))
                   (rate-limit-max (or (option-value :rate-limit-max data)
                                       (uiop:getenv "RATE_LIMIT_MAX")
                                       10))
                   (rate-limit-window (or (option-value :rate-limit-window data)
                                          (uiop:getenv "RATE_LIMIT_WINDOW")
                                          60))
                   (max-body (or (option-value :max-body data)
                                 (uiop:getenv "MAX_BODY")
                                 8192))
                   (trust-proxy (or (option-value :trust-proxy data)
                                    (env-truthy-p "TRUST_PROXY")))
                   (max-threads (or (option-value :max-threads data)
                                    (uiop:getenv "MAX_THREADS")
                                    100))
                   (accept-backlog (or (option-value :accept-backlog data)
                                       (uiop:getenv "ACCEPT_BACKLOG")
                                       200))
                   (analytics-retention-days
                    (or (option-value :analytics-retention-days data)
                        (uiop:getenv "ANALYTICS_RETENTION_DAYS")
                        90))
                   (list-page-size (or (option-value :list-page-size data)
                                       (uiop:getenv "LIST_PAGE_SIZE")
                                       50)))

               (print-banner port db base-url)

               ;; DB Connection
               (link-smasher.db:connect db)
               (link-smasher.db:ensure-schema)

               (let ((days (if (stringp analytics-retention-days)
                               (or (parse-integer analytics-retention-days
                                                  :junk-allowed t)
                                   90)
                               analytics-retention-days)))
                 (when (plusp days)
                   (link-smasher.db:prune-accesses days)))

               ;; WEB Server Start
               (link-smasher.webserver:start-server
                :port port
                :base-url base-url
                :seconds seconds
                :admin-user admin-user
                :admin-password admin-password
                :direct-redirect direct-redirect
                :rate-limit-enabled rate-limit-enabled
                :rate-limit-max rate-limit-max
                :rate-limit-window rate-limit-window
                :max-body max-body
                :trust-proxy trust-proxy
                :max-threads max-threads
                :accept-backlog accept-backlog
                :analytics-retention-days analytics-retention-days
                :list-page-size list-page-size)

               ;; Block main thread until signal received
               (let ((shutdown (sb-thread:make-semaphore :name "shutdown")))
                 (sb-sys:enable-interrupt sb-unix:sigterm
                                          (lambda (sig info ctx)
                                            (declare (ignore sig info ctx))
                                            (sb-thread:signal-semaphore shutdown)))
                 (sb-sys:enable-interrupt sb-unix:sigint
                                          (lambda (sig info ctx)
                                            (declare (ignore sig info ctx))
                                            (sb-thread:signal-semaphore shutdown)))
                 (sb-thread:wait-on-semaphore shutdown))

               ;; Ordered shutdown
               (link-smasher.webserver:stop-server)
               (link-smasher.db:disconnect)
               (sb-ext:exit :code 0))

           (error (e)
             (format *error-output*
                     "~%Runtime error: ~A~%" e)
             (finish-output *error-output*)
             (sb-ext:exit :code 1))))))))
