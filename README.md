# cl-state-sync

Pure Common Lisp state synchronization library for blockchain systems.

## Overview

cl-state-sync provides UTXO snapshot recovery and state trie reconstruction capabilities with zero external dependencies. It is designed for efficient blockchain state synchronization using chunked snapshots and Merkle proofs.

## Features

- **Snapshot-based sync**: Download and verify state snapshots in chunks
- **UTXO set recovery**: Reconstruct complete UTXO sets from snapshots
- **State trie reconstruction**: Rebuild state tries from serialized data
- **Merkle proof verification**: Verify data integrity with cryptographic proofs
- **Checkpointing**: Save and restore sync progress
- **Parallel downloads**: Multi-threaded chunk downloading (SBCL native threading)
- **Pure Common Lisp**: Zero external dependencies

## Requirements

- SBCL (Steel Bank Common Lisp)
- ASDF (bundled with SBCL)

## Installation

```lisp
;; Clone the repository
;; cd cl-state-sync

;; Load the system
(asdf:load-system :cl-state-sync)
```

## Quick Start

```lisp
(use-package :cl-state-sync)

;; Create configuration
(defvar *config*
  (make-sync-config
   :batch-size 1024
   :request-timeout 30
   :verify-proofs t
   :storage-path "/tmp/state-sync/"))

;; Create a snapshot (normally received from peers)
(defvar *snapshot*
  (make-snapshot
   :block-height 500000
   :block-hash (hex-to-bytes "...")
   :state-root (hex-to-bytes "...")
   :utxo-root (hex-to-bytes "...")))

;; Verify snapshot integrity
(let ((verifier (make-verifier :config *config*)))
  (verify-snapshot verifier *snapshot*))

;; Reconstruct state
(let ((reconstructor (make-reconstructor :config *config*
                                         :snapshot *snapshot*)))
  (start-reconstruction reconstructor)
  (reconstruct-from-snapshot reconstructor))
```

## Architecture

### Modules

- **snapshot.lisp**: Snapshot format, UTXO types, state trie types
- **download.lisp**: Chunk download management with parallel workers
- **verify.lisp**: Integrity verification and Merkle proof validation
- **reconstruct.lisp**: UTXO set and state trie reconstruction
- **util.lisp**: Byte utilities, hashing, logging, threading helpers

### Data Flow

```
Snapshot (from peers)
    |
    v
+-------------------+
| Download Manager  |  <-- Parallel chunk downloads
+-------------------+
    |
    v
+-------------------+
|     Verifier      |  <-- Hash + proof verification
+-------------------+
    |
    v
+-------------------+
|   Reconstructor   |  <-- UTXO + trie rebuild
+-------------------+
    |
    v
Reconstructed State
```

## API Reference

### Configuration

```lisp
(make-sync-config &key batch-size request-timeout retry-limit
                       checkpoint-interval storage-path verify-proofs)
```

### Snapshot Types

```lisp
;; Create snapshot
(make-snapshot &key version block-height block-hash
                    state-root utxo-root timestamp chunks metadata)

;; Create chunk
(make-snapshot-chunk &key index start-key end-key hash size data proof)

;; Create UTXO
(make-utxo &key txid vout value script-pubkey height coinbase-p)
```

### Download Operations

```lisp
;; Create download manager
(make-download-manager &key config snapshot)

;; Control downloads
(start-download manager)
(stop-download manager)
(pause-download manager)
(resume-download manager)

;; Check status
(download-status manager)      ; => :idle, :running, :paused, :stopped
(download-progress manager)    ; => sync-progress instance
(download-complete-p manager)  ; => t/nil
```

### Verification

```lisp
;; Create verifier
(make-verifier &key config)

;; Verify snapshot
(verify-snapshot verifier snapshot)

;; Verify individual components
(verify-chunk-integrity chunk)
(verify-merkle-proof root key value proof-nodes)
(compute-merkle-root leaves)
```

### Reconstruction

```lisp
;; Create reconstructor
(make-reconstructor &key config snapshot)

;; Run reconstruction
(start-reconstruction reconstructor)
(reconstruct-from-snapshot reconstructor)

;; Access results
(reconstructor-utxo-set reconstructor)
(reconstructor-trie-root reconstructor)
```

### Checkpointing

```lisp
(create-checkpoint reconstructor)
(restore-from-checkpoint reconstructor checkpoint)
(list-checkpoints config)
(validate-checkpoint checkpoint)
```

## Error Handling

The library defines the following error conditions:

- `sync-error`: Base condition for all sync errors
- `verification-error`: Data verification failures
- `download-error`: Download/network failures
- `reconstruction-error`: State reconstruction failures
- `corrupt-snapshot-error`: Invalid snapshot data

```lisp
(handler-case
    (verify-snapshot verifier snapshot)
  (verification-error (e)
    (format t "Verification failed: ~A" (sync-error-message e))))
```

## Testing

```lisp
(asdf:test-system :cl-state-sync)
```

Or load and run tests directly:

```lisp
(asdf:load-system :cl-state-sync/test)
(cl-state-sync/test:run-tests)
```

## Thread Safety

All shared state is protected by `sb-thread:mutex`. The library uses SBCL native threading (`sb-thread:make-thread`) for parallel operations.

## Performance Considerations

- Chunk size is limited to 16 MB to balance memory usage and transfer efficiency
- Default batch size is 1024 items
- Merkle proof verification is O(log n) per proof
- Parallel download workers can be configured based on available bandwidth

## License

MIT License - see LICENSE file.

## Acknowledgments

Extracted from the CLPIC (Common Lisp P2P Intellectual Property Chain) project.
