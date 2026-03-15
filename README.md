# cl-state-sync

Pure Common Lisp implementation of State Sync

## Overview
This library provides a robust, zero-dependency implementation of State Sync for the Common Lisp ecosystem. It is designed to be highly portable, performant, and easy to integrate into any SBCL/CCL/ECL environment.

## Getting Started

Load the system using ASDF:

```lisp
(asdf:load-system #:cl-state-sync)
```

## Usage Example

```lisp
;; Initialize the environment
(let ((ctx (cl-state-sync:initialize-state-sync :initial-id 42)))
  ;; Perform batch processing using the built-in standard toolkit
  (multiple-value-bind (results errors)
      (cl-state-sync:state-sync-batch-process '(1 2 3) #'identity)
    (format t "Processed ~A items with ~A errors.~%" (length results) (length errors))))
```

## License
Apache-2.0
