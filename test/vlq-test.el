;;; vlq-test.el --- Tests for vlq -*- lexical-binding: t; -*-

;; Run from the package directory (no server needed):
;;   emacs -Q --batch -L . -l test/vlq-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'vlq)

(defun vlq-test--rec (json)
  (json-parse-string json :object-type 'hash-table :null-object nil))

(ert-deftest vlq-test-with-time ()
  (let ((vlq-default-time "1h"))
    (should (equal (vlq--with-time "foo") "_time:1h foo"))
    (should (equal (vlq--with-time "_time:7d foo") "_time:7d foo"))
    (should (equal (vlq--with-time "(_time:2h OR x) foo") "(_time:2h OR x) foo"))
    (should (string-suffix-p "| sort by (_time desc) | limit 20000"
                             (let ((vlq-limit 20000)) (vlq--fetch-query "foo"))))))

(ert-deftest vlq-test-pin ()
  (let ((now (encode-time (parse-time-string "2026-10-21T08:00:00Z")))
        (vlq-default-time "1h"))
    (should (equal (vlq-pin-query "_time:30m SYSLOG_IDENTIFIER:stalwart" now)
                   "_time:[2026-10-21T07:30:00Z, 2026-10-21T08:00:00Z] SYSLOG_IDENTIFIER:stalwart"))
    (should (equal (vlq-pin-query "SYSLOG_IDENTIFIER:x" now)
                   "_time:[2026-10-21T07:00:00Z, 2026-10-21T08:00:00Z] SYSLOG_IDENTIFIER:x"))
    (should (equal (vlq-pin-query "a (_time:2d b)" now)
                   "a (_time:[2026-10-19T08:00:00Z, 2026-10-21T08:00:00Z] b)"))
    (let ((fixed "_time:[2026-10-20T00:00:00Z, 2026-10-21T00:00:00Z] x"))
      (should (equal (vlq-pin-query fixed now) fixed)))))

(ert-deftest vlq-test-saved-roundtrip ()
  (let ((vlq-queries-file (make-temp-file "vlq-queries")))
    (unwind-protect
        (progn
          (vlq-save-query "a" "_time:1h x")
          (vlq-save-query "b" "y | stats count() n")
          (vlq-save-query "a" "_time:2h x")
          (should (equal (vlq-saved-queries) '(("a" . "_time:2h x") ("b" . "y | stats count() n"))))
          (vlq-delete-query "a")
          (should (equal (vlq-saved-queries) '(("b" . "y | stats count() n"))))
          (should-error (vlq-save-query "a:b" "x") :type 'user-error))
      (delete-file vlq-queries-file))))

(ert-deftest vlq-test-format-stalwart ()
  (let* ((process-environment (cons "TZ=UTC" process-environment))
         (rec (vlq-test--rec "{\"_time\":\"2026-10-20T18:41:19.6443Z\",\"_HOSTNAME\":\"mail1\",\"SYSLOG_IDENTIFIER\":\"stalwart\",\"PRIORITY\":\"5\",\"_msg\":\"Message ingested\",\"TO\":\"[bob@example.com]\",\"FROM\":\"alice@example.org\",\"SIZE\":\"5918\",\"BLOBID\":\"29ee\",\"_PID\":\"1\",\"level\":\"notice\"}")))
    (set-time-zone-rule "UTC")
    (should (equal (vlq-format-record rec)
                   "2026-10-20 18:41:19.644 NOTICE mail1/stalwart: Message ingested  FROM=alice@example.org TO=[bob@example.com] SIZE=5918"))))

(ert-deftest vlq-test-format-levels-and-multiline ()
  (set-time-zone-rule "UTC")
  (let ((rec (vlq-test--rec "{\"_time\":\"2026-10-20T18:41:19Z\",\"_HOSTNAME\":\"h\",\"_SYSTEMD_UNIT\":\"caddy.service\",\"level\":\"warn\",\"_msg\":\"a\\nb\",\"logger\":\"http\"}")))
    (should (equal (vlq-format-record rec) "2026-10-20 18:41:19.000 WARNING h/caddy.service: a\n    b")))
  (should (equal (vlq--level (vlq-test--rec "{\"PRIORITY\":\"3\"}")) "ERROR"))
  (should (equal (vlq--level (vlq-test--rec "{\"level\":\"debug\"}")) "DEBUG")))

(ert-deftest vlq-test-format-stats-row ()
  (should (equal (vlq-format-record (vlq-test--rec "{\"request.client_ip\":\"203.0.113.9\",\"requests\":\"12\"}"))
                 "request.client_ip=203.0.113.9  requests=12")))

(ert-deftest vlq-test-parse-order ()
  (let ((recs (vlq--parse "{\"_msg\":\"newest\"}\n{\"_msg\":\"oldest\"}\n")))
    (should (equal (mapcar (lambda (r) (gethash "_msg" r)) recs) '("oldest" "newest"))))
  (let ((recs (vlq--parse "{\"n\":\"9\"}\n{\"n\":\"1\"}\n" t)))
    (should (equal (mapcar (lambda (r) (gethash "n" r)) recs) '("9" "1")))))

(ert-deftest vlq-test-aggregate ()
  (should (vlq-aggregate-p "* | stats by (x) count() n | sort by (n desc)"))
  (should (vlq-aggregate-p "x |sort by (_time)"))
  (should-not (vlq-aggregate-p "\"stats\" | unpack_json from _msg"))
  (should (string-suffix-p "| sort by (n desc) | limit 5"
                           (let ((vlq-limit 5)) (vlq--fetch-query "_time:1h * | stats count() n | sort by (n desc)")))))

(ert-deftest vlq-test-endpoints-file ()
  (let ((vlq-endpoints nil)
        (vlq-endpoints-file (make-temp-file "vlq-endpoints" nil nil
                                            "# comment\nhttp://127.0.0.1:9428/\nhttp://192.0.2.10:9428\nssh logs-host\n")))
    (unwind-protect
        (should (equal (vlq-endpoint-list)
                       '("http://127.0.0.1:9428" "http://192.0.2.10:9428" (ssh "logs-host"))))
      (delete-file vlq-endpoints-file)))
  (let ((vlq-endpoints nil) (vlq-endpoints-file "/nonexistent/vlq-endpoints"))
    (should (equal (vlq-endpoint-list) '("http://127.0.0.1:9428"))))
  (let ((vlq-endpoints '("http://x:9428")))
    (should (equal (vlq-endpoint-list) '("http://x:9428")))))

(ert-deftest vlq-test-ssh-command ()
  (let ((vlq-ssh-remote-url "http://127.0.0.1:9428"))
    (let ((cmd (vlq--command '(ssh "logs-host") "/select/logsql/query")))
      (should (equal (seq-take cmd 2) '("ssh" "logs-host")))
      ;; what the remote shell sees once it removes the quoting backslashes
      (should (equal (replace-regexp-in-string "\\\\" "" (nth 2 cmd))
                     "curl -sS --fail-with-body --data-urlencode query@- http://127.0.0.1:9428/select/logsql/query")))
    (should (equal (car (vlq--command "http://x:9428" "/q")) "curl"))))

;;; vlq-test.el ends here
