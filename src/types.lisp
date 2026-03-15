;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;; SPDX-License-Identifier: Apache-2.0

(in-package #:cl-state-sync)

;;; Core types for cl-state-sync
(deftype cl-state-sync-id () '(unsigned-byte 64))
(deftype cl-state-sync-status () '(member :ready :active :error :shutdown))
