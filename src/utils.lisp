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

(defun random-base62 (&optional (length 7))
  "Generate an unpredictable LENGTH-char base62 string from OS entropy.
Reads bytes from /dev/urandom; rejection-samples to avoid modulo bias
(256 is not a multiple of 62, so bytes >= 248 are discarded)."
  (with-open-file (urandom "/dev/urandom" :element-type '(unsigned-byte 8))
    (let ((out (make-string length)))
      (dotimes (i length out)
        (let ((byte (read-byte urandom)))
          (loop while (>= byte 248)
                do (setf byte (read-byte urandom)))
          (setf (char out i)
                (char *base62-alphabet* (mod byte 62))))))))
