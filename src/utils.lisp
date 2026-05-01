(in-package #:link-smasher.utils)

(defparameter *base62-alphabet*
  "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

(defun encode-base62 (n)
  (when (stringp n)
    (setf n (parse-integer n)))

  (labels ((rec (n acc)
             (if (< n 62)
                 (cons (char *base62-alphabet* n) acc)
                 (rec (floor n 62)
                      (cons (char *base62-alphabet* (mod n 62)) acc)))))
    (coerce (rec n nil) 'string)))
