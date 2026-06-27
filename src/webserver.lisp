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

(defvar *direct-redirect* nil
  "When true, /r/:short auto-redirects (meta-refresh, honoring *seconds*).
When NIL (default), the visitor sees the destination and must click through.")

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

(defun parse-ipv4-octets (host)
  "Return a list of 4 integers if HOST is a dotted-quad IPv4 literal, else NIL."
  (let ((parts (uiop:split-string host :separator ".")))
    (when (= (length parts) 4)
      (handler-case
          (let ((octets (mapcar (lambda (p)
                                  (multiple-value-bind (n end)
                                      (parse-integer p :junk-allowed nil)
                                    (declare (ignore end))
                                    n))
                                parts)))
            (when (every (lambda (o) (<= 0 o 255)) octets)
              octets))
        (error () nil)))))

(defun private-or-local-host-p (host)
  "True when HOST is a loopback / private / link-local target that should not
be shortened (anti-abuse / anti-SSRF). Covers localhost, the IPv4 private
and link-local ranges, and common IPv6 loopback/ULA/link-local literals."
  (when (stringp host)
    (let* ((h (string-downcase (string-trim "[]" host)))
           (octets (parse-ipv4-octets h)))
      (cond
        ((string= h "localhost") t)
        (octets
         (destructuring-bind (a b &rest rest) octets
           (declare (ignore rest))
           (or (= a 0)                       ; 0.0.0.0/8
               (= a 127)                     ; loopback
               (= a 10)                      ; private
               (and (= a 172) (<= 16 b 31))  ; private
               (and (= a 192) (= b 168))     ; private
               (and (= a 169) (= b 254)))))  ; link-local
        ;; IPv6 literals
        ((string= h "::1") t)                ; loopback
        ((or (uiop:string-prefix-p "fc" h)   ; fc00::/7 (ULA)
             (uiop:string-prefix-p "fd" h)) t)
        ((or (uiop:string-prefix-p "fe8" h)  ; fe80::/10 (link-local)
             (uiop:string-prefix-p "fe9" h)
             (uiop:string-prefix-p "fea" h)
             (uiop:string-prefix-p "feb" h)) t)
        (t nil)))))

(defun safe-redirect-url-p (url)
  "True when URL is a public http(s) address safe to store and redirect to.
Rejects non-http(s) schemes, missing host, embedded credentials
(user:pass@host), and private/loopback/link-local hosts."
  (and (stringp url)
       (handler-case
           (let* ((u (quri:uri url))
                  (scheme (quri:uri-scheme u))
                  (host (quri:uri-host u))
                  (userinfo (quri:uri-userinfo u)))
             (and (member scheme '("http" "https") :test #'string-equal)
                  host
                  (plusp (length host))
                  (null userinfo)
                  (not (private-or-local-host-p host))))
         (error () nil))))

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
                        (if (safe-redirect-url-p url)
                            (let ((short (format nil "~Ar/~A" *base-url*
                                                 (link-smasher.db:create-link url))))
                              (render "result.html" :short short))
                            (render "register.html"
                                    :error "URL is not allowed. Must be a public http:// or https:// address."))))

(easy-routes:defroute register-page ("/register" :method :get) ()
                      (render "register.html"))

(easy-routes:defroute list-urls ("/list" :decorators (@require-admin)) ()
                      (let ((all (link-smasher.db:find-all-links)))
                        (render "list.html" :all-links all)))

(easy-routes:defroute redirect ("/r/:short") (&path (short 'string))
                      (let ((long (link-smasher.db:get-original-link short)))
                        (cond
                          ((null long)
                           (setf (hunchentoot:return-code*)
                                 hunchentoot:+http-not-found+)
                           (render "not-found.html"))
                          (*direct-redirect*
                           (render "redirect.html" :long long :secs *seconds* :auto t))
                          (t
                           (render "redirect.html" :long long :auto nil)))))

;;; Server
(defun start-server (&key port base-url seconds admin-user admin-password
                          direct-redirect)
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
    (setf *direct-redirect* direct-redirect)

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
