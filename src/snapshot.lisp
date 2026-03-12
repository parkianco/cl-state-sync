;;;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;;;; SPDX-License-Identifier: BSD-3-Clause

;;;; cl-state-sync - Snapshot Format
;;;;
;;;; Defines the snapshot format for UTXO set and state serialization.
;;;; Supports chunked snapshots for efficient transfer and recovery.

(in-package #:cl-state-sync)

;;;; ============================================================================
;;;; Configuration
;;;; ============================================================================

(defstruct (sync-config
            (:constructor %make-sync-config)
            (:conc-name config-)
            (:copier nil))
  "Configuration for state synchronization.

Slots:
  batch-size          - Items per batch for downloads
  request-timeout     - Timeout for network requests (seconds)
  retry-limit         - Maximum retries per request
  checkpoint-interval - Blocks between checkpoints
  storage-path        - Path for storing state data
  verify-proofs       - Whether to verify Merkle proofs"
  (batch-size +default-batch-size+ :type fixnum)
  (request-timeout +default-timeout+ :type fixnum)
  (retry-limit 3 :type fixnum)
  (checkpoint-interval 10000 :type fixnum)
  (storage-path nil :type (or null string pathname))
  (verify-proofs t :type boolean))

(defun make-sync-config (&key (batch-size +default-batch-size+)
                              (request-timeout +default-timeout+)
                              (retry-limit 3)
                              (checkpoint-interval 10000)
                              storage-path
                              (verify-proofs t))
  "Create a new sync configuration."
  (%make-sync-config
   :batch-size batch-size
   :request-timeout request-timeout
   :retry-limit retry-limit
   :checkpoint-interval checkpoint-interval
   :storage-path storage-path
   :verify-proofs verify-proofs))

;;;; ============================================================================
;;;; Snapshot Header
;;;; ============================================================================

(defstruct (snapshot-header
            (:constructor %make-snapshot-header)
            (:copier nil))
  "Header for a snapshot file.

The header contains metadata needed to parse and verify the snapshot.

Slots:
  magic        - Magic number identifying file format
  version      - Snapshot format version
  block-height - Block height at snapshot time
  chunk-count  - Number of chunks in snapshot
  total-size   - Total size of all chunk data"
  (magic +snapshot-magic+ :type (unsigned-byte 32))
  (version +snapshot-version+ :type (unsigned-byte 16))
  (block-height 0 :type (unsigned-byte 64))
  (chunk-count 0 :type (unsigned-byte 32))
  (total-size 0 :type (unsigned-byte 64)))

(defun make-snapshot-header (&key (magic +snapshot-magic+)
                                  (version +snapshot-version+)
                                  (block-height 0)
                                  (chunk-count 0)
                                  (total-size 0))
  "Create a new snapshot header."
  (%make-snapshot-header
   :magic magic
   :version version
   :block-height block-height
   :chunk-count chunk-count
   :total-size total-size))

;;;; ============================================================================
;;;; Snapshot Chunk
;;;; ============================================================================

(defstruct (snapshot-chunk
            (:constructor %make-snapshot-chunk)
            (:conc-name chunk-)
            (:copier nil))
  "A chunk of snapshot data.

Chunks partition the state into manageable pieces for transfer.

Slots:
  index     - Chunk index within snapshot
  start-key - First key in this chunk (inclusive)
  end-key   - Last key in this chunk (exclusive)
  hash      - Hash of chunk data
  size      - Size of chunk data in bytes
  data      - The chunk data (byte vector)
  proof     - Merkle proof for chunk"
  (index 0 :type fixnum)
  (start-key nil :type (or null (simple-array (unsigned-byte 8) (*))))
  (end-key nil :type (or null (simple-array (unsigned-byte 8) (*))))
  (hash nil :type (or null (simple-array (unsigned-byte 8) (*))))
  (size 0 :type fixnum)
  (data nil :type (or null (simple-array (unsigned-byte 8) (*))))
  (proof nil :type list))

(defun make-snapshot-chunk (&key (index 0) start-key end-key hash (size 0) data proof)
  "Create a new snapshot chunk."
  (%make-snapshot-chunk
   :index index
   :start-key start-key
   :end-key end-key
   :hash hash
   :size size
   :data data
   :proof proof))

;;;; ============================================================================
;;;; Snapshot
;;;; ============================================================================

(defstruct (snapshot
            (:constructor %make-snapshot)
            (:copier nil))
  "Complete snapshot of blockchain state.

A snapshot contains the entire UTXO set and state trie at a
specific block height.

Slots:
  version      - Snapshot format version
  block-height - Block at which snapshot was taken
  block-hash   - Hash of the snapshot block
  state-root   - Root hash of state trie
  utxo-root    - Root hash of UTXO set
  timestamp    - When snapshot was created
  chunks       - List of snapshot chunks
  metadata     - Additional metadata plist"
  (version +snapshot-version+ :type fixnum)
  (block-height 0 :type fixnum)
  (block-hash nil :type (or null (simple-array (unsigned-byte 8) (*))))
  (state-root nil :type (or null (simple-array (unsigned-byte 8) (*))))
  (utxo-root nil :type (or null (simple-array (unsigned-byte 8) (*))))
  (timestamp 0 :type fixnum)
  (chunks nil :type list)
  (metadata nil :type list))

(defun make-snapshot (&key (version +snapshot-version+)
                           (block-height 0)
                           block-hash
                           state-root
                           utxo-root
                           (timestamp (current-timestamp))
                           chunks
                           metadata)
  "Create a new snapshot."
  (%make-snapshot
   :version version
   :block-height block-height
   :block-hash block-hash
   :state-root state-root
   :utxo-root utxo-root
   :timestamp timestamp
   :chunks chunks
   :metadata metadata))

;;;; ============================================================================
;;;; UTXO Types
;;;; ============================================================================

(defstruct (utxo
            (:constructor %make-utxo)
            (:copier nil))
  "Unspent Transaction Output.

Slots:
  txid          - Transaction ID (32 bytes)
  vout          - Output index
  value         - Value in satoshis
  script-pubkey - Locking script
  height        - Block height where created
  coinbase-p    - Whether from coinbase tx"
  (txid nil :type (or null (simple-array (unsigned-byte 8) (*))))
  (vout 0 :type fixnum)
  (value 0 :type (unsigned-byte 64))
  (script-pubkey nil :type (or null (simple-array (unsigned-byte 8) (*))))
  (height 0 :type fixnum)
  (coinbase-p nil :type boolean))

(defun make-utxo (&key txid (vout 0) (value 0) script-pubkey (height 0) coinbase-p)
  "Create a new UTXO."
  (%make-utxo
   :txid txid
   :vout vout
   :value value
   :script-pubkey script-pubkey
   :height height
   :coinbase-p coinbase-p))

(defun utxo-outpoint (utxo)
  "Get the outpoint (txid:vout) for a UTXO."
  (let ((result (make-array 36 :element-type '(unsigned-byte 8))))
    (when (utxo-txid utxo)
      (replace result (utxo-txid utxo)))
    (let ((vout (utxo-vout utxo)))
      (setf (aref result 32) (ldb (byte 8 0) vout))
      (setf (aref result 33) (ldb (byte 8 8) vout))
      (setf (aref result 34) (ldb (byte 8 16) vout))
      (setf (aref result 35) (ldb (byte 8 24) vout)))
    result))

(defstruct (utxo-set
            (:constructor %make-utxo-set)
            (:copier nil))
  "Complete UTXO set.

Slots:
  root        - Merkle root of the set
  count       - Number of UTXOs
  total-value - Sum of all UTXO values"
  (root nil :type (or null (simple-array (unsigned-byte 8) (*))))
  (count 0 :type fixnum)
  (total-value 0 :type (unsigned-byte 64)))

(defun make-utxo-set (&key root (count 0) (total-value 0))
  "Create a new UTXO set."
  (%make-utxo-set
   :root root
   :count count
   :total-value total-value))

;;;; ============================================================================
;;;; State Trie Types
;;;; ============================================================================

(defstruct (trie-node
            (:constructor %make-trie-node)
            (:copier nil))
  "A node in the state trie.

Slots:
  hash     - Hash of this node
  data     - Node data (encoded)
  children - Child node hashes (for branch nodes)
  type     - Node type: :leaf, :extension, :branch"
  (hash nil :type (or null (simple-array (unsigned-byte 8) (*))))
  (data nil :type (or null (simple-array (unsigned-byte 8) (*))))
  (children nil :type list)
  (type :leaf :type keyword))

(defun make-trie-node (&key hash data children (type :leaf))
  "Create a new trie node."
  (%make-trie-node
   :hash hash
   :data data
   :children children
   :type type))

(defstruct (trie-proof
            (:constructor %make-trie-proof)
            (:copier nil))
  "Merkle proof for a trie value.

Slots:
  key   - The key being proven
  value - The value at the key
  nodes - List of nodes in proof path"
  (key nil :type (or null (simple-array (unsigned-byte 8) (*))))
  (value nil :type (or null (simple-array (unsigned-byte 8) (*))))
  (nodes nil :type list))

(defun make-trie-proof (&key key value nodes)
  "Create a new trie proof."
  (%make-trie-proof
   :key key
   :value value
   :nodes nodes))

;;;; ============================================================================
;;;; Checkpoint
;;;; ============================================================================

(defstruct (checkpoint
            (:constructor %make-checkpoint)
            (:copier nil))
  "State checkpoint for recovery.

Slots:
  height    - Block height
  hash      - Block hash
  utxo-root - UTXO set root
  timestamp - When checkpoint was created"
  (height 0 :type fixnum)
  (hash nil :type (or null (simple-array (unsigned-byte 8) (*))))
  (utxo-root nil :type (or null (simple-array (unsigned-byte 8) (*))))
  (timestamp 0 :type fixnum))

(defun make-checkpoint (&key (height 0) hash utxo-root (timestamp (current-timestamp)))
  "Create a new checkpoint."
  (%make-checkpoint
   :height height
   :hash hash
   :utxo-root utxo-root
   :timestamp timestamp))

;;;; ============================================================================
;;;; Progress Tracking
;;;; ============================================================================

(defstruct (sync-progress
            (:constructor %make-sync-progress)
            (:copier nil))
  "Progress tracking for synchronization.

Slots:
  phase               - Current phase: :downloading, :verifying, :reconstructing
  current             - Current item number
  total               - Total items
  bytes-downloaded    - Bytes downloaded so far
  chunks-verified     - Chunks verified so far
  estimated-remaining - Estimated time remaining (seconds)"
  (phase :idle :type keyword)
  (current 0 :type fixnum)
  (total 0 :type fixnum)
  (bytes-downloaded 0 :type fixnum)
  (chunks-verified 0 :type fixnum)
  (estimated-remaining 0 :type fixnum))

(defun make-sync-progress (&key (phase :idle) (current 0) (total 0)
                                (bytes-downloaded 0) (chunks-verified 0)
                                (estimated-remaining 0))
  "Create sync progress tracker."
  (%make-sync-progress
   :phase phase
   :current current
   :total total
   :bytes-downloaded bytes-downloaded
   :chunks-verified chunks-verified
   :estimated-remaining estimated-remaining))

(defun progress-percentage (progress)
  "Calculate progress as a percentage."
  (if (zerop (sync-progress-total progress))
      0.0
      (* 100.0 (/ (sync-progress-current progress)
                  (sync-progress-total progress)))))

;;;; ============================================================================
;;;; Snapshot Serialization
;;;; ============================================================================

(defun serialize-snapshot-header (header)
  "Serialize a snapshot header to bytes."
  (let ((bytes (make-array 22 :element-type '(unsigned-byte 8))))
    ;; Magic (4 bytes, big-endian)
    (let ((magic (snapshot-header-magic header)))
      (setf (aref bytes 0) (ldb (byte 8 24) magic))
      (setf (aref bytes 1) (ldb (byte 8 16) magic))
      (setf (aref bytes 2) (ldb (byte 8 8) magic))
      (setf (aref bytes 3) (ldb (byte 8 0) magic)))
    ;; Version (2 bytes)
    (let ((ver (snapshot-header-version header)))
      (setf (aref bytes 4) (ldb (byte 8 8) ver))
      (setf (aref bytes 5) (ldb (byte 8 0) ver)))
    ;; Block height (8 bytes)
    (let ((height (snapshot-header-block-height header)))
      (loop for i from 0 below 8
            do (setf (aref bytes (+ 6 i))
                     (ldb (byte 8 (* 8 (- 7 i))) height))))
    ;; Chunk count (4 bytes)
    (let ((count (snapshot-header-chunk-count header)))
      (setf (aref bytes 14) (ldb (byte 8 24) count))
      (setf (aref bytes 15) (ldb (byte 8 16) count))
      (setf (aref bytes 16) (ldb (byte 8 8) count))
      (setf (aref bytes 17) (ldb (byte 8 0) count)))
    ;; Total size placeholder (4 bytes at end for alignment)
    bytes))

(defun parse-snapshot-header (bytes)
  "Parse a snapshot header from bytes."
  (when (< (length bytes) 22)
    (error "Snapshot header too short"))
  (let ((magic (logior (ash (aref bytes 0) 24)
                       (ash (aref bytes 1) 16)
                       (ash (aref bytes 2) 8)
                       (aref bytes 3))))
    (unless (= magic +snapshot-magic+)
      (error "Invalid snapshot magic: ~X" magic)))
  (make-snapshot-header
   :version (logior (ash (aref bytes 4) 8) (aref bytes 5))
   :block-height (loop for i from 0 below 8
                       sum (ash (aref bytes (+ 6 i)) (* 8 (- 7 i))))
   :chunk-count (logior (ash (aref bytes 14) 24)
                        (ash (aref bytes 15) 16)
                        (ash (aref bytes 16) 8)
                        (aref bytes 17))))

;;;; ============================================================================
;;;; Print Methods
;;;; ============================================================================

(defmethod print-object ((obj snapshot) stream)
  (print-unreadable-object (obj stream :type t)
    (format stream "height:~A chunks:~A"
            (snapshot-block-height obj)
            (length (snapshot-chunks obj)))))

(defmethod print-object ((obj snapshot-chunk) stream)
  (print-unreadable-object (obj stream :type t)
    (format stream "index:~A size:~A"
            (chunk-index obj)
            (format-bytes (chunk-size obj)))))

(defmethod print-object ((obj sync-progress) stream)
  (print-unreadable-object (obj stream :type t)
    (format stream "~A ~,1F%"
            (sync-progress-phase obj)
            (progress-percentage obj))))
