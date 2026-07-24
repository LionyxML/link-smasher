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

(defvar *rate-limit-enabled* t
  "When true (default), POST /register is rate limited per client IP.")

(defvar *rate-limit-max* 10
  "Max allowed POST /register requests per client IP within *rate-limit-window*.")

(defvar *rate-limit-window* 60
  "Length of the rate-limit sliding window, in seconds.")

(defvar *max-body-bytes* 8192
  "Maximum accepted request body size (Content-Length) in bytes.")

(defvar *trust-proxy* nil
  "When true, take the client IP from the X-Forwarded-For header instead of the
socket peer. Enable ONLY when running behind a trusted reverse proxy (e.g. Caddy)
that sets the header; otherwise clients could spoof it to dodge the rate limit.")

(defvar *analytics-retention-days* 90
  "Access events older than this many days are deleted. 0 keeps them forever.")

(defvar *prune-interval* 3600
  "Minimum seconds between retention sweeps.")

(defvar *last-prune* 0
  "Universal time of the last retention sweep.")

(defvar *prune-lock* (sb-thread:make-mutex :name "prune"))

(defvar *rate-limit-table* (make-hash-table :test #'equal)
  "Maps client IP (string) -> list of request timestamps (universal-time).")

(defvar *rate-limit-lock* (sb-thread:make-mutex :name "rate-limit")
  "Guards *rate-limit-table* (Hunchentoot serves one thread per request).")

;; Parameters
(defparameter *www-directory*
  (asdf:system-relative-pathname
   :link-smasher
   "www/"))

(defparameter *template-directory*
  (asdf:system-relative-pathname
   :link-smasher
   "templates/"))

(defparameter *template-files*
  '("index.html" "register.html" "result.html" "list.html" "stats.html"
    "redirect.html" "not-found.html" "rate-limited.html" "about.html"
    "unauthorized.html" "error.html")
  "Templates rendered by routes; precompiled at startup. (layout.html is the
base and gets pulled in when its children compile.)")

;; Helpers
(defvar *template-cache* (make-hash-table :test #'equal)
  "Maps template name (string) -> compiled djula template.
Compiling on every request races under Hunchentoot's thread-per-request model
and is slow; compile once, reuse.")

(defvar *template-cache-lock* (sb-thread:make-mutex :name "template-cache"))

(defun compiled-template (template-name)
  "Return the compiled template for TEMPLATE-NAME, compiling and caching on
first use. Guarded so concurrent first hits compile only once."
  (or (gethash template-name *template-cache*)
      (sb-thread:with-mutex (*template-cache-lock*)
        (or (gethash template-name *template-cache*)
            (setf (gethash template-name *template-cache*)
                  (djula:compile-template*
                   (merge-pathnames template-name *template-directory*)))))))

(defun render (template-name &rest args)
  (apply
   #'djula:render-template*
   (compiled-template template-name)
   nil
   :title (getf link-smasher:*app* :name)
   :description (getf link-smasher:*app* :description)
   :version (getf link-smasher:*app* :version)
   :repository (getf link-smasher:*app* :repository)
   :base-url *base-url*
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

(defparameter *bot-user-agent-markers*
  '("bot" "crawler" "spider" "slurp" "preview" "facebookexternalhit"
    "whatsapp" "telegram" "slack" "discord" "twitter" "embedly" "skype"
    "curl" "wget" "python-requests" "go-http-client" "headless" "monitor")
  "Heuristic: UAs are self-reported, so this catches honest previewers, not liars.")

(defun bot-user-agent-p (ua)
  (and (stringp ua)
       (let ((u (string-downcase ua)))
         (some (lambda (marker) (search marker u)) *bot-user-agent-markers*))))

(defun referrer-host ()
  "Host only: a full referrer URL can carry paths and tokens from the referring page."
  (let ((ref (hunchentoot:header-in* :referer)))
    (when (and (stringp ref) (plusp (length ref)))
      (handler-case
          (let ((host (quri:uri-host (quri:uri ref))))
            (when (and host (plusp (length host))) host))
        (error () nil)))))

(defun maybe-prune-accesses ()
  "Sweep at most once per *prune-interval*, driven by traffic instead of a timer
thread. Errors are swallowed so a failed sweep never breaks the request."
  (when (plusp *analytics-retention-days*)
    (let ((now (get-universal-time)))
      (when (> (- now *last-prune*) *prune-interval*)
        (sb-thread:with-mutex (*prune-lock*)
          (when (> (- now *last-prune*) *prune-interval*)
            (setf *last-prune* now)
            (ignore-errors
              (link-smasher.db:prune-accesses *analytics-retention-days*))))))))

(defun visitor-country ()
  "Country from CF-IPCountry, only when *trust-proxy* is set — without a proxy
stripping it, any client can forge the header. XX (unknown) and T1 (Tor) are dropped."
  (when *trust-proxy*
    (let ((cc (hunchentoot:header-in* :cf-ipcountry)))
      (when (and (stringp cc)
                 (= (length cc) 2)
                 (every #'alpha-char-p cc)
                 (not (string-equal cc "XX"))
                 (not (string-equal cc "T1")))
        (string-upcase cc)))))

(defun booleanize-bot-flag (rows)
  "Djula's truth test treats any non-sequence as true, so a raw 0 would read as a bot."
  (mapcar (lambda (row)
            (let ((copy (copy-list row)))
              (setf (getf copy :|is_bot|)
                    (and (eql (getf row :|is_bot|) 1) t))
              copy))
          rows))

(defun truncated (string limit)
  (when (stringp string)
    (if (> (length string) limit) (subseq string 0 limit) string)))

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

(defun rate-limit-check (ip)
  "Record a request from IP and decide whether it is allowed.
Sliding window: keep only timestamps within the last *rate-limit-window*
seconds; allow (and record) while fewer than *rate-limit-max* remain.
Returns (values allowed-p retry-after-seconds)."
  (let ((now (get-universal-time))
        (window *rate-limit-window*)
        (max *rate-limit-max*))
    (sb-thread:with-mutex (*rate-limit-lock*)
      (let ((recent (remove-if (lambda (ts) (< ts (- now window)))
                               (gethash ip *rate-limit-table*))))
        (cond
          ((< (length recent) max)
           (setf (gethash ip *rate-limit-table*) (cons now recent))
           (values t 0))
          (t
           ;; Denied. Drop the recorded (but unused) entry back so a rejected
           ;; request does not extend the window, and report when the oldest
           ;; in-window stamp ages out.
           (setf (gethash ip *rate-limit-table*) recent)
           (values nil (max 1 (- (+ (first (last recent)) window) now)))))))))

(defun client-ip ()
  "The IP used for rate limiting. By default the real socket peer
(hunchentoot:remote-addr*), which cannot be spoofed. When *trust-proxy* is on,
use hunchentoot:real-remote-addr, which reads X-Forwarded-For — correct only
behind a trusted reverse proxy (otherwise the client controls the header)."
  (if *trust-proxy*
      (hunchentoot:real-remote-addr)
      (hunchentoot:remote-addr*)))

(defun @rate-limit (next)
  "easy-routes decorator: per-IP rate limit. On denial responds 429 with a
Retry-After header and a friendly page; otherwise calls NEXT. See CLIENT-IP for
how the client address is resolved (socket peer, or X-Forwarded-For behind a
trusted proxy when --trust-proxy / TRUST_PROXY is set)."
  (if *rate-limit-enabled*
      (multiple-value-bind (allowed retry-after)
          (rate-limit-check (client-ip))
        (if allowed
            (funcall next)
            (progn
              (setf (hunchentoot:return-code*) 429
                    (hunchentoot:header-out :retry-after) retry-after)
              (render "rate-limited.html" :retry retry-after))))
      (funcall next)))

(defun @limit-body (next)
  "easy-routes decorator: reject requests whose Content-Length exceeds
*max-body-bytes* with 413. A missing length (e.g. chunked) is allowed through;
browser form POSTs always send Content-Length."
  (let* ((raw (hunchentoot:header-in* :content-length))
         (len (and raw (parse-integer raw :junk-allowed t))))
    (if (and len (> len *max-body-bytes*))
        (progn
          (setf (hunchentoot:return-code*) 413
                (hunchentoot:content-type*) "text/plain")
          "Request body too large.")
        (funcall next))))

;;; Routes
(easy-routes:defroute root ("/") ()
                      (render "index.html"))

(easy-routes:defroute register-submit
    ("/register" :method :post :decorators (@limit-body @rate-limit)) ()
    (let ((url (hunchentoot:parameter "url")))
      (if (safe-redirect-url-p url)
          (let ((short (format nil "~Ar/~A" *base-url*
                               (link-smasher.db:create-link url))))
            (render "result.html" :short short))
          (render "register.html"
                  :error "URL is not allowed. Must be a public http:// or https:// address."))))

(easy-routes:defroute register-page ("/register" :method :get) ()
                      (render "register.html"))

(easy-routes:defroute about-page ("/about") ()
                      (render "about.html"))

(defvar *list-page-size* 50
  "Number of links shown per page on /list.")

(easy-routes:defroute list-urls ("/list" :decorators (@require-admin)) ()
                      (let* ((sort-desc (string= (or (hunchentoot:parameter "sort") "") "desc"))
                             (total (link-smasher.db:count-links))
                             (size *list-page-size*)
                             (pages (max 1 (ceiling total size)))
                             (page (min pages (max 1 (or (parse-integer
                                                          (or (hunchentoot:parameter "page") "1")
                                                          :junk-allowed t)
                                                         1))))
                             (offset (* (1- page) size))
                             (all (link-smasher.db:find-all-links
                                   :sort-by-accesses sort-desc
                                   :limit size :offset offset))
                             (shown (length all)))
                        (render "list.html"
                                :all-links all :sort-desc sort-desc
                                :total total :page page :pages pages
                                :from (if (zerop shown) 0 (1+ offset))
                                :to (+ offset shown)
                                :prev-page (when (> page 1) (1- page))
                                :next-page (when (< page pages) (1+ page)))))

(easy-routes:defroute link-stats
    ("/list/stats/:short" :decorators (@require-admin)) (&path (short 'string))
    (let ((row (first (link-smasher.db:find-by-short-code short))))
      (if (null row)
          (progn
            (setf (hunchentoot:return-code*) hunchentoot:+http-not-found+)
            (render "not-found.html"))
          (let ((id (getf row :|id|)))
            (render "stats.html"
                    :link row
                    :totals (link-smasher.db:access-totals id)
                    :referrers (link-smasher.db:access-counts-by "referrer_host" id)
                    :countries (link-smasher.db:access-counts-by "country" id)
                    :retention-days (when (plusp *analytics-retention-days*)
                                      *analytics-retention-days*)
                    :recent (booleanize-bot-flag
                             (link-smasher.db:find-accesses id :limit 50)))))))

(easy-routes:defroute delete-url
    ("/list/delete" :method :post :decorators (@limit-body @require-admin)) ()
    (let ((short (hunchentoot:parameter "short_code")))
      (when short
        (link-smasher.db:delete-by-short-code short))
      (hunchentoot:redirect "/list")))

(easy-routes:defroute redirect ("/r/:short") (&path (short 'string))
                      (let* ((row (first (link-smasher.db:find-by-short-code short)))
                             (long (getf row :|original_url|)))
                        (when row
                          (let ((bot (bot-user-agent-p
                                      (hunchentoot:header-in* :user-agent))))
                            ;; Bots get an event but not a count.
                            (unless bot
                              (link-smasher.db:increment-accesses short))
                            (link-smasher.db:record-access
                             (getf row :|id|)
                             :referrer-host (referrer-host)
                             :user-agent (truncated
                                          (hunchentoot:header-in* :user-agent) 255)
                             :is-bot (if bot 1 0)
                             :country (visitor-country))
                            (maybe-prune-accesses)))
                        (cond
                          ((null long)
                           (setf (hunchentoot:return-code*)
                                 hunchentoot:+http-not-found+)
                           (render "not-found.html"))
                          (*direct-redirect*
                           (render "redirect.html" :long long :short short
                                   :secs *seconds* :auto t))
                          (t
                           (render "redirect.html" :long long :short short
                                   :auto nil)))))

;;; Server
(defclass smasher-acceptor (easy-routes:easy-routes-acceptor) ()
  (:documentation "Routing acceptor that serves our own templates for the
status pages Hunchentoot would otherwise generate itself (404, 401, ...)."))

(defmethod hunchentoot:acceptor-status-message
    ((acceptor smasher-acceptor) status-code &key &allow-other-keys)
  (setf (hunchentoot:content-type*) "text/html; charset=utf-8")
  (case status-code
    (404 (render "not-found.html"))
    (401 (render "unauthorized.html"))
    (t (render "error.html"
               :status status-code
               :reason (hunchentoot:reason-phrase status-code)))))

(defun start-server (&key port base-url seconds admin-user admin-password
                       direct-redirect (rate-limit-enabled t)
                       rate-limit-max rate-limit-window max-body
                       trust-proxy max-threads accept-backlog
                       analytics-retention-days list-page-size)
  (flet ((as-int (v default)
           (etypecase v
             (null default)
             (integer v)
             (string (parse-integer v)))))
    (let ((port (as-int port nil))
          (seconds (as-int seconds nil))
          (max-threads (as-int max-threads 100))
          (accept-backlog (as-int accept-backlog 200)))

      (setf *base-url* base-url)
      (setf *seconds* seconds)
      (when admin-user
        (setf *admin-user* admin-user))
      (setf *admin-password* admin-password)
      (setf *direct-redirect* direct-redirect)
      (setf *rate-limit-enabled* rate-limit-enabled)
      (setf *rate-limit-max* (as-int rate-limit-max 10))
      (setf *rate-limit-window* (as-int rate-limit-window 60))
      (setf *max-body-bytes* (as-int max-body 8192))
      (setf *trust-proxy* trust-proxy)
      (setf *analytics-retention-days* (max 0 (as-int analytics-retention-days 90)))
      (setf *list-page-size* (max 1 (as-int list-page-size 50)))

      (format t "~&Starting the web server on port ~a~&" port)
      (force-output)

      (pushnew
       (hunchentoot:create-folder-dispatcher-and-handler "/" *www-directory*)
       hunchentoot:*dispatch-table*
       :test #'equal)

      ;; Precompile templates now (single-threaded) so no request thread hits a
      ;; cold cache and races the first compile.
      (dolist (tpl *template-files*)
        (compiled-template tpl))

      (setf *server*
            (make-instance 'smasher-acceptor
                           :port port
                           :taskmaster
                           (make-instance 'hunchentoot:one-thread-per-connection-taskmaster
                                          :max-thread-count max-threads
                                          :max-accept-count (+ max-threads accept-backlog))))

      (hunchentoot:start *server*))))

(defun stop-server ()
  (hunchentoot:stop *server*))
