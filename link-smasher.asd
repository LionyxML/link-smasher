(asdf:defsystem #:link-smasher
    :description "A link (URL) shortner / redicretor"
    :author "Rahul Martim Juliato"
    :license "MIT"
    :version "0.1.0"
    :depends-on (#:hunchentoot #:easy-routes #:djula #:cl-dbi #:dbd-sqlite3)
    :entry-point "link-smasher:main"
    :components
    ((:module "src"
              :components
              ((:file "packages")
               (:file  "utils"    :depends-on ("packages"))
               (:file "cli"       :depends-on ("packages"))
               (:file "db"        :depends-on ("packages"))
               (:file "webserver" :depends-on ("packages"))
               (:file "main"      :depends-on ("packages" "utils" "cli" "webserver" "db"))))))
