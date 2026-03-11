;;;; cl-state-sync - State Reconstruction
;;;;
;;;; Reconstructs UTXO set and state trie from snapshot chunks.

(in-package #:cl-state-sync)

;;;; ============================================================================
;;;; Reconstructor
;;;; ============================================================================

(defstruct (reconstructor
            (:constructor %make-reconstructor)
            (:copier nil))
  "State reconstruction engine.

Slots:
  config    - Sync configuration
  state     - Reconstructor state
  snapshot  - Source snapshot
  utxo-set  - Rebuilt UTXO set
  trie-root - Rebuilt trie root
  progress  - Reconstruction progress
  lock      - Mutex for thread safety"
  (config nil :type (or null sync-config))
  (state :idle :type keyword)
  (snapshot nil :type (or null snapshot))
  (utxo-set nil :type (or null utxo-set))
  (trie-root nil :type (or null (simple-array (unsigned-byte 8) (*))))
  (progress (make-sync-progress) :type sync-progress)
  (lock (make-lock "reconstruct-lock") :read-only t))

(defun make-reconstructor (&key config snapshot)
  "Create a new reconstructor."
  (%make-reconstructor
   :config (or config (make-sync-config))
   :snapshot snapshot))

;;;; ============================================================================
;;;; Reconstruction Operations
;;;; ============================================================================

(defun start-reconstruction (reconstructor)
  "Start state reconstruction.

Arguments:
  reconstructor - Reconstructor instance

Returns:
  T if started successfully."
  (with-lock ((reconstructor-lock reconstructor))
    (when (eq (reconstructor-state reconstructor) :running)
      (sync-log-warn "Reconstruction already running")
      (return-from start-reconstruction nil))

    (unless (reconstructor-snapshot reconstructor)
      (sync-log-error "No snapshot configured")
      (return-from start-reconstruction nil))

    (setf (reconstructor-state reconstructor) :running)
    (setf (sync-progress-phase (reconstructor-progress reconstructor))
          :reconstructing)

    (sync-log-info "Starting state reconstruction")
    t))

(defun stop-reconstruction (reconstructor)
  "Stop reconstruction.

Arguments:
  reconstructor - Reconstructor instance"
  (with-lock ((reconstructor-lock reconstructor))
    (setf (reconstructor-state reconstructor) :stopped))
  (sync-log-info "Reconstruction stopped"))

(defun reconstruction-status (reconstructor)
  "Get current reconstruction status.

Arguments:
  reconstructor - Reconstructor instance

Returns:
  Status keyword."
  (reconstructor-state reconstructor))

(defun reconstruction-progress (reconstructor)
  "Get current reconstruction progress.

Arguments:
  reconstructor - Reconstructor instance

Returns:
  sync-progress instance."
  (reconstructor-progress reconstructor))

;;;; ============================================================================
;;;; Snapshot Reconstruction
;;;; ============================================================================

(defun reconstruct-from-snapshot (reconstructor)
  "Reconstruct complete state from snapshot.

Arguments:
  reconstructor - Reconstructor instance

Returns:
  T if reconstruction succeeded."
  (unless (eq (reconstructor-state reconstructor) :running)
    (error 'reconstruction-error
           :message "Reconstructor not running"))

  (let* ((snapshot (reconstructor-snapshot reconstructor))
         (chunks (snapshot-chunks snapshot))
         (total (length chunks)))

    (setf (sync-progress-total (reconstructor-progress reconstructor)) total)

    ;; Merge all chunks
    (sync-log-info "Merging ~A chunks" total)
    (let ((merged-data (merge-chunks chunks)))

      ;; Reconstruct UTXO set
      (sync-log-info "Reconstructing UTXO set")
      (let ((utxo-set (reconstruct-utxo-set merged-data)))
        (setf (reconstructor-utxo-set reconstructor) utxo-set))

      ;; Reconstruct state trie
      (sync-log-info "Reconstructing state trie")
      (let ((trie-root (reconstruct-state-trie merged-data)))
        (setf (reconstructor-trie-root reconstructor) trie-root)))

    ;; Verify reconstruction
    (verify-reconstruction reconstructor)

    (setf (reconstructor-state reconstructor) :complete)
    (sync-log-info "Reconstruction complete")
    t))

;;;; ============================================================================
;;;; Chunk Merging
;;;; ============================================================================

(defun merge-chunks (chunks)
  "Merge all chunks into a single data stream.

Arguments:
  chunks - List of snapshot chunks in order

Returns:
  Merged byte vector."
  ;; Sort chunks by index
  (let ((sorted (sort (copy-list chunks) #'< :key #'chunk-index)))

    ;; Calculate total size
    (let* ((total-size (reduce #'+ sorted :key #'chunk-size))
           (result (make-array total-size :element-type '(unsigned-byte 8)))
           (offset 0))

      ;; Copy each chunk
      (dolist (chunk sorted)
        (when (chunk-data chunk)
          (replace result (chunk-data chunk) :start1 offset)
          (incf offset (chunk-size chunk))))

      result)))

(defun apply-chunk (state chunk)
  "Apply a single chunk to reconstruct state.

Arguments:
  state - Current reconstruction state (hash-table)
  chunk - Chunk to apply

Returns:
  Updated state."
  (let ((data (chunk-data chunk)))
    (when data
      ;; Parse chunk data and update state
      ;; Format: repeated [key-len][key][value-len][value]
      (let ((pos 0)
            (len (length data)))
        (loop while (< pos len)
              do (when (< (- len pos) 4)
                   (return))

                 ;; Read key length (4 bytes, big-endian)
                 (let ((key-len (logior (ash (aref data pos) 24)
                                        (ash (aref data (+ pos 1)) 16)
                                        (ash (aref data (+ pos 2)) 8)
                                        (aref data (+ pos 3)))))
                   (incf pos 4)

                   (when (< (- len pos) key-len)
                     (return))

                   ;; Read key
                   (let ((key (make-array key-len
                                          :element-type '(unsigned-byte 8))))
                     (replace key data :start2 pos)
                     (incf pos key-len)

                     (when (< (- len pos) 4)
                       (return))

                     ;; Read value length
                     (let ((val-len (logior (ash (aref data pos) 24)
                                            (ash (aref data (+ pos 1)) 16)
                                            (ash (aref data (+ pos 2)) 8)
                                            (aref data (+ pos 3)))))
                       (incf pos 4)

                       (when (< (- len pos) val-len)
                         (return))

                       ;; Read value
                       (let ((value (make-array val-len
                                                :element-type '(unsigned-byte 8))))
                         (replace value data :start2 pos)
                         (incf pos val-len)

                         ;; Store in state
                         (setf (gethash key state) value))))))))

    state))

;;;; ============================================================================
;;;; UTXO Set Reconstruction
;;;; ============================================================================

(defun reconstruct-utxo-set (data)
  "Reconstruct UTXO set from merged chunk data.

Arguments:
  data - Merged chunk data

Returns:
  utxo-set instance."
  (let ((utxos (make-hash-table :test 'equalp))
        (total-value 0)
        (count 0))

    ;; Parse UTXO entries from data
    ;; Format per UTXO: [txid:32][vout:4][value:8][script-len:4][script:N][height:4][flags:1]
    (let ((pos 0)
          (len (length data)))

      (loop while (< pos len)
            do (when (< (- len pos) 49)  ; Minimum UTXO size
                 (return))

               ;; Read txid (32 bytes)
               (let ((txid (make-array 32 :element-type '(unsigned-byte 8))))
                 (replace txid data :start2 pos)
                 (incf pos 32)

                 ;; Read vout (4 bytes)
                 (let ((vout (logior (ash (aref data pos) 24)
                                     (ash (aref data (+ pos 1)) 16)
                                     (ash (aref data (+ pos 2)) 8)
                                     (aref data (+ pos 3)))))
                   (incf pos 4)

                   ;; Read value (8 bytes)
                   (let ((value (loop for i from 0 below 8
                                      sum (ash (aref data (+ pos i))
                                               (* 8 (- 7 i))))))
                     (incf pos 8)

                     ;; Read script length (4 bytes)
                     (let ((script-len (logior (ash (aref data pos) 24)
                                               (ash (aref data (+ pos 1)) 16)
                                               (ash (aref data (+ pos 2)) 8)
                                               (aref data (+ pos 3)))))
                       (incf pos 4)

                       (when (< (- len pos) (+ script-len 5))
                         (return))

                       ;; Read script
                       (let ((script (make-array script-len
                                                 :element-type '(unsigned-byte 8))))
                         (replace script data :start2 pos)
                         (incf pos script-len)

                         ;; Read height (4 bytes)
                         (let ((height (logior (ash (aref data pos) 24)
                                               (ash (aref data (+ pos 1)) 16)
                                               (ash (aref data (+ pos 2)) 8)
                                               (aref data (+ pos 3)))))
                           (incf pos 4)

                           ;; Read flags (1 byte)
                           (let ((flags (aref data pos)))
                             (incf pos 1)

                             ;; Create UTXO
                             (let ((utxo (make-utxo
                                          :txid txid
                                          :vout vout
                                          :value value
                                          :script-pubkey script
                                          :height height
                                          :coinbase-p (plusp (logand flags 1)))))

                               ;; Store by outpoint
                               (setf (gethash (utxo-outpoint utxo) utxos) utxo)
                               (incf total-value value)
                               (incf count)))))))))))

    ;; Compute UTXO set root
    (let* ((utxo-hashes (loop for utxo being the hash-values of utxos
                              collect (hash-data (utxo-outpoint utxo))))
           (root (compute-merkle-root utxo-hashes)))

      (make-utxo-set
       :root root
       :count count
       :total-value total-value))))

;;;; ============================================================================
;;;; State Trie Reconstruction
;;;; ============================================================================

(defun reconstruct-state-trie (data)
  "Reconstruct state trie from merged chunk data.

Arguments:
  data - Merged chunk data

Returns:
  Trie root hash."
  ;; Build trie from key-value pairs
  (let ((nodes (make-hash-table :test 'equalp))
        (leaves nil))

    ;; Parse key-value pairs and create leaf nodes
    (let ((pos 0)
          (len (length data)))

      (loop while (< pos len)
            do (when (< (- len pos) 8)
                 (return))

               ;; Read key length
               (let ((key-len (logior (ash (aref data pos) 24)
                                      (ash (aref data (+ pos 1)) 16)
                                      (ash (aref data (+ pos 2)) 8)
                                      (aref data (+ pos 3)))))
                 (incf pos 4)

                 (when (< (- len pos) (+ key-len 4))
                   (return))

                 ;; Read key
                 (let ((key (make-array key-len :element-type '(unsigned-byte 8))))
                   (replace key data :start2 pos)
                   (incf pos key-len)

                   ;; Read value length
                   (let ((val-len (logior (ash (aref data pos) 24)
                                          (ash (aref data (+ pos 1)) 16)
                                          (ash (aref data (+ pos 2)) 8)
                                          (aref data (+ pos 3)))))
                     (incf pos 4)

                     (when (< (- len pos) val-len)
                       (return))

                     ;; Read value
                     (let ((value (make-array val-len
                                              :element-type '(unsigned-byte 8))))
                       (replace value data :start2 pos)
                       (incf pos val-len)

                       ;; Create leaf node
                       (let* ((leaf-data (concatenate '(vector (unsigned-byte 8))
                                                      key value))
                              (leaf-hash (hash-data leaf-data))
                              (node (make-trie-node
                                     :hash leaf-hash
                                     :data leaf-data
                                     :type :leaf)))
                         (setf (gethash leaf-hash nodes) node)
                         (push leaf-hash leaves))))))))

    ;; Build tree from leaves
    (if leaves
        (compute-merkle-root (nreverse leaves))
        (make-array +hash-size+ :element-type '(unsigned-byte 8)
                                :initial-element 0))))

;;;; ============================================================================
;;;; Reconstruction Verification
;;;; ============================================================================

(defun verify-reconstruction (reconstructor)
  "Verify reconstructed state matches snapshot.

Arguments:
  reconstructor - Reconstructor instance

Returns:
  T if verification passed."
  (let ((snapshot (reconstructor-snapshot reconstructor))
        (utxo-set (reconstructor-utxo-set reconstructor))
        (trie-root (reconstructor-trie-root reconstructor)))

    ;; Verify UTXO root
    (when (and utxo-set (snapshot-utxo-root snapshot))
      (unless (equalp (utxo-set-root utxo-set)
                      (snapshot-utxo-root snapshot))
        (error 'reconstruction-error
               :message "UTXO root mismatch after reconstruction")))

    ;; Verify state root
    (when (and trie-root (snapshot-state-root snapshot))
      (unless (equalp trie-root (snapshot-state-root snapshot))
        (sync-log-warn "State root mismatch - may need healing")))

    t))

;;;; ============================================================================
;;;; Checkpointing
;;;; ============================================================================

(defun create-checkpoint (reconstructor)
  "Create a checkpoint from current reconstruction state.

Arguments:
  reconstructor - Reconstructor instance

Returns:
  checkpoint instance."
  (let ((snapshot (reconstructor-snapshot reconstructor))
        (utxo-set (reconstructor-utxo-set reconstructor)))

    (make-checkpoint
     :height (snapshot-block-height snapshot)
     :hash (snapshot-block-hash snapshot)
     :utxo-root (when utxo-set (utxo-set-root utxo-set))
     :timestamp (current-timestamp))))

(defun restore-from-checkpoint (reconstructor checkpoint)
  "Restore reconstruction state from checkpoint.

Arguments:
  reconstructor - Reconstructor instance
  checkpoint    - Checkpoint to restore from

Returns:
  T if restoration succeeded."
  (sync-log-info "Restoring from checkpoint at height ~A"
                 (checkpoint-height checkpoint))

  ;; Validate checkpoint
  (validate-checkpoint checkpoint)

  ;; In a full implementation, would:
  ;; 1. Load saved state from disk
  ;; 2. Verify against checkpoint hashes
  ;; 3. Resume reconstruction from checkpoint

  t)

(defun list-checkpoints (config)
  "List available checkpoints.

Arguments:
  config - Sync configuration

Returns:
  List of checkpoint instances."
  (let ((path (sync-config-storage-path config)))
    (unless path
      (return-from list-checkpoints nil))

    ;; Would scan storage path for checkpoint files
    nil))

;;;; ============================================================================
;;;; Print Methods
;;;; ============================================================================

(defmethod print-object ((obj reconstructor) stream)
  (print-unreadable-object (obj stream :type t)
    (format stream "~A utxos:~A"
            (reconstructor-state obj)
            (if (reconstructor-utxo-set obj)
                (utxo-set-count (reconstructor-utxo-set obj))
                0))))

(defmethod print-object ((obj utxo-set) stream)
  (print-unreadable-object (obj stream :type t)
    (format stream "count:~A total:~A"
            (utxo-set-count obj)
            (utxo-set-total-value obj))))
