(in-package #:link-smasher.webserver)

;; Defvars
(defvar *server* nil
  "Server instance (Hunchentoot acceptor).")

(defvar *base-url* "/"
  "Base URL to use with generated link.")

(defvar *seconds* "3"
  "Seconds to wait before redirecting.")

(defvar *admin-user* "admin"
  "Username required to access the admin-only routes.")

(defvar *admin-password* nil
  "Password required to access the admin-only routes.
When NIL or empty, admin routes are closed (fail-closed).")

;; Parameters
(defparameter *www-directory*
  (asdf:system-relative-pathname
   :link-smasher
   "www/"))

(defparameter *template-directory*
  (asdf:system-relative-pathname
   :link-smasher
   "templates/"))

;; Helpers
(defun render (template-name &rest args)
  (apply
   #'djula:render-template*
   (djula:compile-template*
    (merge-pathnames template-name
                     *template-directory*))
   nil
   :title (getf link-smasher:*app* :name)
   :description (getf link-smasher:*app* :description)
   :version (getf link-smasher:*app* :version)
   args))

(defun valid-url-p (url)
  (and (stringp url)
       (or (uiop:string-prefix-p "http://" url)
           (uiop:string-prefix-p "https://" url))))

(defun constant-time-string= (a b)
  "Compare two strings in time independent of where they first differ.
Reduces timing-oracle leakage on credential checks. Returns NIL unless
both are strings of equal length with identical contents."
  (and (stringp a) (stringp b)
       (= (length a) (length b))
       (loop with diff = 0
             for ca across a
             for cb across b
             do (setf diff (logior diff (logxor (char-code ca) (char-code cb))))
             finally (return (zerop diff)))))

(defun admin-authorized-p ()
  "True when the request carries valid admin Basic-Auth credentials.
Fail-closed: if no admin password is configured, always returns NIL."
  (and (stringp *admin-password*)
       (plusp (length *admin-password*))
       (multiple-value-bind (user password) (hunchentoot:authorization)
         (and (constant-time-string= user *admin-user*)
              (constant-time-string= password *admin-password*)))))

(defun @require-admin (next)
  "easy-routes decorator: gate a route behind admin Basic Auth.
Calls NEXT when authorized, otherwise responds 401 with WWW-Authenticate."
  (if (admin-authorized-p)
      (funcall next)
      (hunchentoot:require-authorization "LinkSmasher Admin")))

;;; Routes
(easy-routes:defroute root ("/") ()
                      (render "index.html"))

(easy-routes:defroute register-submit ("/register" :method :post) ()
                      (let ((url (hunchentoot:parameter "url")))
                        (if (valid-url-p url)
                            (let ((short (format nil "~Ar/~A" *base-url*
                                                 (link-smasher.db:create-link url))))
                              (render "result.html" :short short))
                            (render "register.html" :error "URL must start with http:// or https://"))))

(easy-routes:defroute register-page ("/register" :method :get) ()
                      (render "register.html"))

(easy-routes:defroute list-urls ("/list" :decorators (@require-admin)) ()
                      (let ((all (link-smasher.db:find-all-links)))
                        (render "list.html" :all-links all)))

(easy-routes:defroute redirect ("/r/:short") (&path (short 'string))
                      (let ((long (link-smasher.db:get-original-link short)))
                        (render "redirect.html" :long long :secs *seconds*)))

;;; Server
(defun start-server (&key port base-url seconds admin-user admin-password)
  (let ((port (etypecase port
                (integer port)
                (string (parse-integer port))))
        (seconds (etypecase seconds
                   (integer seconds)
                   (string (parse-integer seconds)))))

    (setf *base-url* base-url)
    (setf *seconds* seconds)
    (when admin-user
      (setf *admin-user* admin-user))
    (setf *admin-password* admin-password)

    (format t "~&Starting the web server on port ~a~&" port)
    (force-output)

    (pushnew
     (hunchentoot:create-folder-dispatcher-and-handler "/" *www-directory*)
     hunchentoot:*dispatch-table*
     :test #'equal)

    (setf *server*
          (make-instance 'easy-routes:easy-routes-acceptor
                         :port port))

    (hunchentoot:start *server*)))

(defun stop-server ()
  (hunchentoot:stop *server*))
