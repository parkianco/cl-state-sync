;;;; cl-state-sync.asd - Standalone State Sync Library
;;;;
;;;; Pure Common Lisp state synchronization for blockchain systems.
;;;; Provides UTXO snapshot recovery and state trie reconstruction.
;;;;
;;;; Zero external dependencies - uses only SBCL native facilities.

(asdf:defsystem #:cl-state-sync
  :description "Pure CL blockchain state synchronization library"
  :author "CLPIC Project"
  :license "MIT"
  :version "0.1.0"
  :serial t
  :depends-on ()  ; No external deps
  :components
  ((:file "package")
   (:module "src"
    :serial t
    :components
    ((:file "util")
     (:file "snapshot")
     (:file "download")
     (:file "verify")
     (:file "reconstruct"))))
  :in-order-to ((test-op (test-op #:cl-state-sync/test))))

(asdf:defsystem #:cl-state-sync/test
  :description "Tests for cl-state-sync"
  :depends-on (#:cl-state-sync)
  :serial t
  :components
  ((:module "test"
    :components
    ((:file "test-state-sync"))))
  :perform (test-op (o c)
             (uiop:symbol-call :cl-state-sync/test :run-tests)))
