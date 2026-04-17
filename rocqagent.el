;;; rocqagent.el --- Minimal Rocq/Proof General agent API -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)

(define-error 'rocqagent-interrupted "Rocqagent operation interrupted")

(defvar rocqagent--active-kind nil
  "Kind of the currently running rocqagent operation, or nil.")

(defvar rocqagent--active-file nil
  "Absolute filename for the currently running rocqagent operation, or nil.")

(defvar rocqagent--active-buffer nil
  "Buffer associated with the currently running rocqagent operation, or nil.")

(defvar rocqagent--active-process nil
  "Non-proof-shell subprocess tracked by the current rocqagent operation.")

(defvar rocqagent--active-id nil
  "Identifier for the currently running rocqagent operation, or nil.")

(defvar rocqagent--active-cancel-file nil
  "Filesystem cancel token path for the current rocqagent operation.")

(defvar rocqagent--active-status-file nil
  "Filesystem status path for the current rocqagent server.")

(defvar rocqagent--status-last-touch 0.0
  "Last time the status file was refreshed for the current operation.")

(defvar rocqagent--cancel-requested nil
  "Non-nil when the current rocqagent operation should be interrupted.")

(defvar rocqagent--interrupt-sent nil
  "Non-nil when an interrupt has already been sent for the current operation.")

(defvar rocqagent--next-operation-id 0
  "Monotone counter used to identify rocqagent operations.")

(defvar rocqagent--latest-result nil
  "Most recent completed rocqagent result plist for the current server.")

(defvar rocqagent--active-target nil
  "Current target point for the active rocqagent check, or nil.")

(defvar rocqagent--active-subphase nil
  "Current finer-grained phase for the active operation, or nil.")

(defun rocqagent--control-dir ()
  "Return the directory that stores rocqagent control files."
  (let ((dir (expand-file-name "rocqagent" temporary-file-directory)))
    (make-directory dir t)
    dir))

(defun rocqagent--server-tag ()
  "Return a filesystem-safe tag for the current Emacs server."
  (replace-regexp-in-string
   "[^[:alnum:]_.-]" "_"
   (or (and (boundp 'server-name) server-name)
       "default")))

(defun rocqagent--server-socket-name ()
  "Return the actual Emacs server socket name."
  (or (and (boundp 'server-name) server-name)
      "server"))

(defun rocqagent--status-file ()
  "Return the status file path for the current Emacs server."
  (expand-file-name
   (format "%s.status" (rocqagent--server-tag))
   (rocqagent--control-dir)))

(defun rocqagent--socket-dir ()
  "Return the directory where the current Emacs server socket lives, if known."
  (cond
   ((and (boundp 'server-socket-dir)
         (stringp server-socket-dir)
         (not (string-empty-p server-socket-dir)))
    (expand-file-name server-socket-dir))
   ((and (boundp 'server-auth-dir)
         (stringp server-auth-dir)
         (not (string-empty-p server-auth-dir)))
    (expand-file-name server-auth-dir))
   (t nil)))

(defun rocqagent--socket-path ()
  "Return the expected socket path for the current Emacs server, if known."
  (let ((dir (rocqagent--socket-dir)))
    (when dir
      (expand-file-name
       (rocqagent--server-socket-name)
       dir))))

(defun rocqagent--fresh-cancel-file ()
  "Return a fresh random cancel token path for one rocqagent operation."
  (make-temp-name
   (expand-file-name
    (format "%s-cancel-" (rocqagent--server-tag))
    (rocqagent--control-dir))))

(defun rocqagent--process-pid (&optional proc)
  "Return the OS PID of PROC when available."
  (when (and (processp proc)
             (process-live-p proc)
             (fboundp 'process-id))
    (process-id proc)))

(defun rocqagent--process-comm-from-pid (pid)
  "Return the kernel command name for PID when available."
  (when (and (integerp pid) (> pid 0))
    (let ((attrs (ignore-errors (process-attributes pid))))
      (when attrs
        (cdr (assq 'comm attrs))))))

(defun rocqagent--linux-pid-startticks (pid)
  "Return Linux `/proc/<pid>/stat` start-time ticks for PID, or nil."
  (when (and (integerp pid) (> pid 0))
    (let ((path (format "/proc/%d/stat" pid)))
      (when (file-readable-p path)
        (with-temp-buffer
          (insert-file-contents path)
          (let* ((text (buffer-string))
                 (close (cl-position ?\) text :from-end t)))
            (when close
              (let* ((rest (substring text (+ close 2)))
                     (fields (split-string rest " " t)))
                ;; rest starts at stat field 3 (state), so field 22 is index 19.
                (when (> (length fields) 19)
                  (string-to-number (nth 19 fields)))))))))))

(defun rocqagent--tracked-process-plist (prefix pid)
  "Return status plist entries for PID under PREFIX."
  (let ((comm (rocqagent--process-comm-from-pid pid))
        (startticks (rocqagent--linux-pid-startticks pid)))
    (append
     (when pid
       (list (intern (format ":%s-pid" prefix)) pid))
     (when comm
       (list (intern (format ":%s-comm" prefix)) comm))
     (when startticks
       (list (intern (format ":%s-startticks" prefix)) startticks)))))

(defun rocqagent--write-file-atomically (path writer)
  "Write PATH atomically by calling WRITER in a temp buffer and renaming.
WRITER is called with the temp buffer current."
  (let* ((dir (file-name-directory path))
         (name (file-name-nondirectory path))
         (temp (make-temp-file
                (expand-file-name (format ".%s.tmp-" name) dir)))
         (mode (and (file-exists-p path)
                    (file-modes path))))
    (unwind-protect
        (progn
          (with-temp-file temp
            (funcall writer))
          (when mode
            (set-file-modes temp mode))
          (rename-file temp path t)
          path)
      (when (file-exists-p temp)
        (ignore-errors
          (delete-file temp))))))

(defun rocqagent--write-status-plist (plist)
  "Write PLIST atomically to the current server's status file."
  (let ((path (or rocqagent--active-status-file
                  (rocqagent--status-file)))
        (socket-dir (rocqagent--socket-dir))
        (socket-path (rocqagent--socket-path))
        (emacs-pid (emacs-pid))
        (proof-pid (rocqagent--process-pid (rocqagent--proof-shell-process)))
        (active-pid (rocqagent--process-pid rocqagent--active-process)))
    (rocqagent--write-file-atomically
     path
     (lambda ()
        (let ((print-length nil)
              (print-level nil))
          (prin1
           (append
            plist
            (list :server (rocqagent--server-tag)
                  :server-name (rocqagent--server-socket-name)
                  :emacs-pid emacs-pid)
            (rocqagent--tracked-process-plist "emacs" emacs-pid)
            (rocqagent--tracked-process-plist "proof" proof-pid)
            (rocqagent--tracked-process-plist "active" active-pid)
            (list :socket-dir socket-dir
                  :socket-path socket-path
                  :updated-at (float-time)))
           (current-buffer)))))
    path))

(defun rocqagent--write-status (busy &optional kind file op-id cancel-file phase result)
  "Write a shell-visible status plist for the current server.
When BUSY is non-nil, include KIND, FILE, OP-ID, CANCEL-FILE, and PHASE.
When RESULT is non-nil, persist it in the status file."
  (let ((plist
         (append
          (list :busy (and busy t))
          (when phase (list :phase phase))
          (when kind (list :kind kind))
          (when file (list :file file))
          (when op-id (list :id op-id))
          (when cancel-file (list :cancel-file cancel-file))
          (when rocqagent--active-target (list :target rocqagent--active-target))
          (when (and busy rocqagent--active-subphase)
            (list :subphase rocqagent--active-subphase))
          (when (and (buffer-live-p rocqagent--active-buffer)
                     (with-current-buffer rocqagent--active-buffer
                       (fboundp 'proof-unprocessed-begin)))
            (list :locked-end
                  (with-current-buffer rocqagent--active-buffer
                    (proof-unprocessed-begin))))
          (when result (list :result result)))))
    (setq rocqagent--status-last-touch (float-time))
    (rocqagent--write-status-plist plist)))

(defun rocqagent--set-subphase (subphase &optional force)
  "Record SUBPHASE for the active operation and refresh status if needed."
  (when rocqagent--active-kind
    (when (or force
              (not (eq rocqagent--active-subphase subphase)))
      (setq rocqagent--active-subphase subphase)
      (rocqagent--write-status
       t
       rocqagent--active-kind
       rocqagent--active-file
       rocqagent--active-id
       rocqagent--active-cancel-file
       'running))))

(defun rocqagent--touch-status (&optional phase)
  "Refresh the current status file while an operation is active."
  (when rocqagent--active-kind
    (let ((now (float-time)))
      (when (> (- now rocqagent--status-last-touch) 0.25)
        (rocqagent--write-status
         t
         rocqagent--active-kind
         rocqagent--active-file
         rocqagent--active-id
         rocqagent--active-cancel-file
         (or phase 'running))))))

(defun rocqagent--external-cancel-requested-p ()
  "Return non-nil when the current operation's cancel token has been touched."
  (and (stringp rocqagent--active-cancel-file)
       (file-exists-p rocqagent--active-cancel-file)))

(defun rocqagent--begin-operation (kind file buf)
  "Record a running rocqagent operation of KIND for FILE in BUF."
  (when rocqagent--active-kind
    (error "Another rocqagent operation is already active (id=%s kind=%s)"
           rocqagent--active-id rocqagent--active-kind))
  (let* ((expanded-file (expand-file-name file))
         (op-id (cl-incf rocqagent--next-operation-id))
         (cancel-file (rocqagent--fresh-cancel-file))
         (status-file (rocqagent--status-file)))
    (setq rocqagent--active-kind kind
          rocqagent--active-file expanded-file
          rocqagent--active-id op-id
          rocqagent--active-cancel-file cancel-file
          rocqagent--active-status-file status-file
          rocqagent--active-buffer buf
          rocqagent--active-process nil
          rocqagent--cancel-requested nil
          rocqagent--interrupt-sent nil
          rocqagent--latest-result nil
          rocqagent--active-target nil
          rocqagent--active-subphase nil
          rocqagent--status-last-touch 0.0)
    (rocqagent--write-status t kind expanded-file op-id cancel-file 'running)
    op-id))

(defun rocqagent--finish-operation (&optional phase result)
  "Clear the currently tracked rocqagent operation.
PHASE defaults to `done'. RESULT, when non-nil, is stored in the status file."
  (let ((kind rocqagent--active-kind)
        (file rocqagent--active-file)
        (op-id rocqagent--active-id)
        (cancel-file rocqagent--active-cancel-file)
        (proof-proc (rocqagent--proof-shell-process rocqagent--active-buffer))
        (active-proc rocqagent--active-process))
    (when (stringp cancel-file)
      (ignore-errors
        (delete-file cancel-file)))
    (ignore-errors
      (rocqagent--unlock-process-thread proof-proc))
    (ignore-errors
      (rocqagent--unlock-process-thread active-proc))
    (setq rocqagent--latest-result result)
    (rocqagent--write-status nil kind file op-id nil (or phase 'done) result)
    (setq rocqagent--active-kind nil
          rocqagent--active-file nil
          rocqagent--active-id nil
          rocqagent--active-cancel-file nil
          rocqagent--active-status-file nil
          rocqagent--active-buffer nil
          rocqagent--active-process nil
          rocqagent--active-target nil
          rocqagent--active-subphase nil
          rocqagent--status-last-touch 0.0
          rocqagent--cancel-requested nil
          rocqagent--interrupt-sent nil)))

(defun rocqagent--busy-p (&optional buf proc)
  "Return non-nil when BUF or PROC is still busy for the current operation."
  (or (and (processp proc) (process-live-p proc))
      (and (buffer-live-p buf)
           (with-current-buffer buf
             (and (boundp 'proof-shell-busy) proof-shell-busy)))))

(defun rocqagent--proof-shell-process (&optional buf)
  "Return the live Proof General process for BUF, or nil."
  (let ((script-buf (or buf
                        rocqagent--active-buffer
                        (and (boundp 'proof-script-buffer) proof-script-buffer))))
    (when (buffer-live-p script-buf)
      (with-current-buffer script-buf
        (let ((shell-buf (and (boundp 'proof-shell-buffer) proof-shell-buffer)))
          (and (buffer-live-p shell-buf)
               (get-buffer-process shell-buf)))))))

(defun rocqagent--claim-process-thread (&optional proc)
  "Move PROC's Emacs thread lock to the current thread when needed."
  (let ((p (or proc (rocqagent--proof-shell-process))))
    (when (and (processp p)
               (process-live-p p)
               (fboundp 'process-thread)
               (fboundp 'set-process-thread))
      (let ((owner (process-thread p))
            (me (current-thread)))
        (unless (eq owner me)
          (set-process-thread p me))))
    p))

(defun rocqagent--unlock-process-thread (&optional proc)
  "Release PROC's Emacs thread lock."
  (let ((p (or proc (rocqagent--proof-shell-process))))
    (when (and (processp p)
               (process-live-p p)
               (fboundp 'set-process-thread))
      (set-process-thread p nil))))

(defun rocqagent--signal-interrupt (&optional hard)
  "Interrupt the active rocqagent operation.
When HARD is non-nil, escalate to killing the tracked subprocess or shell."
  (let ((buf rocqagent--active-buffer)
        (proc rocqagent--active-process))
    (setq rocqagent--cancel-requested t)
    (unless rocqagent--interrupt-sent
      (setq rocqagent--interrupt-sent t)
      (cond
       ((process-live-p proc)
        (condition-case _err
            (interrupt-process proc)
          (error nil))
        (when hard
          (condition-case _err
              (kill-process proc)
            (error nil))))
       ((buffer-live-p buf)
        (with-current-buffer buf
          (when (and (boundp 'proof-shell-buffer)
                     (buffer-live-p proof-shell-buffer))
            (condition-case _err
                (if hard
                    (proof-shell-exit t)
                  (proof-interrupt-process))
              (error nil)))))))))

(defun rocqagent--maybe-handle-cancel (&optional buf proc)
  "Abort the current operation if cancellation has been requested."
  (when (rocqagent--external-cancel-requested-p)
    (setq rocqagent--cancel-requested t)
    (ignore-errors
      (delete-file rocqagent--active-cancel-file)))
  (when rocqagent--cancel-requested
    (unless rocqagent--interrupt-sent
      (rocqagent--signal-interrupt))
    (unless (rocqagent--busy-p buf proc)
      (signal 'rocqagent-interrupted nil))))

(defun rocqagent--wait-for-process-with-ui (proc &optional ui-buf)
  "Wait for PROC to finish while keeping Emacs responsive."
  (rocqagent--set-subphase 'dune-deps t)
  (while (process-live-p proc)
    (rocqagent--maybe-handle-cancel ui-buf proc)
    (rocqagent--touch-status 'running)
    (accept-process-output nil 0.05)
    (thread-yield)
    (redisplay t))
  (rocqagent--maybe-handle-cancel ui-buf proc)
  (process-exit-status proc))

(defun my-coq--interrupted-result (&optional locked-end target)
  "Return a plist describing an interrupted operation."
  (append (list :ok nil :error "Interrupted" :interrupted t)
          (when locked-end (list :locked-end locked-end))
          (when target (list :target target))))

(defun find-root (buffer-name)
  "Find the dune workspace root containing BUFFER-NAME."
  (locate-dominating-file buffer-name "dune-workspace"))

(defun rocqagent--buffer-string (buf)
  "Return trimmed plain text from BUF, or the empty string if BUF is dead."
  (if (buffer-live-p buf)
      (with-current-buffer buf
        (string-trim
         (buffer-substring-no-properties (point-min) (point-max))))
    ""))

(defun reload-to-current-point_aux (vfilename vfilebuf _syncCIDuneCacheFirst)
  "Restart Rocq for VFILENAME and process to point in VFILEBUF."
  (interactive)
  (when (= (point) (point-min))
    ;; If the file was just opened, checking to EOF is usually intended.
    (goto-char (point-max)))
  (when (buffer-live-p proof-shell-buffer)
    (proof-shell-exit t))
  (let* ((dune-buffer (get-buffer-create "*compile-deps-dune*"))
         (proot (find-root (buffer-file-name))))
    (with-current-buffer dune-buffer
      (compilation-mode)
      (read-only-mode -1)
      (setq default-directory proot)
      (erase-buffer)
      (goto-char (point-max)))
    (switch-to-buffer dune-buffer)
    (rocqagent--maybe-handle-cancel vfilebuf)
    (let* ((default-directory proot)
           (proc (start-file-process
                  "rocqagent-dune-top"
                  dune-buffer
                  "dune" "rocq" "top" "--toplevel=true"
                  (file-relative-name vfilename proot)))
           (retcode nil))
      (setq rocqagent--active-process proc)
      (unwind-protect
          (setq retcode (rocqagent--wait-for-process-with-ui proc vfilebuf))
        (when (eq rocqagent--active-process proc)
          (setq rocqagent--active-process nil)))
      (if (eq retcode 0)
          (progn
            (switch-to-buffer vfilebuf)
            (proof-goto-point)
            (list :ok t))
        (list :ok nil
              :error (let ((text (rocqagent--buffer-string dune-buffer)))
                         (if (> (length text) 0)
                             text
                         (format "dune rocq top failed with exit code %s" retcode)))
              :retcode retcode
              :source 'dune-top)))))

(defun my-coq--none-like-p (x)
  "Return non-nil when X means \"no value\" for API callers."
  (or (null x)
      (eq x :none)
      (eq x 'none)
      (eq x 'None)
      (and (stringp x)
           (member (downcase x) '("none" "nil")))))

(defmacro my-coq--without-file-change-prompts (&rest body)
  "Run BODY while auto-accepting supersession prompts."
  `(cl-letf (((symbol-function 'ask-user-about-supersession-threat)
              (lambda (&rest _args) t)))
     ,@body))

(defun save-file (filename)
  "Save existing buffer visiting FILENAME, if that buffer is open."
  (interactive "fFile: ")
  (condition-case err
      (my-coq--without-file-change-prompts
        (let* ((file (expand-file-name filename))
               (buf (get-file-buffer file)))
          (if (not (buffer-live-p buf))
              (list :ok t :file file :buffer-live nil :saved nil)
            (with-current-buffer buf
              (let ((was-modified (buffer-modified-p)))
                (when was-modified
                  (let ((inhibit-message t))
                    (save-buffer)))
                (list :ok t
                      :file file
                      :buffer-live t
                      :saved was-modified
                      :modified (buffer-modified-p)))))))
    (error
     (list :ok nil :error (error-message-string err)))))

(defun my-coq--coerce-integer (x name)
  "Return X as integer, or signal an error mentioning NAME."
  (cond
   ((integerp x) x)
   ((and (stringp x) (string-match-p (rx bos (? "-") (+ digit) eos) x))
    (string-to-number x))
   (t
    (error "Expected integer for %s, got: %S" name x))))

(defun my-coq--target-point-from-line-column (line column)
  "Return target point for LINE and COLUMN in current buffer.
LINE is 1-based and COLUMN is 0-based. If both are nil/None-like, return EOF."
  (if (and (my-coq--none-like-p line) (my-coq--none-like-p column))
      (if (fboundp 'proof-script-end)
          (proof-script-end)
        (point-max))
    (when (my-coq--none-like-p line)
      (error "linenum must be non-nil when columnnum is provided"))
    (let ((linenum (max 1 (my-coq--coerce-integer line "linenum")))
          (columnnum (if (my-coq--none-like-p column)
                         0
                       (max 0 (my-coq--coerce-integer column "columnnum")))))
      (save-excursion
        (goto-char (point-min))
        (forward-line (1- linenum))
        (move-to-column columnnum)
        (let ((raw-point (point))
              (script-end (if (fboundp 'proof-script-end)
                              (proof-script-end)
                            (point-max))))
          (min raw-point script-end))))))

(defun my-coq--goto-safe-processing-point (target-point)
  "Move point near TARGET-POINT, avoiding `proof-goto-point' EOF edge cases."
  (let ((clamped (min (max target-point (point-min)) (point-max))))
    (goto-char
     (if (and (= clamped (point-max))
              (> (point-max) (point-min)))
         (1- clamped)
       clamped))))

(defun my-coq--goals-string ()
  "Return plain-text goal buffer contents."
  (let ((goals
         (if (buffer-live-p proof-goals-buffer)
             (with-current-buffer proof-goals-buffer
               (string-trim
                (buffer-substring-no-properties (point-min) (point-max))))
           "")))
    (if (> (length goals) 0)
        goals
      (condition-case _err
          (let* ((raw (and (fboundp 'proof-shell-invisible-command)
                           (my-coq--run-invisible-command-with-ui
                            "Show."
                            'no-response-display
                            'no-error-display)))
                 (plain (if (and (stringp raw)
                                 (fboundp 'proof-shell-strip-output-markup))
                            (proof-shell-strip-output-markup raw)
                          raw)))
            (if (stringp plain)
                (string-trim plain)
              ""))
        (error "")))))

(defun my-coq--last-error-string ()
  "Return best-effort plain-text error output."
  (cl-labels
      ((extract-error (text)
         (let ((clean (string-trim (or text ""))))
           (cond
            ((string-match "Error:" clean)
             (let ((start 0)
                   (scan 0))
               (while (string-match "Error:" clean scan)
                 (setq start (match-beginning 0))
                 (setq scan (1+ start)))
               (string-trim (substring clean start))))
            ((string-match "Anomaly:" clean)
             (string-trim clean))
            ((string-match "Exception:" clean)
             (string-trim clean))
            (t
             nil)))))
    (let* ((raw proof-shell-last-output)
           (shell-text (and (stringp raw)
                            (string-trim
                             (if (fboundp 'proof-shell-strip-output-markup)
                                 (proof-shell-strip-output-markup raw)
                               raw))))
           (shell-error (extract-error shell-text)))
      (cond
       ((and shell-error (> (length shell-error) 0))
        shell-error)
       ((buffer-live-p proof-response-buffer)
        (with-current-buffer proof-response-buffer
          (let ((response-text
                 (string-trim
                  (buffer-substring-no-properties (point-min) (point-max)))))
            (or (extract-error response-text)
                (and (> (length response-text) 0) response-text)))))
       ((get-buffer "*compile-deps-dune*")
        (with-current-buffer "*compile-deps-dune*"
          (let ((dune-text
                 (string-trim
                  (buffer-substring-no-properties (point-min) (point-max)))))
            (or (extract-error dune-text)
                (and (> (length dune-text) 0) dune-text)))))
       ((and shell-text (> (length shell-text) 0))
        shell-text)
       (t
        "Unknown Coq error")))))

(defun my-coq--coq-active-buffer-p (buf)
  "Return non-nil if BUF is the currently active Rocq scripting buffer."
  (and (buffer-live-p buf)
       (with-current-buffer buf
         (and (eq major-mode 'coq-mode)
              (eq proof-script-buffer buf)
              (buffer-live-p proof-shell-buffer)
              (not proof-shell-busy)))))

(defun my-coq--wait-for-proof-shell-with-ui (&optional script-buf)
  "Wait for Proof General to become idle while keeping redisplay responsive."
  (let ((buf (or script-buf
                 (and (boundp 'proof-script-buffer) proof-script-buffer)
                 (current-buffer))))
    (rocqagent--set-subphase
     (if (eq rocqagent--active-kind 'query) 'query 'checking)
     t)
    (while (and (boundp 'proof-shell-busy) proof-shell-busy)
      (rocqagent--maybe-handle-cancel buf)
      (rocqagent--touch-status 'running)
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (let* ((proc-point (if (fboundp 'proof-unprocessed-begin)
                                 (proof-unprocessed-begin)
                               (point-min)))
                 (wins (get-buffer-window-list buf nil t)))
            (dolist (win wins)
              (when (window-live-p win)
                (set-window-point
                 win
                 (min (max proc-point (point-min)) (point-max))))))))
      (accept-process-output nil 0.05)
      (thread-yield)
      (redisplay t)))
  (rocqagent--maybe-handle-cancel
   (or script-buf
       (and (boundp 'proof-script-buffer) proof-script-buffer)
       (current-buffer)))
  (redisplay t))

(defun my-coq--result-at-target (target-point &optional forced-error initial-locked-end)
  "Return API result plist based on TARGET-POINT in current buffer.
When FORCED-ERROR is non-nil, always return an error plist.
INITIAL-LOCKED-END is the checked frontier before the current `proof-goto-point'
attempt.  When TARGET-POINT is behind that frontier, Proof General retracts to
the nearest command boundary at or before TARGET-POINT, so success is
`locked-end <= TARGET-POINT' rather than `locked-end >= TARGET-POINT'."
  (let* ((locked-end (if (fboundp 'proof-unprocessed-begin)
                         (proof-unprocessed-begin)
                       (point-min)))
         (target-reached
          (or (null target-point)
              (if (and initial-locked-end
                       (< target-point initial-locked-end))
                  (<= locked-end target-point)
                (>= locked-end target-point))))
         (error-text (my-coq--last-error-string)))
    (cond
     ((eq proof-shell-last-output-kind 'interrupt)
      (my-coq--interrupted-result locked-end target-point))
     ((or forced-error
          (eq proof-shell-last-output-kind 'error)
          (not target-reached))
      (list :ok nil
            :error (if (or forced-error
                           (eq proof-shell-last-output-kind 'error)
                           (not (string= error-text "Unknown Coq error")))
                       error-text
                     (format "Coq stopped before target (%d < %d)"
                             locked-end target-point))
            :locked-end locked-end
            :target target-point))
     (t
      (list :ok t
            :goal (my-coq--goals-string)
            :locked-end locked-end
            :target target-point)))))

(defun my-coq--response-string ()
  "Return plain-text contents of `proof-response-buffer'."
  (if (buffer-live-p proof-response-buffer)
      (with-current-buffer proof-response-buffer
        (string-trim
         (buffer-substring-no-properties (point-min) (point-max))))
    ""))

(defun my-coq--normalize-query-command (query)
  "Normalize QUERY into a non-empty single Rocq query command string."
  (let ((q (string-trim (or query ""))))
    (when (= (length q) 0)
      (error "Query string is empty"))
    (unless (string-match-p
             "^[[:space:]]*\\(Search\\|SearchAbout\\|SearchPattern\\|About\\|Print\\|Locate\\|Check\\|Compute\\|Eval\\|Show\\)\\>"
             q)
      (error "Unsupported query prefix. Allowed: Search/About/Print/Locate/Check/Compute/Eval/Show"))
    (if (string-suffix-p "." q)
        q
      (concat q "."))))

(defun my-coq--run-invisible-command-with-ui (cmd &rest flags)
  "Run invisible CMD asynchronously, waiting in a cancel-aware loop."
  (rocqagent--maybe-handle-cancel (current-buffer))
  (apply #'proof-shell-invisible-command cmd nil nil flags)
  (my-coq--wait-for-proof-shell-with-ui (current-buffer))
  proof-shell-last-output)

(defun rocqagent--classify-final-phase (result)
  "Return status phase keyword for RESULT plist."
  (cond
   ((plist-get result :interrupted) 'canceled)
   ((plist-get result :ok) 'done)
   (t 'error)))

(defun rocqagent--coqcheck-until-body (filename linenum columnnum restart)
  "Internal implementation shared by sync and async Coq checks."
  (let* ((file (expand-file-name filename))
         (existing (get-file-buffer file))
         (buf (or existing (find-file-noselect file)))
         (target-point nil))
    (condition-case err
        (my-coq--without-file-change-prompts
          (let ((reuse (and (not restart)
                            existing
                            (my-coq--coq-active-buffer-p existing))))
            (unless (file-readable-p file)
              (error "File is not readable: %s" file))
            (with-current-buffer buf
              (unless (eq major-mode 'coq-mode)
                (coq-mode))
              ;; Avoid interactive PG prompts in non-interactive API calls.
              (let ((proof-query-file-save-when-activating-scripting nil)
                    (proof-auto-action-when-deactivating-scripting 'retract)
                    (restart-result nil)
                    (initial-locked-end nil))
                (rocqagent--claim-process-thread)
                (rocqagent--maybe-handle-cancel buf)
                (when (and (boundp 'proof-shell-busy) proof-shell-busy
                           (fboundp 'proof-shell-wait))
                  (my-coq--wait-for-proof-shell-with-ui buf))
                ;; Sync script buffer text to disk first in both paths.
                (coq-partial-revert-buffer)
                (setq target-point
                      (my-coq--target-point-from-line-column
                       linenum columnnum))
                (setq rocqagent--active-target target-point)
                (setq initial-locked-end
                      (if (fboundp 'proof-unprocessed-begin)
                          (proof-unprocessed-begin)
                        (point-min)))
                (if reuse
                    (unless (= target-point (proof-unprocessed-begin))
                      (my-coq--goto-safe-processing-point target-point)
                      (proof-goto-point)
                      (my-coq--wait-for-proof-shell-with-ui buf))
                  (progn
                    (unless (find-root file)
                      (error "Could not find dune-workspace above %s" file))
                    (my-coq--goto-safe-processing-point target-point)
                    (setq restart-result
                          (reload-to-current-point_aux file buf nil))
                    (when (and (plist-get restart-result :ok)
                               (boundp 'proof-shell-busy) proof-shell-busy
                               (fboundp 'proof-shell-wait))
                      (my-coq--wait-for-proof-shell-with-ui buf))))
                (if (and restart-result
                         (not (plist-get restart-result :ok)))
                    (append
                     restart-result
                     (list :locked-end (if (fboundp 'proof-unprocessed-begin)
                                           (proof-unprocessed-begin)
                                         (point-min))
                           :target target-point))
                  (my-coq--result-at-target
                   target-point
                   (and (not reuse)
                        (not (my-coq--coq-active-buffer-p buf)))
                   initial-locked-end))))))
      (rocqagent-interrupted
       (my-coq--interrupted-result
        (and (buffer-live-p buf)
             (with-current-buffer buf
               (if (fboundp 'proof-unprocessed-begin)
                   (proof-unprocessed-begin)
                 (point-min))))
        target-point))
      (error
       (list :ok nil :error (error-message-string err))))))

(defun coqcheck_until (filename linenum columnnum restart)
  "Synchronously process Rocq script up to target and return goal/error plist.

Arguments:
- FILENAME: absolute path to .v file.
- LINENUM: 1-based line (or nil/None to mean end-of-file).
- COLUMNNUM: 0-based column (or nil/None to mean end-of-file).
- RESTART: when non-nil, force full restart path.

Return shape:
- success: (:ok t :goal STRING :locked-end INT :target INT)
- failure: (:ok nil :error STRING :locked-end INT :target INT)

If processing fails at or before the requested point, this returns
an error plist instead of a goal plist."
  (interactive "fFile: \nnLine (1-based): \nnColumn (0-based): \nP")
  (let* ((file (expand-file-name filename))
         (buf (or (get-file-buffer file) (find-file-noselect file)))
         (result nil))
    (rocqagent--begin-operation 'check file buf)
    (unwind-protect
        (progn
          (setq result
                (rocqagent--coqcheck-until-body
                 filename linenum columnnum restart))
          result)
      (rocqagent--finish-operation
       (and result (rocqagent--classify-final-phase result))
       result))))

(defun coqquery_at_curpoint (query filename)
  "Run QUERY at current checked state for FILENAME without changing unwind state.

Caller must first establish scripting state using `coqcheck_until' on FILENAME.
This function does not move point or check script text.

Arguments:
- QUERY: Rocq query command string (with or without trailing dot).
- FILENAME: absolute path to .v file.

Return shape:
- success: (:ok t :query STRING :locked-end INT)
- failure: (:ok nil :error STRING :locked-end INT)"
  (interactive "sQuery: \nfFile: ")
  (let* ((file (expand-file-name filename))
         (buf (get-file-buffer file))
         (locked-before nil))
    (if (not (buffer-live-p buf))
        (list :ok nil
              :error (format "Coq scripting not active for %s; call coqcheck_until first" file))
      (rocqagent--begin-operation 'query file buf)
      (unwind-protect
          (condition-case err
              (my-coq--without-file-change-prompts
                (with-current-buffer buf
                  (if (not (and (eq major-mode 'coq-mode)
                                (boundp 'proof-script-buffer)
                                (eq proof-script-buffer buf)
                                (buffer-live-p proof-shell-buffer)))
                      (list :ok nil
                            :error (format "Coq scripting not active for %s; call coqcheck_until first" file))
                    (let* ((query-cmd (my-coq--normalize-query-command query))
                           (raw "")
                           (query-output "")
                           (locked-after nil))
                      (rocqagent--claim-process-thread)
                      (rocqagent--maybe-handle-cancel buf)
                      (setq locked-before
                            (if (fboundp 'proof-unprocessed-begin)
                                (proof-unprocessed-begin)
                              (point-min)))
                      (when (and (boundp 'proof-shell-busy) proof-shell-busy)
                        (my-coq--wait-for-proof-shell-with-ui buf))
                      (unless (fboundp 'proof-shell-invisible-command)
                        (error "proof-shell-invisible-command is unavailable"))
                      (setq raw
                            (my-coq--run-invisible-command-with-ui
                             query-cmd
                             'no-response-display
                             'no-error-display))
                      (setq query-output
                            (string-trim
                             (if (and (stringp raw)
                                      (fboundp 'proof-shell-strip-output-markup))
                                 (proof-shell-strip-output-markup raw)
                               (or raw ""))))
                      (when (= (length query-output) 0)
                        (setq query-output (my-coq--response-string)))
                      (setq locked-after
                            (if (fboundp 'proof-unprocessed-begin)
                                (proof-unprocessed-begin)
                              (point-min)))
                      (when (/= locked-after locked-before)
                        (save-excursion
                          (my-coq--goto-safe-processing-point locked-before)
                          (proof-goto-point))
                        (my-coq--wait-for-proof-shell-with-ui buf))
                      (cond
                       ((eq proof-shell-last-output-kind 'interrupt)
                        (my-coq--interrupted-result locked-before))
                       ((or (eq proof-shell-last-output-kind 'error)
                            (/= locked-after locked-before))
                        (list :ok nil
                              :error (if (/= locked-after locked-before)
                                         (format "Query changed proof state (%d -> %d); rewound to preserve unwind semantics"
                                                 locked-before locked-after)
                                       (my-coq--last-error-string))
                              :locked-end locked-before))
                       (t
                        (list :ok t
                              :query query-output
                              :locked-end locked-before)))))))
            (rocqagent-interrupted
             (my-coq--interrupted-result locked-before))
            (error
             (list :ok nil :error (error-message-string err))))
        (rocqagent--finish-operation)))))

(defun my-coq--first-diff-pos (s1 s2)
  "Return 1-based position of first difference between S1 and S2, or nil."
  (let* ((n1 (length s1))
         (n2 (length s2))
         (n (min n1 n2))
         (i 0))
    (while (and (< i n)
                (= (aref s1 i) (aref s2 i)))
      (setq i (1+ i)))
    (unless (and (= i n) (= n1 n2))
      (1+ i))))

(defun coq-partial-revert-buffer (&optional _ignore-auto _noconfirm)
  "Reload current Rocq buffer from disk, retracting only to the first changed command."
  (interactive)
  (unless (and buffer-file-name (file-readable-p buffer-file-name))
    (user-error "Current buffer is not visiting a readable file"))
  (when (buffer-modified-p)
    (user-error "Buffer has unsaved Emacs edits; refusing to overwrite them"))
  (when (and (boundp 'proof-shell-busy) proof-shell-busy)
    (user-error "Proof General is busy"))

  (let* ((file buffer-file-name)
         (tmp (generate-new-buffer " *coq-reload*")))
    (unwind-protect
        (my-coq--without-file-change-prompts
          (save-restriction
            (widen)
            (let ((old (buffer-substring-no-properties (point-min) (point-max))))
              (with-current-buffer tmp
                (insert-file-contents file))
              (let* ((new (with-current-buffer tmp
                            (buffer-substring-no-properties (point-min) (point-max))))
                     (diff (my-coq--first-diff-pos old new))
                     (locked-end (if (fboundp 'proof-unprocessed-begin)
                                     (proof-unprocessed-begin)
                                   (point-min))))
                (when (and diff (< diff locked-end))
                  (save-excursion
                    (goto-char (min diff (point-max)))
                    (proof-goto-point))
                  (when (fboundp 'proof-shell-wait)
                    (my-coq--wait-for-proof-shell-with-ui (current-buffer))))
                (when diff
                  (let ((start (min diff (point-max))))
                    (set-visited-file-modtime)
                    (save-excursion
                      (goto-char start)
                      (combine-after-change-calls
                        (delete-region start (point-max))
                        (insert (substring new (1- start)))))))
                (set-visited-file-modtime)
                (set-buffer-modified-p nil)
                (let ((inhibit-message t))
                  (unless (buffer-modified-p)
                    (set-buffer-modified-p t))
                  (save-buffer))
                (set-visited-file-modtime)
                (set-buffer-modified-p nil)))))
      (kill-buffer tmp))))

(defun rocqagent_shutdown_server ()
  "Gracefully stop the current Proof General session and exit this Emacs server.

This is intended to be called through a dedicated cleanup path, not as a normal
proof RPC."
  (interactive)
  (setq rocqagent--cancel-requested t)
  (ignore-errors
    (rocqagent--signal-interrupt t))
  (when (process-live-p rocqagent--active-process)
    (ignore-errors
      (kill-process rocqagent--active-process)))
  (when (and (boundp 'proof-shell-buffer)
             (buffer-live-p proof-shell-buffer))
    (ignore-errors
      (proof-shell-exit t)))
  (kill-emacs 0))

(when (fboundp 'rocqagent_interrupt)
  (fmakunbound 'rocqagent_interrupt))

(provide 'rocqagent)
