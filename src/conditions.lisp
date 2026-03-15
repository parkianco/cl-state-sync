;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;; SPDX-License-Identifier: Apache-2.0

(in-package #:cl-state-sync)

(define-condition cl-state-sync-error (error)
  ((message :initarg :message :reader cl-state-sync-error-message))
  (:report (lambda (condition stream)
             (format stream "cl-state-sync error: ~A" (cl-state-sync-error-message condition)))))
