;;;; cl-state-sync - Tests
;;;;
;;;; Test suite for state synchronization library.

(defpackage #:cl-state-sync/test
  (:use #:cl #:cl-state-sync)
  (:export #:run-tests))

(in-package #:cl-state-sync/test)

;;;; ============================================================================
;;;; Test Infrastructure
;;;; ============================================================================

(defvar *test-count* 0)
(defvar *pass-count* 0)
(defvar *fail-count* 0)

(defmacro deftest (name &body body)
  "Define a test case."
  `(defun ,name ()
     (incf *test-count*)
     (handler-case
         (progn
           ,@body
           (incf *pass-count*)
           (format t "  PASS: ~A~%" ',name))
       (error (e)
         (incf *fail-count*)
         (format t "  FAIL: ~A~%        ~A~%" ',name e)))))

(defmacro assert-equal (expected actual &optional description)
  "Assert that two values are equal."
  `(unless (equal ,expected ,actual)
     (error "Assertion failed~@[: ~A~]~%  Expected: ~S~%  Actual: ~S"
            ,description ,expected ,actual)))

(defmacro assert-true (form &optional description)
  "Assert that a form evaluates to true."
  `(unless ,form
     (error "Assertion failed~@[: ~A~]~%  Expected true, got: ~S"
            ,description ,form)))

(defmacro assert-error (form &optional description)
  "Assert that a form signals an error."
  `(handler-case
       (progn
         ,form
         (error "Expected error~@[: ~A~]" ,description))
     (error () nil)))

;;;; ============================================================================
;;;; Utility Tests
;;;; ============================================================================

(deftest test-bytes-to-hex
  (assert-equal "00FF10"
                (bytes-to-hex #(0 255 16))
                "bytes-to-hex"))

(deftest test-hex-to-bytes
  (let ((bytes (hex-to-bytes "00FF10")))
    (assert-equal 0 (aref bytes 0))
    (assert-equal 255 (aref bytes 1))
    (assert-equal 16 (aref bytes 2))))

(deftest test-compare-bytes
  (assert-equal 0 (compare-bytes #(1 2 3) #(1 2 3)))
  (assert-equal -1 (compare-bytes #(1 2 3) #(1 2 4)))
  (assert-equal 1 (compare-bytes #(1 2 4) #(1 2 3)))
  (assert-equal -1 (compare-bytes #(1 2) #(1 2 3))))

(deftest test-increment-bytes
  (let ((result (increment-bytes #(0 0 255))))
    (assert-equal 0 (aref result 0))
    (assert-equal 1 (aref result 1))
    (assert-equal 0 (aref result 2))))

(deftest test-hash-data
  (let ((hash1 (hash-data "test"))
        (hash2 (hash-data "test"))
        (hash3 (hash-data "other")))
    (assert-equal 32 (length hash1) "hash length")
    (assert-true (equalp hash1 hash2) "same input same hash")
    (assert-true (not (equalp hash1 hash3)) "different input different hash")))

(deftest test-format-bytes
  (assert-equal "100 B" (format-bytes 100))
  (assert-equal "1.0 KB" (format-bytes 1024))
  (assert-equal "1.0 MB" (format-bytes (* 1024 1024))))

(deftest test-format-duration
  (assert-equal "30s" (format-duration 30))
  (assert-equal "2m 30s" (format-duration 150))
  (assert-equal "1h 30m" (format-duration 5400)))

;;;; ============================================================================
;;;; Snapshot Tests
;;;; ============================================================================

(deftest test-make-sync-config
  (let ((config (make-sync-config :batch-size 512
                                  :retry-limit 5)))
    (assert-equal 512 (config-batch-size config))
    (assert-equal 5 (config-retry-limit config))
    (assert-equal +default-timeout+ (config-request-timeout config))))

(deftest test-make-snapshot
  (let ((snapshot (make-snapshot :block-height 100000
                                 :block-hash (hex-to-bytes "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"))))
    (assert-equal 100000 (snapshot-block-height snapshot))
    (assert-equal +snapshot-version+ (snapshot-version snapshot))))

(deftest test-make-snapshot-chunk
  (let* ((data (make-array 1024 :element-type '(unsigned-byte 8) :initial-element 42))
         (chunk (make-snapshot-chunk :index 0
                                     :size 1024
                                     :data data
                                     :hash (hash-data data))))
    (assert-equal 0 (chunk-index chunk))
    (assert-equal 1024 (chunk-size chunk))
    (assert-true (chunk-hash chunk))))

(deftest test-make-utxo
  (let ((utxo (make-utxo :txid (make-array 32 :element-type '(unsigned-byte 8))
                         :vout 0
                         :value 100000000
                         :height 500000
                         :coinbase-p t)))
    (assert-equal 100000000 (utxo-value utxo))
    (assert-true (utxo-coinbase-p utxo))))

(deftest test-utxo-outpoint
  (let* ((txid (make-array 32 :element-type '(unsigned-byte 8) :initial-element 1))
         (utxo (make-utxo :txid txid :vout 2))
         (outpoint (utxo-outpoint utxo)))
    (assert-equal 36 (length outpoint))
    (assert-equal 2 (aref outpoint 32))))

(deftest test-snapshot-header-serialization
  (let* ((header (make-snapshot-header :block-height 500000
                                       :chunk-count 100))
         (bytes (serialize-snapshot-header header))
         (parsed (parse-snapshot-header bytes)))
    (assert-equal (snapshot-header-block-height header)
                  (snapshot-header-block-height parsed))
    (assert-equal (snapshot-header-chunk-count header)
                  (snapshot-header-chunk-count parsed))))

;;;; ============================================================================
;;;; Download Tests
;;;; ============================================================================

(deftest test-make-download-manager
  (let* ((config (make-sync-config))
         (manager (make-download-manager :config config)))
    (assert-equal :idle (download-status manager))
    (assert-equal 0 (hash-table-count (download-manager-completed manager)))))

(deftest test-download-task
  (let ((task (make-download-task :type :chunk :chunk-id 42)))
    (assert-equal :chunk (download-task-type task))
    (assert-equal 42 (download-task-chunk-id task))
    (assert-equal :pending (download-task-status task))))

(deftest test-start-download-no-snapshot
  (let ((manager (make-download-manager)))
    (assert-true (not (start-download manager))
                 "Should fail without snapshot")))

(deftest test-download-complete-empty
  (let ((manager (make-download-manager)))
    (assert-true (not (download-complete-p manager)))))

;;;; ============================================================================
;;;; Verification Tests
;;;; ============================================================================

(deftest test-make-verifier
  (let ((verifier (make-verifier)))
    (assert-equal :idle (verifier-state verifier))))

(deftest test-verify-chunk-integrity
  (let* ((data (make-array 100 :element-type '(unsigned-byte 8) :initial-element 1))
         (chunk (make-snapshot-chunk :index 0
                                     :size 100
                                     :data data
                                     :hash (hash-data data))))
    (assert-true (verify-chunk-integrity chunk))))

(deftest test-verify-chunk-size-mismatch
  (let* ((data (make-array 100 :element-type '(unsigned-byte 8)))
         (chunk (make-snapshot-chunk :index 0
                                     :size 200  ; Wrong size
                                     :data data)))
    (assert-error (verify-chunk-integrity chunk)
                  "Should fail on size mismatch")))

(deftest test-verify-chunk-hash-mismatch
  (let* ((data (make-array 100 :element-type '(unsigned-byte 8)))
         (wrong-hash (make-array 32 :element-type '(unsigned-byte 8) :initial-element 0))
         (chunk (make-snapshot-chunk :index 0
                                     :size 100
                                     :data data
                                     :hash wrong-hash)))
    (assert-error (verify-chunk-integrity chunk)
                  "Should fail on hash mismatch")))

(deftest test-compute-merkle-root-empty
  (let ((root (compute-merkle-root nil)))
    (assert-equal 32 (length root))))

(deftest test-compute-merkle-root-single
  (let* ((leaf (hash-data "test"))
         (root (compute-merkle-root (list leaf))))
    (assert-true (equalp leaf root))))

(deftest test-compute-merkle-root-multiple
  (let* ((leaf1 (hash-data "test1"))
         (leaf2 (hash-data "test2"))
         (root (compute-merkle-root (list leaf1 leaf2))))
    (assert-equal 32 (length root))
    (assert-true (not (equalp root leaf1)))
    (assert-true (not (equalp root leaf2)))))

(deftest test-validate-checkpoint
  (let ((checkpoint (make-checkpoint :height 100
                                     :hash (make-array 32 :element-type '(unsigned-byte 8))
                                     :utxo-root (make-array 32 :element-type '(unsigned-byte 8)))))
    (assert-true (validate-checkpoint checkpoint))))

(deftest test-validate-checkpoint-missing-height
  (let ((checkpoint (make-checkpoint :hash (make-array 32 :element-type '(unsigned-byte 8))
                                     :utxo-root (make-array 32 :element-type '(unsigned-byte 8)))))
    (setf (checkpoint-height checkpoint) nil)
    (assert-error (validate-checkpoint checkpoint))))

;;;; ============================================================================
;;;; Reconstruction Tests
;;;; ============================================================================

(deftest test-make-reconstructor
  (let ((reconstructor (make-reconstructor)))
    (assert-equal :idle (reconstruction-status reconstructor))))

(deftest test-merge-chunks-empty
  (let ((merged (merge-chunks nil)))
    (assert-equal 0 (length merged))))

(deftest test-merge-chunks-single
  (let* ((data (make-array 100 :element-type '(unsigned-byte 8) :initial-element 42))
         (chunk (make-snapshot-chunk :index 0 :size 100 :data data))
         (merged (merge-chunks (list chunk))))
    (assert-equal 100 (length merged))
    (assert-equal 42 (aref merged 0))))

(deftest test-merge-chunks-multiple
  (let* ((data1 (make-array 50 :element-type '(unsigned-byte 8) :initial-element 1))
         (data2 (make-array 50 :element-type '(unsigned-byte 8) :initial-element 2))
         (chunk1 (make-snapshot-chunk :index 0 :size 50 :data data1))
         (chunk2 (make-snapshot-chunk :index 1 :size 50 :data data2))
         (merged (merge-chunks (list chunk2 chunk1))))  ; Out of order
    (assert-equal 100 (length merged))
    (assert-equal 1 (aref merged 0))   ; First chunk data
    (assert-equal 2 (aref merged 50)))) ; Second chunk data

(deftest test-make-utxo-set
  (let ((utxo-set (make-utxo-set :count 1000
                                 :total-value 5000000000)))
    (assert-equal 1000 (utxo-set-count utxo-set))
    (assert-equal 5000000000 (utxo-set-total-value utxo-set))))

;;;; ============================================================================
;;;; Progress Tests
;;;; ============================================================================

(deftest test-sync-progress
  (let ((progress (make-sync-progress :phase :downloading
                                      :current 50
                                      :total 100)))
    (assert-equal :downloading (sync-progress-phase progress))
    (assert-equal 50.0 (progress-percentage progress))))

(deftest test-progress-percentage-zero-total
  (let ((progress (make-sync-progress :current 0 :total 0)))
    (assert-equal 0.0 (progress-percentage progress))))

;;;; ============================================================================
;;;; Error Condition Tests
;;;; ============================================================================

(deftest test-sync-error
  (handler-case
      (error 'sync-error :code :test :message "test error")
    (sync-error (e)
      (assert-equal :test (sync-error-code e))
      (assert-equal "test error" (sync-error-message e)))))

(deftest test-verification-error
  (handler-case
      (error 'verification-error :message "verification failed")
    (verification-error (e)
      (assert-equal :verification-failed (sync-error-code e)))))

;;;; ============================================================================
;;;; Integration Tests
;;;; ============================================================================

(deftest test-full-workflow
  "Test complete sync workflow with mock data."
  (let* (;; Create config
         (config (make-sync-config :batch-size 10
                                   :verify-proofs t))

         ;; Create chunks
         (chunk-data (make-array 256 :element-type '(unsigned-byte 8)
                                     :initial-element 0))
         (chunk (make-snapshot-chunk :index 0
                                     :size 256
                                     :data chunk-data
                                     :hash (hash-data chunk-data)))

         ;; Create snapshot
         (snapshot (make-snapshot :block-height 100
                                  :block-hash (hash-data "block")
                                  :state-root (compute-merkle-root
                                               (list (chunk-hash chunk)))
                                  :chunks (list chunk)))

         ;; Create verifier and verify
         (verifier (make-verifier :config config)))

    ;; Verify snapshot
    (assert-true (verify-snapshot verifier snapshot)
                 "Snapshot verification should pass")

    ;; Create reconstructor
    (let ((reconstructor (make-reconstructor :config config
                                             :snapshot snapshot)))
      (start-reconstruction reconstructor)

      ;; Merge chunks
      (let ((merged (merge-chunks (snapshot-chunks snapshot))))
        (assert-equal 256 (length merged))))))

;;;; ============================================================================
;;;; Test Runner
;;;; ============================================================================

(defun run-tests ()
  "Run all tests and report results."
  (setf *test-count* 0
        *pass-count* 0
        *fail-count* 0)

  (format t "~%Running cl-state-sync tests...~%~%")

  ;; Utility tests
  (format t "Utility tests:~%")
  (test-bytes-to-hex)
  (test-hex-to-bytes)
  (test-compare-bytes)
  (test-increment-bytes)
  (test-hash-data)
  (test-format-bytes)
  (test-format-duration)

  ;; Snapshot tests
  (format t "~%Snapshot tests:~%")
  (test-make-sync-config)
  (test-make-snapshot)
  (test-make-snapshot-chunk)
  (test-make-utxo)
  (test-utxo-outpoint)
  (test-snapshot-header-serialization)

  ;; Download tests
  (format t "~%Download tests:~%")
  (test-make-download-manager)
  (test-download-task)
  (test-start-download-no-snapshot)
  (test-download-complete-empty)

  ;; Verification tests
  (format t "~%Verification tests:~%")
  (test-make-verifier)
  (test-verify-chunk-integrity)
  (test-verify-chunk-size-mismatch)
  (test-verify-chunk-hash-mismatch)
  (test-compute-merkle-root-empty)
  (test-compute-merkle-root-single)
  (test-compute-merkle-root-multiple)
  (test-validate-checkpoint)
  (test-validate-checkpoint-missing-height)

  ;; Reconstruction tests
  (format t "~%Reconstruction tests:~%")
  (test-make-reconstructor)
  (test-merge-chunks-empty)
  (test-merge-chunks-single)
  (test-merge-chunks-multiple)
  (test-make-utxo-set)

  ;; Progress tests
  (format t "~%Progress tests:~%")
  (test-sync-progress)
  (test-progress-percentage-zero-total)

  ;; Error tests
  (format t "~%Error condition tests:~%")
  (test-sync-error)
  (test-verification-error)

  ;; Integration tests
  (format t "~%Integration tests:~%")
  (test-full-workflow)

  ;; Summary
  (format t "~%========================================~%")
  (format t "Tests: ~A  Passed: ~A  Failed: ~A~%"
          *test-count* *pass-count* *fail-count*)
  (format t "========================================~%")

  (zerop *fail-count*))
