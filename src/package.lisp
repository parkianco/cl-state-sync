;;;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;;;; SPDX-License-Identifier: Apache-2.0

;;;; cl-state-sync - Package Definition
;;;;
;;;; Standalone state synchronization library for blockchain systems.
;;;; Provides snapshot-based recovery and state trie reconstruction.
;;;;
;;;; Pure Common Lisp - zero external dependencies.

(defpackage #:cl-state-sync
  (:use #:cl)
  (:nicknames #:state-sync)
  (:export
   #:with-state-sync-timing
   #:state-sync-batch-process
   #:state-sync-health-check;; ============================================================================
   ;; Configuration
   ;; ============================================================================
   #:sync-config
   #:make-sync-config
   #:config-batch-size
   #:config-request-timeout
   #:config-retry-limit
   #:config-checkpoint-interval
   #:config-storage-path
   #:config-verify-proofs

   ;; ============================================================================
   ;; Snapshot Types
   ;; ============================================================================
   #:snapshot
   #:make-snapshot
   #:snapshot-version
   #:snapshot-block-height
   #:snapshot-block-hash
   #:snapshot-state-root
   #:snapshot-utxo-root
   #:snapshot-timestamp
   #:snapshot-chunks
   #:snapshot-metadata

   #:snapshot-chunk
   #:make-snapshot-chunk
   #:chunk-index
   #:chunk-start-key
   #:chunk-end-key
   #:chunk-hash
   #:chunk-size
   #:chunk-data
   #:chunk-proof

   #:snapshot-header
   #:make-snapshot-header
   #:snapshot-header-magic
   #:snapshot-header-version
   #:snapshot-header-block-height
   #:snapshot-header-chunk-count
   #:snapshot-header-total-size

   ;; ============================================================================
   ;; UTXO Types
   ;; ============================================================================
   #:utxo
   #:make-utxo
   #:utxo-txid
   #:utxo-vout
   #:utxo-value
   #:utxo-script-pubkey
   #:utxo-height
   #:utxo-coinbase-p

   #:utxo-set
   #:make-utxo-set
   #:utxo-set-root
   #:utxo-set-count
   #:utxo-set-total-value

   ;; ============================================================================
   ;; State Trie Types
   ;; ============================================================================
   #:trie-node
   #:make-trie-node
   #:trie-node-hash
   #:trie-node-data
   #:trie-node-children
   #:trie-node-type

   #:trie-proof
   #:make-trie-proof
   #:trie-proof-key
   #:trie-proof-value
   #:trie-proof-nodes

   ;; ============================================================================
   ;; Download Operations
   ;; ============================================================================
   #:download-manager
   #:make-download-manager
   #:start-download
   #:stop-download
   #:pause-download
   #:resume-download
   #:download-status
   #:download-progress

   #:download-task
   #:make-download-task
   #:download-task-id
   #:download-task-type
   #:download-task-status
   #:download-task-retries

   #:request-chunk
   #:process-chunk-response
   #:verify-chunk
   #:store-chunk

   ;; ============================================================================
   ;; Verification Operations
   ;; ============================================================================
   #:verifier
   #:make-verifier
   #:verify-snapshot
   #:verify-chunk-integrity
   #:verify-merkle-proof
   #:verify-utxo-set
   #:verify-state-root
   #:compute-merkle-root

   ;; ============================================================================
   ;; Reconstruction Operations
   ;; ============================================================================
   #:reconstructor
   #:make-reconstructor
   #:start-reconstruction
   #:stop-reconstruction
   #:reconstruction-status
   #:reconstruction-progress

   #:reconstruct-utxo-set
   #:reconstruct-state-trie
   #:reconstruct-from-snapshot
   #:merge-chunks
   #:apply-chunk

   ;; ============================================================================
   ;; Progress Tracking
   ;; ============================================================================
   #:sync-progress
   #:make-sync-progress
   #:sync-progress-phase
   #:sync-progress-current
   #:sync-progress-total
   #:sync-progress-bytes-downloaded
   #:sync-progress-chunks-verified
   #:sync-progress-estimated-remaining

   ;; ============================================================================
   ;; Checkpointing
   ;; ============================================================================
   #:checkpoint
   #:make-checkpoint
   #:checkpoint-height
   #:checkpoint-hash
   #:checkpoint-utxo-root
   #:checkpoint-timestamp

   #:create-checkpoint
   #:restore-from-checkpoint
   #:list-checkpoints
   #:validate-checkpoint

   ;; ============================================================================
   ;; Error Conditions
   ;; ============================================================================
   #:sync-error
   #:sync-error-code
   #:sync-error-message
   #:verification-error
   #:download-error
   #:reconstruction-error
   #:corrupt-snapshot-error

   ;; ============================================================================
   ;; Utility Functions
   ;; ============================================================================
   #:bytes-to-hex
   #:hex-to-bytes
   #:hash-data
   #:current-timestamp
   #:format-bytes

   ;; ============================================================================
   ;; Constants
   ;; ============================================================================
   #:+snapshot-version+
   #:+snapshot-magic+
   #:+max-chunk-size+
   #:+default-batch-size+
   #:+default-timeout+))

(in-package #:cl-state-sync)
