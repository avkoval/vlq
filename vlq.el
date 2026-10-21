;;; vlq.el --- Search VictoriaLogs from Emacs, notmuch style -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Oleksii Koval

;; Author: Oleksii Koval
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, unix
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; A front end for VictoriaLogs (https://docs.victoriametrics.com/victorialogs/)
;; in the spirit of notmuch's hello screen:
;;
;;   M-x vlq        the *vlq* buffer: a search line and the saved queries,
;;                  each with how many lines it matches now.  RET runs one.
;;   M-x vlq-search run a LogsQL query typed in the minibuffer.
;;
;; Results open in a buffer in `logview-mode' (when logview is installed),
;; oldest line first, local time, one line per entry, application fields
;; (upper-case, not journald's own `_' ones) appended as NAME=value:
;;
;;   2026-10-20 21:41:19.644 NOTICE mail1/stalwart: Message ingested  FROM=alice@example.org TO=[bob@example.com] SIZE=5918
;;
;; From a results buffer: C-c C-s saves the query, C-c C-p saves it "pinned"
;; (its relative _time:1h becomes a fixed [start, end], so the same lines come
;; back later -- a bookmark on an incident), C-c C-l opens the same lines in
;; lnav, C-c C-d shows every field of the entry at point, C-c C-e edits the
;; query, g or C-c C-r runs it again (g replaces logview's file reload).
;;
;; Saved queries live in `vlq-queries-file', one "name: LogsQL" per line --
;; the same file the `bin/vlq' command-line companion reads, so both see the
;; same bookmarks.  VictoriaLogs is reached over HTTP with curl; the first
;; endpoint that answers is used, and an (ssh HOST) endpoint runs curl on
;; HOST, for when the server's port is only reachable through SSH.  Endpoints
;; come from `vlq-endpoints' or, when that is nil, from `vlq-endpoints-file'
;; (shared with bin/vlq), else http://127.0.0.1:9428.

;;; Code:

(require 'json)
(require 'subr-x)
(require 'seq)
(require 'cl-lib)
(require 'parse-time)

(declare-function logview-choose-submode "logview")
(declare-function vterm "vterm")
(declare-function term-mode "term")
(declare-function term-char-mode "term")
(defvar vterm-shell)
(defvar logview-additional-submodes)

(defgroup vlq nil
  "Search VictoriaLogs."
  :group 'tools
  :prefix "vlq-")

(defcustom vlq-endpoints nil
  "Where VictoriaLogs is reached; the first one that answers is used.
A string is a base URL.  (ssh HOST) runs curl on HOST against
`vlq-ssh-remote-url'.  nil: read `vlq-endpoints-file'."
  :type '(choice (const :tag "From vlq-endpoints-file" nil)
                 (repeat (choice string (list (const ssh) string)))))

(defcustom vlq-endpoints-file "~/.config/vlq/endpoints"
  "Endpoints when `vlq-endpoints' is nil, shared with bin/vlq.
One per line: a base URL, or \"ssh HOST\"; `#' starts a comment.
Missing or empty: http://127.0.0.1:9428."
  :type 'file)

(defcustom vlq-ssh-remote-url "http://127.0.0.1:9428"
  "Base URL of VictoriaLogs as seen from an (ssh HOST) endpoint."
  :type 'string)

(defcustom vlq-queries-file "~/.config/vlq/queries"
  "Saved queries, one \"name: LogsQL\" per line, `#' starts a comment."
  :type 'file)

(defcustom vlq-default-time "1h"
  "Time window added to queries without a _time filter."
  :type 'string)

(defcustom vlq-limit 20000
  "Maximum number of lines fetched per query (the newest ones)."
  :type 'integer)

(defcustom vlq-hello-counts t
  "Non-nil: the *vlq* buffer shows each saved query's current match count."
  :type 'boolean)

(defcustom vlq-shown-fields-regexp "\\`[A-Z][A-Z0-9_]*\\'"
  "Extra fields shown after the message as NAME=value.
Matched against field names; journald's own fields start with `_'
and are never shown, nor those in `vlq-hidden-fields'."
  :type 'regexp)

(defcustom vlq-hidden-fields
  '("PRIORITY" "SYSLOG_IDENTIFIER" "SYSLOG_FACILITY" "SYSLOG_PID" "SYSLOG_TIMESTAMP"
    "CODE_FILE" "CODE_LINE" "CODE_FUNC" "MESSAGE_ID" "INVOCATION_ID" "SPANID"
    "CONTAINER_ID" "CONTAINER_ID_FULL" "CONTAINER_NAME" "CONTAINER_TAG" "IMAGE_NAME"
    "TID" "ELAPSED" "LOCALPORT" "REMOTEPORT"
    "BLOBID" "CHANGEID" "DOCUMENTID" "MAILBOXID" "ACCOUNTID" "QUEUEID" "LISTENERID" "TOTAL")
  "Fields never shown in the result line (all are in C-c C-d)."
  :type '(repeat string))

(defcustom vlq-field-order
  '("FROM" "TO" "ACCOUNTNAME" "REMOTEIP" "HOSTNAME" "DOMAIN" "CODE" "DETAILS" "REASON" "SIZE")
  "Shown fields that come first, in this order; the rest follow by name."
  :type '(repeat string))

(defcustom vlq-cache-directory "~/.cache/vlq"
  "Where raw JSON results are written for lnav."
  :type 'directory)

(defcustom vlq-terminal-command '("kitty" "--")
  "Terminal used to run lnav from a graphical frame; the command is appended."
  :type '(repeat string))

(defvar vlq-search-history nil "Minibuffer history of LogsQL queries.")

;;;; Endpoint and transport

(defvar vlq--endpoint nil "Endpoint chosen for this session.")

(defun vlq--healthy-p (endpoint)
  "Non-nil if ENDPOINT answers.  ssh endpoints are assumed reachable."
  (or (consp endpoint)
      (eq 0 (call-process "curl" nil nil nil "-s" "-f" "-m" "2" "-o" "/dev/null"
                          (concat endpoint "/health")))))

(defun vlq-endpoint-list ()
  "Endpoints to try, from `vlq-endpoints' or `vlq-endpoints-file'."
  (or vlq-endpoints
      (let ((file (expand-file-name vlq-endpoints-file)) result)
        (when (file-readable-p file)
          (with-temp-buffer
            (insert-file-contents file)
            (dolist (line (split-string (buffer-string) "\n" t "[ \t]+"))
              (cond ((string-prefix-p "#" line))
                    ((string-match "\\`ssh[ \t]+\\(.+\\)\\'" line)
                     (push (list 'ssh (match-string 1 line)) result))
                    (t (push (string-remove-suffix "/" line) result))))))
        (or (nreverse result) (list "http://127.0.0.1:9428")))))

(defun vlq--endpoint ()
  "The endpoint in use, probing the endpoints on first use."
  (or vlq--endpoint
      (setq vlq--endpoint (or (seq-find #'vlq--healthy-p (vlq-endpoint-list))
                              (user-error "vlq: no VictoriaLogs endpoint answers")))))

(defun vlq-reset-endpoint ()
  "Forget the chosen endpoint (after moving between networks)."
  (interactive)
  (setq vlq--endpoint nil)
  (message "vlq: endpoint %s" (vlq--endpoint-label (vlq--endpoint))))

(defun vlq--endpoint-label (endpoint)
  (if (consp endpoint) (format "ssh %s" (cadr endpoint)) endpoint))

(defun vlq--command (endpoint path)
  "Command list that POSTs the query (read from stdin) to PATH at ENDPOINT."
  (let ((curl (lambda (base) (list "curl" "-sS" "--fail-with-body" "--data-urlencode" "query@-"
                                   (concat base path)))))
    (if (consp endpoint)
        (list "ssh" (cadr endpoint) (mapconcat #'shell-quote-argument (funcall curl vlq-ssh-remote-url) " "))
      (funcall curl endpoint))))

(defun vlq--request (query path callback)
  "Send QUERY to PATH asynchronously; call CALLBACK with the output string.
On failure, CALLBACK gets nil and the error is shown."
  (let* ((endpoint (vlq--endpoint))
         (buf (generate-new-buffer " *vlq-request*"))
         (proc (make-process
                :name "vlq" :buffer buf :connection-type 'pipe :noquery t
                :command (vlq--command endpoint path)
                :sentinel (lambda (p _event)
                            (when (memq (process-status p) '(exit signal))
                              (let ((out (with-current-buffer buf (buffer-string)))
                                    (ok (eq 0 (process-exit-status p))))
                                (kill-buffer buf)
                                (unless ok
                                  (message "vlq: %s" (string-trim (string-limit out 300))))
                                (funcall callback (and ok out))))))))
    (process-send-string proc query)
    (process-send-eof proc)
    proc))

;;;; Queries

(defun vlq--has-time-p (query)
  (string-match-p "\\(?:^\\|[[:space:](]\\)_time:" query))

(defun vlq--with-time (query)
  "QUERY with `vlq-default-time' added when it has no _time filter."
  (if (vlq--has-time-p query) query (format "_time:%s %s" vlq-default-time query)))

(defun vlq-aggregate-p (query)
  "Non-nil if QUERY has its own stats/sort pipe; its order is kept as is."
  (string-match-p "|[[:space:]]*\\(?:stats\\|sort\\|top\\|uniq\\|count_uniq\\|facets\\)\\_>" query))

(defun vlq--fetch-query (query)
  "The LogsQL actually sent for QUERY: newest `vlq-limit' lines.
An aggregate query (see `vlq-aggregate-p') only gets the limit."
  (if (vlq-aggregate-p query)
      (format "%s | limit %d" (vlq--with-time query) vlq-limit)
    (format "%s | sort by (_time desc) | limit %d" (vlq--with-time query) vlq-limit)))

(defconst vlq--units '(("s" . 1) ("m" . 60) ("h" . 3600) ("d" . 86400) ("w" . 604800)))

(defun vlq-pin-query (query &optional now)
  "Return QUERY with a relative _time:<n><unit> replaced by a fixed range.
Without a _time filter, `vlq-default-time' is pinned.  NOW (a time value)
defaults to the current time.  Absolute or other _time forms are kept."
  (let* ((q (vlq--with-time query))
         (re "\\(?:^\\|[[:space:](]\\)\\(_time:\\([0-9]+\\)\\([smhdw]\\)\\)\\_>"))
    (if (not (string-match re q))
        q
      (let* ((secs (* (string-to-number (match-string 2 q))
                      (cdr (assoc (match-string 3 q) vlq--units))))
             (end (or now (current-time)))
             (start (time-subtract end secs))
             (fmt (lambda (time) (format-time-string "%Y-%m-%dT%H:%M:%SZ" time t))))
        (concat (substring q 0 (match-beginning 1))
                (format "_time:[%s, %s]" (funcall fmt start) (funcall fmt end))
                (substring q (match-end 1)))))))

;;;; Saved queries (shared with bin/vlq)

(defun vlq-saved-queries ()
  "Alist (NAME . QUERY) from `vlq-queries-file', in file order."
  (let ((file (expand-file-name vlq-queries-file)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (let (result)
          (dolist (line (split-string (buffer-string) "\n" t "[ \t]+"))
            (when (and (not (string-prefix-p "#" line))
                       (string-match "\\`\\([^:]+?\\)[ \t]*:[ \t]*\\(.+\\)\\'" line))
              (push (cons (match-string 1 line) (match-string 2 line)) result)))
          (nreverse result))))))

(defun vlq--write-saved (alist)
  (let ((file (expand-file-name vlq-queries-file)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert "# vlq saved queries: 'name: LogsQL' (vlq.el and bin/vlq)\n")
      (dolist (e alist) (insert (car e) ": " (cdr e) "\n")))))

(defun vlq-save-query (name query)
  "Save QUERY under NAME, replacing an existing entry of that name."
  (when (string-match-p ":" name) (user-error "vlq: a name can't contain `:'"))
  (let ((alist (vlq-saved-queries)))
    (if-let* ((cell (assoc name alist)))
        (setcdr cell query)
      (setq alist (append alist (list (cons name query)))))
    (vlq--write-saved alist)
    (message "vlq: saved %s: %s" name query)))

(defun vlq-delete-query (name)
  "Delete the saved query NAME."
  (vlq--write-saved (seq-remove (lambda (e) (equal (car e) name)) (vlq-saved-queries))))

(defun vlq--read-query (&optional initial)
  "Read a query: a saved name (completion) or any LogsQL.  Returns (NAME . QUERY)."
  (let* ((saved (vlq-saved-queries))
         (completion-extra-properties
          (list :annotation-function
                (lambda (c) (when-let* ((q (cdr (assoc c saved))))
                              (concat "  " (propertize q 'face 'shadow))))))
         (input (completing-read "LogsQL or saved query: " (mapcar #'car saved) nil nil
                                 initial 'vlq-search-history)))
    (if-let* ((cell (assoc input saved))) cell (cons nil input))))

;;;; Formatting

(defconst vlq--levels ["EMERGENCY" "ALERT" "CRITICAL" "ERROR" "WARNING" "NOTICE" "INFO" "DEBUG"])

(defun vlq--level (rec)
  "Level name of REC (a hash table) from PRIORITY, else from its level field."
  (let ((prio (gethash "PRIORITY" rec)))
    (if (and prio (string-match-p "\\`[0-7]\\'" prio))
        (aref vlq--levels (string-to-number prio))
      (pcase (downcase (or (gethash "level" rec) "info"))
        ((or "err" "error") "ERROR") ((or "warn" "warning") "WARNING")
        ("notice" "NOTICE") ("debug" "DEBUG") ((or "crit" "critical") "CRITICAL")
        (_ "INFO")))))

(defun vlq--source (rec)
  "host/identifier of REC."
  (let ((host (gethash "_HOSTNAME" rec "-"))
        (ident (or (gethash "SYSLOG_IDENTIFIER" rec) (gethash "CONTAINER_NAME" rec)
                   (gethash "_SYSTEMD_UNIT" rec) (gethash "_COMM" rec) "-")))
    (replace-regexp-in-string "[ :]" "_" (concat host "/" ident))))

(defun vlq-format-record (rec)
  "One log line for REC: local timestamp with millis, level, source, message.
Continuation lines of a multi-line message are indented.  A record without
_time (a `stats' row) becomes its fields as NAME=value."
  (if (not (gethash "_time" rec))
      (let (pairs)
        (maphash (lambda (k v) (push (format "%s=%s" k v) pairs)) rec)
        (string-join (nreverse pairs) "  "))
    (vlq--format-entry rec)))

(defun vlq--format-entry (rec)
  (let* ((iso (gethash "_time" rec))
         (time (parse-iso8601-time-string iso))
         ;; parse-iso8601-time-string drops the fraction: take the millis from the string
         (millis (if (string-match "\\.\\([0-9]\\{1,3\\}\\)" iso)
                     (string-pad (match-string 1 iso) 3 ?0)
                   "000"))
         (ts (concat (format-time-string "%Y-%m-%d %H:%M:%S." time) millis))
         (msg (string-trim-right (gethash "_msg" rec ""))))
    (format "%s %s %s: %s%s" ts (vlq--level rec) (vlq--source rec)
            (replace-regexp-in-string "\n" "\n    " msg)
            (vlq--extras rec))))

(defun vlq--extras (rec)
  "\" NAME=value\" for the fields of REC worth showing (`vlq-field-order' first)."
  (let ((case-fold-search nil)
        keys)
    (maphash (lambda (k v)
               (when (and (string-match-p vlq-shown-fields-regexp k)
                          (not (member k vlq-hidden-fields))
                          (stringp v) (not (string-empty-p v)))
                 (push k keys)))
             rec)
    (setq keys (sort keys (lambda (a b)
                            (let ((ia (or (seq-position vlq-field-order a) 1000))
                                  (ib (or (seq-position vlq-field-order b) 1000)))
                              (if (= ia ib) (string< a b) (< ia ib))))))
    (if (null keys) ""
      (concat "  " (mapconcat (lambda (k)
                                (let ((v (gethash k rec)))
                                  (format "%s=%s" k (if (string-match-p "[ \"]" v) (prin1-to-string v) v))))
                              keys " ")))))

(defun vlq--parse (json-lines &optional keep-order)
  "Records (hash tables) from JSON-LINES, oldest first.
The query returns newest first, so the order is reversed, unless KEEP-ORDER."
  (let (records)
    (dolist (line (split-string json-lines "\n" t))
      (push (json-parse-string line :object-type 'hash-table :null-object nil) records))
    (if keep-order (nreverse records) records)))

;;;; Results buffer

(defvar-local vlq--name nil "Saved name of this buffer's query, if any.")
(defvar-local vlq--query nil "This buffer's LogsQL query.")
(defvar-local vlq--raw nil "Raw JSON lines of the last result.")

(defvar-keymap vlq-results-mode-map
  :doc "Keys of `vlq-results-mode' (C-c prefix: logview uses plain letters)."
  "C-c C-r" #'vlq-rerun
  "C-c C-e" #'vlq-edit-query
  "C-c C-s" #'vlq-save-current
  "C-c C-p" #'vlq-pin-current
  "C-c C-l" #'vlq-lnav
  "C-c C-d" #'vlq-show-record
  "C-c C-h" #'vlq)

;; `g' (logview: reload the file) runs the query again: these buffers have no
;; file.  Set outside `defvar-keymap' so reloading the package updates it.
(keymap-set vlq-results-mode-map "g" #'vlq-rerun)

(define-minor-mode vlq-results-mode
  "Minor mode of vlq results buffers.
\\{vlq-results-mode-map}"
  :lighter " vlq")

(with-eval-after-load 'logview
  (add-to-list 'logview-additional-submodes
               '("vlq" . ((format . "TIMESTAMP LEVEL <<RX:NAME:[^ ]+>>:")
                          (levels . "RFC 5424")
                          (timestamp . ("ISO 8601 datetime + millis"))))))

(defun vlq--buffer-name (name query)
  (format "*vlq: %s*" (or name (string-limit query 50))))

(defun vlq--header (count)
  (concat (propertize (or vlq--name "query") 'face 'bold) "  "
          vlq--query "  "
          (propertize (format "[%s lines%s, %s]" count
                              (if (>= count vlq-limit) ", limit reached" "")
                              (vlq--endpoint-label (vlq--endpoint)))
                      'face 'shadow)))

(defun vlq--show (name query)
  "Fetch QUERY and show it in a results buffer named after NAME or QUERY."
  (let ((buf (get-buffer-create (vlq--buffer-name name query))))
    (with-current-buffer buf
      (setq vlq--name name vlq--query query)
      (let ((inhibit-read-only t)) (erase-buffer) (insert "Fetching...\n"))
      (setq header-line-format (concat "vlq: " query)))
    (pop-to-buffer-same-window buf)
    (vlq--request (vlq--fetch-query query) "/select/logsql/query"
                  (lambda (out) (when (and out (buffer-live-p buf)) (vlq--fill buf out))))
    buf))

(defun vlq--fill (buf out)
  (with-current-buffer buf
    (let ((records (vlq--parse out (vlq-aggregate-p vlq--query)))
          (inhibit-read-only t)
          (name vlq--name) (query vlq--query))
      (if (fboundp 'logview-mode)
          (progn (logview-mode) (ignore-errors (logview-choose-submode "vlq" "ISO 8601 datetime + millis")))
        (special-mode))
      ;; major mode change killed the locals
      (setq vlq--name name vlq--query query vlq--raw out)
      ;; `g' in logview (and `revert-buffer') runs the query again
      (setq-local revert-buffer-function (lambda (&rest _) (vlq-rerun)))
      (erase-buffer)
      (dolist (rec records)
        (let ((start (point)))
          (insert (vlq-format-record rec) "\n")
          (put-text-property start (point) 'vlq-record rec)))
      (goto-char (point-max))
      (forward-line -1)
      (setq buffer-read-only t)
      (set-buffer-modified-p nil)
      (vlq-results-mode 1)
      (setq header-line-format (vlq--header (length records))))))

;;;###autoload
(defun vlq-search (query)
  "Run LogsQL QUERY (or a saved query's name) and show the result."
  (interactive (list (vlq--read-query)))
  (let ((cell (if (consp query) query (or (assoc query (vlq-saved-queries)) (cons nil query)))))
    (vlq--show (car cell) (cdr cell))))

(defun vlq-rerun ()
  "Fetch this buffer's query again."
  (interactive)
  (vlq--show vlq--name vlq--query))

(defun vlq-edit-query ()
  "Edit this buffer's query and run it."
  (interactive)
  (let ((q (read-string "LogsQL: " vlq--query 'vlq-search-history)))
    (vlq--show nil q)))

(defun vlq-save-current (name)
  "Save this buffer's query under NAME."
  (interactive (list (read-string "Save as: " vlq--name)))
  (vlq-save-query name vlq--query)
  (setq vlq--name name)
  (rename-buffer (vlq--buffer-name name vlq--query) t))

(defun vlq-pin-current (name)
  "Save this buffer's query under NAME with its time range fixed to now."
  (interactive (list (read-string "Pin as: " (and vlq--name (concat vlq--name "-" (format-time-string "%Y%m%d-%H%M"))))))
  (let ((pinned (vlq-pin-query vlq--query)))
    (vlq-save-query name pinned)
    (vlq--show name pinned)))

(defun vlq-show-record ()
  "Show every field of the entry at point."
  (interactive)
  (let ((rec (get-text-property (line-beginning-position) 'vlq-record)))
    (unless rec (user-error "No log entry here"))
    (with-current-buffer-window "*vlq record*" nil nil
      (let ((keys (sort (hash-table-keys rec) #'string<)))
        (dolist (k keys)
          (insert (propertize (format "%-28s" k) 'face 'font-lock-keyword-face)
                  (format "%s\n" (gethash k rec))))))))

;;;; lnav

(defun vlq--cache-file (name query)
  (let ((slug (string-trim (replace-regexp-in-string "[^A-Za-z0-9]+" "_" (or name query)) "_" "_")))
    (expand-file-name (format "%s-%s.json" (string-limit slug 60) (substring (sha1 query) 0 8))
                      vlq-cache-directory)))

(defun vlq-lnav ()
  "Open this buffer's result (or a query read from the minibuffer) in lnav.
In a graphical frame lnav runs in `vlq-terminal-command'; in a terminal
frame in vterm when available, else in a `term' buffer."
  (interactive)
  (let* ((cell (if (and vlq-results-mode vlq--raw) (cons vlq--name vlq--query) (vlq--read-query)))
         (file (vlq--cache-file (car cell) (cdr cell)))
         (run (lambda (raw)
                (make-directory (file-name-directory file) t)
                ;; RAW is newest first; lnav flags lines that go back in time
                (with-temp-file file
                  (let ((lines (split-string raw "\n" t)))
                    (insert (mapconcat #'identity
                                       (if (vlq-aggregate-p (cdr cell)) lines (nreverse lines))
                                       "\n")
                            "\n")))
                (cond ((display-graphic-p)
                       (apply #'start-process "vlq-lnav" nil (append vlq-terminal-command (list "lnav" file))))
                      ((fboundp 'vterm)
                       (let ((vterm-shell (concat "lnav " (shell-quote-argument file))))
                         (vterm (format "*lnav %s*" (file-name-base file)))))
                      (t (let ((buf (make-term (format "lnav %s" (file-name-base file)) "lnav" nil file)))
                           (with-current-buffer buf (term-mode) (term-char-mode))
                           (pop-to-buffer-same-window buf)))))))
    (if (and vlq-results-mode vlq--raw)
        (funcall run vlq--raw)
      (vlq--request (vlq--fetch-query (cdr cell)) "/select/logsql/query"
                    (lambda (out) (when out (funcall run out)))))))

;;;; The *vlq* buffer

(defvar-keymap vlq-hello-mode-map
  :parent special-mode-map
  "RET" #'vlq-hello-run
  "s"   #'vlq-search
  "l"   #'vlq-hello-lnav
  "e"   #'vlq-hello-edit
  "+"   #'vlq-hello-add
  "d"   #'vlq-hello-delete
  "g"   #'vlq-hello-refresh
  "n"   #'next-line
  "p"   #'previous-line)

(define-derived-mode vlq-hello-mode special-mode "vlq"
  "Saved VictoriaLogs queries.
\\{vlq-hello-mode-map}")

(defun vlq--hello-entry ()
  (or (get-text-property (point) 'vlq-entry) (user-error "No saved query on this line")))

;;;###autoload
(defun vlq ()
  "Show the *vlq* buffer: a search line and the saved queries."
  (interactive)
  (pop-to-buffer-same-window (get-buffer-create "*vlq*"))
  (vlq-hello-mode)
  (vlq-hello-refresh))

(defun vlq-hello-refresh ()
  "Redraw the *vlq* buffer and recount the saved queries."
  (interactive)
  (let ((inhibit-read-only t)
        (saved (vlq-saved-queries))
        (width 0))
    (erase-buffer)
    (insert (propertize "VictoriaLogs" 'face 'bold) "  "
            (propertize (vlq--endpoint-label (vlq--endpoint)) 'face 'shadow) "\n\n")
    (insert-text-button "Search" 'action (lambda (_) (call-interactively #'vlq-search)) 'follow-link t)
    (insert "  (s) any LogsQL; queries without _time get the last " vlq-default-time "\n\n")
    (insert (propertize "Saved queries" 'face 'bold) "  "
            (propertize "RET run  l lnav  e edit  + add  d delete  g refresh" 'face 'shadow) "\n")
    (dolist (e saved) (setq width (max width (length (car e)))))
    (dolist (e saved)
      (let ((start (point)))
        (insert (format "  %8s  %s  %s\n" "" (string-pad (car e) width)
                        (propertize (cdr e) 'face 'shadow)))
        (put-text-property start (point) 'vlq-entry e)
        (when vlq-hello-counts (vlq--hello-count start e))))
    (unless saved (insert "  none yet: run a search, then C-c C-s in its buffer\n"))
    (goto-char (point-min))
    (when saved (text-property-search-forward 'vlq-entry))
    (beginning-of-line)))

(defun vlq--hello-count (pos entry)
  "Fill in the match count of ENTRY on the line at POS when it arrives."
  (let ((buf (current-buffer))
        (marker (copy-marker pos)))
    (vlq--request (concat (vlq--with-time (cdr entry)) " | stats count() n") "/select/logsql/query"
                  (lambda (out)
                    (when (and out (buffer-live-p buf))
                      (with-current-buffer buf
                        (let ((n (ignore-errors
                                   (gethash "n" (json-parse-string (car (split-string out "\n" t))))))
                              (inhibit-read-only t))
                          (save-excursion
                            (goto-char (+ marker 2))
                            (when (looking-at " \\{8\\}")
                              (replace-match (propertize (format "%8s" (or n "?")) 'face 'success) t t)
                              (put-text-property (line-beginning-position) (line-end-position)
                                                 'vlq-entry entry))))))))))

(defun vlq-hello-run ()
  "Run the saved query on this line."
  (interactive)
  (let ((e (vlq--hello-entry))) (vlq--show (car e) (cdr e))))

(defun vlq-hello-lnav ()
  "Open the saved query on this line in lnav."
  (interactive)
  (let ((e (vlq--hello-entry)))
    (cl-letf (((symbol-function 'vlq--read-query) (lambda (&rest _) e)))
      (vlq-lnav))))

(defun vlq-hello-edit ()
  "Edit the saved query on this line."
  (interactive)
  (let* ((e (vlq--hello-entry))
         (q (read-string (format "%s: " (car e)) (cdr e) 'vlq-search-history)))
    (vlq-save-query (car e) q)
    (vlq-hello-refresh)))

(defun vlq-hello-add (name query)
  "Add a saved query NAME with QUERY."
  (interactive (list (read-string "Name: ") (read-string "LogsQL: " nil 'vlq-search-history)))
  (vlq-save-query name query)
  (vlq-hello-refresh))

(defun vlq-hello-delete ()
  "Delete the saved query on this line."
  (interactive)
  (let ((e (vlq--hello-entry)))
    (when (yes-or-no-p (format "Delete saved query %s? " (car e)))
      (vlq-delete-query (car e))
      (vlq-hello-refresh))))

(provide 'vlq)
;;; vlq.el ends here
