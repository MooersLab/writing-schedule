;;; test-writing-schedule-integration.el --- Integration tests  -*- lexical-binding: t; -*-

;;; Commentary:
;; Integration tests for writing-schedule.el.  These exercise the real
;; interaction paths: parsing a live org buffer, running the interactive
;; commands with stubbed prompts, adding to the agenda, and exporting to
;; iCalendar through org's own back-end.  Every test is tagged
;; `integration' so it can be selected on its own.
;;
;;   emacs --batch -L . -L test \
;;         -l test/test-writing-schedule-integration.el \
;;         --eval '(ert-run-tests-batch-and-exit "(tag integration)")'

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'calendar)
(require 'org)
(require 'ox-icalendar)
(require 'writing-schedule)

(defconst writing-schedule-test--example "\
#+TITLE: Writing Schedule for 3 Projects

| Time <l>      | M | Tu | W | Th | F | Sa |
|---------------+---+----+---+----+---+----|
| Generative:   |   |    |   |    |   |    |
| 04:00-5:30    | A | B  | A | B  | B |    |
| 05:45-07:15   | A | B  | A | B  | B | B  |
| 07:30-09:00   | B | A  | A | A  | A | B  |
|---------------+---+----+---+----+---+----|
| Rewriting:    |   |    |   |    |   |    |
| 9:15 - 10:45  | B | A  | A | A  | A | B  |
| 11:30 - 13:00 | A | B  | A | A  | B | A  |
|---------------+---+----+---+----+---+----|
| Supporting    |   |    |   |    |   |    |
| 13:15-14:45   | A | B  | A | B  | A | A  |
| 15:00- 16:30  | A | B  | A | B  | A | A  |
| 16:45-18:15   | B | B  | B | B  | A | A  |
| 20:30-22:00   | B | A  | B | B  | B | A  |
|---------------+---+----+---+----+---+----|
| A:            |   |    |   |    |   |    |
| B:            |   |    |   |    |   |    |
| C:            |   |    |   |    |   |    |
"
  "A filled three-project table used across the integration tests.")

(defun writing-schedule-test--events-from-example ()
  "Parse the shared example and return its event list."
  (with-temp-buffer
    (insert writing-schedule-test--example)
    (org-mode)
    (goto-char (point-min))
    (search-forward "|")
    (plist-get (writing-schedule--parse (org-table-to-lisp)) :events)))

;;;; Parsing a live buffer

(ert-deftest writing-schedule/integration/parse-example-buffer ()
  "Parsing the example org buffer yields 53 events across letters A and B."
  :tags '(integration)
  (with-temp-buffer
    (insert writing-schedule-test--example)
    (org-mode)
    (goto-char (point-min))
    (search-forward "|")
    (let ((parsed (writing-schedule--parse (org-table-to-lisp))))
      (should (= (length (plist-get parsed :events)) 53))
      (should (equal (plist-get parsed :letters) '("A" "B"))))))

;;;; Interactive mapping with stubbed prompts

(ert-deftest writing-schedule/integration/read-mapping-collects-answers ()
  "Reading the mapping collects a code and a description for each letter."
  :tags '(integration)
  (let ((answers '("100" "Alpha desc" "200" "Beta desc")))
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) (pop answers))))
      (let ((mapping (writing-schedule--read-mapping '("A" "B") '(("A" . "Alpha")))))
        (should (equal (plist-get (car mapping) :letter) "A"))
        (should (equal (plist-get (car mapping) :code) "100"))
        (should (equal (plist-get (car mapping) :desc) "Alpha desc"))
        (should (equal (plist-get (cadr mapping) :letter) "B"))
        (should (equal (plist-get (cadr mapping) :code) "200"))))))

;;;; Agenda registration

(ert-deftest writing-schedule/integration/ensure-agenda-adds-once ()
  "Adding a file to the agenda is idempotent."
  :tags '(integration)
  (let ((org-agenda-files '())
        (file (make-temp-file "ws-agenda" nil ".org")))
    (unwind-protect
        (progn
          (writing-schedule--ensure-agenda file)
          (should (member (expand-file-name file)
                          (mapcar #'expand-file-name org-agenda-files)))
          (writing-schedule--ensure-agenda file)
          (should (= 1 (length org-agenda-files))))
      (delete-file file))))

;;;; Template insertion

(ert-deftest writing-schedule/integration/insert-template-three ()
  "A three-project template has legend rows A, B, and C but not D."
  :tags '(integration)
  (with-temp-buffer
    (org-mode)
    (writing-schedule-insert-template 3)
    (let ((case-fold-search nil)
          (text (buffer-string)))
      (should (string-match-p "A:" text))
      (should (string-match-p "B:" text))
      (should (string-match-p "C:" text))
      (should-not (string-match-p "D:" text))
      (should (string-match-p "Generative:" text)))
    (goto-char (point-min))
    (search-forward "|")
    (should (org-table-to-lisp))))

(ert-deftest writing-schedule/integration/insert-template-clamps-range ()
  "The project count is clamped into the range one to four."
  :tags '(integration)
  (with-temp-buffer
    (org-mode)
    (writing-schedule-insert-template 9)
    (let ((case-fold-search nil))
      (should (string-match-p "D:" (buffer-string)))))
  (with-temp-buffer
    (org-mode)
    (writing-schedule-insert-template 0)
    (let ((case-fold-search nil)
          (text (buffer-string)))
      (should (string-match-p "A:" text))
      (should-not (string-match-p "B:" text)))))

;;;; Full generate command with stubbed input

(ert-deftest writing-schedule/integration/generate-writes-dated-file ()
  "The generate command writes a dated archival file and registers it.
The default output path is derived from the week's Monday, so a week
that begins 2026-01-19 lands in writing-2026-01-19.org."
  :tags '(integration)
  (let* ((dir (make-temp-file "ws-archive" t))
         (writing-schedule-directory dir)
         (org-agenda-files '())
         (fixed-date (org-read-date nil t "2026-01-21"))
         (expected (writing-schedule-file-for-week
                    (calendar-absolute-from-gregorian '(1 19 2026))))
         (answers '("100" "Alpha" "200" "Beta")))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'read-string) (lambda (&rest _) (pop answers)))
                    ((symbol-function 'org-read-date) (lambda (&rest _) fixed-date))
                    ;; Accept the dated default the command offers.
                    ((symbol-function 'read-file-name) (lambda (&rest _) expected))
                    ((symbol-function 'y-or-n-p) (lambda (&rest _) nil))
                    ((symbol-function 'find-file) (lambda (&rest _) nil)))
            (with-temp-buffer
              (insert writing-schedule-test--example)
              (org-mode)
              (goto-char (point-min))
              (search-forward "|")
              (writing-schedule-generate)))
          (should (string= (file-name-nondirectory expected) "writing-2026-01-19.org"))
          (should (file-exists-p expected))
          (let ((body (with-temp-buffer (insert-file-contents expected) (buffer-string))))
            (should (string-match-p "#\\+TITLE: Writing Schedule (week of 2026-01-19)" body))
            (should (string-match-p "<2026-01-19 Mon 04:00-05:30>" body))
            (should (string-match-p "\\* Summary" body)))
          (should (member (expand-file-name expected)
                          (mapcar #'expand-file-name org-agenda-files))))
      (delete-directory dir t))))

(ert-deftest writing-schedule/integration/generate-errors-outside-table ()
  "The generate command refuses to run outside an org table."
  :tags '(integration)
  (with-temp-buffer
    (org-mode)
    (insert "no table here\n")
    (goto-char (point-min))
    (should-error (writing-schedule-generate) :type 'user-error)))

;;;; iCalendar export

(ert-deftest writing-schedule/integration/export-ics-produces-vevents ()
  "Exporting a two-event schedule produces two VEVENT blocks."
  :tags '(integration)
  (let* ((events (list (list :section "Gen" :offset 0 :start "04:00" :end "05:30" :letter "A")
                       (list :section "Gen" :offset 1 :start "09:15" :end "10:45" :letter "B")))
         (mapping (list (list :letter "A" :code "1" :desc "Alpha proj")
                        (list :letter "B" :code "2" :desc "Beta proj")))
         (monday (calendar-absolute-from-gregorian '(1 19 2026)))
         (org-file (make-temp-file "ws-ics" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file org-file
            (insert (writing-schedule--build-org events mapping monday "Test week")))
          (let* ((ics (writing-schedule-export-ics org-file))
                 (text (with-temp-buffer (insert-file-contents ics) (buffer-string))))
            (should (file-exists-p ics))
            (should (string-match-p "BEGIN:VCALENDAR" text))
            (should (= 2 (cl-count-if (lambda (line) (string= line "BEGIN:VEVENT"))
                                      (split-string text "[\r\n]+"))))
            (should (string-match-p "Alpha proj" text))
            (delete-file ics)))
      (delete-file org-file))))

;;;; End-to-end pipeline

(ert-deftest writing-schedule/integration/full-pipeline-example ()
  "The example flows through parse, build, and export to 53 VEVENTs."
  :tags '(integration)
  (let ((org-file (make-temp-file "ws-full" nil ".org")))
    (unwind-protect
        (let* ((events (writing-schedule-test--events-from-example))
               (mapping (list (list :letter "A" :code "1" :desc "Alpha")
                              (list :letter "B" :code "2" :desc "Beta")))
               (monday (calendar-absolute-from-gregorian '(1 19 2026))))
          (should (= (length events) 53))
          (with-temp-file org-file
            (insert (writing-schedule--build-org events mapping monday "Full")))
          (let* ((ics (writing-schedule-export-ics org-file))
                 (text (with-temp-buffer (insert-file-contents ics) (buffer-string)))
                 (n (cl-count-if (lambda (line) (string= line "BEGIN:VEVENT"))
                                 (split-string text "[\r\n]+"))))
            (should (= n 53))
            (delete-file ics)))
      (delete-file org-file))))

(ert-deftest writing-schedule/integration/ensure-agenda-non-list ()
  "When `org-agenda-files' is not a plain list, the file is left untouched."
  :tags '(integration)
  (let ((org-agenda-files "~/agenda-list.org")
        (file (make-temp-file "ws-agenda" nil ".org")))
    (unwind-protect
        (progn
          (writing-schedule--ensure-agenda file)
          (should (equal org-agenda-files "~/agenda-list.org")))
      (delete-file file))))

(ert-deftest writing-schedule/integration/add-to-agenda-command ()
  "The public wrapper adds a file to the agenda list."
  :tags '(integration)
  (let ((org-agenda-files '())
        (file (make-temp-file "ws-agenda" nil ".org")))
    (unwind-protect
        (progn
          (writing-schedule-add-to-agenda file)
          (should (member (expand-file-name file)
                          (mapcar #'expand-file-name org-agenda-files))))
      (delete-file file))))

(ert-deftest writing-schedule/integration/generate-errors-on-empty-table ()
  "The generate command refuses a table that has no filled blocks."
  :tags '(integration)
  (with-temp-buffer
    (insert "| Time <l> | M | Tu |\n\
|-\n\
| Gen: |  |  |\n\
| 04:00-05:30 |  |  |\n")
    (org-mode)
    (goto-char (point-min))
    (search-forward "|")
    (should-error (writing-schedule-generate) :type 'user-error)))

(ert-deftest writing-schedule/integration/export-ics-uses-current-week-file ()
  "Called with no argument, the exporter uses the current week's dated file."
  :tags '(integration)
  (let* ((dir (make-temp-file "ws-archive" t))
         (writing-schedule-directory dir)
         (monday (writing-schedule--week-monday (current-time)))
         (file (writing-schedule-file-for-week monday))
         (events (list (list :section "Gen" :offset 0 :start "04:00" :end "05:30" :letter "A")))
         (mapping (list (list :letter "A" :code "1" :desc "Alpha"))))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert (writing-schedule--build-org events mapping monday "Default")))
          (let ((ics (writing-schedule-export-ics)))
            (should (file-exists-p ics))))
      (delete-directory dir t))))

(ert-deftest writing-schedule/integration/generate-exports-when-confirmed ()
  "When the user confirms, generate calls the iCalendar exporter."
  :tags '(integration)
  (let* ((dir (make-temp-file "ws-archive" t))
         (writing-schedule-directory dir)
         (org-agenda-files '())
         (fixed-date (org-read-date nil t "2026-01-21"))
         (out (writing-schedule-file-for-week
               (calendar-absolute-from-gregorian '(1 19 2026))))
         (answers '("100" "Alpha" "200" "Beta"))
         (exported nil))
    (unwind-protect
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) (pop answers)))
                  ((symbol-function 'org-read-date) (lambda (&rest _) fixed-date))
                  ((symbol-function 'read-file-name) (lambda (&rest _) out))
                  ((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                  ((symbol-function 'find-file) (lambda (&rest _) nil))
                  ((symbol-function 'writing-schedule-export-ics)
                   (lambda (&rest _) (setq exported t) "dummy.ics")))
          (with-temp-buffer
            (insert writing-schedule-test--example)
            (org-mode)
            (goto-char (point-min))
            (search-forward "|")
            (writing-schedule-generate))
          (should exported))
      (delete-directory dir t))))

;;;; Browsing the archive

(defmacro writing-schedule-test--with-archive (dir dates &rest body)
  "Bind DIR to a fresh archive holding a file per date in DATES, run BODY.
`writing-schedule-directory' is bound to DIR for the duration."
  (declare (indent 2))
  `(let* ((,dir (make-temp-file "ws-archive" t))
          (writing-schedule-directory ,dir))
     (unwind-protect
         (progn
           (dolist (d ,dates)
             (with-temp-file (writing-schedule-file-for-week
                              (writing-schedule--week-monday (org-read-date nil t d)))
               (insert "* placeholder\n")))
           ,@body)
       (delete-directory ,dir t))))

(ert-deftest writing-schedule/integration/open-recent-opens-newest ()
  "`writing-schedule-open-recent' visits the most recent archived week."
  :tags '(integration)
  (writing-schedule-test--with-archive dir '("2026-01-19" "2026-02-02" "2026-01-26")
    (let ((buffer (writing-schedule-open-recent)))
      (unwind-protect
          (should (string-suffix-p "writing-2026-02-02.org"
                                   (buffer-file-name buffer)))
        (kill-buffer buffer)))))

(ert-deftest writing-schedule/integration/open-recent-errors-when-empty ()
  "`writing-schedule-open-recent' signals when nothing is archived."
  :tags '(integration)
  (writing-schedule-test--with-archive dir '()
    (should-error (writing-schedule-open-recent) :type 'user-error)))

(ert-deftest writing-schedule/integration/open-week-completion ()
  "`writing-schedule-open-week' opens the week chosen through completion."
  :tags '(integration)
  (writing-schedule-test--with-archive dir '("2026-01-19" "2026-02-02")
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "2026-01-19")))
      (let ((buffer (writing-schedule-open-week)))
        (unwind-protect
            (should (string-suffix-p "writing-2026-01-19.org"
                                     (buffer-file-name buffer)))
          (kill-buffer buffer))))))

(ert-deftest writing-schedule/integration/open-week-by-date ()
  "With a prefix argument, `writing-schedule-open-week' opens by date."
  :tags '(integration)
  (writing-schedule-test--with-archive dir '("2026-01-19")
    (let ((fixed (org-read-date nil t "2026-01-22"))) ; a Thursday in that week
      (cl-letf (((symbol-function 'org-read-date) (lambda (&rest _) fixed)))
        (let ((buffer (writing-schedule-open-week t)))
          (unwind-protect
              (should (string-suffix-p "writing-2026-01-19.org"
                                       (buffer-file-name buffer)))
            (kill-buffer buffer)))))))

(ert-deftest writing-schedule/integration/open-week-by-date-missing ()
  "Opening a week that was never archived signals an error."
  :tags '(integration)
  (writing-schedule-test--with-archive dir '("2026-01-19")
    (let ((fixed (org-read-date nil t "2026-03-15"))) ; a week with no file
      (cl-letf (((symbol-function 'org-read-date) (lambda (&rest _) fixed)))
        (should-error (writing-schedule-open-week t) :type 'user-error)))))

(ert-deftest writing-schedule/integration/open-week-empty-falls-back-to-date ()
  "With no archive, `writing-schedule-open-week' uses the date prompt."
  :tags '(integration)
  (writing-schedule-test--with-archive dir '()
    (let ((fixed (org-read-date nil t "2026-01-22")))
      (cl-letf (((symbol-function 'org-read-date) (lambda (&rest _) fixed)))
        ;; No file exists for that week, so the date path errors.
        (should-error (writing-schedule-open-week) :type 'user-error)))))

(ert-deftest writing-schedule/integration/new-week-copies-and-opens ()
  "The command copies the chosen template to this week's table and opens it."
  :tags '(integration)
  (let* ((tdir (make-temp-file "ws-templates" t))
         (tabdir (make-temp-file "ws-tables" t))
         (writing-schedule-template-directory tdir)
         (writing-schedule-table-directory tabdir)
         (monday (writing-schedule--week-monday (current-time)))
         (dest (writing-schedule-table-file-for-week monday)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "teaching-week.org" tdir)
            (insert "| Time <l> | M |\n|-\n| Gen: |  |\n| 04:00-05:30 | A |\n"))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (&rest _) "teaching-week.org")))
            (let ((buffer (writing-schedule-new-week-from-template)))
              (unwind-protect
                  (progn
                    (should (file-exists-p dest))
                    (should (file-equal-p (buffer-file-name buffer) dest))
                    ;; Point should sit on a table line, ready to generate.
                    (with-current-buffer buffer
                      (should (org-at-table-p))))
                (kill-buffer buffer)))))
      (delete-directory tdir t)
      (delete-directory tabdir t))))

(ert-deftest writing-schedule/integration/new-week-errors-without-templates ()
  "The command signals when the template directory has no templates."
  :tags '(integration)
  (let* ((tdir (make-temp-file "ws-templates" t))
         (writing-schedule-template-directory tdir))
    (unwind-protect
        (should-error (writing-schedule-new-week-from-template) :type 'user-error)
      (delete-directory tdir t))))

(ert-deftest writing-schedule/integration/new-week-declines-overwrite ()
  "Declining the overwrite keeps the existing table and opens it."
  :tags '(integration)
  (let* ((tdir (make-temp-file "ws-templates" t))
         (tabdir (make-temp-file "ws-tables" t))
         (writing-schedule-template-directory tdir)
         (writing-schedule-table-directory tabdir)
         (monday (writing-schedule--week-monday (current-time)))
         (dest (writing-schedule-table-file-for-week monday)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "retreat.org" tdir)
            (insert "| Time <l> | M |\n|-\n| Gen: |  |\n| 04:00-05:30 | B |\n"))
          ;; A pre-existing table for this week, with distinct content.
          (with-temp-file dest (insert "existing table content\n"))
          (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "retreat.org"))
                    ((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
            (let ((buffer (writing-schedule-new-week-from-template)))
              (unwind-protect
                  (should (string-match-p "existing table content"
                                          (with-temp-buffer
                                            (insert-file-contents dest)
                                            (buffer-string))))
                (kill-buffer buffer)))))
      (delete-directory tdir t)
      (delete-directory tabdir t))))

;;;; Batch use from the command line

(ert-deftest writing-schedule/integration/batch-list-templates ()
  "The batch lister prints org templates and ignores other files."
  :tags '(integration)
  (let ((dir (make-temp-file "ws-tpl" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "teaching.org" dir) (insert "x"))
          (with-temp-file (expand-file-name "retreat.org" dir) (insert "x"))
          (with-temp-file (expand-file-name "notes.txt" dir) (insert "x"))
          (let ((out (with-output-to-string
                       (writing-schedule-batch-list-templates dir))))
            (should (string-match-p "retreat.org" out))
            (should (string-match-p "teaching.org" out))
            (should-not (string-match-p "notes.txt" out))))
      (delete-directory dir t))))

(ert-deftest writing-schedule/integration/batch-list-templates-empty ()
  "The batch lister reports when a directory has no templates."
  :tags '(integration)
  (let ((dir (make-temp-file "ws-tpl" t)))
    (unwind-protect
        (should (string-match-p "No templates found"
                                (with-output-to-string
                                  (writing-schedule-batch-list-templates dir))))
      (delete-directory dir t))))

(ert-deftest writing-schedule/integration/batch-generate-produces-ics ()
  "Batch generation writes a dated schedule and an iCalendar file."
  :tags '(integration)
  (let* ((tpl-dir (make-temp-file "ws-tpl" t))
         (out-dir (make-temp-file "ws-out" t))
         (writing-schedule-directory out-dir)
         (table (expand-file-name "three.org" tpl-dir))
         (expected-org (writing-schedule-file-for-week
                        (calendar-absolute-from-gregorian '(1 19 2026)))))
    (unwind-protect
        (progn
          (with-temp-file table (insert writing-schedule-test--example))
          (let ((ics (with-temp-buffer
                       (let ((standard-output (current-buffer)))
                         (writing-schedule-batch-generate table "2026-01-21")))))
            (should (file-exists-p expected-org))
            (should (file-exists-p ics))
            (let ((text (with-temp-buffer (insert-file-contents ics) (buffer-string))))
              (should (string-match-p "BEGIN:VCALENDAR" text))
              (should (= 53 (cl-count-if (lambda (line) (string= line "BEGIN:VEVENT"))
                                         (split-string text "[\r\n]+")))))))
      (delete-directory tpl-dir t)
      (delete-directory out-dir t))))

(ert-deftest writing-schedule/integration/batch-generate-out-dir ()
  "Batch generation honours an explicit output directory."
  :tags '(integration)
  (let* ((tpl-dir (make-temp-file "ws-tpl" t))
         (out-dir (make-temp-file "ws-out" t))
         (writing-schedule-directory writing-schedule-directory) ; restored after
         (table (expand-file-name "three.org" tpl-dir)))
    (unwind-protect
        (progn
          (with-temp-file table (insert writing-schedule-test--example))
          (let ((ics (with-temp-buffer
                       (let ((standard-output (current-buffer)))
                         (writing-schedule-batch-generate table "2026-01-21" out-dir)))))
            (should (file-exists-p ics))
            (should (string-prefix-p (file-name-as-directory (expand-file-name out-dir))
                                     (expand-file-name ics)))))
      (delete-directory tpl-dir t)
      (delete-directory out-dir t))))

(ert-deftest writing-schedule/integration/batch-generate-errors ()
  "Batch generation signals for a missing file, no table, or no filled cells."
  :tags '(integration)
  (should-error (writing-schedule-batch-generate "/no/such/file.org" "2026-01-21"))
  (let ((f (make-temp-file "ws-notable" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file f (insert "no table here\n"))
          (should-error (writing-schedule-batch-generate f "2026-01-21")))
      (delete-file f)))
  (let ((f (make-temp-file "ws-empty" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file f (insert "| Time <l> | M | Tu |\n|-\n| Gen: |  |  |\n| 04:00-05:30 |  |  |\n"))
          (should-error (writing-schedule-batch-generate f "2026-01-21")))
      (delete-file f))))

(ert-deftest writing-schedule/integration/batch-list-templates-default-dir ()
  "With no argument, the batch lister uses `writing-schedule-template-directory'."
  :tags '(integration)
  (let* ((dir (make-temp-file "ws-tpl" t))
         (writing-schedule-template-directory dir))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "one.org" dir) (insert "x"))
          (should (string-match-p "one.org"
                                  (with-output-to-string
                                    (writing-schedule-batch-list-templates)))))
      (delete-directory dir t))))

(ert-deftest writing-schedule/integration/add-to-agenda-default-current-week ()
  "With no argument, the agenda wrapper adds the current week's dated file."
  :tags '(integration)
  (let* ((dir (make-temp-file "ws-arch" t))
         (writing-schedule-directory dir)
         (org-agenda-files '()))
    (unwind-protect
        (progn
          (writing-schedule-add-to-agenda)
          (should (member (expand-file-name (writing-schedule--current-week-file))
                          (mapcar #'expand-file-name org-agenda-files))))
      (delete-directory dir t))))

(ert-deftest writing-schedule/integration/generate-from-template ()
  "Selecting a saved table generates the dated schedule from it."
  :tags '(integration)
  (let* ((tpl-dir (make-temp-file "ws-tpl" t))
         (out-dir (make-temp-file "ws-out" t))
         (writing-schedule-template-directory tpl-dir)
         (writing-schedule-directory out-dir)
         (fixed-date (org-read-date nil t "2026-01-21"))
         (answers '("100" "Alpha" "200" "Beta"))
         (expected (writing-schedule-file-for-week
                    (calendar-absolute-from-gregorian '(1 19 2026)))))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "meeting-week.org" tpl-dir)
            (insert writing-schedule-test--example))
          (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "meeting-week.org"))
                    ((symbol-function 'read-string) (lambda (&rest _) (pop answers)))
                    ((symbol-function 'org-read-date) (lambda (&rest _) fixed-date))
                    ((symbol-function 'read-file-name) (lambda (&rest _) expected))
                    ((symbol-function 'y-or-n-p) (lambda (&rest _) nil))
                    ((symbol-function 'find-file) (lambda (&rest _) nil)))
            (writing-schedule-generate-from-template))
          (should (file-exists-p expected))
          (let ((body (with-temp-buffer (insert-file-contents expected) (buffer-string))))
            (should (string-match-p "#\\+TITLE: Writing Schedule (week of 2026-01-19)" body))
            (should (string-match-p "<2026-01-19 Mon 04:00-05:30>" body))))
      (delete-directory tpl-dir t)
      (delete-directory out-dir t))))

(ert-deftest writing-schedule/integration/generate-from-template-errors-when-empty ()
  "The command signals when the template directory has no tables."
  :tags '(integration)
  (let* ((dir (make-temp-file "ws-tpl" t))
         (writing-schedule-template-directory dir))
    (unwind-protect
        (should-error (writing-schedule-generate-from-template) :type 'user-error)
      (delete-directory dir t))))

(ert-deftest writing-schedule/integration/generate-from-template-errors-without-table ()
  "The command signals when the chosen file has no org table."
  :tags '(integration)
  (let* ((dir (make-temp-file "ws-tpl" t))
         (writing-schedule-template-directory dir))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "notes.org" dir) (insert "no table here\n"))
          (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "notes.org")))
            (should-error (writing-schedule-generate-from-template) :type 'user-error)))
      (delete-directory dir t))))

(ert-deftest writing-schedule/integration/save-template-writes ()
  "Saving the table at point writes a named template, preserving the title."
  :tags '(integration)
  (let* ((dir (make-temp-file "ws-tpl" t))
         (writing-schedule-template-directory dir))
    (unwind-protect
        (with-temp-buffer
          (insert writing-schedule-test--example)
          (org-mode)
          (goto-char (point-min))
          (search-forward "|")
          (let ((dest (writing-schedule-save-template-table "meeting-week")))
            (should (file-exists-p dest))
            (should (string-suffix-p "meeting-week.org" dest))
            (let ((body (with-temp-buffer (insert-file-contents dest) (buffer-string))))
              (should (string-match-p "#\\+TITLE: Writing Schedule for 3 Projects" body))
              (should (string-match-p "20:30-22:00" body)))))
      (delete-directory dir t))))

(ert-deftest writing-schedule/integration/save-template-errors-outside-table ()
  "Saving refuses when point is not in an org table."
  :tags '(integration)
  (with-temp-buffer
    (org-mode)
    (insert "no table here\n")
    (goto-char (point-min))
    (should-error (writing-schedule-save-template-table "x") :type 'user-error)))

(ert-deftest writing-schedule/integration/save-template-title-from-name-and-empty ()
  "An empty name errors, and a buffer without a title gets its title from the name."
  :tags '(integration)
  (let* ((dir (make-temp-file "ws-tpl" t))
         (writing-schedule-template-directory dir))
    (unwind-protect
        (with-temp-buffer
          (insert "| Time <l> | M |\n|-\n| Gen: |  |\n| 04:00-05:30 | A |\n")
          (org-mode)
          (goto-char (point-min))
          (search-forward "|")
          (should-error (writing-schedule-save-template-table "  ") :type 'user-error)
          (let* ((dest (writing-schedule-save-template-table "light.org"))
                 (body (with-temp-buffer (insert-file-contents dest) (buffer-string))))
            (should (string-match-p "#\\+TITLE: light" body))))
      (delete-directory dir t))))

(ert-deftest writing-schedule/integration/save-template-declines-overwrite ()
  "Declining the overwrite keeps the existing template."
  :tags '(integration)
  (let* ((dir (make-temp-file "ws-tpl" t))
         (writing-schedule-template-directory dir)
         (dest (expand-file-name "dup.org" dir)))
    (unwind-protect
        (progn
          (with-temp-file dest (insert "old content\n"))
          (with-temp-buffer
            (insert "| Time <l> | M |\n|-\n| Gen: |  |\n| 04:00-05:30 | A |\n")
            (org-mode)
            (goto-char (point-min))
            (search-forward "|")
            (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
              (should-error (writing-schedule-save-template-table "dup") :type 'user-error)))
          (should (string-match-p "old content"
                                  (with-temp-buffer (insert-file-contents dest) (buffer-string)))))
      (delete-directory dir t))))

(ert-deftest writing-schedule/integration/save-template-interactive-and-newline ()
  "The name can be read interactively, and a table without a trailing
newline is still saved with one."
  :tags '(integration)
  (let* ((dir (make-temp-file "ws-tpl" t))
         (writing-schedule-template-directory dir))
    (unwind-protect
        (with-temp-buffer
          ;; No trailing newline after the last table row.
          (insert "| Time <l> | M |\n|-\n| Gen: |  |\n| 04:00-05:30 | A |")
          (org-mode)
          (goto-char (point-min))
          (search-forward "|")
          (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "prompted")))
            (let* ((dest (writing-schedule-save-template-table))
                   (body (with-temp-buffer (insert-file-contents dest) (buffer-string))))
              (should (string-suffix-p "prompted.org" dest))
              (should (string-suffix-p "\n" body)))))
      (delete-directory dir t))))

(ert-deftest writing-schedule/integration/batch-insert-template ()
  "Batch insert prints a template, or writes it to a file."
  :tags '(integration)
  (let ((out (with-output-to-string (writing-schedule-batch-insert-template 2))))
    (should (string-match-p "for 2 Projects" out))
    (should (string-match-p "| A: |" out))
    (should (string-match-p "| B: |" out))
    (should-not (string-match-p "| C: |" out)))
  (let* ((dir (make-temp-file "ws-t" t))
         (dest (expand-file-name "blank.org" dir)))
    (unwind-protect
        (progn
          (with-output-to-string (writing-schedule-batch-insert-template 4 dest))
          (should (file-exists-p dest))
          (should (string-match-p "for 4 Projects"
                                  (with-temp-buffer (insert-file-contents dest) (buffer-string)))))
      (delete-directory dir t))))

(ert-deftest writing-schedule/integration/batch-list-weeks ()
  "Batch list-weeks prints dated files newest first and ignores others."
  :tags '(integration)
  (let ((dir (make-temp-file "ws-arch" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "writing-2026-01-19.org" dir) (insert "x"))
          (with-temp-file (expand-file-name "writing-2026-01-26.org" dir) (insert "x"))
          (with-temp-file (expand-file-name "notes.org" dir) (insert "x"))
          (let ((out (with-output-to-string (writing-schedule-batch-list-weeks dir))))
            (should (string-match-p "writing-2026-01-26.org" out))
            (should (string-match-p "writing-2026-01-19.org" out))
            (should (< (string-match "2026-01-26" out) (string-match "2026-01-19" out)))
            (should-not (string-match-p "notes.org" out))))
      (delete-directory dir t))))

(ert-deftest writing-schedule/integration/batch-list-weeks-empty ()
  "Batch list-weeks reports when the archive is empty."
  :tags '(integration)
  (let* ((dir (make-temp-file "ws-arch" t))
         (writing-schedule-directory dir))
    (unwind-protect
        (should (string-match-p "No archived weeks"
                                (with-output-to-string (writing-schedule-batch-list-weeks))))
      (delete-directory dir t))))

(ert-deftest writing-schedule/integration/batch-save-template ()
  "Batch save-template copies a table file into the library with a title."
  :tags '(integration)
  (let* ((tpl-dir (make-temp-file "ws-tpl" t))
         (src-dir (make-temp-file "ws-src" t))
         (writing-schedule-template-directory tpl-dir)
         (src (expand-file-name "week.org" src-dir)))
    (unwind-protect
        (progn
          (with-temp-file src (insert writing-schedule-test--example))
          (let ((dest (with-temp-buffer
                        (let ((standard-output (current-buffer)))
                          (writing-schedule-batch-save-template src "grant-week")))))
            (should (file-exists-p dest))
            (should (string-suffix-p "grant-week.org" dest))
            (let ((body (with-temp-buffer (insert-file-contents dest) (buffer-string))))
              (should (string-match-p "#\\+TITLE: Writing Schedule for 3 Projects" body))
              (should (string-match-p "20:30-22:00" body)))))
      (delete-directory tpl-dir t)
      (delete-directory src-dir t))))

(ert-deftest writing-schedule/integration/batch-save-template-errors ()
  "Batch save-template signals for a missing file, empty name, or no table."
  :tags '(integration)
  (let* ((tpl-dir (make-temp-file "ws-tpl" t))
         (writing-schedule-template-directory tpl-dir))
    (unwind-protect
        (progn
          (should-error (writing-schedule-batch-save-template "/no/such.org" "x"))
          (let ((f (make-temp-file "ws" nil ".org")))
            (unwind-protect
                (progn
                  (with-temp-file f (insert "| Time | M |\n|-\n| 04:00-05:30 | A |\n"))
                  (should-error (writing-schedule-batch-save-template f "  ")))
              (delete-file f)))
          (let ((f (make-temp-file "ws" nil ".org")))
            (unwind-protect
                (progn
                  (with-temp-file f (insert "no table here\n"))
                  (should-error (writing-schedule-batch-save-template f "x")))
              (delete-file f))))
      (delete-directory tpl-dir t))))

(ert-deftest writing-schedule/integration/batch-save-template-title-from-name ()
  "When the source has no title, the template title comes from the name."
  :tags '(integration)
  (let* ((tpl-dir (make-temp-file "ws-tpl" t))
         (src-dir (make-temp-file "ws-src" t))
         (writing-schedule-template-directory tpl-dir)
         (src (expand-file-name "raw.org" src-dir)))
    (unwind-protect
        (progn
          (with-temp-file src (insert "| Time | M |\n|-\n| 04:00-05:30 | A |\n"))
          (let ((dest (with-temp-buffer
                        (let ((standard-output (current-buffer)))
                          (writing-schedule-batch-save-template src "retreat")))))
            (should (string-match-p "#\\+TITLE: retreat"
                                    (with-temp-buffer (insert-file-contents dest) (buffer-string))))))
      (delete-directory tpl-dir t)
      (delete-directory src-dir t))))

(ert-deftest writing-schedule/integration/batch-timeblock-sheets-week ()
  "One week file is written, and it is not compiled when no compiler exists."
  :tags '(integration)
  (let* ((src-dir (make-temp-file "ws-src" t))
         (out-dir (make-temp-file "ws-out" t))
         (src (expand-file-name "wk.org" src-dir))
         (writing-schedule-latex-compiler "nonexistent-xyz"))
    (unwind-protect
        (progn
          (with-temp-file src (insert writing-schedule-test--example))
          (let ((files (with-temp-buffer
                         (let ((standard-output (current-buffer)))
                           (writing-schedule-batch-timeblock-sheets
                            src "2026-01-21" nil out-dir)))))
            (should (= (length files) 1))
            (should (string-match-p "sheets-week-2026-01-19.tex" (car files)))
            (should (file-exists-p (car files)))
            (let ((tex (with-temp-buffer (insert-file-contents (car files)) (buffer-string))))
              (should (string-match-p "Date: 2026-01-19 (Monday)" tex))
              (should (string-match-p "Date: 2026-01-24 (Saturday)" tex)))))
      (delete-directory src-dir t)
      (delete-directory out-dir t))))

(ert-deftest writing-schedule/integration/batch-timeblock-sheets-per-day ()
  "One file is written per day, and the compiler is invoked when present."
  :tags '(integration)
  (let* ((src-dir (make-temp-file "ws-src" t))
         (out-dir (make-temp-file "ws-out" t))
         (src (expand-file-name "wk.org" src-dir))
         (writing-schedule-latex-compiler "true"))
    (unwind-protect
        (progn
          (with-temp-file src (insert writing-schedule-test--example))
          (let ((files (with-temp-buffer
                         (let ((standard-output (current-buffer)))
                           (writing-schedule-batch-timeblock-sheets
                            src "2026-01-21" t out-dir)))))
            (should (= (length files) 6))
            (should (cl-every (lambda (f)
                                (string-match-p "sheet-2026-01-[0-9]+\\.tex" f))
                              files))))
      (delete-directory src-dir t)
      (delete-directory out-dir t))))

(ert-deftest writing-schedule/integration/batch-timeblock-sheets-errors ()
  "Sheets signal for a missing file, no table, or no day columns."
  :tags '(integration)
  (let ((writing-schedule-latex-compiler "nonexistent-xyz"))
    (should-error (writing-schedule-batch-timeblock-sheets "/no/such.org" "2026-01-21"))
    (let ((f (make-temp-file "ws" nil ".org")))
      (unwind-protect
          (progn (with-temp-file f (insert "no table here\n"))
                 (should-error (writing-schedule-batch-timeblock-sheets f "2026-01-21")))
        (delete-file f)))
    (let ((f (make-temp-file "ws" nil ".org")))
      (unwind-protect
          (progn (with-temp-file f (insert "| foo | bar |\n| 04:00-05:30 | A |\n"))
                 (should-error (writing-schedule-batch-timeblock-sheets f "2026-01-21")))
        (delete-file f)))))

(ert-deftest writing-schedule/integration/timeblock-sheets-command ()
  "The interactive command writes sheets for the chosen week."
  :tags '(integration)
  (let* ((out-dir (make-temp-file "ws-out" t))
         (writing-schedule-sheets-directory out-dir)
         (writing-schedule-latex-compiler "nonexistent-xyz"))
    (unwind-protect
        (with-temp-buffer
          (insert writing-schedule-test--example)
          (org-mode)
          (goto-char (point-min))
          (search-forward "|")
          (cl-letf (((symbol-function 'org-read-date)
                     (lambda (&rest _) (date-to-time "2026-01-21 12:00:00"))))
            (let ((files (writing-schedule-timeblock-sheets)))
              (should (= (length files) 1))
              (should (file-exists-p (car files))))))
      (delete-directory out-dir t))))

(ert-deftest writing-schedule/integration/timeblock-sheets-command-needs-table ()
  "The sheet command refuses when point is not in an org table."
  :tags '(integration)
  (with-temp-buffer
    (org-mode)
    (insert "no table here\n")
    (goto-char (point-min))
    (should-error (writing-schedule-timeblock-sheets) :type 'user-error)))

(provide 'test-writing-schedule-integration)
;;; test-writing-schedule-integration.el ends here
