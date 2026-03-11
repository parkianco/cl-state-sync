;;;; cl-state-sync - Chunk Download
;;;;
;;;; Manages downloading snapshot chunks from peers.
;;;; Uses SBCL native threading for parallel downloads.

(in-package #:cl-state-sync)

;;;; ============================================================================
;;;; Download Task
;;;; ============================================================================

(defstruct (download-task
            (:constructor %make-download-task)
            (:copier nil))
  "A single download task.

Slots:
  id       - Unique task ID
  type     - Task type: :chunk, :header, :proof
  chunk-id - Index of chunk to download
  status   - Status: :pending, :active, :complete, :failed
  retries  - Number of retry attempts
  data     - Downloaded data
  error    - Error if failed"
  (id (generate-id) :type fixnum)
  (type :chunk :type keyword)
  (chunk-id 0 :type fixnum)
  (status :pending :type keyword)
  (retries 0 :type fixnum)
  (data nil :type t)
  (error nil :type t))

(defun make-download-task (&key (type :chunk) (chunk-id 0))
  "Create a new download task."
  (%make-download-task
   :type type
   :chunk-id chunk-id))

;;;; ============================================================================
;;;; Download Manager
;;;; ============================================================================

(defstruct (download-manager
            (:constructor %make-download-manager)
            (:copier nil))
  "Manages chunk downloads with parallel workers.

Slots:
  config     - Sync configuration
  state      - Manager state: :idle, :running, :paused, :stopped
  snapshot   - Target snapshot being downloaded
  queue      - Queue of pending tasks
  active     - Currently active tasks
  completed  - Completed chunks
  workers    - Worker thread handles
  progress   - Current progress
  lock       - Mutex for thread safety
  cond       - Condition variable for coordination
  stats      - Download statistics"
  (config nil :type (or null sync-config))
  (state :idle :type keyword)
  (snapshot nil :type (or null snapshot))
  (queue nil :type list)
  (active nil :type list)
  (completed (make-hash-table :test 'eql) :type hash-table)
  (workers nil :type list)
  (progress (make-sync-progress) :type sync-progress)
  (lock (make-lock "download-lock") :read-only t)
  (cond (make-condition-var "download-cond") :read-only t)
  (stats nil :type list))

(defun make-download-manager (&key config snapshot)
  "Create a new download manager."
  (%make-download-manager
   :config (or config (make-sync-config))
   :snapshot snapshot))

;;;; ============================================================================
;;;; Download Operations
;;;; ============================================================================

(defun start-download (manager)
  "Start downloading chunks.

Arguments:
  manager - Download manager

Returns:
  T if started successfully."
  (with-lock ((download-manager-lock manager))
    (when (eq (download-manager-state manager) :running)
      (sync-log-warn "Download already running")
      (return-from start-download nil))

    (let ((snapshot (download-manager-snapshot manager)))
      (unless snapshot
        (sync-log-error "No snapshot configured for download")
        (return-from start-download nil))

      ;; Initialize queue with all chunk tasks
      (let ((chunk-count (length (snapshot-chunks snapshot))))
        (setf (download-manager-queue manager)
              (loop for i from 0 below chunk-count
                    collect (make-download-task :type :chunk :chunk-id i)))

        ;; Update progress
        (setf (sync-progress-phase (download-manager-progress manager)) :downloading)
        (setf (sync-progress-total (download-manager-progress manager)) chunk-count)
        (setf (sync-progress-current (download-manager-progress manager)) 0))

      ;; Start state
      (setf (download-manager-state manager) :running)
      (setf (download-manager-stats manager)
            (list :started (current-timestamp)
                  :bytes 0
                  :chunks 0))

      (sync-log-info "Started download of ~A chunks"
                     (length (download-manager-queue manager)))
      t)))

(defun stop-download (manager)
  "Stop downloading.

Arguments:
  manager - Download manager"
  (with-lock ((download-manager-lock manager))
    (setf (download-manager-state manager) :stopped)
    (sb-thread:condition-broadcast (download-manager-cond manager)))
  (sync-log-info "Download stopped"))

(defun pause-download (manager)
  "Pause downloading.

Arguments:
  manager - Download manager"
  (with-lock ((download-manager-lock manager))
    (when (eq (download-manager-state manager) :running)
      (setf (download-manager-state manager) :paused)
      (sync-log-info "Download paused"))))

(defun resume-download (manager)
  "Resume downloading.

Arguments:
  manager - Download manager"
  (with-lock ((download-manager-lock manager))
    (when (eq (download-manager-state manager) :paused)
      (setf (download-manager-state manager) :running)
      (sb-thread:condition-broadcast (download-manager-cond manager))
      (sync-log-info "Download resumed"))))

(defun download-status (manager)
  "Get current download status.

Arguments:
  manager - Download manager

Returns:
  Status keyword."
  (download-manager-state manager))

(defun download-progress (manager)
  "Get current download progress.

Arguments:
  manager - Download manager

Returns:
  sync-progress instance."
  (download-manager-progress manager))

;;;; ============================================================================
;;;; Task Management
;;;; ============================================================================

(defun next-task (manager)
  "Get the next pending task.

Arguments:
  manager - Download manager

Returns:
  download-task or NIL if none available."
  (with-lock ((download-manager-lock manager))
    (unless (eq (download-manager-state manager) :running)
      (return-from next-task nil))

    (let ((task (pop (download-manager-queue manager))))
      (when task
        (setf (download-task-status task) :active)
        (push task (download-manager-active manager)))
      task)))

(defun complete-task (manager task)
  "Mark a task as complete.

Arguments:
  manager - Download manager
  task    - Completed task"
  (with-lock ((download-manager-lock manager))
    ;; Remove from active
    (setf (download-manager-active manager)
          (remove task (download-manager-active manager)))

    ;; Add to completed
    (setf (gethash (download-task-chunk-id task)
                   (download-manager-completed manager))
          task)

    ;; Update progress
    (incf (sync-progress-current (download-manager-progress manager)))
    (when (download-task-data task)
      (incf (sync-progress-bytes-downloaded (download-manager-progress manager))
            (length (download-task-data task))))

    ;; Update stats
    (incf (getf (download-manager-stats manager) :chunks))

    ;; Signal completion
    (sb-thread:condition-broadcast (download-manager-cond manager))))

(defun fail-task (manager task error)
  "Mark a task as failed.

Arguments:
  manager - Download manager
  task    - Failed task
  error   - Error that occurred"
  (with-lock ((download-manager-lock manager))
    (setf (download-task-error task) error)
    (incf (download-task-retries task))

    (let ((max-retries (sync-config-retry-limit
                        (download-manager-config manager))))
      (if (< (download-task-retries task) max-retries)
          ;; Retry: put back in queue
          (progn
            (setf (download-task-status task) :pending)
            (setf (download-manager-active manager)
                  (remove task (download-manager-active manager)))
            (push task (download-manager-queue manager))
            (sync-log-warn "Task ~A failed, retrying (~A/~A)"
                           (download-task-id task)
                           (download-task-retries task)
                           max-retries))
          ;; Give up
          (progn
            (setf (download-task-status task) :failed)
            (sync-log-error "Task ~A permanently failed: ~A"
                            (download-task-id task) error))))))

(defun retry-task (manager task)
  "Retry a failed task.

Arguments:
  manager - Download manager
  task    - Task to retry"
  (with-lock ((download-manager-lock manager))
    (setf (download-task-status task) :pending)
    (setf (download-task-error task) nil)
    (push task (download-manager-queue manager))))

;;;; ============================================================================
;;;; Chunk Operations
;;;; ============================================================================

(defun request-chunk (manager index)
  "Request a specific chunk.

This is the main entry point for requesting chunk data.
In a real implementation, this would send a network request.

Arguments:
  manager - Download manager
  index   - Chunk index

Returns:
  T if request was sent."
  (declare (ignore manager))
  ;; Placeholder - actual implementation would:
  ;; 1. Select a peer that has this chunk
  ;; 2. Send a request message
  ;; 3. Return the request ID
  (sync-log-debug "Requesting chunk ~A" index)
  t)

(defun process-chunk-response (manager index data)
  "Process a chunk response from a peer.

Arguments:
  manager - Download manager
  index   - Chunk index
  data    - Received chunk data

Returns:
  T if processed successfully."
  (with-lock ((download-manager-lock manager))
    ;; Find the active task for this chunk
    (let ((task (find index (download-manager-active manager)
                      :key #'download-task-chunk-id)))
      (unless task
        (sync-log-warn "Received chunk ~A but no active task" index)
        (return-from process-chunk-response nil))

      ;; Store data in task
      (setf (download-task-data task) data)

      ;; Update snapshot chunk
      (let* ((snapshot (download-manager-snapshot manager))
             (chunk (nth index (snapshot-chunks snapshot))))
        (when chunk
          (setf (chunk-data chunk) data)
          (setf (chunk-size chunk) (length data))))

      ;; Mark complete
      (setf (download-task-status task) :complete)
      (complete-task manager task)

      t)))

(defun store-chunk (manager chunk)
  "Store a downloaded chunk to disk.

Arguments:
  manager - Download manager
  chunk   - Chunk to store

Returns:
  T if stored successfully."
  (let* ((config (download-manager-config manager))
         (path (sync-config-storage-path config)))
    (when path
      (let ((chunk-file (format nil "~A/chunk-~6,'0D.dat"
                                path (chunk-index chunk))))
        ;; Write chunk data
        (with-open-file (out chunk-file
                             :direction :output
                             :element-type '(unsigned-byte 8)
                             :if-exists :supersede)
          (write-sequence (chunk-data chunk) out))
        (sync-log-debug "Stored chunk ~A to ~A"
                        (chunk-index chunk) chunk-file)
        t))))

;;;; ============================================================================
;;;; Download Statistics
;;;; ============================================================================

(defun download-rate (manager)
  "Calculate current download rate in bytes/second.

Arguments:
  manager - Download manager

Returns:
  Download rate as float."
  (let* ((stats (download-manager-stats manager))
         (started (getf stats :started))
         (bytes (sync-progress-bytes-downloaded
                 (download-manager-progress manager))))
    (if (and started (> bytes 0))
        (let ((elapsed (- (current-timestamp) started)))
          (if (> elapsed 0)
              (/ bytes elapsed)
              0.0))
        0.0)))

(defun estimate-remaining-time (manager)
  "Estimate remaining download time.

Arguments:
  manager - Download manager

Returns:
  Estimated seconds remaining."
  (let* ((progress (download-manager-progress manager))
         (current (sync-progress-current progress))
         (total (sync-progress-total progress))
         (remaining (- total current))
         (rate (download-rate manager)))
    (if (and (> remaining 0) (> rate 0))
        ;; Estimate based on average chunk size
        (let ((avg-chunk-size (if (> current 0)
                                  (/ (sync-progress-bytes-downloaded progress) current)
                                  +max-chunk-size+)))
          (floor (* remaining avg-chunk-size) rate))
        0)))

;;;; ============================================================================
;;;; Download Complete Check
;;;; ============================================================================

(defun download-complete-p (manager)
  "Check if download is complete.

Arguments:
  manager - Download manager

Returns:
  T if all chunks downloaded."
  (with-lock ((download-manager-lock manager))
    (let* ((snapshot (download-manager-snapshot manager))
           (total (if snapshot (length (snapshot-chunks snapshot)) 0))
           (completed (hash-table-count (download-manager-completed manager))))
      (and (> total 0) (= completed total)))))

(defun missing-chunks (manager)
  "Get list of missing chunk indices.

Arguments:
  manager - Download manager

Returns:
  List of missing chunk indices."
  (with-lock ((download-manager-lock manager))
    (let* ((snapshot (download-manager-snapshot manager))
           (total (if snapshot (length (snapshot-chunks snapshot)) 0))
           (completed (download-manager-completed manager)))
      (loop for i from 0 below total
            unless (gethash i completed)
            collect i))))

;;;; ============================================================================
;;;; Print Methods
;;;; ============================================================================

(defmethod print-object ((obj download-manager) stream)
  (print-unreadable-object (obj stream :type t)
    (format stream "~A ~A/~A chunks"
            (download-manager-state obj)
            (hash-table-count (download-manager-completed obj))
            (if (download-manager-snapshot obj)
                (length (snapshot-chunks (download-manager-snapshot obj)))
                0))))

(defmethod print-object ((obj download-task) stream)
  (print-unreadable-object (obj stream :type t)
    (format stream "~A chunk:~A ~A"
            (download-task-id obj)
            (download-task-chunk-id obj)
            (download-task-status obj))))
