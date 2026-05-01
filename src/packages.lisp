(defpackage #:link-smasher
  (:use #:cl)
  (:export
   #:main
   #:*app*))

(defpackage #:link-smasher.cli
  (:use #:cl)
  (:export
   #:parse-args
   #:print-app-help
   #:print-app-version))

(defpackage #:link-smasher.utils
  (:use #:cl)
  (:export #:encode-base62))

(defpackage #:link-smasher.webserver
  (:use #:cl)
  (:export
   #:start-server
   #:stop-server))

(defpackage #:link-smasher.db
  (:use #:cl)
  (:export
   #:connect
   #:disconnect
   #:reset-schema
   #:ensure-schema
   #:insert-url
   #:find-all-links
   #:find-by-id
   #:find-by-short-code
   #:find-by-original-url
   #:create-link
   #:get-original-link))
