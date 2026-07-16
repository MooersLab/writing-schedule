;;; test-writing-schedule.el --- Unit tests for writing-schedule.el  -*- lexical-binding: t; -*-

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

;;;; writing-schedule--day-offset

(ert-deftest writing-schedule/day-offset/known-abbreviations ()
  "Known day abbreviations map to the correct Monday offset."
  (dolist (case '(("M" . 0) ("Mo" . 0) ("Mon" . 0) ("mon" . 0)
                  ("Tu" . 1) ("tue" . 1)
                  ("W" . 2) ("We" . 2) ("Wed" . 2)
                  ("Th" . 3) ("thu" . 3)
                  ("F" . 4) ("Fr" . 4) ("Fri" . 4)
                  ("Sa" . 5) ("sat" . 5)
                  ("Su" . 6) ("Sun" . 6)))
    (should (equal (writing-schedule--day-offset (car case)) (cdr case)))))

(ert-deftest writing-schedule/day-offset/trims-whitespace ()
  "Surrounding whitespace does not defeat the lookup."
  (should (equal (writing-schedule--day-offset "  M  ") 0)))

(ert-deftest writing-schedule/day-offset/rejects-unknown ()
  "Unknown or ambiguous cells return nil."
  (should-not (writing-schedule--day-offset "X"))
  (should-not (writing-schedule--day-offset ""))
  (should-not (writing-schedule--day-offset nil))
  ;; A lone T is ambiguous between Tuesday and Thursday, so it is excluded.
  (should-not (writing-schedule--day-offset "T")))

;;;; writing-schedule--parse-time

(ert-deftest writing-schedule/parse-time/happy-path ()
  "A well formed range returns zero padded start and end strings."
  (should (equal (writing-schedule--parse-time "04:00-05:30") '("04:00" . "05:30")))
  (should (equal (writing-schedule--parse-time "20:30-22:00") '("20:30" . "22:00"))))

(ert-deftest writing-schedule/parse-time/zero-pads-single-digit-hour ()
  "A single digit hour is padded to two digits."
  (should (equal (writing-schedule--parse-time "9:15 - 10:45") '("09:15" . "10:45")))
  (should (equal (writing-schedule--parse-time "04:00-5:30") '("04:00" . "05:30"))))

(ert-deftest writing-schedule/parse-time/tolerates-irregular-spacing ()
  "Irregular spacing around the dash is accepted."
  (should (equal (writing-schedule--parse-time "15:00- 16:30") '("15:00" . "16:30")))
  (should (equal (writing-schedule--parse-time "11:30 - 13:00") '("11:30" . "13:00"))))

(ert-deftest writing-schedule/parse-time/rejects-non-times ()
  "Cells that hold no time return nil."
  (should-not (writing-schedule--parse-time "Generative:"))
  (should-not (writing-schedule--parse-time ""))
  (should-not (writing-schedule--parse-time nil)))

(ert-deftest writing-schedule/parse-time/tolerates-space-after-colon ()
  "A space after the colon in a time is tolerated, as in 16: 30."
  (should (equal (writing-schedule--parse-time "15:00-16: 30") '("15:00" . "16:30")))
  (should (equal (writing-schedule--parse-time "9: 15 - 10:45") '("09:15" . "10:45"))))

;;;; writing-schedule--minutes

(ert-deftest writing-schedule/minutes/various-durations ()
  "The minute count matches the elapsed time."
  (should (= (writing-schedule--minutes "04:00" "05:30") 90))
  (should (= (writing-schedule--minutes "09:15" "10:45") 90))
  (should (= (writing-schedule--minutes "04:00" "05:00") 60))
  (should (= (writing-schedule--minutes "04:00" "04:15") 15)))

(ert-deftest writing-schedule/minutes/zero-duration ()
  "Equal start and end yield zero minutes."
  (should (= (writing-schedule--minutes "00:00" "00:00") 0)))

;;;; writing-schedule--parse

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
         (parsed (writing-schedule--parse table))
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
         (event (car (plist-get (writing-schedule--parse table) :events))))
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
         (event (car (plist-get (writing-schedule--parse table) :events))))
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
         (legend (plist-get (writing-schedule--parse table) :legend)))
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
         (parsed (writing-schedule--parse table))
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
         (parsed (writing-schedule--parse table)))
    (should (equal (cdr (assoc "EM" (plist-get parsed :legend))) "email"))
    (should-not (assoc "GEN" (plist-get parsed :legend)))
    (should (equal (plist-get (car (plist-get parsed :events)) :section) "Gen"))))

(ert-deftest writing-schedule/parse/section-without-colon ()
  "A section header written without a trailing colon is still recognized."
  (let* ((table '(("Time <l>" "M")
                  hline
                  ("Support" "")
                  ("13:15-14:45" "A")))
         (event (car (plist-get (writing-schedule--parse table) :events))))
    (should (equal (plist-get event :section) "Support"))))

(ert-deftest writing-schedule/parse/header-only-has-no-events ()
  "A table with only a header row yields no events."
  (should-not (plist-get (writing-schedule--parse '(("Time" "M" "Tu") hline))
                         :events)))

;;;; writing-schedule--week-monday

(ert-deftest writing-schedule/week-monday/snaps-any-day-to-monday ()
  "Any day inside a week snaps back to that week's Monday."
  (dolist (day '("2026-01-19"    ; Monday itself
                 "2026-01-20"    ; Tuesday
                 "2026-01-24"    ; Saturday
                 "2026-01-25"))  ; Sunday
    (let ((monday (writing-schedule--week-monday (org-read-date nil t day))))
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

;;;; writing-schedule--iso-date and writing-schedule-file-for-week

(ert-deftest writing-schedule/iso-date/formats-absolute-date ()
  "An absolute date renders as a zero-padded ISO string."
  (should (string= (writing-schedule--iso-date
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
  (let ((s (writing-schedule--template-string 3)))
    (should (string-match-p "#\\+TITLE: Writing Schedule for 3 Projects" s))
    (should (string-match-p "Time <l>" s))
    (should (string-match-p "| A: |" s))
    (should (string-match-p "| C: |" s))
    (should-not (string-match-p "| D: |" s)))
  (should (string-match-p "for 1 Project\n" (writing-schedule--template-string 0)))
  (should (string-match-p "for 9 Projects" (writing-schedule--template-string "9")))
  (should (string-match-p "for 26 Projects" (writing-schedule--template-string 99))))

(ert-deftest writing-schedule/template-string/more-than-four ()
  "The scaffold can produce more than four single-letter projects."
  (let ((s (writing-schedule--template-string 6)))
    (should (string-match-p "| E: |" s))
    (should (string-match-p "| F: |" s))
    (should-not (string-match-p "| G: |" s))))

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
                  ("t" . writing-schedule-insert-template)
                  ("n" . writing-schedule-new-week-from-template)
                  ("f" . writing-schedule-generate-from-template)
                  ("s" . writing-schedule-save-template-table)
                  ("o" . writing-schedule-open-week)
                  ("r" . writing-schedule-open-recent)
                  ("e" . writing-schedule-export-ics)
                  ("a" . writing-schedule-add-to-agenda)))
    (should (eq (lookup-key writing-schedule-command-map (kbd (car pair)))
                (cdr pair)))))

(provide 'test-writing-schedule)
;;; test-writing-schedule.el ends here
