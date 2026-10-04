;;; test-writing-schedule.el --- Unit tests for writing-schedule.el  -*- lexical-binding: t; -*-

;; Author: Blaine Mooers <blaine-mooers@ou.edu>
;; Assisted-by: Claude Code:claude-opus-4-8

;;; Commentary:
;; Unit tests for the pure helper functions of writing-schedule.el.
;; Each test exercises one function with a happy path, edge cases, and
;; error or rejection cases.  Run with:
;;
;;   emacs --batch -L . -L test -l test/test-writing-schedule.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'calendar)
(require 'writing-schedule)

;;;; writing-schedule-day-offset

(ert-deftest writing-schedule/day-offset/known-abbreviations ()
  "Known day abbreviations map to the correct Monday offset."
  (dolist (case '(("M" . 0) ("Mo" . 0) ("Mon" . 0) ("mon" . 0)
                  ("Tu" . 1) ("tue" . 1)
                  ("W" . 2) ("We" . 2) ("Wed" . 2)
                  ("Th" . 3) ("thu" . 3)
                  ("F" . 4) ("Fr" . 4) ("Fri" . 4)
                  ("Sa" . 5) ("sat" . 5)
                  ("Su" . 6) ("Sun" . 6)))
    (should (equal (writing-schedule-day-offset (car case)) (cdr case)))))

(ert-deftest writing-schedule/day-offset/trims-whitespace ()
  "Surrounding whitespace does not defeat the lookup."
  (should (equal (writing-schedule-day-offset "  M  ") 0)))

(ert-deftest writing-schedule/day-offset/rejects-unknown ()
  "Unknown or ambiguous cells return nil."
  (should-not (writing-schedule-day-offset "X"))
  (should-not (writing-schedule-day-offset ""))
  (should-not (writing-schedule-day-offset nil))
  ;; A lone T is ambiguous between Tuesday and Thursday, so it is excluded.
  (should-not (writing-schedule-day-offset "T")))

;;;; writing-schedule-parse-time

(ert-deftest writing-schedule/parse-time/happy-path ()
  "A well formed range returns zero padded start and end strings."
  (should (equal (writing-schedule-parse-time "04:00-05:30") '("04:00" . "05:30")))
  (should (equal (writing-schedule-parse-time "20:30-22:00") '("20:30" . "22:00"))))

(ert-deftest writing-schedule/parse-time/zero-pads-single-digit-hour ()
  "A single digit hour is padded to two digits."
  (should (equal (writing-schedule-parse-time "9:15 - 10:45") '("09:15" . "10:45")))
  (should (equal (writing-schedule-parse-time "04:00-5:30") '("04:00" . "05:30"))))

(ert-deftest writing-schedule/parse-time/tolerates-irregular-spacing ()
  "Irregular spacing around the dash is accepted."
  (should (equal (writing-schedule-parse-time "15:00- 16:30") '("15:00" . "16:30")))
  (should (equal (writing-schedule-parse-time "11:30 - 13:00") '("11:30" . "13:00"))))

(ert-deftest writing-schedule/parse-time/rejects-non-times ()
  "Cells that hold no time return nil."
  (should-not (writing-schedule-parse-time "Generative:"))
  (should-not (writing-schedule-parse-time ""))
  (should-not (writing-schedule-parse-time nil)))

(ert-deftest writing-schedule/parse-time/tolerates-space-after-colon ()
  "A space after the colon in a time is tolerated, as in 16: 30."
  (should (equal (writing-schedule-parse-time "15:00-16: 30") '("15:00" . "16:30")))
  (should (equal (writing-schedule-parse-time "9: 15 - 10:45") '("09:15" . "10:45"))))

;;;; writing-schedule-minutes-between

(ert-deftest writing-schedule/minutes/various-durations ()
  "The minute count matches the elapsed time."
  (should (= (writing-schedule-minutes-between "04:00" "05:30") 90))
  (should (= (writing-schedule-minutes-between "09:15" "10:45") 90))
  (should (= (writing-schedule-minutes-between "04:00" "05:00") 60))
  (should (= (writing-schedule-minutes-between "04:00" "04:15") 15)))

(ert-deftest writing-schedule/minutes/zero-duration ()
  "Equal start and end yield zero minutes."
  (should (= (writing-schedule-minutes-between "00:00" "00:00") 0)))

;;;; writing-schedule-parse-table

(ert-deftest writing-schedule/parse/reads-events-letters-legend ()
  "The parser returns events, sorted letters, and the legend."
  (let* ((table '(("Time <l>" "M" "Tu" "W")
                  hline
                  ("Gen:" "" "" "")
                  ("04:00-05:30" "A" "B" "")
                  ("05:45-07:15" "" "a" "B")
                  hline
                  ("Support" "" "" "")
                  ("13:15-14:45" "A" "" "")
                  hline
                  ("A:" "Proj Alpha" "" "")
                  ("B:" "Proj Beta" "" "")
                  ("C: Gamma inline" "" "" "")))
         (parsed (writing-schedule-parse-table table))
         (events (plist-get parsed :events))
         (letters (plist-get parsed :letters))
         (legend (plist-get parsed :legend)))
    (should (= (length events) 5))
    (should (equal letters '("A" "B")))
    (should (equal (cdr (assoc "A" legend)) "Proj Alpha"))
    (should (equal (cdr (assoc "B" legend)) "Proj Beta"))
    (should (equal (cdr (assoc "C" legend)) "Gamma inline"))))

(ert-deftest writing-schedule/parse/first-event-fields ()
  "The first event carries the correct section, day, time, and letter."
  (let* ((table '(("Time <l>" "M" "Tu" "W")
                  hline
                  ("Gen:" "" "" "")
                  ("04:00-05:30" "A" "B" "")))
         (event (car (plist-get (writing-schedule-parse-table table) :events))))
    (should (equal (plist-get event :section) "Gen"))
    (should (equal (plist-get event :offset) 0))
    (should (equal (plist-get event :start) "04:00"))
    (should (equal (plist-get event :end) "05:30"))
    (should (equal (plist-get event :letter) "A"))))

(ert-deftest writing-schedule/parse/uppercases-letters ()
  "A lower-case cell letter is normalized to upper case."
  (let* ((table '(("Time <l>" "M")
                  hline
                  ("Gen:" "")
                  ("04:00-05:30" "a")))
         (event (car (plist-get (writing-schedule-parse-table table) :events))))
    (should (equal (plist-get event :letter) "A"))))

(ert-deftest writing-schedule/parse/legend-description-in-first-column ()
  "A legend row carries the description in its first cell after the colon."
  (let* ((table '(("Time <l>" "M")
                  hline
                  ("Gen:" "")
                  ("04:00-05:30" "A")
                  hline
                  ("A:0211dnph1docking" "")
                  ("B: DUSP1 radiation" "")))
         (legend (plist-get (writing-schedule-parse-table table) :legend)))
    (should (equal (cdr (assoc "A" legend)) "0211dnph1docking"))
    (should (equal (cdr (assoc "B" legend)) "DUSP1 radiation"))))

(ert-deftest writing-schedule/parse/two-letter-codes-and-many-projects ()
  "Two-letter task codes attach legend descriptions, beyond four projects."
  (let* ((table '(("Time <l>" "M" "Tu" "W")
                  hline
                  ("Generative:" "" "" "")
                  ("04:00-05:30" "A" "EM" "W")
                  ("05:45-07:15" "B" "EX" "TT")
                  hline
                  ("A: DNPH1 docking" "" "" "")
                  ("B: DUSP1 radiation" "" "" "")
                  ("EM: email" "" "" "")
                  ("EX: exercise" "" "" "")
                  ("W: 2026words" "" "" "")
                  ("TT: time tracking" "" "" "")))
         (parsed (writing-schedule-parse-table table))
         (legend (plist-get parsed :legend))
         (letters (plist-get parsed :letters)))
    (should (equal letters '("A" "B" "EM" "EX" "TT" "W")))
    (should (equal (cdr (assoc "EM" legend)) "email"))
    (should (equal (cdr (assoc "W" legend)) "2026words"))
    (should (equal (cdr (assoc "TT" legend)) "time tracking"))
    (should-not (assoc "GENERATIVE" legend))))

(ert-deftest writing-schedule/parse/legend-code-is-case-sensitive ()
  "An uppercase code is a legend row; a capitalized word is a section."
  (let* ((table '(("Time <l>" "M")
                  hline
                  ("Gen:" "")
                  ("04:00-05:30" "EM")
                  hline
                  ("EM: email" "")))
         (parsed (writing-schedule-parse-table table)))
    (should (equal (cdr (assoc "EM" (plist-get parsed :legend))) "email"))
    (should-not (assoc "GEN" (plist-get parsed :legend)))
    (should (equal (plist-get (car (plist-get parsed :events)) :section) "Gen"))))

(ert-deftest writing-schedule/parse/section-without-colon ()
  "A section header written without a trailing colon is still recognized."
  (let* ((table '(("Time <l>" "M")
                  hline
                  ("Support" "")
                  ("13:15-14:45" "A")))
         (event (car (plist-get (writing-schedule-parse-table table) :events))))
    (should (equal (plist-get event :section) "Support"))))

(ert-deftest writing-schedule/parse/header-only-has-no-events ()
  "A table with only a header row yields no events."
  (should-not (plist-get (writing-schedule-parse-table '(("Time" "M" "Tu") hline))
                         :events)))

;;;; writing-schedule-week-monday

(ert-deftest writing-schedule/week-monday/snaps-any-day-to-monday ()
  "Any day inside a week snaps back to that week's Monday."
  (dolist (day '("2026-01-19"    ; Monday itself
                 "2026-01-20"    ; Tuesday
                 "2026-01-24"    ; Saturday
                 "2026-01-25"))  ; Sunday
    (let ((monday (writing-schedule-week-monday (org-read-date nil t day))))
      (should (equal (calendar-gregorian-from-absolute monday) '(1 19 2026))))))

;;;; writing-schedule--week-file-regexp and archived-weeks

(ert-deftest writing-schedule/week-file-regexp/matches-dated-names ()
  "The regexp matches dated org names and captures the ISO date."
  (let ((writing-schedule-file-format "writing-%s.org")
        (re (writing-schedule--week-file-regexp)))
    (should (string-match re "writing-2026-01-19.org"))
    (should (equal (match-string 1 "writing-2026-01-19.org") "2026-01-19"))
    (should-not (string-match re "writing-schedule.org"))
    (should-not (string-match re "writing-2026-01-19.ics"))
    (should-not (string-match re "notes.org"))))

(ert-deftest writing-schedule/archived-weeks/lists-newest-first ()
  "Archived weeks are returned newest first, ignoring other files."
  (let ((dir (make-temp-file "ws-archive" t))
        (writing-schedule-file-format "writing-%s.org"))
    (let ((writing-schedule-directory dir))
      (unwind-protect
          (progn
            (dolist (d '("2026-01-19" "2026-02-02" "2026-01-26"))
              (with-temp-file (expand-file-name (format "writing-%s.org" d) dir)
                (insert "x")))
            ;; Decoys that must be ignored.
            (with-temp-file (expand-file-name "writing-2026-01-19.ics" dir) (insert "x"))
            (with-temp-file (expand-file-name "notes.org" dir) (insert "x"))
            (let ((weeks (writing-schedule--archived-weeks)))
              (should (equal (mapcar #'car weeks)
                             '("2026-02-02" "2026-01-26" "2026-01-19")))
              (should (string-suffix-p "writing-2026-02-02.org" (cdr (car weeks))))))
        (delete-directory dir t)))))

(ert-deftest writing-schedule/week-file-regexp/fallback-without-format-token ()
  "When the format lacks %s, the regexp still matches a dated name."
  (let* ((writing-schedule-file-format "weekly.org")
         (re (writing-schedule--week-file-regexp)))
    (should (string-match re "weekly-2026-01-19.org"))
    (should (equal (match-string 1 "weekly-2026-01-19.org") "2026-01-19"))))

(ert-deftest writing-schedule/ordered-table/preserves-order-and-completes ()
  "The ordered completion table reports identity sorting and completes."
  (let* ((candidates '("2026-02-02" "2026-01-26" "2026-01-19"))
         (table (writing-schedule--ordered-table candidates))
         (metadata (funcall table "" nil 'metadata)))
    (should (eq (cdr (assq 'display-sort-function (cdr metadata))) #'identity))
    (should (equal (funcall table "2026-01" nil t)
                   '("2026-01-26" "2026-01-19")))
    (should (equal (funcall table "2026-02-02" nil nil) t))))

;;;; writing-schedule-iso-date and writing-schedule-file-for-week

(ert-deftest writing-schedule/iso-date/formats-absolute-date ()
  "An absolute date renders as a zero-padded ISO string."
  (should (string= (writing-schedule-iso-date
                    (calendar-absolute-from-gregorian '(1 19 2026)))
                   "2026-01-19")))

(ert-deftest writing-schedule/file-for-week/builds-dated-path ()
  "The weekly file path combines the directory, the format, and the date."
  (let ((writing-schedule-directory "/tmp/ws")
        (writing-schedule-file-format "writing-%s.org"))
    (should (string= (writing-schedule-file-for-week
                      (calendar-absolute-from-gregorian '(1 19 2026)))
                     "/tmp/ws/writing-2026-01-19.org"))))

;;;; writing-schedule--timestamp

(ert-deftest writing-schedule/timestamp/formats-active-range ()
  "The timestamp string matches the org active range format."
  (let ((monday (calendar-absolute-from-gregorian '(1 19 2026))))
    (should (string= (writing-schedule--timestamp monday 0 "04:00" "05:30")
                     "<2026-01-19 Mon 04:00-05:30>"))
    (should (string= (writing-schedule--timestamp monday 5 "20:30" "22:00")
                     "<2026-01-24 Sat 20:30-22:00>"))))

;;;; writing-schedule--map-get

(ert-deftest writing-schedule/map-get/finds-and-misses ()
  "Lookup returns the matching plist, or nil when the letter is absent."
  (let ((mapping (list (list :letter "A" :code "1")
                       (list :letter "B" :code "2"))))
    (should (equal (plist-get (writing-schedule--map-get mapping "B") :code) "2"))
    (should-not (writing-schedule--map-get mapping "Z"))))

;;;; writing-schedule--blank-row

(ert-deftest writing-schedule/blank-row/builds-cells ()
  "A blank row has the label plus the requested number of empty cells."
  (should (string= (writing-schedule--blank-row "A:" 6)
                   "| A: |  |  |  |  |  |  |\n"))
  (should (string= (writing-schedule--blank-row "X" 1)
                   "| X |  |\n")))

;;;; writing-schedule--build-org

(ert-deftest writing-schedule/build-org/contains-expected-structure ()
  "The generated org body carries the title, header, sections, and stamps."
  (let* ((events (list (list :section "Gen" :offset 0 :start "04:00" :end "05:30" :letter "A")
                       (list :section "Gen" :offset 1 :start "04:00" :end "05:30" :letter "B")))
         (mapping (list (list :letter "A" :code "100" :desc "Alpha")
                        (list :letter "B" :code "200" :desc "Beta")))
         (monday (calendar-absolute-from-gregorian '(1 19 2026)))
         (org (writing-schedule--build-org events mapping monday "My Title")))
    (should (string-match-p "#\\+TITLE: My Title" org))
    (should (string-match-p "usepackage\\[margin=0.5in\\]{geometry}" org))
    (should (string-match-p "^\\* Gen$" org))
    (should (string-match-p ":CATEGORY: Gen" org))
    (should (string-match-p "\\*\\* TODO Alpha :A:" org))
    (should (string-match-p ":WS_CODE: 100" org))
    (should (string-match-p "<2026-01-19 Mon 04:00-05:30>" org))
    (should (string-match-p "<2026-01-20 Tue 04:00-05:30>" org))))

(ert-deftest writing-schedule/build-org/honours-use-todo-nil ()
  "With `writing-schedule-use-todo' nil the events omit the TODO keyword."
  (let* ((writing-schedule-use-todo nil)
         (events (list (list :section "Gen" :offset 0 :start "04:00" :end "05:30" :letter "A")))
         (mapping (list (list :letter "A" :code "100" :desc "Alpha")))
         (monday (calendar-absolute-from-gregorian '(1 19 2026)))
         (org (writing-schedule--build-org events mapping monday "T")))
    (should (string-match-p "^\\*\\* Alpha :A:$" org))
    (should-not (string-match-p "TODO" org))))

;;;; writing-schedule--summary

(ert-deftest writing-schedule/summary/totals-hours-per-letter ()
  "The summary totals the weekly hours for each letter."
  (let* ((events (list (list :section "Gen" :offset 0 :start "04:00" :end "05:30" :letter "A")
                       (list :section "Gen" :offset 1 :start "04:00" :end "05:30" :letter "A")))
         (mapping (list (list :letter "A" :code "100" :desc "Alpha")))
         (summary (writing-schedule--summary events mapping)))
    (should (string-match-p "\\* Summary" summary))
    (should (string-match-p "- A = 3\\.00 h (Alpha)" summary))))

(ert-deftest writing-schedule/build-org/head-falls-back-to-code-then-letter ()
  "The headline uses the code when the description is empty, and a
generic label when neither a description nor a code is available."
  (let* ((events (list (list :section "Gen" :offset 0 :start "04:00" :end "05:30" :letter "A")
                       (list :section "Gen" :offset 1 :start "04:00" :end "05:30" :letter "C")))
         (mapping (list (list :letter "A" :code "77" :desc "")))
         (monday (calendar-absolute-from-gregorian '(1 19 2026)))
         (org (writing-schedule--build-org events mapping monday "T")))
    (should (string-match-p "\\*\\* TODO 77 :A:" org))
    (should (string-match-p "\\*\\* TODO Project C :C:" org))))

(ert-deftest writing-schedule/summary/label-falls-back-to-code-then-letter ()
  "The summary label uses the code, then a generic label, when the
description is missing."
  (let* ((events (list (list :section "Gen" :offset 0 :start "04:00" :end "05:30" :letter "A")
                       (list :section "Gen" :offset 1 :start "04:00" :end "05:30" :letter "C")))
         (mapping (list (list :letter "A" :code "77" :desc "")))
         (summary (writing-schedule--summary events mapping)))
    (should (string-match-p "- A = 1\\.50 h (77)" summary))
    (should (string-match-p "- C = 1\\.50 h (Project C)" summary))))

(ert-deftest writing-schedule/table-file-for-week/builds-path ()
  "The working table path combines the table directory and the date."
  (let ((writing-schedule-table-directory "/tmp/ws/tables"))
    (should (string= (writing-schedule-table-file-for-week
                      (calendar-absolute-from-gregorian '(1 19 2026)))
                     "/tmp/ws/tables/table-2026-01-19.org"))))

(ert-deftest writing-schedule/directory-accessors/derive-or-override ()
  "The template and table directories derive from the base when nil,
and are used verbatim when set, at call time and in any load order."
  (let ((writing-schedule-directory "/tmp/base")
        (writing-schedule-template-directory nil)
        (writing-schedule-table-directory nil))
    (should (string= (writing-schedule--template-directory) "/tmp/base/templates"))
    (should (string= (writing-schedule--table-directory) "/tmp/base/tables"))
    ;; Changing the base updates both, because they derive at call time.
    (setq writing-schedule-directory "/tmp/other")
    (should (string= (writing-schedule--template-directory) "/tmp/other/templates"))
    (should (string= (writing-schedule--table-directory) "/tmp/other/tables"))
    ;; An explicit value overrides the derivation.
    (setq writing-schedule-template-directory "/custom/tpl"
          writing-schedule-table-directory "/custom/tab")
    (should (string= (writing-schedule--template-directory) "/custom/tpl"))
    (should (string= (writing-schedule--table-directory) "/custom/tab"))))

(ert-deftest writing-schedule/template-string/builds-n-projects ()
  "The template has a title, a day header, and one legend row per project."
  (let ((s (writing-schedule-template-string 3)))
    (should (string-match-p "#\\+TITLE: Writing Schedule for 3 Projects" s))
    (should (string-match-p "Time <l>" s))
    (should (string-match-p "| A: |" s))
    (should (string-match-p "| C: |" s))
    (should-not (string-match-p "| D: |" s)))
  (should (string-match-p "for 1 Project\n" (writing-schedule-template-string 0)))
  (should (string-match-p "for 9 Projects" (writing-schedule-template-string "9")))
  (should (string-match-p "for 26 Projects" (writing-schedule-template-string 99))))

(ert-deftest writing-schedule/template-string/more-than-four ()
  "The scaffold can produce more than four single-letter projects."
  (let ((s (writing-schedule-template-string 6)))
    (should (string-match-p "| E: |" s))
    (should (string-match-p "| F: |" s))
    (should-not (string-match-p "| G: |" s))))

(ert-deftest writing-schedule/timeblock/custom-code-descriptions ()
  "Custom descriptions fill the key, and the table legend takes precedence."
  (let ((writing-schedule-code-descriptions '(("Z" . "zebra") ("A" . "ignored"))))
    (let ((eff (writing-schedule--effective-legend '(("A" . "docking")))))
      (should (equal (cdr (assoc "A" eff)) "docking"))
      (should (equal (cdr (assoc "Z" eff)) "zebra")))
    (let* ((table '(("Time <l>" "M")
                    hline
                    ("04:00-05:30" "Z")))
           (parsed (writing-schedule-parse-table table))
           (monday (calendar-absolute-from-gregorian '(1 19 2026)))
           (kd (writing-schedule--timeblock-days parsed monday)))
      (should (string-match-p "Z = zebra" (car kd)))))
  ;; With no custom descriptions the legend is unchanged.
  (let ((writing-schedule-code-descriptions nil))
    (should (equal (writing-schedule--effective-legend '(("A" . "docking")))
                   '(("A" . "docking"))))))

(ert-deftest writing-schedule/timeblock/colspec ()
  "The column spec has a narrow time column and N plan columns."
  (should (equal (writing-schedule--timeblock-colspec 4)
                 "|m{1cm}:m{4cm}:m{4cm}:m{4cm}:m{4cm}|"))
  (should (equal (writing-schedule--timeblock-colspec 1) "|m{1cm}:m{4cm}|")))

(ert-deftest writing-schedule/timeblock/latex-escape ()
  "LaTeX special characters are escaped."
  (should (equal (writing-schedule--latex-escape "a & b_c 50%") "a \\& b\\_c 50\\%"))
  (should (equal (writing-schedule--latex-escape nil) "")))

(ert-deftest writing-schedule/timeblock/spans-cover-the-range ()
  "A block span runs from its start row to its end row."
  (let ((writing-schedule-timeblock-subrows 5)
        (events '((:letter "A" :start "04:00" :end "05:30" :offset 0))))
    (let* ((spans (writing-schedule--timeblock-spans events))
           (s (car spans)))
      ;; start 4:00 -> row 20, end 5:30 -> row 27 (floor of the sub-row)
      (should (= (nth 0 s) 20))
      (should (= (nth 1 s) 27))
      (should (string-prefix-p "A" (nth 2 s)))))
  ;; A block shorter than one sub-row still spans at least one row.
  (let ((writing-schedule-timeblock-subrows 5)
        (events '((:letter "X" :start "04:00" :end "04:10" :offset 0))))
    (let ((s (car (writing-schedule--timeblock-spans events))))
      (should (= (nth 1 s) (1+ (nth 0 s)))))))

(ert-deftest writing-schedule/timeblock/document-has-block-outline ()
  "The document draws a block with heavy rules and boxed cells."
  (let* ((table '(("Time <l>" "M")
                  hline
                  ("04:00-05:30" "A")
                  hline
                  ("A: docking" "")))
         (parsed (writing-schedule-parse-table table))
         (monday (calendar-absolute-from-gregorian '(1 19 2026)))
         (kd (writing-schedule--timeblock-days parsed monday))
         (doc (writing-schedule--timeblock-document (car kd) (cdr kd))))
    (should (string-match-p "cmidrule\\[1pt\\]{2-2}" doc))
    (should (string-match-p "vrule width 1pt" doc))
    (should (string-match-p "4:00-5:30" doc))))

(ert-deftest writing-schedule/timeblock/sheets-directory ()
  "The sheets directory derives from the base, or is used verbatim."
  (let ((writing-schedule-directory "/tmp/base")
        (writing-schedule-sheets-directory nil))
    (should (string= (writing-schedule--sheets-directory) "/tmp/base/sheets")))
  (let ((writing-schedule-sheets-directory "/custom/sheets"))
    (should (string= (writing-schedule--sheets-directory) "/custom/sheets"))))

(ert-deftest writing-schedule/timeblock/document-content ()
  "The document carries the key, the dates, the plan, and page breaks."
  (let* ((table '(("Time <l>" "M" "Tu")
                  hline
                  ("Gen:" "" "")
                  ("04:00-05:30" "A" "EM")
                  hline
                  ("A: docking" "" "")
                  ("EM: email" "" "")))
         (parsed (writing-schedule-parse-table table))
         (monday (calendar-absolute-from-gregorian '(1 19 2026)))
         (kd (writing-schedule--timeblock-days parsed monday))
         (doc (writing-schedule--timeblock-document (car kd) (cdr kd))))
    (should (string-match-p "A = docking" doc))
    (should (string-match-p "EM = email" doc))
    (should (string-match-p "Date: 2026-01-19 (Monday)" doc))
    (should (string-match-p "Date: 2026-01-20 (Tuesday)" doc))
    (should (string-match-p "4:00-5:30" doc))
    (should (string-match-p "\\\\newpage" doc))
    (should (string-match-p "\\\\clearpage" doc))
    (should (string-match-p "\\\\documentclass{article}" doc))))

(ert-deftest writing-schedule/timeblock/org-document ()
  "The org export carries a key, per-day tables, and the margin header."
  (let* ((table '(("Time <l>" "M" "Tu")
                  hline
                  ("04:00-05:30" "A" "EM")
                  hline
                  ("A: docking" "" "")
                  ("EM: email" "" "")))
         (parsed (writing-schedule-parse-table table))
         (monday (calendar-absolute-from-gregorian '(1 19 2026)))
         (org (writing-schedule--timeblock-org-document parsed monday)))
    (should (string-match-p "#\\+TITLE: Time-Block Sheets, week of 2026-01-19" org))
    (should (string-match-p "usepackage\\[margin=0.5in\\]{geometry}" org))
    (should (string-match-p "=A= :: docking" org))
    (should (string-match-p "^\\* 2026-01-19 (Monday)" org))
    (should (string-match-p "^\\* 2026-01-20 (Tuesday)" org))
    (should (string-match-p ":booktabs t" org))
    (should (string-match-p "| Time | Code | Task | Revision |" org))
    (should (string-match-p "| 4:00-5:30 | A | docking | |" org))))

(ert-deftest writing-schedule/timeblock/org-document-single-day ()
  "With an offset, the org export covers only that one day."
  (let* ((table '(("Time <l>" "M" "Tu")
                  hline
                  ("04:00-05:30" "A" "EM")
                  hline
                  ("A: docking" "" "")
                  ("EM: email" "" "")))
         (parsed (writing-schedule-parse-table table))
         (monday (calendar-absolute-from-gregorian '(1 19 2026)))
         (org (writing-schedule--timeblock-org-document parsed monday 1)))
    (should (string-match-p "#\\+TITLE: Time-Block Sheet, 2026-01-20" org))
    (should (string-match-p "^\\* 2026-01-20 (Tuesday)" org))
    (should-not (string-match-p "2026-01-19 (Monday)" org))
    (should (string-match-p "| 4:00-5:30 | EM | email | |" org))))

(ert-deftest writing-schedule/timeblock/latex-single-day ()
  "With an offset, the LaTeX sheet covers only that one day."
  (let* ((table '(("Time <l>" "M" "Tu")
                  hline
                  ("Gen:" "" "")
                  ("04:00-05:30" "A" "EM")
                  hline
                  ("A: docking" "" "")
                  ("EM: email" "" "")))
         (parsed (writing-schedule-parse-table table))
         (monday (calendar-absolute-from-gregorian '(1 19 2026)))
         (kd (writing-schedule--timeblock-days parsed monday 1))
         (doc (writing-schedule--timeblock-document (car kd) (cdr kd))))
    (should (= (length (cdr kd)) 1))
    (should (string-match-p "Date: 2026-01-20 (Tuesday)" doc))
    (should-not (string-match-p "Date: 2026-01-19 (Monday)" doc))))

(ert-deftest writing-schedule/timeblock/days-blank-for-absent-day ()
  "An offset with no column still returns one day, with no blocks."
  (let* ((table '(("Time <l>" "M")
                  hline
                  ("04:00-05:30" "A")))
         (parsed (writing-schedule-parse-table table))
         (monday (calendar-absolute-from-gregorian '(1 19 2026)))
         (kd (writing-schedule--timeblock-days parsed monday 6))) ; Sunday
    (should (= (length (cdr kd)) 1))
    (should (string-match-p "2026-01-25 (Sunday)" (nth 0 (car (cdr kd)))))
    ;; The day now carries (DATE-STR SPANS NOTE); an absent day has no spans.
    (should (null (nth 1 (car (cdr kd)))))
    (should (null (nth 2 (car (cdr kd)))))))

;;;; writing-schedule day-abs and monday-of-abs

(ert-deftest writing-schedule/day-abs/today-and-iso ()
  "A day spec resolves an ISO date, and today from nil, the empty string, or the word."
  (should (= (writing-schedule--day-abs "2026-01-20")
             (calendar-absolute-from-gregorian '(1 20 2026))))
  (let ((today (writing-schedule--abs-from-time (current-time))))
    (should (= (writing-schedule--day-abs nil) today))
    (should (= (writing-schedule--day-abs "") today))
    (should (= (writing-schedule--day-abs "  Today ") today))))

(ert-deftest writing-schedule/monday-of-abs/snaps-any-day ()
  "Any day in a week maps to that week's Monday."
  (let ((monday (calendar-absolute-from-gregorian '(1 19 2026))))
    (dolist (greg '((1 19 2026) (1 20 2026) (1 24 2026) (1 25 2026)))
      (should (= (writing-schedule--monday-of-abs
                  (calendar-absolute-from-gregorian greg))
                 monday)))))

;;;; writing-schedule single-day schedule

(ert-deftest writing-schedule/day-title/formats-date-and-weekday ()
  "A single-day title carries the ISO date and the weekday name."
  (should (string= (writing-schedule--day-title
                    (calendar-absolute-from-gregorian '(1 21 2026)))
                   "Writing Schedule (2026-01-21 Wednesday)")))

(ert-deftest writing-schedule/day-events/filters-to-one-day ()
  "Only the events whose offset falls on the day survive."
  (let* ((events (list (list :section "Gen" :offset 0
                             :start "04:00" :end "05:30" :letter "A")
                       (list :section "Gen" :offset 2
                             :start "09:00" :end "10:30" :letter "B")))
         (monday (calendar-absolute-from-gregorian '(1 19 2026)))
         (wed (calendar-absolute-from-gregorian '(1 21 2026)))
         (filtered (writing-schedule--day-events events monday wed)))
    (should (= (length filtered) 1))
    (should (equal (plist-get (car filtered) :letter) "B"))
    (should (equal (writing-schedule--day-letters filtered) '("B")))))

(ert-deftest writing-schedule/day-file-for-day/builds-day-name ()
  "The single-day file uses the day- prefix and the ISO date."
  (let ((writing-schedule-directory "/tmp/base")
        (writing-schedule-day-file-format "day-%s.org"))
    (should (string= (writing-schedule-day-file-for-day
                      (calendar-absolute-from-gregorian '(1 21 2026)))
                     "/tmp/base/day-2026-01-21.org"))))

;;;; writing-schedule overlap detection and guard

(defun ws-test--ev (offset start end letter &optional section)
  (list :section (or section "Writing") :offset offset
        :start start :end end :letter letter))

(ert-deftest writing-schedule/overlaps/same-day-clash ()
  "Two blocks on the same day whose intervals overlap conflict."
  (let ((conflicts (writing-schedule-overlaps
                    (list (ws-test--ev 2 "09:00" "10:30" "B" "Editing")
                          (ws-test--ev 2 "10:00" "11:00" "C" "Support")))))
    (should (= (length conflicts) 1))
    (should (= (plist-get (car conflicts) :offset) 2))
    (should (equal (plist-get (plist-get (car conflicts) :first) :letter) "B"))
    (should (equal (plist-get (plist-get (car conflicts) :second) :letter) "C"))))

(ert-deftest writing-schedule/overlaps/touching-blocks-clean ()
  "Half-open intervals mean touching blocks do not conflict."
  (should (null (writing-schedule-overlaps
                 (list (ws-test--ev 0 "04:00" "05:30" "A")
                       (ws-test--ev 0 "05:30" "07:00" "B"))))))

(ert-deftest writing-schedule/overlaps/identical-blocks-clash ()
  "Two identical blocks on the same day conflict."
  (should (= 1 (length (writing-schedule-overlaps
                        (list (ws-test--ev 0 "09:00" "10:00" "A" "Gen")
                              (ws-test--ev 0 "09:00" "10:00" "B" "Sup")))))))

(ert-deftest writing-schedule/overlaps/three-blocks-pairs ()
  "A long block overlaps two others; the middle two do not overlap."
  (let* ((conflicts (writing-schedule-overlaps
                     (list (ws-test--ev 2 "09:00" "11:00" "A")
                           (ws-test--ev 2 "09:30" "09:45" "B")
                           (ws-test--ev 2 "10:00" "12:00" "C"))))
         (pairs (mapcar (lambda (c)
                          (cons (plist-get (plist-get c :first) :letter)
                                (plist-get (plist-get c :second) :letter)))
                        conflicts)))
    (should (equal pairs '(("A" . "B") ("A" . "C"))))))

(ert-deftest writing-schedule/overlaps/different-days-clean ()
  "Blocks on different days never conflict."
  (should (null (writing-schedule-overlaps
                 (list (ws-test--ev 0 "09:00" "10:30" "A")
                       (ws-test--ev 1 "09:00" "10:30" "B"))))))

(ert-deftest writing-schedule/overlaps/overnight-same-day ()
  "An overnight block conflicts with a later block on its own day."
  (should (= 1 (length (writing-schedule-overlaps
                        (list (ws-test--ev 0 "22:00" "01:00" "A")
                              (ws-test--ev 0 "23:00" "23:30" "B")))))))

(ert-deftest writing-schedule/overlaps/overnight-no-cross-day ()
  "The after-midnight tail does not reach the next day."
  (should (null (writing-schedule-overlaps
                 (list (ws-test--ev 0 "22:00" "01:00" "A")
                       (ws-test--ev 1 "00:30" "01:00" "B"))))))

(ert-deftest writing-schedule/overlaps/empty ()
  "No events, no conflicts."
  (should (null (writing-schedule-overlaps '()))))

(ert-deftest writing-schedule/overlap-lines/matches-python-wording ()
  "The formatted line matches the Python port exactly."
  (let ((lines (writing-schedule-overlap-lines
                (writing-schedule-overlaps
                 (list (ws-test--ev 2 "09:00" "10:30" "B" "Editing")
                       (ws-test--ev 2 "10:00" "11:00" "C" "Support"))))))
    (should (equal lines
                   '("Wednesday: 09:00-10:30 [B, Editing] overlaps 10:00-11:00 [C, Support]")))))

(ert-deftest writing-schedule/conflicting-identities/includes-both ()
  "The identity set holds both clashing blocks and not the clean one."
  (let* ((a (ws-test--ev 2 "09:00" "10:30" "B" "Editing"))
         (b (ws-test--ev 2 "10:00" "11:00" "C" "Support"))
         (clean (ws-test--ev 2 "13:00" "14:00" "D" "Writing"))
         (ids (writing-schedule-conflicting-identities (list a b clean))))
    (should (member (writing-schedule--event-identity a) ids))
    (should (member (writing-schedule--event-identity b) ids))
    (should-not (member (writing-schedule--event-identity clean) ids))))

(ert-deftest writing-schedule/guard/warn-returns-t ()
  "The warn action reports and proceeds."
  (let ((writing-schedule-overlap-action 'warn))
    (should (writing-schedule--guard-overlaps
             (list (ws-test--ev 0 "09:00" "10:30" "A" "Gen")
                   (ws-test--ev 0 "10:00" "11:00" "B" "Sup"))))))

(ert-deftest writing-schedule/guard/error-signals ()
  "The error action refuses with a user error."
  (let ((writing-schedule-overlap-action 'error))
    (should-error
     (writing-schedule--guard-overlaps
      (list (ws-test--ev 0 "09:00" "10:30" "A" "Gen")
            (ws-test--ev 0 "10:00" "11:00" "B" "Sup")))
     :type 'user-error)))

(ert-deftest writing-schedule/guard/confirm-honors-answer ()
  "The confirm action returns whatever the prompt answers."
  (let ((writing-schedule-overlap-action 'confirm)
        (events (list (ws-test--ev 0 "09:00" "10:30" "A" "Gen")
                      (ws-test--ev 0 "10:00" "11:00" "B" "Sup"))))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (should (writing-schedule--guard-overlaps events)))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
      (should-not (writing-schedule--guard-overlaps events)))))

(ert-deftest writing-schedule/guard/batch-warns-and-proceeds ()
  "In batch the confirm action prints a warning and proceeds."
  (let ((writing-schedule-overlap-action 'confirm))
    (let ((out (with-output-to-string
                 (should (writing-schedule--guard-overlaps
                          (list (ws-test--ev 0 "09:00" "10:30" "A" "Gen")
                                (ws-test--ev 0 "10:00" "11:00" "B" "Sup"))
                          t)))))
      (should (string-match-p "warning" out))
      (should (string-match-p "Monday" out)))))

(ert-deftest writing-schedule/guard/clean-proceeds ()
  "A clean table proceeds under every action."
  (dolist (action '(confirm warn error))
    (let ((writing-schedule-overlap-action action))
      (should (writing-schedule--guard-overlaps
               (list (ws-test--ev 0 "09:00" "10:00" "A")))))))

;;;; writing-schedule--legend-mapping

(ert-deftest writing-schedule/legend-mapping/uses-legend-descriptions ()
  "The batch mapping takes descriptions from the legend and leaves codes empty."
  (let ((mapping (writing-schedule--legend-mapping
                  '("A" "B") '(("A" . "Alpha") ("C" . "Gamma")))))
    (should (equal (plist-get (car mapping) :letter) "A"))
    (should (equal (plist-get (car mapping) :desc) "Alpha"))
    (should (equal (plist-get (car mapping) :code) ""))
    (should (equal (plist-get (cadr mapping) :desc) ""))))

;;;; writing-schedule-command-map

(ert-deftest writing-schedule/command-map/binds-each-command ()
  "The command map is a keymap that binds each key to its command."
  (should (keymapp writing-schedule-command-map))
  (dolist (pair '(("g" . writing-schedule-generate)
                  ("G" . writing-schedule-generate-for-day)
                  ("t" . writing-schedule-insert-template)
                  ("n" . writing-schedule-new-week-from-template)
                  ("f" . writing-schedule-generate-from-template)
                  ("s" . writing-schedule-save-template-table)
                  ("b" . writing-schedule-timeblock-sheets)
                  ("d" . writing-schedule-timeblock-sheet-for-day)
                  ("k" . writing-schedule-check-overlaps)
                  ("o" . writing-schedule-open-week)
                  ("r" . writing-schedule-open-recent)
                  ("e" . writing-schedule-export-ics)
                  ("a" . writing-schedule-add-to-agenda)))
    (should (eq (lookup-key writing-schedule-command-map (kbd (car pair)))
                (cdr pair)))))

;;;; Public API of 0.3.1

(defconst writing-schedule-test--dir
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory of this test file, used to find the parity fixture.")

(ert-deftest writing-schedule/split-row/trims-like-python ()
  "The default form trims each cell, as `split_row' does in Python."
  (should (equal (writing-schedule-split-row "| a | b |") '("a" "b")))
  (should (equal (writing-schedule-split-row "  | A: x |  |\n") '("A: x" "")))
  (should (equal (writing-schedule-split-row "|  |") '(""))))

(ert-deftest writing-schedule/split-row/raw-keeps-padding ()
  "The RAW form keeps padding so the line can be rebuilt byte for byte."
  (let* ((line "| 05:00-06:00 | A  |   |")
         (cells (writing-schedule-split-row line t)))
    (should (equal cells '(" 05:00-06:00 " " A  " "   ")))
    (should (equal (concat "|" (mapconcat #'identity cells "|") "|") line))))

(ert-deftest writing-schedule/table-lines-to-lisp/matches-org ()
  "The string reader returns the shape of `org-table-to-lisp'."
  (let* ((text "#+TITLE: t\n\n| Time | M |\n|------+---|\n| 05:00-06:00 | A |\n\nafter\n| x |\n")
         (rows (writing-schedule-table-lines-to-lisp text)))
    (should (equal rows '(("Time" "M") hline ("05:00-06:00" "A"))))
    (should (equal rows
                   (with-temp-buffer
                     (insert text)
                     (org-mode)
                     (goto-char (point-min))
                     (search-forward "| Time")
                     (org-table-to-lisp))))))

(ert-deftest writing-schedule/parse-text/parity-fixture ()
  "The parity fixture yields 44 events and 12 codes, as in the Python port."
  (let* ((file (expand-file-name "projects-and-tasks.org" writing-schedule-test--dir))
         (parsed (writing-schedule-parse-text
                  (with-temp-buffer (insert-file-contents file) (buffer-string)))))
    (should (= (length (plist-get parsed :events)) 44))
    (should (equal (plist-get parsed :letters)
                   '("A" "B" "CE" "CM" "EM" "EX" "LC" "LP" "RT" "TP" "TT" "W")))))

(ert-deftest writing-schedule/obsolete-names/still-work ()
  "The private names of 0.1.0 remain callable and are marked obsolete."
  (with-no-warnings
    (should (equal (writing-schedule--parse-time "5:00-6:30") '("05:00" . "06:30")))
    (should (= (writing-schedule--minutes "05:00" "06:30") 90))
    (should (= (writing-schedule--day-offset "Tu") 1)))
  (dolist (old '(writing-schedule--parse writing-schedule--overlaps
                 writing-schedule--overlap-lines
                 writing-schedule--conflicting-identities
                 writing-schedule--template-string
                 writing-schedule--week-monday writing-schedule--iso-date))
    (should (fboundp old))
    (should (get old 'byte-obsolete-info))))

(provide 'test-writing-schedule)
;;; test-writing-schedule.el ends here
