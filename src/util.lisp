;;;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;;;; SPDX-License-Identifier: Apache-2.0

;;;; cl-state-sync - Utility Functions
;;;;
;;;; Helper functions for state synchronization.
;;;; Pure Common Lisp - no external dependencies.

(in-package #:cl-state-sync)

;;;; ============================================================================
;;;; Constants
;;;; ============================================================================

(defconstant +snapshot-version+ 1
  "Current snapshot format version.")

(defconstant +snapshot-magic+ #x53545359
  "Magic number for snapshot files: 'STSY' in hex.")

(defconstant +max-chunk-size+ (* 16 1024 1024)
  "Maximum chunk size: 16 MB.")

(defconstant +default-batch-size+ 1024
  "Default batch size for operations.")

(defconstant +default-timeout+ 30
  "Default timeout in seconds.")

(defconstant +hash-size+ 32
  "Size of hash output in bytes (SHA-256).")

;;;; ============================================================================
;;;; Byte Utilities
;;;; ============================================================================

(defun bytes-to-hex (bytes)
  "Convert byte vector to hexadecimal string."
  (with-output-to-string (s)
    (loop for byte across bytes
          do (format s "~2,'0X" byte))))

(defun hex-to-bytes (hex-string)
  "Convert hexadecimal string to byte vector."
  (let* ((len (length hex-string))
         (bytes (make-array (/ len 2) :element-type '(unsigned-byte 8))))
    (loop for i from 0 below len by 2
          for j from 0
          do (setf (aref bytes j)
                   (parse-integer hex-string :start i :end (+ i 2) :radix 16)))
    bytes))

(defun compare-bytes (a b)
  "Compare two byte vectors lexicographically.
Returns -1 if a < b, 0 if equal, 1 if a > b."
  (let ((len-a (length a))
        (len-b (length b)))
    (loop for i from 0 below (min len-a len-b)
          for byte-a = (aref a i)
          for byte-b = (aref b i)
          when (< byte-a byte-b) return -1
          when (> byte-a byte-b) return 1
          finally (return (cond ((< len-a len-b) -1)
                                ((> len-a len-b) 1)
                                (t 0))))))

(defun increment-bytes (bytes)
  "Increment a byte vector by 1 (big-endian).
Returns a new byte vector."
  (let* ((len (length bytes))
         (result (make-array len :element-type '(unsigned-byte 8))))
    (replace result bytes)
    (loop for i from (1- len) downto 0
          do (if (< (aref result i) 255)
                 (progn
                   (incf (aref result i))
                   (return))
                 (setf (aref result i) 0)))
    result))

;;;; ============================================================================
;;;; Hash Functions (Simplified SHA-256 Stub)
;;;; ============================================================================

;; Note: In production, use a proper SHA-256 implementation.
;; This is a placeholder that can be replaced with SBCL's MD5 or
;; integrated with a proper crypto module.

(defun hash-data (data)
  "Hash data using SHA-256.
DATA can be a byte vector or string.
Returns a 32-byte hash."
  ;; Placeholder: uses simple XOR folding for demonstration
  ;; Replace with actual SHA-256 in production
  (let ((bytes (etypecase data
                 ((simple-array (unsigned-byte 8) (*)) data)
                 (string (map '(vector (unsigned-byte 8)) #'char-code data))))
        (hash (make-array +hash-size+ :element-type '(unsigned-byte 8)
                                       :initial-element 0)))
    ;; Simple hash: XOR fold input into 32-byte output
    (loop for i from 0 below (length bytes)
          for j = (mod i +hash-size+)
          do (setf (aref hash j)
                   (logxor (aref hash j) (aref bytes i))))
    ;; Add some mixing
    (loop for round from 0 below 4
          do (loop for i from 0 below +hash-size+
                   for j = (mod (+ i 7) +hash-size+)
                   do (setf (aref hash i)
                            (logxor (aref hash i)
                                    (ash (aref hash j) (- (mod i 5)))))))
    hash))

(defun hash-combine (&rest hashes)
  "Combine multiple hashes into one."
  (let ((combined (make-array (* (length hashes) +hash-size+)
                              :element-type '(unsigned-byte 8))))
    (loop for hash in hashes
          for offset from 0 by +hash-size+
          do (replace combined hash :start1 offset))
    (hash-data combined)))

;;;; ============================================================================
;;;; Time Utilities
;;;; ============================================================================

(defun current-timestamp ()
  "Get current Unix timestamp."
  (- (get-universal-time)
     ;; Unix epoch in universal time
     2208988800))

(defun format-duration (seconds)
  "Format duration in human-readable form."
  (cond ((< seconds 60)
         (format nil "~Ds" seconds))
        ((< seconds 3600)
         (format nil "~Dm ~Ds" (floor seconds 60) (mod seconds 60)))
        ((< seconds 86400)
         (format nil "~Dh ~Dm" (floor seconds 3600) (mod (floor seconds 60) 60)))
        (t
         (format nil "~Dd ~Dh" (floor seconds 86400) (mod (floor seconds 3600) 24)))))

(defun format-bytes (bytes)
  "Format byte count in human-readable form."
  (cond ((< bytes 1024)
         (format nil "~D B" bytes))
        ((< bytes (* 1024 1024))
         (format nil "~,1F KB" (/ bytes 1024.0)))
        ((< bytes (* 1024 1024 1024))
         (format nil "~,1F MB" (/ bytes (* 1024.0 1024))))
        (t
         (format nil "~,2F GB" (/ bytes (* 1024.0 1024 1024))))))

;;;; ============================================================================
;;;; Threading Utilities (SBCL Native)
;;;; ============================================================================

(defmacro with-lock ((lock) &body body)
  "Execute BODY with LOCK held."
  `(sb-thread:with-mutex (,lock)
     ,@body))

(defun make-lock (&optional name)
  "Create a new mutex lock."
  (sb-thread:make-mutex :name (or name "sync-lock")))

(defun make-condition-var (&optional name)
  "Create a new condition variable."
  (sb-thread:make-waitqueue :name (or name "sync-cond")))

(defun spawn-thread (name function)
  "Spawn a new thread running FUNCTION."
  (sb-thread:make-thread function :name name))

;;;; ============================================================================
;;;; ID Generation
;;;; ============================================================================

(defvar *id-counter* 0)
(defvar *id-lock* (make-lock "id-lock"))

(defun generate-id ()
  "Generate a unique ID."
  (with-lock (*id-lock*)
    (incf *id-counter*)))

;;;; ============================================================================
;;;; Logging
;;;; ============================================================================

(defvar *log-level* :info
  "Current log level: :debug, :info, :warn, :error")

(defun log-level-priority (level)
  "Get numeric priority for log level."
  (case level
    (:debug 0)
    (:info 1)
    (:warn 2)
    (:error 3)
    (otherwise 1)))

(defun sync-log (level format-string &rest args)
  "Log a message at the given level."
  (when (>= (log-level-priority level)
            (log-level-priority *log-level*))
    (format t "~&[~A] [STATE-SYNC] ~?~%"
            (string-upcase (symbol-name level))
            format-string args)
    (force-output)))

(defun sync-log-debug (format-string &rest args)
  "Log a debug message."
  (apply #'sync-log :debug format-string args))

(defun sync-log-info (format-string &rest args)
  "Log an info message."
  (apply #'sync-log :info format-string args))

(defun sync-log-warn (format-string &rest args)
  "Log a warning message."
  (apply #'sync-log :warn format-string args))

(defun sync-log-error (format-string &rest args)
  "Log an error message."
  (apply #'sync-log :error format-string args))
