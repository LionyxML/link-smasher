(in-package #:link-smasher.webserver)

;; Defvars
(defvar *server* nil
  "Server instance (Hunchentoot acceptor).")

(defvar *base-url* "/"
  "Base URL to use with generated link.")

(defvar *seconds* "3"
  "Seconds to wait before redirecting.")

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

(easy-routes:defroute list-urls ("/list") ()
                      (let ((all (link-smasher.db:find-all-links)))
                        (render "list.html" :all-links all)))

(easy-routes:defroute redirect ("/r/:short") (&path (short 'string))
                      (let ((long (link-smasher.db:get-original-link short)))
                        (render "redirect.html" :long long :secs *seconds*)))

;;; Server
(defun start-server (&key port base-url seconds)
  (let ((port (etypecase port
                (integer port)
                (string (parse-integer port))))
        (seconds (etypecase seconds
                (integer seconds)
                (string (parse-integer seconds)))))

    (setf *base-url* base-url)
    (setf *seconds* seconds)

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
