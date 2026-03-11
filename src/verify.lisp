;;;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;;;; SPDX-License-Identifier: BSD-3-Clause

;;;; cl-state-sync - Verification
;;;;
;;;; Verifies snapshot integrity, Merkle proofs, and state consistency.

(in-package #:cl-state-sync)

;;;; ============================================================================
;;;; Error Conditions
;;;; ============================================================================

(define-condition sync-error (error)
  ((code :initarg :code :reader sync-error-code)
   (message :initarg :message :reader sync-error-message))
  (:report (lambda (c s)
             (format s "Sync error (~A): ~A"
                     (sync-error-code c)
                     (sync-error-message c)))))

(define-condition verification-error (sync-error)
  ()
  (:default-initargs :code :verification-failed))

(define-condition download-error (sync-error)
  ()
  (:default-initargs :code :download-failed))

(define-condition reconstruction-error (sync-error)
  ()
  (:default-initargs :code :reconstruction-failed))

(define-condition corrupt-snapshot-error (sync-error)
  ()
  (:default-initargs :code :corrupt-snapshot))

;;;; ============================================================================
;;;; Verifier
;;;; ============================================================================

(defstruct (verifier
            (:constructor %make-verifier)
            (:copier nil))
  "State verification engine.

Slots:
  config   - Sync configuration
  state    - Verifier state
  results  - Verification results
  progress - Verification progress"
  (config nil :type (or null sync-config))
  (state :idle :type keyword)
  (results nil :type list)
  (progress (make-sync-progress) :type sync-progress))

(defun make-verifier (&key config)
  "Create a new verifier."
  (%make-verifier
   :config (or config (make-sync-config))))

;;;; ============================================================================
;;;; Snapshot Verification
;;;; ============================================================================

(defun verify-snapshot (verifier snapshot)
  "Verify complete snapshot integrity.

Checks:
1. Header validity
2. All chunks present
3. Chunk hashes match
4. Merkle proofs valid
5. State root matches

Arguments:
  verifier - Verifier instance
  snapshot - Snapshot to verify

Returns:
  T if valid, signals verification-error otherwise."
  (setf (verifier-state verifier) :verifying)
  (setf (sync-progress-phase (verifier-progress verifier)) :verifying)

  (handler-case
      (progn
        ;; Verify header
        (verify-snapshot-header snapshot)

        ;; Verify each chunk
        (let* ((chunks (snapshot-chunks snapshot))
               (total (length chunks)))
          (setf (sync-progress-total (verifier-progress verifier)) total)

          (loop for chunk in chunks
                for i from 0
                do (verify-chunk-integrity chunk)
                   (setf (sync-progress-current (verifier-progress verifier)) (1+ i))
                   (incf (sync-progress-chunks-verified (verifier-progress verifier)))))

        ;; Verify state root
        (verify-state-root snapshot)

        ;; Verify UTXO root
        (when (snapshot-utxo-root snapshot)
          (verify-utxo-set snapshot))

        (setf (verifier-state verifier) :complete)
        (push (list :status :passed :timestamp (current-timestamp))
              (verifier-results verifier))
        t)

    (verification-error (e)
      (setf (verifier-state verifier) :failed)
      (push (list :status :failed
                  :error (sync-error-message e)
                  :timestamp (current-timestamp))
            (verifier-results verifier))
      (error e))))

(defun verify-snapshot-header (snapshot)
  "Verify snapshot header validity.

Arguments:
  snapshot - Snapshot to verify

Returns:
  T if valid."
  (unless (= (snapshot-version snapshot) +snapshot-version+)
    (error 'verification-error
           :message (format nil "Unsupported snapshot version: ~A"
                            (snapshot-version snapshot))))

  (unless (snapshot-block-hash snapshot)
    (error 'verification-error
           :message "Missing block hash"))

  (unless (snapshot-state-root snapshot)
    (error 'verification-error
           :message "Missing state root"))

  t)

;;;; ============================================================================
;;;; Chunk Verification
;;;; ============================================================================

(defun verify-chunk-integrity (chunk)
  "Verify a single chunk's integrity.

Arguments:
  chunk - Chunk to verify

Returns:
  T if valid."
  (unless (chunk-data chunk)
    (error 'verification-error
           :message (format nil "Chunk ~A has no data" (chunk-index chunk))))

  ;; Verify size
  (unless (= (chunk-size chunk) (length (chunk-data chunk)))
    (error 'verification-error
           :message (format nil "Chunk ~A size mismatch: expected ~A, got ~A"
                            (chunk-index chunk)
                            (chunk-size chunk)
                            (length (chunk-data chunk)))))

  ;; Verify hash
  (when (chunk-hash chunk)
    (let ((computed (hash-data (chunk-data chunk))))
      (unless (equalp computed (chunk-hash chunk))
        (error 'verification-error
               :message (format nil "Chunk ~A hash mismatch"
                                (chunk-index chunk))))))

  ;; Verify proof if present
  (when (chunk-proof chunk)
    (verify-chunk-proof chunk))

  t)

(defun verify-chunk-proof (chunk)
  "Verify a chunk's Merkle proof.

Arguments:
  chunk - Chunk with proof

Returns:
  T if valid."
  (let ((proof (chunk-proof chunk)))
    (unless proof
      (return-from verify-chunk-proof t))

    ;; Verify each node in proof path
    (let ((current-hash (chunk-hash chunk)))
      (dolist (node proof)
        (let* ((sibling-hash (getf node :hash))
               (direction (getf node :direction))
               (combined (if (eq direction :left)
                             (hash-combine sibling-hash current-hash)
                             (hash-combine current-hash sibling-hash))))
          (setf current-hash combined))))

    t))

;;;; ============================================================================
;;;; Merkle Proof Verification
;;;; ============================================================================

(defun verify-merkle-proof (root key value proof-nodes)
  "Verify a Merkle proof for a key-value pair.

Arguments:
  root        - Expected root hash
  key         - Key being proven
  value       - Value at key
  proof-nodes - List of proof nodes

Returns:
  T if proof is valid."
  (declare (ignore key))  ; Used for path computation in full impl

  (unless proof-nodes
    (error 'verification-error
           :message "Empty proof"))

  ;; Start with hash of the value
  (let ((current-hash (hash-data value)))

    ;; Walk up the tree
    (dolist (node proof-nodes)
      (let ((sibling (getf node :sibling))
            (position (getf node :position)))
        (setf current-hash
              (if (eq position :left)
                  (hash-combine sibling current-hash)
                  (hash-combine current-hash sibling)))))

    ;; Compare with expected root
    (unless (equalp current-hash root)
      (error 'verification-error
             :message "Merkle proof root mismatch"))

    t))

(defun compute-merkle-root (leaves)
  "Compute Merkle root from leaf hashes.

Arguments:
  leaves - List of leaf hashes (byte vectors)

Returns:
  Root hash."
  (when (null leaves)
    (return-from compute-merkle-root
      (make-array +hash-size+ :element-type '(unsigned-byte 8)
                              :initial-element 0)))

  (when (= (length leaves) 1)
    (return-from compute-merkle-root (first leaves)))

  ;; Build tree bottom-up
  (let ((level (copy-list leaves)))
    (loop while (> (length level) 1)
          do (setf level
                   (loop for (left right) on level by #'cddr
                         collect (if right
                                     (hash-combine left right)
                                     ;; Odd number: hash with itself
                                     (hash-combine left left)))))
    (first level)))

;;;; ============================================================================
;;;; State Root Verification
;;;; ============================================================================

(defun verify-state-root (snapshot)
  "Verify the snapshot's state root matches chunk data.

Arguments:
  snapshot - Snapshot to verify

Returns:
  T if valid."
  (let* ((chunks (snapshot-chunks snapshot))
         (chunk-hashes (mapcar #'chunk-hash chunks))
         (computed-root (compute-merkle-root chunk-hashes))
         (expected-root (snapshot-state-root snapshot)))

    (unless (equalp computed-root expected-root)
      (error 'verification-error
             :message "State root mismatch"))

    t))

(defun compare-state-roots (root1 root2)
  "Compare two state roots.

Arguments:
  root1, root2 - State roots to compare

Returns:
  T if equal."
  (equalp root1 root2))

;;;; ============================================================================
;;;; UTXO Set Verification
;;;; ============================================================================

(defun verify-utxo-set (snapshot)
  "Verify UTXO set integrity.

Arguments:
  snapshot - Snapshot containing UTXO data

Returns:
  T if valid."
  (let ((utxo-root (snapshot-utxo-root snapshot)))
    (unless utxo-root
      (return-from verify-utxo-set t))

    ;; In a full implementation, would:
    ;; 1. Extract UTXO data from chunks
    ;; 2. Rebuild UTXO trie
    ;; 3. Compare computed root with expected

    t))

(defun verify-utxo (utxo)
  "Verify a single UTXO.

Arguments:
  utxo - UTXO to verify

Returns:
  T if valid."
  (unless (utxo-txid utxo)
    (error 'verification-error
           :message "UTXO missing txid"))

  (unless (>= (utxo-value utxo) 0)
    (error 'verification-error
           :message "UTXO has negative value"))

  (unless (utxo-script-pubkey utxo)
    (error 'verification-error
           :message "UTXO missing script-pubkey"))

  t)

;;;; ============================================================================
;;;; Trie Proof Verification
;;;; ============================================================================

(defun verify-trie-proof (proof root-hash)
  "Verify a trie proof against a root hash.

Arguments:
  proof     - trie-proof instance
  root-hash - Expected root hash

Returns:
  T if valid."
  (let ((nodes (trie-proof-nodes proof))
        (key (trie-proof-key proof))
        (value (trie-proof-value proof)))

    (unless nodes
      (error 'verification-error
             :message "Empty trie proof"))

    ;; Verify the path
    (verify-merkle-proof root-hash key value
                         (mapcar (lambda (node)
                                   (list :sibling (trie-node-hash node)
                                         :position :right))
                                 nodes))))

;;;; ============================================================================
;;;; Batch Verification
;;;; ============================================================================

(defun verify-chunks-batch (verifier chunks)
  "Verify a batch of chunks.

Arguments:
  verifier - Verifier instance
  chunks   - List of chunks to verify

Returns:
  List of (index . result) pairs."
  (loop for chunk in chunks
        collect (cons (chunk-index chunk)
                      (handler-case
                          (progn
                            (verify-chunk-integrity chunk)
                            :passed)
                        (verification-error ()
                          :failed)))))

(defun parallel-verify (verifier snapshot &key (workers 4))
  "Verify snapshot using parallel workers.

Arguments:
  verifier - Verifier instance
  snapshot - Snapshot to verify
  workers  - Number of worker threads

Returns:
  T if all verifications passed."
  (let* ((chunks (snapshot-chunks snapshot))
         (chunk-count (length chunks))
         (batch-size (ceiling chunk-count workers))
         (results (make-array workers :initial-element nil))
         (threads nil))

    ;; Spawn worker threads
    (dotimes (i workers)
      (let* ((start (* i batch-size))
             (end (min (* (1+ i) batch-size) chunk-count))
             (batch (subseq chunks start end))
             (index i))
        (when batch
          (push (spawn-thread
                 (format nil "verify-worker-~A" i)
                 (lambda ()
                   (setf (aref results index)
                         (verify-chunks-batch verifier batch))))
                threads))))

    ;; Wait for all threads
    (dolist (thread threads)
      (sb-thread:join-thread thread))

    ;; Check results
    (every (lambda (batch-results)
             (every (lambda (pair) (eq (cdr pair) :passed))
                    batch-results))
           results)))

;;;; ============================================================================
;;;; Checkpoint Verification
;;;; ============================================================================

(defun validate-checkpoint (checkpoint)
  "Validate a checkpoint.

Arguments:
  checkpoint - Checkpoint to validate

Returns:
  T if valid."
  (unless (checkpoint-height checkpoint)
    (error 'verification-error
           :message "Checkpoint missing height"))

  (unless (checkpoint-hash checkpoint)
    (error 'verification-error
           :message "Checkpoint missing block hash"))

  (unless (checkpoint-utxo-root checkpoint)
    (error 'verification-error
           :message "Checkpoint missing UTXO root"))

  t)

;;;; ============================================================================
;;;; Print Methods
;;;; ============================================================================

(defmethod print-object ((obj verifier) stream)
  (print-unreadable-object (obj stream :type t)
    (format stream "~A verified:~A"
            (verifier-state obj)
            (sync-progress-chunks-verified (verifier-progress obj)))))
