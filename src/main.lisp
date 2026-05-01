(in-package #:link-smasher)

(defparameter *app*
  '(:name        "LinkSmasher"
    :bin-name    "link-smasher"
    :version     "0.1.0"
    :description "Register long URLs and generate smashed links."))

(defun option-value (key options)
  (cdr (assoc key options)))

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
                                 3)))

               (print-banner port db base-url)

               ;; DB Connection
               (link-smasher.db:connect db)
               (link-smasher.db:ensure-schema)

               ;; WEB Server Start
               (link-smasher.webserver:start-server
                :port port
                :base-url base-url
                :seconds seconds)

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
