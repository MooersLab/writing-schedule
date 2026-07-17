;;; writing-schedule.el --- Generate agenda events and iCalendar from a weekly writing-block template -*- lexical-binding: t; -*-

;; Author: Blaine Mooers <blaine-mooers@ou.edu>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: calendar, outlines, convenience

;;; Commentary:
;;
;; writing-schedule.el generates a week of writing blocks from a reusable
;; template and exports it to iCalendar.  It is the generation-side
;; complement to a timeblock viewer such as org-timeblock (see Related
;; work below), because it produces the week rather than viewing
;; timestamps that already exist.
;;
;; This package reads a weekly writing schedule that you keep as an
;; org-mode table.  Each row is a time block.  Each column after the
;; first is a day of the week.  Each filled cell holds a short uppercase
;; code that names the project or task worked on during that block, for
;; example A, B, or a two-letter task code such as EM for email.  A table
;; can hold many codes, so it is not limited to four projects.
;;
;; The package turns that table into dated events.  Each week is
;; archived in its own dated file, such as writing-2026-01-19.org,
;; inside `writing-schedule-directory'.  Those events feed the org
;; agenda and, through org's own iCalendar exporter, an .ics file that
;; Outlook Web or any calendar app can import.
;;
;; Think of the table as a seating chart and the generator as the
;; usher.  You decide who sits where, meaning which project fills which
;; block.  The usher walks the chart, stamps each seat with a real date
;; and time, and hands the guest list to your calendar.
;;
;; Main commands:
;;   `writing-schedule-insert-template'         insert a blank table for 1 to 26 projects
;;   `writing-schedule-new-week-from-template'  start this week from a saved template
;;   `writing-schedule-generate'                parse the table at point and write the org file
;;   `writing-schedule-timeblock-sheets'        print time-block sheets for the week
;;   `writing-schedule-open-week'               open an archived week, by completion or by date
;;   `writing-schedule-open-recent'             open the most recent archived week
;;   `writing-schedule-export-ics'              export the org file to .ics
;;   `writing-schedule-add-to-agenda'           add the org file to `org-agenda-files'
;;
;; A shell front end, writing-schedule.sh, lets people who do not use
;; Emacs list templates and generate an iCalendar file from one.
;;
;; Related work:
;;   org-timeblock gives org-agenda an interactive timeblock view of
;;   scheduled tasks.  This package is complementary, because it
;;   generates and archives a week from a reusable template and exports
;;   it to iCalendar, rather than viewing timestamps that already exist,
;;   so the two pair well.

;;; Code:

(require 'org)
(require 'calendar)
(require 'subr-x)
(require 'cl-lib)
(require 'seq)

;;;; Customization

(defgroup writing-schedule nil
  "Turn a weekly writing-block table into agenda events and iCalendar."
  :group 'org
  :prefix "writing-schedule-")

(defcustom writing-schedule-directory
  (expand-file-name "writing-schedule"
                    (if (and (boundp 'org-directory) org-directory)
                        org-directory "~/org"))
  "Directory that holds one dated schedule file per week.
Each generated week is archived here under its own file, so past
weeks are kept rather than overwritten."
  :type 'directory)

(defcustom writing-schedule-file-format "writing-%s.org"
  "Format of a weekly schedule file name.
The %s is replaced by the Monday of the week in ISO form, for
example 2026-01-19, giving a file such as writing-2026-01-19.org."
  :type 'string)

(defcustom writing-schedule-template-directory nil
  "Directory of saved context templates.
Each template is an org file that already has the letters assigned
in its table, for example a teaching week or a meeting week.
`writing-schedule-new-week-from-template' reads from here.

When nil, it derives from `writing-schedule-directory' as a
templates subdirectory, computed each time it is used, so setting
`writing-schedule-directory' is enough and the load order does not
matter.  Set this only to place templates somewhere else."
  :type '(choice (const :tag "Derive from writing-schedule-directory" nil)
                 directory))

(defcustom writing-schedule-table-directory nil
  "Directory where the working table for each week is copied.
`writing-schedule-new-week-from-template' places this week's copy of
the chosen template here.  A subdirectory keeps these input tables
out of the way of the dated schedule files and the agenda.

When nil, it derives from `writing-schedule-directory' as a tables
subdirectory, computed each time it is used, so setting
`writing-schedule-directory' is enough.  Set this only to place the
working tables somewhere else."
  :type '(choice (const :tag "Derive from writing-schedule-directory" nil)
                 directory))

(defcustom writing-schedule-use-todo t
  "When non-nil, each generated event is a TODO headline.
This makes the schedule file double as a source of TODO items.
Set to nil for cleaner iCalendar summaries."
  :type 'boolean)

(defcustom writing-schedule-todo-keyword "TODO"
  "Keyword placed before each event when `writing-schedule-use-todo' is non-nil."
  :type 'string)

(defcustom writing-schedule-add-to-agenda t
  "When non-nil, add each generated dated file to `org-agenda-files'."
  :type 'boolean)

(defcustom writing-schedule-default-slots
  '(("Generative" "04:00-05:30" "05:45-07:15" "07:30-09:00")
    ("Rewriting"   "09:15-10:45" "11:30-13:00")
    ("Supporting"  "13:15-14:45" "15:00-16:30" "16:45-18:15" "20:30-22:00"))
  "Sections and time blocks used by `writing-schedule-insert-template'.
Each element is a list whose head is a section name and whose tail
is a list of time ranges written as HH:MM-HH:MM."
  :type '(alist :key-type string :value-type (repeat string)))

;;;; Low-level parsing helpers

(defconst writing-schedule--time-regexp
  "\\([0-9]\\{1,2\\}\\):[ \t]*\\([0-9]\\{2\\}\\)[ \t]*-+[ \t]*\\([0-9]\\{1,2\\}\\):[ \t]*\\([0-9]\\{2\\}\\)"
  "Match a start time and an end time inside a table label cell.
Whitespace after a colon is tolerated, so 16: 30 reads as 16:30.")

(defconst writing-schedule--day-alist
  '(("m" . 0) ("mo" . 0) ("mon" . 0)
    ("tu" . 1) ("tue" . 1)
    ("w" . 2) ("we" . 2) ("wed" . 2)
    ("th" . 3) ("thu" . 3)
    ("f" . 4) ("fr" . 4) ("fri" . 4)
    ("sa" . 5) ("sat" . 5)
    ("su" . 6) ("sun" . 6))
  "Map a lower-case day abbreviation to an offset from Monday.")

(defun writing-schedule--day-offset (cell)
  "Return the Monday offset for CELL when it names a day, else nil."
  (cdr (assoc (downcase (string-trim (or cell ""))) writing-schedule--day-alist)))

(defun writing-schedule--parse-time (cell)
  "Return (START . END) as HH:MM strings from CELL, or nil.
The returned strings are always zero padded to five characters."
  (when (and cell (string-match writing-schedule--time-regexp cell))
    (cons (format "%02d:%02d"
                  (string-to-number (match-string 1 cell))
                  (string-to-number (match-string 2 cell)))
          (format "%02d:%02d"
                  (string-to-number (match-string 3 cell))
                  (string-to-number (match-string 4 cell))))))

(defun writing-schedule--minutes (start end)
  "Return the number of minutes between START and END HH:MM strings."
  (let ((s (+ (* 60 (string-to-number (substring start 0 2)))
              (string-to-number (substring start 3 5))))
        (e (+ (* 60 (string-to-number (substring end 0 2)))
              (string-to-number (substring end 3 5)))))
    (- e s)))

(defun writing-schedule--parse (table)
  "Parse TABLE from `org-table-to-lisp' into a plist.
The plist keys are :events, :legend, :letters, and :columns.
An event is a plist with keys :section, :offset, :start, :end,
and :letter."
  (let ((columns nil)                   ; alist of (col-index . day-offset)
        (section nil)
        (events '())
        (legend '())
        (letters '()))
    (dolist (row table)
      (unless (eq row 'hline)
        (let* ((cells (mapcar (lambda (c) (string-trim (or c ""))) row))
               (label (car cells)))
          (cond
           ;; Header row.  It is the first row that names weekdays.
           ((and (null columns)
                 (cl-some #'writing-schedule--day-offset (cdr cells)))
            (let ((i 0))
              (dolist (c cells)
                (let ((off (writing-schedule--day-offset c)))
                  (when (and off (> i 0))
                    (push (cons i off) columns)))
                (setq i (1+ i))))
            (setq columns (nreverse columns)))
           ;; Legend row.  A short uppercase code (one letter, then up to
           ;; three more letters or digits), then a colon.  The match is
           ;; case-sensitive, so an uppercase code such as A, EM, or W2 is
           ;; a legend row, while a capitalized section header such as
           ;; Generative is not.
           ((let ((case-fold-search nil))
              (string-match "\\`\\([A-Z][A-Z0-9]\\{0,3\\}\\)[ \t]*:\\(.*\\)\\'" label))
            (let ((ltr (upcase (match-string 1 label)))
                  (desc (string-trim (match-string 2 label))))
              (when (string-empty-p desc)
                (setq desc (string-trim (mapconcat #'identity (cdr cells) " "))))
              (push (cons ltr desc) legend)))
           ;; Time-block row.
           ((and columns (writing-schedule--parse-time label))
            (let ((range (writing-schedule--parse-time label)))
              (dolist (col columns)
                (let ((cell (nth (car col) cells)))
                  (when (and cell (not (string-empty-p cell)))
                    (let ((ltr (upcase cell)))
                      (push (list :section (or section "Writing")
                                  :offset (cdr col)
                                  :start (car range)
                                  :end (cdr range)
                                  :letter ltr)
                            events)
                      (cl-pushnew ltr letters :test #'equal)))))))
           ;; Section header.  A word or words, no time, non-empty.
           ((and (not (string-empty-p label))
                 (string-match "\\`[A-Za-z][A-Za-z ]*:?\\'" label)
                 (not (writing-schedule--parse-time label)))
            (setq section (string-trim (replace-regexp-in-string ":" "" label))))
           (t nil)))))
    (list :events (nreverse events)
          :legend (nreverse legend)
          :letters (sort letters #'string<)
          :columns columns)))

;;;; Date helpers

(defun writing-schedule--week-monday (time)
  "Return the absolute calendar date of the Monday on or before TIME."
  (let* ((decoded (decode-time time))
         (greg (list (nth 4 decoded) (nth 3 decoded) (nth 5 decoded)))
         (abs (calendar-absolute-from-gregorian greg))
         (dow (calendar-day-of-week greg))) ; 0 is Sunday, 6 is Saturday
    (- abs (if (= dow 0) 6 (1- dow)))))

(defun writing-schedule--iso-date (abs)
  "Return the ISO date string, such as 2026-01-19, for absolute date ABS."
  (let ((greg (calendar-gregorian-from-absolute abs)))
    (format "%04d-%02d-%02d" (nth 2 greg) (nth 0 greg) (nth 1 greg))))

(defun writing-schedule-file-for-week (monday-abs)
  "Return the archival file path for the week beginning MONDAY-ABS.
The file lives in `writing-schedule-directory' and is named
according to `writing-schedule-file-format'."
  (expand-file-name (format writing-schedule-file-format
                            (writing-schedule--iso-date monday-abs))
                    writing-schedule-directory))

(defun writing-schedule--current-week-file ()
  "Return the archival file path for the current week."
  (writing-schedule-file-for-week
   (writing-schedule--week-monday (current-time))))

(defun writing-schedule--template-directory ()
  "Return the directory of saved templates.
Use `writing-schedule-template-directory' when it is non-nil, otherwise
derive a templates subdirectory from `writing-schedule-directory'.  The
value is computed here rather than at load time, so setting the base
directory works regardless of load order."
  (if writing-schedule-template-directory
      (expand-file-name writing-schedule-template-directory)
    (expand-file-name "templates" writing-schedule-directory)))

(defun writing-schedule--table-directory ()
  "Return the directory of working tables.
Use `writing-schedule-table-directory' when it is non-nil, otherwise
derive a tables subdirectory from `writing-schedule-directory'."
  (if writing-schedule-table-directory
      (expand-file-name writing-schedule-table-directory)
    (expand-file-name "tables" writing-schedule-directory)))

(defun writing-schedule-table-file-for-week (monday-abs)
  "Return the working table path for the week beginning MONDAY-ABS.
The file lives in the directory returned by
`writing-schedule--table-directory'."
  (expand-file-name (format "table-%s.org" (writing-schedule--iso-date monday-abs))
                    (writing-schedule--table-directory)))

(defun writing-schedule--timestamp (monday-abs offset start end)
  "Build an org active timestamp string for a block.
MONDAY-ABS is the absolute date of Monday.  OFFSET adds days.
START and END are HH:MM strings."
  (let* ((abs (+ monday-abs offset))
         (greg (calendar-gregorian-from-absolute abs))
         (dow (calendar-day-name greg t)))
    (format "<%s %s %s-%s>" (writing-schedule--iso-date abs) dow start end)))

;;;; Mapping and org generation

(defun writing-schedule--map-get (mapping ltr)
  "Return the mapping plist for LTR in MAPPING, or nil."
  (cl-find ltr mapping
           :key (lambda (m) (plist-get m :letter))
           :test #'equal))

(defun writing-schedule--read-mapping (letters legend)
  "Prompt for a project code and a description for each letter in LETTERS.
LEGEND supplies default descriptions.  Return a list of plists
with keys :letter, :code, and :desc."
  (mapcar
   (lambda (ltr)
     (let* ((default-desc (cdr (assoc ltr legend)))
            (code (read-string (format "Project code for %s: " ltr)))
            (desc (read-string (format "Description for %s: " ltr)
                               nil nil (or default-desc ""))))
       (list :letter ltr :code (string-trim code) :desc (string-trim desc))))
   letters))

(defun writing-schedule--build-org (events mapping monday-abs title)
  "Return the org file body as a string.
EVENTS is the parsed event list.  MAPPING assigns projects to
letters.  MONDAY-ABS anchors the week.  TITLE names the file."
  (let ((sections '())
        (out '()))
    ;; Preserve the order in which sections first appear.
    (dolist (ev events)
      (let ((s (plist-get ev :section)))
        (unless (member s sections) (push s sections))))
    (setq sections (nreverse sections))
    (push (format "#+TITLE: %s\n" title) out)
    (push "#+FILETAGS: :writing:\n" out)
    (push "#+LaTeX_HEADER: \\usepackage[margin=0.5in]{geometry}\n\n" out)
    (push "# Letter to project map:\n" out)
    (dolist (m mapping)
      (push (format "#   %s = %s%s\n"
                    (plist-get m :letter)
                    (plist-get m :code)
                    (let ((d (plist-get m :desc)))
                      (if (string-empty-p d) "" (format " (%s)" d))))
            out))
    (push "\n" out)
    (dolist (s sections)
      (push (format "* %s\n" s) out)
      (push (format "  :PROPERTIES:\n  :CATEGORY: %s\n  :END:\n" s) out)
      (dolist (ev events)
        (when (equal (plist-get ev :section) s)
          (let* ((ltr (plist-get ev :letter))
                 (m (writing-schedule--map-get mapping ltr))
                 (desc (or (and m (plist-get m :desc)) ""))
                 (code (or (and m (plist-get m :code)) ""))
                 (head (cond ((not (string-empty-p desc)) desc)
                             ((not (string-empty-p code)) code)
                             (t (format "Project %s" ltr))))
                 (ts (writing-schedule--timestamp
                      monday-abs (plist-get ev :offset)
                      (plist-get ev :start) (plist-get ev :end))))
            (push (format "** %s%s :%s:\n"
                          (if writing-schedule-use-todo
                              (concat writing-schedule-todo-keyword " ") "")
                          head ltr)
                  out)
            (unless (string-empty-p code)
              (push (format "   :PROPERTIES:\n   :WS_CODE: %s\n   :END:\n" code) out))
            (push (format "   %s\n" ts) out)))))
    (apply #'concat (nreverse out))))

(defun writing-schedule--summary (events mapping)
  "Return an org Summary section that totals weekly hours per letter.
The section carries no timestamp, so the iCalendar exporter skips it."
  (let ((totals (make-hash-table :test #'equal))
        (order '()))
    (dolist (ev events)
      (let ((ltr (plist-get ev :letter)))
        (unless (member ltr order) (push ltr order))
        (puthash ltr (+ (gethash ltr totals 0)
                        (writing-schedule--minutes
                         (plist-get ev :start) (plist-get ev :end)))
                 totals)))
    (setq order (sort order #'string<))
    (concat
     "\n* Summary\n"
     (mapconcat
      (lambda (ltr)
        (let* ((m (writing-schedule--map-get mapping ltr))
               (mins (gethash ltr totals 0))
               (label (cond ((and m (not (string-empty-p (plist-get m :desc))))
                             (plist-get m :desc))
                            ((and m (not (string-empty-p (plist-get m :code))))
                             (plist-get m :code))
                            (t (concat "Project " ltr)))))
          (format "- %s = %.2f h (%s)" ltr (/ mins 60.0) label)))
      order "\n")
     "\n")))

;;;; Agenda and iCalendar

(defun writing-schedule--ensure-agenda (file)
  "Add FILE to `org-agenda-files' when it is a plain list."
  (let ((file (expand-file-name file)))
    (if (listp org-agenda-files)
        (unless (member file (mapcar #'expand-file-name org-agenda-files))
          (add-to-list 'org-agenda-files file t))
      (message "org-agenda-files is not a plain list; add %s yourself" file))))

;;;###autoload
(defun writing-schedule-add-to-agenda (&optional file)
  "Add FILE to `org-agenda-files'.
With no argument, add the current week's dated file."
  (interactive)
  (writing-schedule--ensure-agenda (or file (writing-schedule--current-week-file))))

;;;###autoload
(defun writing-schedule-export-ics (&optional file)
  "Export FILE to an iCalendar file.
With no argument, export the current week's dated file.  The .ics
file is written beside the org file, so it is archived by week as
well.  Return the absolute path of the .ics file."
  (interactive)
  (require 'ox-icalendar)
  (let* ((file (expand-file-name (or file (writing-schedule--current-week-file))))
         (org-icalendar-include-todo nil)
         (org-icalendar-with-timestamps 'active)
         (org-icalendar-store-UID t))
    (with-current-buffer (find-file-noselect file)
      ;; `org-icalendar-export-to-ics' returns a name relative to this
      ;; buffer's directory.  Expand it here, where the default directory
      ;; is the directory of FILE, so the caller receives an absolute path.
      (let ((ics (expand-file-name (org-icalendar-export-to-ics))))
        (message "Exported %s" ics)
        ics))))

;;;; Interactive entry points

;;;###autoload
(defun writing-schedule-generate ()
  "Parse the schedule table at point and write the schedule org file.
Prompt for a project code and description for each letter, and for
the week to schedule."
  (interactive)
  (unless (org-at-table-p)
    (user-error "Point is not in an org table.  Move into your schedule table first"))
  (let* ((table (org-table-to-lisp))
         (parsed (writing-schedule--parse table))
         (events (plist-get parsed :events))
         (letters (plist-get parsed :letters))
         (legend (plist-get parsed :legend)))
    (unless events
      (user-error "No filled time blocks found in this table"))
    (let* ((mapping (writing-schedule--read-mapping letters legend))
           (monday (writing-schedule--week-monday
                    (org-read-date nil t nil "Week to schedule (any day in it): ")))
           (title (format "Writing Schedule (week of %s)"
                          (writing-schedule--iso-date monday)))
           (body (concat (writing-schedule--build-org events mapping monday title)
                         (writing-schedule--summary events mapping)))
           (default-file (writing-schedule-file-for-week monday))
           (file (progn
                   ;; Make sure the archive directory exists before the
                   ;; prompt, so completion works and the write succeeds.
                   (make-directory (file-name-directory default-file) t)
                   (read-file-name "Write schedule to: "
                                   (file-name-directory default-file)
                                   default-file nil
                                   (file-name-nondirectory default-file)))))
      (with-temp-file file (insert body))
      (when writing-schedule-add-to-agenda
        (writing-schedule--ensure-agenda file))
      (when (y-or-n-p "Export this schedule to an .ics file now? ")
        (writing-schedule-export-ics file))
      (find-file file)
      (message "Wrote %d events to %s" (length events) file))))

(defun writing-schedule--blank-row (label nd)
  "Return a table row with LABEL and ND empty day cells."
  (concat "| " label " |"
          (mapconcat (lambda (_) "  |") (make-list nd t) "")
          "\n"))

(defconst writing-schedule--project-letters
  '("A" "B" "C" "D" "E" "F" "G" "H" "I" "J" "K" "L" "M"
    "N" "O" "P" "Q" "R" "S" "T" "U" "V" "W" "X" "Y" "Z")
  "Default single-letter project codes for a scaffolded template.")

(defun writing-schedule--template-string (n)
  "Return a blank weekly schedule template for N projects (1 to 26).
The scaffold uses single-letter codes.  For task codes of your own, such
as EM or EX, edit the legend rows and the day cells to use them, because
any short uppercase code is accepted."
  (setq n (max 1 (min (length writing-schedule--project-letters)
                      (if (stringp n) (string-to-number n) n))))
  (let* ((days '("M" "Tu" "W" "Th" "F" "Sa"))
         (nd (length days))
         (letters (seq-take writing-schedule--project-letters n)))
    (concat
     (format "#+TITLE: Writing Schedule for %d Project%s\n\n" n (if (= n 1) "" "s"))
     "| Time <l> | " (mapconcat #'identity days " | ") " |\n"
     "|-\n"
     (mapconcat
      (lambda (sec)
        (concat (writing-schedule--blank-row (concat (car sec) ":") nd)
                (mapconcat (lambda (slot) (writing-schedule--blank-row slot nd))
                           (cdr sec) "")
                "|-\n"))
      writing-schedule-default-slots "")
     (mapconcat (lambda (ltr) (writing-schedule--blank-row (concat ltr ":") nd))
                letters "")
     "|-\n")))

(defun writing-schedule--table-title ()
  "Return the buffer's \"#+TITLE:\" value, or nil when absent or empty."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^#\\+TITLE:[ \t]*\\(.*\\)$" nil t)
      (let ((found (string-trim (match-string 1))))
        (unless (string-empty-p found) found)))))

(defun writing-schedule--template-dest (name)
  "Return the destination path in the template directory for NAME.
NAME may omit the .org extension."
  (expand-file-name (if (string-suffix-p ".org" name) name (concat name ".org"))
                    (writing-schedule--template-directory)))

(defun writing-schedule--write-template (dest table title)
  "Write TABLE with TITLE to DEST, creating the directory as needed.
Return DEST."
  (make-directory (file-name-directory dest) t)
  (with-temp-file dest
    (insert (format "#+TITLE: %s\n\n" title))
    (insert table)
    (unless (bolp) (insert "\n")))
  dest)

;;;###autoload
(defun writing-schedule-insert-template (n)
  "Insert a blank weekly schedule table for N projects (1 to 26).
The scaffold uses single-letter codes.  You can rename the legend rows
and use your own short uppercase codes, such as EM or EX, in the cells."
  (interactive "nNumber of writing projects (1-26): ")
  (let ((start (point)))
    (insert (writing-schedule--template-string n))
    (goto-char start)
    (forward-line 2)
    (when (org-at-table-p) (org-table-align))))

;;;; Browsing the archive

(defun writing-schedule--week-file-regexp ()
  "Return a regexp matching an archived weekly file name.
Group 1 captures the ISO date.  The regexp is derived from
`writing-schedule-file-format' so it follows any custom naming."
  (let ((idx (string-match "%s" writing-schedule-file-format)))
    (if idx
        (concat "\\`"
                (regexp-quote (substring writing-schedule-file-format 0 idx))
                "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)"
                (regexp-quote (substring writing-schedule-file-format (+ idx 2)))
                "\\'")
      "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)")))

(defun writing-schedule--archived-weeks ()
  "Return archived weeks as a list of (ISO-DATE . PATH), newest first.
ISO dates sort lexically, so a plain descending string sort orders
the weeks from most to least recent."
  (let ((dir (expand-file-name writing-schedule-directory))
        (regexp (writing-schedule--week-file-regexp))
        (weeks '()))
    (when (file-directory-p dir)
      (dolist (name (directory-files dir nil nil t))
        (when (string-match regexp name)
          (push (cons (match-string 1 name) (expand-file-name name dir)) weeks))))
    (sort weeks (lambda (a b) (string> (car a) (car b))))))

(defun writing-schedule--ordered-table (candidates)
  "Return a completion table over CANDIDATES that keeps their order.
Without this, most completion interfaces would re-sort the weeks and
lose the newest-first ordering."
  (lambda (string pred action)
    (if (eq action 'metadata)
        '(metadata (display-sort-function . identity)
                   (cycle-sort-function . identity))
      (complete-with-action action candidates string pred))))

;;;###autoload
(defun writing-schedule-open-recent ()
  "Open the most recent archived weekly file."
  (interactive)
  (let ((weeks (writing-schedule--archived-weeks)))
    (unless weeks
      (user-error "No archived weeks found in %s" writing-schedule-directory))
    (find-file (cdr (car weeks)))))

;;;###autoload
(defun writing-schedule-open-week (&optional pick-date)
  "Open an archived weekly file.
By default, choose from the archived weeks with completion, listed
newest first.  With a prefix argument PICK-DATE, or when nothing is
archived yet, prompt for a date instead and open the file for the
week that contains it."
  (interactive "P")
  (let ((weeks (writing-schedule--archived-weeks)))
    (if (or pick-date (null weeks))
        (let* ((monday (writing-schedule--week-monday
                        (org-read-date nil t nil
                                       "Open the week containing (any day): ")))
               (file (writing-schedule-file-for-week monday)))
          (unless (file-exists-p file)
            (user-error "No schedule archived for the week of %s"
                        (writing-schedule--iso-date monday)))
          (find-file file))
      (let* ((choice (completing-read "Open week (newest first): "
                                      (writing-schedule--ordered-table
                                       (mapcar #'car weeks))
                                      nil t))
             (path (cdr (assoc choice weeks))))
        (find-file path)))))

;;;###autoload
(defun writing-schedule-new-week-from-template ()
  "Start the current week from a saved context template.
Choose a template from `writing-schedule-template-directory', copy it
to this week's working table file in `writing-schedule-table-directory',
open that copy, and place point in the table so you can run
`writing-schedule-generate' right away.  This turns the weekly job of
placing the letters into a one-time choice per context, for example a
teaching week, a meeting week, or a writing retreat."
  (interactive)
  (let* ((tdir (writing-schedule--template-directory))
         (templates (and (file-directory-p tdir)
                         (directory-files tdir nil "\\.org\\'" t))))
    (unless templates
      (user-error "No templates found in %s.  Add filled table files there first"
                  tdir))
    (let* ((choice (completing-read "Start this week from template: "
                                    (sort templates #'string<) nil t))
           (source (expand-file-name choice tdir))
           (monday (writing-schedule--week-monday (current-time)))
           (dest (writing-schedule-table-file-for-week monday))
           (overwrite (or (not (file-exists-p dest))
                          (y-or-n-p
                           (format "A table for the week of %s exists.  Overwrite it? "
                                   (writing-schedule--iso-date monday)))))
           buffer)
      (make-directory (file-name-directory dest) t)
      (when overwrite (copy-file source dest t))
      (setq buffer (find-file dest))
      ;; Land on the first table line, ready to generate.
      (goto-char (point-min))
      (when (re-search-forward "^[ \t]*|" nil t)
        (forward-line 0))
      (if overwrite
          (message "Copied %s to %s.  Adjust the letters, then run writing-schedule-generate."
                   choice (file-name-nondirectory dest))
        (message "Kept the existing table %s.  Run writing-schedule-generate when ready."
                 (file-name-nondirectory dest)))
      buffer)))

;;;###autoload
(defun writing-schedule-generate-from-template ()
  "Select a saved table and generate a week's schedule from it.
Choose one of the tables in the template directory, meaning your library
of recurring-week tables, then generate the dated schedule of events for
the org agenda.  The table is loaded into a buffer and
`writing-schedule-generate' runs on it, so you are prompted for the
project mapping and the week as usual.  The saved table is not modified,
because the schedule is written to a separate dated file.

Use this when a saved table already matches the coming week.  Use
`writing-schedule-new-week-from-template' instead when you want to copy a
table and adjust a few letters before generating."
  (interactive)
  (let* ((tdir (writing-schedule--template-directory))
         (tables (and (file-directory-p tdir)
                      (directory-files tdir nil "\\.org\\'" t))))
    (unless tables
      (user-error "No tables found in %s.  Add filled tables there first" tdir))
    (let* ((choice (completing-read "Generate from table: "
                                    (sort tables #'string<) nil t))
           (source (expand-file-name choice tdir))
           (buffer (get-buffer-create (format "*writing-schedule: %s*" choice))))
      (with-current-buffer buffer
        (erase-buffer)
        (insert-file-contents source)
        (org-mode)
        (goto-char (point-min))
        (unless (re-search-forward "^[ \t]*|" nil t)
          (user-error "No org table found in %s" choice))
        (forward-line 0)
        (writing-schedule-generate)))))

;;;###autoload
(defun writing-schedule-save-template-table (&optional name)
  "Save the org table at point as a template named NAME.
Write it to the template directory, so you can later choose it with
`writing-schedule-generate-from-template' or
`writing-schedule-new-week-from-template'.  Use this to keep a table you
have customized for a particular kind of week.  An existing
\"#+TITLE:\" line in the buffer is preserved, otherwise the title is
taken from NAME.  Put the project description in the first column of each
legend row, for example a row whose first cell is \"A: my project\"."
  (interactive)
  (unless (org-at-table-p)
    (user-error "Point is not in an org table.  Move into the table to save it"))
  (let ((name (string-trim (or name (read-string "Save table as template named: ")))))
    (when (string-empty-p name)
      (user-error "A template name is required"))
    (let* ((dest (writing-schedule--template-dest name))
           (table (buffer-substring-no-properties (org-table-begin) (org-table-end)))
           (title (or (writing-schedule--table-title) (file-name-base dest))))
      (when (and (file-exists-p dest)
                 (not (y-or-n-p (format "Template %s exists.  Overwrite it? "
                                        (file-name-nondirectory dest)))))
        (user-error "Not saved"))
      (writing-schedule--write-template dest table title)
      (message "Saved table to %s" dest)
      dest)))

;;;; Batch use from the command line

(defun writing-schedule--legend-mapping (letters legend)
  "Build a non-interactive mapping for LETTERS from LEGEND.
Each entry has an empty code and a description taken from the legend,
so batch generation needs no prompts."
  (mapcar (lambda (ltr)
            (list :letter ltr :code ""
                  :desc (or (cdr (assoc ltr legend)) "")))
          letters))

;;;###autoload
(defun writing-schedule-batch-list-templates (&optional directory)
  "Print available templates to standard output, one per line.
DIRECTORY defaults to the directory returned by
`writing-schedule--template-directory'.  This is meant to be called from
a shell through emacs --batch, so that people who do not use Emacs can
still see which schedules are available.  Return the template file names."
  (let* ((dir (expand-file-name (or directory (writing-schedule--template-directory))))
         (files (and (file-directory-p dir)
                     (sort (directory-files dir nil "\\.org\\'" t) #'string<))))
    (if files
        (dolist (f files) (princ (format "%s\n" f)))
      (princ (format "No templates found in %s\n" dir)))
    files))

;;;###autoload
(defun writing-schedule-batch-generate (table week &optional out-dir)
  "Generate a dated schedule and an iCalendar file from TABLE for WEEK.
TABLE is a path to an org file that holds a filled schedule table.
WEEK is any date inside the target week as an ISO string, and it snaps
to the Monday.  OUT-DIR, when given, overrides `writing-schedule-directory'.
Letters are mapped to projects from the table's legend rows, so no
prompts are needed.  Print the paths written and return the .ics path.
Meant to be called from a shell through emacs --batch."
  (require 'ox-icalendar)
  (let ((table (expand-file-name table)))
    (unless (file-readable-p table)
      (error "Cannot read table file: %s" table))
    (when out-dir
      (setq writing-schedule-directory (expand-file-name out-dir)))
    (with-temp-buffer
      (insert-file-contents table)
      (org-mode)
      (goto-char (point-min))
      (unless (re-search-forward "^[ \t]*|" nil t)
        (error "No org table found in %s" table))
      (let* ((parsed (writing-schedule--parse (org-table-to-lisp)))
             (events (plist-get parsed :events)))
        (unless events
          (error "No filled time blocks found in %s" table))
        (let* ((mapping (writing-schedule--legend-mapping
                         (plist-get parsed :letters)
                         (plist-get parsed :legend)))
               (monday (writing-schedule--week-monday (org-read-date nil t week)))
               (title (format "Writing Schedule (week of %s)"
                              (writing-schedule--iso-date monday)))
               (body (concat (writing-schedule--build-org events mapping monday title)
                             (writing-schedule--summary events mapping)))
               (org-file (writing-schedule-file-for-week monday)))
          (make-directory (file-name-directory org-file) t)
          (with-temp-file org-file (insert body))
          (let ((ics (writing-schedule-export-ics org-file)))
            (princ (format "Wrote schedule:  %s\n" org-file))
            (princ (format "Wrote iCalendar: %s\n" ics))
            ics))))))

;;;###autoload
(defun writing-schedule-batch-insert-template (n &optional file)
  "Write or print a blank template for N projects.
When FILE is non-empty, write the template there, otherwise print it to
standard output.  Return the template text or the destination path.
Meant to be called from a shell through emacs --batch."
  (let ((text (writing-schedule--template-string n)))
    (if (and file (not (string-empty-p file)))
        (let ((dest (expand-file-name file)))
          (make-directory (file-name-directory dest) t)
          (with-temp-file dest (insert text))
          (princ (format "Wrote template to %s\n" dest))
          dest)
      (princ text)
      text)))

;;;###autoload
(defun writing-schedule-batch-list-weeks (&optional directory)
  "Print archived weekly files to standard output, newest first.
DIRECTORY overrides `writing-schedule-directory'.  Return the list of
file names.  Meant to be called from a shell through emacs --batch."
  (let* ((writing-schedule-directory
          (if (and directory (not (string-empty-p directory)))
              (expand-file-name directory)
            writing-schedule-directory))
         (weeks (writing-schedule--archived-weeks)))
    (if weeks
        (dolist (w weeks) (princ (format "%s\n" (file-name-nondirectory (cdr w)))))
      (princ (format "No archived weeks in %s\n"
                     (expand-file-name writing-schedule-directory))))
    (mapcar (lambda (w) (file-name-nondirectory (cdr w))) weeks)))

;;;###autoload
(defun writing-schedule-batch-save-template (table-file name)
  "Save the table in TABLE-FILE as a template named NAME.
Write it into the template directory, wrapping it with the file's title
or NAME, and overwrite silently.  Return the destination path.  Meant to
be called from a shell through emacs --batch."
  (let ((table-file (expand-file-name table-file))
        (name (string-trim name)))
    (unless (file-readable-p table-file)
      (error "Cannot read table file: %s" table-file))
    (when (string-empty-p name)
      (error "A template name is required"))
    (with-temp-buffer
      (insert-file-contents table-file)
      (org-mode)
      (goto-char (point-min))
      (unless (re-search-forward "^[ \t]*|" nil t)
        (error "No org table found in %s" table-file))
      (forward-line 0)
      (let* ((dest (writing-schedule--template-dest name))
             (table (buffer-substring-no-properties (org-table-begin) (org-table-end)))
             (title (or (writing-schedule--table-title) (file-name-base dest))))
        (writing-schedule--write-template dest table title)
        (princ (format "Saved template to %s\n" dest))
        dest))))

;;;; Printable time-block sheets

(defcustom writing-schedule-timeblock-start-hour 4
  "First hour shown on a printable time-block sheet."
  :type 'integer)

(defcustom writing-schedule-timeblock-end-hour 23
  "Last hour shown on a printable time-block sheet."
  :type 'integer)

(defcustom writing-schedule-timeblock-columns 4
  "Number of plan columns on a printable time-block sheet.
The first column holds the planned blocks.  The rest are left blank, so
you can write a revised plan in the next column each time the day
changes, which is what gives the sheet its flexibility."
  :type 'integer)

(defcustom writing-schedule-timeblock-subrows 5
  "Number of writing rows per hour on a printable time-block sheet."
  :type 'integer)

(defcustom writing-schedule-latex-compiler "pdflatex"
  "Program used to compile a time-block sheet to PDF."
  :type 'string)

(defcustom writing-schedule-sheets-directory nil
  "Directory for generated time-block sheets.
When nil, derive a \"sheets\" subdirectory of `writing-schedule-directory'."
  :type '(choice (const :tag "Derive from writing-schedule-directory" nil)
                 directory))

(defcustom writing-schedule-code-descriptions nil
  "Alist that maps a project code to a description for the sheet key.
Each element is a cons cell of a code string and a description string,
for example (\"A\" . \"DNPH1 docking\").  These descriptions fill the key
across the top of a sheet, and the Task column of the org export, for
codes that the table legend does not already describe.  A description in
the table legend takes precedence, because it is specific to that week.
Set this to keep a standing dictionary of your project codes, so the key
is labeled even when a table carries bare codes without legend rows."
  :type '(alist :key-type string :value-type string))

(defun writing-schedule--sheets-directory ()
  "Return the directory for generated time-block sheets."
  (if writing-schedule-sheets-directory
      (expand-file-name writing-schedule-sheets-directory)
    (expand-file-name "sheets" writing-schedule-directory)))

(defun writing-schedule--latex-escape (s)
  "Escape LaTeX special characters in string S."
  (let ((s (or s "")))
    (dolist (pair '(("\\\\" . "\\\\textbackslash{}")
                    ("&" . "\\\\&") ("%" . "\\\\%") ("\\$" . "\\\\$")
                    ("#" . "\\\\#") ("_" . "\\\\_") ("{" . "\\\\{")
                    ("}" . "\\\\}") ("~" . "\\\\textasciitilde{}")
                    ("\\^" . "\\\\textasciicircum{}")) s)
      (setq s (replace-regexp-in-string (car pair) (cdr pair) s t)))))

(defun writing-schedule--hhmm-tidy (s)
  "Drop a leading zero on the hour of an HH:MM string S."
  (replace-regexp-in-string "\\`0" "" (or s "")))

(defun writing-schedule--timeblock-colspec (n)
  "Return a tabular spec with a narrow time column and N plan columns."
  (concat "|m{1cm}" (mapconcat (lambda (_) ":m{4cm}") (make-list n t) "") "|"))

(defun writing-schedule--effective-legend (legend)
  "Merge `writing-schedule-code-descriptions' into LEGEND.
Entries in LEGEND take precedence, because they are specific to the week,
and the custom descriptions fill in any codes the legend omits."
  (append legend
          (seq-remove (lambda (pair) (assoc (car pair) legend))
                      writing-schedule-code-descriptions)))

(defun writing-schedule--timeblock-key (letters legend)
  "Return the code key line for LETTERS using LEGEND descriptions."
  (mapconcat
   (lambda (ltr)
     (let ((desc (cdr (assoc ltr legend))))
       (if (and desc (not (string-empty-p desc)))
           (format "%s = %s" ltr (writing-schedule--latex-escape desc))
         ltr)))
   letters ",\\quad "))

(defun writing-schedule--timeblock-spans (events)
  "Return block spans (START-ROW END-ROW LABEL) for EVENTS.
A row index is HOUR times the sub-row count plus the sub-row.  START-ROW
comes from the block start, END-ROW from the block end, so the span
covers the whole time range."
  (let ((sub writing-schedule-timeblock-subrows)
        (spans '()))
    (dolist (ev events)
      (let* ((sp (split-string (plist-get ev :start) ":"))
             (ep (split-string (plist-get ev :end) ":"))
             (sh (string-to-number (car sp)))
             (sm (string-to-number (cadr sp)))
             (eh (string-to-number (car ep)))
             (em (string-to-number (cadr ep)))
             (sg (+ (* sh sub) (min (1- sub) (/ (* sm sub) 60))))
             (eg (+ (* eh sub) (min sub (/ (* em sub) 60))))
             (label (format "%s\\quad %s-%s"
                            (plist-get ev :letter)
                            (writing-schedule--hhmm-tidy (plist-get ev :start))
                            (writing-schedule--hhmm-tidy (plist-get ev :end)))))
        (when (<= eg sg) (setq eg (1+ sg)))
        (push (list sg eg label) spans)))
    spans))

(defun writing-schedule--timeblock-row (timecol data1 ncols)
  "Return a table row of TIMECOL, DATA1, and blank cells filling NCOLS columns."
  (concat (mapconcat #'identity
                     (cons timecol (cons data1 (make-list (1- ncols) "")))
                     " & ")
          " \\\\"))

(defun writing-schedule--timeblock-preamble ()
  "Return the LaTeX preamble for a time-block sheet."
  (concat "\\documentclass{article}\n"
          "\\usepackage{array}\n"
          "\\usepackage{arydshln}\n"
          "\\usepackage{helvet}\n"
          "\\renewcommand{\\familydefault}{\\sfdefault}\n"
          "\\usepackage[margin=0.5in]{geometry}\n"
          "\\usepackage{booktabs}\n"
          "\\renewcommand{\\arraystretch}{0.8}\n"
          "\\setlength{\\aboverulesep}{0pt}\n"
          "\\setlength{\\belowrulesep}{0pt}\n"
          "\\setlength{\\cmidrulewidth}{1pt}\n"))

(defun writing-schedule--timeblock-page (date-str key-str spans lo hi ncols)
  "Return one page of a sheet for hours LO to HI.
DATE-STR heads the page, KEY-STR is the code key, and SPANS draws each
planned block as an outlined box with heavy rules in the first plan
column.  A block that reaches the page edge is left open there, so a box
that crosses the page break reads as one block."
  (let ((sub writing-schedule-timeblock-subrows)
        (lines '()))
    (dolist (h (number-sequence lo hi))
      (dotimes (sr sub)
        (let* ((g (+ (* h sub) sr))
               (inside (cl-find-if (lambda (s) (and (<= (nth 0 s) g) (< g (nth 1 s)))) spans))
               (starts (cl-find-if (lambda (s) (= (nth 0 s) g)) spans))
               (ends-after (cl-find-if (lambda (s) (= (nth 1 s) (1+ g))) spans))
               (timecol (if (= sr 0) (format "%d:00" h) ""))
               (label (if starts (nth 2 starts) ""))
               (cell (if inside
                         (format (concat "\\multicolumn{1}{!{\\vrule width 1pt}"
                                         "m{4cm}!{\\vrule width 1pt}}{%s}")
                                 label)
                       label)))
          (when starts (push "\\cmidrule[1pt]{2-2}" lines))
          (push (concat (mapconcat #'identity
                                   (cons timecol (cons cell (make-list (1- ncols) "")))
                                   " & ")
                        " \\\\")
                lines)
          (when ends-after (push "\\cmidrule[1pt]{2-2}" lines))))
      (push "\\midrule" lines))
    (setq lines (cdr lines))            ; drop the trailing midrule
    (concat "{\\small\\noindent\\textbf{Key:}\\quad " key-str "}\n\n"
            "\\begin{center}\n\\begin{tabular}{"
            (writing-schedule--timeblock-colspec ncols) "}\n"
            "\\toprule\n"
            "\\multicolumn{" (number-to-string (1+ ncols)) "}{|l|}{Date: "
            date-str "} \\\\\n\\midrule\n"
            (writing-schedule--timeblock-row "" "" ncols) "\n"
            (writing-schedule--timeblock-row "" "" ncols) "\n\\midrule\n"
            (mapconcat #'identity (nreverse lines) "\n") "\n"
            "\\bottomrule\n\\end{tabular}\n\\end{center}\n")))

(defun writing-schedule--timeblock-day (date-str key-str spans)
  "Return the two pages of a sheet for DATE-STR, KEY-STR, and SPANS."
  (let* ((lo writing-schedule-timeblock-start-hour)
         (hi writing-schedule-timeblock-end-hour)
         (ncols writing-schedule-timeblock-columns)
         (total (1+ (- hi lo)))
         (mid (+ lo (/ (1+ total) 2) -1)))
    (concat (writing-schedule--timeblock-page date-str key-str spans lo mid ncols)
            "\n\\newpage\n"
            (writing-schedule--timeblock-page date-str key-str spans
                                              (1+ mid) hi ncols))))

(defun writing-schedule--timeblock-document (key-str days)
  "Return a full LaTeX document from KEY-STR and DAYS.
DAYS is a list of (DATE-STR . SPANS)."
  (concat (writing-schedule--timeblock-preamble)
          "\n\\begin{document}\n\n"
          (mapconcat (lambda (day)
                       (writing-schedule--timeblock-day (car day) key-str (cdr day)))
                     days "\n\\clearpage\n")
          "\n\\end{document}\n"))

(defun writing-schedule--timeblock-days (parsed monday-abs)
  "Return (KEY-STR . DAYS) for PARSED starting at MONDAY-ABS.
DAYS is a list of (DATE-STR . CELLS), one per day column in the table."
  (let* ((events (plist-get parsed :events))
         (columns (plist-get parsed :columns))
         (key (writing-schedule--timeblock-key
               (plist-get parsed :letters)
               (writing-schedule--effective-legend (plist-get parsed :legend))))
         (offsets (sort (delete-dups (mapcar #'cdr columns)) #'<))
         (days '()))
    (dolist (off offsets)
      (let* ((day-events (seq-filter (lambda (e) (= (plist-get e :offset) off)) events))
             (abs (+ monday-abs off))
             (greg (calendar-gregorian-from-absolute abs))
             (date-str (format "%s (%s)" (writing-schedule--iso-date abs)
                               (calendar-day-name greg))))
        (push (cons date-str (writing-schedule--timeblock-spans day-events)) days)))
    (cons key (nreverse days))))

(defun writing-schedule--timeblock-org-document (parsed monday)
  "Return an editable org document of the week's blocks for PARSED and MONDAY.
Each day is a section with a table of Time, Code, Task, and a blank
Revision column, so you can edit the events and export the schedule to
HTML or other formats."
  (let* ((events (plist-get parsed :events))
         (columns (plist-get parsed :columns))
         (letters (plist-get parsed :letters))
         (legend (writing-schedule--effective-legend (plist-get parsed :legend)))
         (offsets (sort (delete-dups (mapcar #'cdr columns)) #'<)))
    (concat
     (format "#+TITLE: Time-Block Sheets, week of %s\n"
             (writing-schedule--iso-date monday))
     "#+LaTeX_HEADER: \\usepackage[margin=0.5in]{geometry}\n"
     "#+OPTIONS: toc:nil\n\n"
     "* Key\n"
     (mapconcat
      (lambda (l)
        (let ((d (cdr (assoc l legend))))
          (format "- =%s=%s" l
                  (if (and d (not (string-empty-p d))) (format " :: %s" d) ""))))
      letters "\n")
     "\n\n"
     (mapconcat
      (lambda (off)
        (let* ((abs (+ monday off))
               (greg (calendar-gregorian-from-absolute abs))
               (date-str (format "%s (%s)" (writing-schedule--iso-date abs)
                                 (calendar-day-name greg)))
               (day-events
                (sort (seq-filter (lambda (e) (= (plist-get e :offset) off)) events)
                      (lambda (a b) (string< (plist-get a :start) (plist-get b :start))))))
          (concat
           (format "* %s\n" date-str)
           (format "#+CAPTION: Planned time blocks for %s.\n" date-str)
           "#+ATTR_LATEX: :booktabs t\n"
           "| Time | Code | Task | Revision |\n|-\n"
           (if day-events
               (mapconcat
                (lambda (e)
                  (format "| %s-%s | %s | %s | |"
                          (writing-schedule--hhmm-tidy (plist-get e :start))
                          (writing-schedule--hhmm-tidy (plist-get e :end))
                          (plist-get e :letter)
                          (or (cdr (assoc (plist-get e :letter) legend)) "")))
                day-events "\n")
             "| | | | |")
           "\n")))
      offsets "\n"))))

(defun writing-schedule--write-and-compile (tex-file content)
  "Write CONTENT to TEX-FILE and compile it to PDF when a compiler exists.
Return TEX-FILE."
  (with-temp-file tex-file (insert content))
  (let ((compiler (executable-find writing-schedule-latex-compiler)))
    (if (not compiler)
        (message "Wrote %s.  Install %s to make the PDF"
                 tex-file writing-schedule-latex-compiler)
      (let ((default-directory (file-name-directory tex-file)))
        (call-process compiler nil nil nil "-interaction=nonstopmode"
                      "-halt-on-error" (file-name-nondirectory tex-file)))))
  tex-file)

(defun writing-schedule--timeblock-generate (parsed monday per-day dir format)
  "Write time-block sheets for PARSED and MONDAY into DIR.
PER-DAY writes one PDF per day, else one PDF for the week.  FORMAT is one
of the symbols pdf, org, or both.  The org file is always a single week
file.  Return the list of files written."
  (let ((written '())
        (stamp (writing-schedule--iso-date monday)))
    (unless (delete-dups (mapcar #'cdr (plist-get parsed :columns)))
      (error "No day columns found in the table"))
    (make-directory dir t)
    (when (memq format '(pdf both))
      (let* ((kd (writing-schedule--timeblock-days parsed monday))
             (key (car kd))
             (days (cdr kd)))
        (if per-day
            (dolist (day days)
              (let* ((date (car (split-string (car day) " ")))
                     (tex (expand-file-name (format "sheet-%s.tex" date) dir)))
                (writing-schedule--write-and-compile
                 tex (writing-schedule--timeblock-document key (list day)))
                (push tex written)))
          (let ((tex (expand-file-name (format "sheets-week-%s.tex" stamp) dir)))
            (writing-schedule--write-and-compile
             tex (writing-schedule--timeblock-document key days))
            (push tex written)))))
    (when (memq format '(org both))
      (let ((org (expand-file-name (format "sheets-week-%s.org" stamp) dir)))
        (with-temp-file org
          (insert (writing-schedule--timeblock-org-document parsed monday)))
        (push org written)))
    (nreverse written)))

;;;###autoload
(defun writing-schedule-timeblock-sheets (&optional per-day)
  "Generate printable time-block sheets from the table at point.
Each day becomes a two-page sheet with the planned blocks drawn as
outlined boxes in the first plan column, the code key across the top, and
the remaining columns blank.  As the day changes, you write a revised
plan in the next column, which gives the schedule flexibility and
antifragility.  With a prefix argument, or PER-DAY non-nil, write one PDF
per day.  Otherwise write one PDF for the week.  You also choose the
output, meaning the PDF, an editable org file, or both.  PDFs compile
when a LaTeX compiler is available."
  (interactive "P")
  (unless (org-at-table-p)
    (user-error "Point is not in an org table.  Move into your schedule table first"))
  (let* ((parsed (writing-schedule--parse (org-table-to-lisp)))
         (format (intern (completing-read "Output (pdf, org, both): "
                                          '("pdf" "org" "both") nil t nil nil "both")))
         (monday (writing-schedule--week-monday
                  (org-read-date nil t nil "Week for the sheets (any day in it): ")))
         (files (writing-schedule--timeblock-generate
                 parsed monday per-day (writing-schedule--sheets-directory) format)))
    (message "Wrote %d sheet file%s to %s" (length files)
             (if (= (length files) 1) "" "s") (writing-schedule--sheets-directory))
    files))

;;;###autoload
(defun writing-schedule-batch-timeblock-sheets (table week &optional per-day out-dir format)
  "Generate time-block sheets from TABLE for WEEK.
Non-nil PER-DAY writes one PDF per day, else one for the week.  OUT-DIR
overrides the sheets directory.  FORMAT is the string \"pdf\", \"org\",
or \"both\", and defaults to both.  Print the files written and return
them.  Meant to be called from a shell through emacs --batch."
  (let ((table (expand-file-name table)))
    (unless (file-readable-p table)
      (error "Cannot read table file: %s" table))
    (with-temp-buffer
      (insert-file-contents table)
      (org-mode)
      (goto-char (point-min))
      (unless (re-search-forward "^[ \t]*|" nil t)
        (error "No org table found in %s" table))
      (let* ((parsed (writing-schedule--parse (org-table-to-lisp)))
             (monday (writing-schedule--week-monday (org-read-date nil t week)))
             (dir (if (and out-dir (not (string-empty-p out-dir)))
                      (expand-file-name out-dir)
                    (writing-schedule--sheets-directory)))
             (fmt (if (and format (not (string-empty-p format)))
                      (intern format)
                    'both))
             (files (writing-schedule--timeblock-generate parsed monday per-day dir fmt)))
        (dolist (f files) (princ (format "Wrote %s\n" f)))
        files))))

;;;; Suggested key map

;;;###autoload (autoload 'writing-schedule-command-map "writing-schedule" nil t 'keymap)
(defvar writing-schedule-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "g" #'writing-schedule-generate)
    (define-key map "t" #'writing-schedule-insert-template)
    (define-key map "n" #'writing-schedule-new-week-from-template)
    (define-key map "f" #'writing-schedule-generate-from-template)
    (define-key map "s" #'writing-schedule-save-template-table)
    (define-key map "b" #'writing-schedule-timeblock-sheets)
    (define-key map "o" #'writing-schedule-open-week)
    (define-key map "r" #'writing-schedule-open-recent)
    (define-key map "e" #'writing-schedule-export-ics)
    (define-key map "a" #'writing-schedule-add-to-agenda)
    map)
  "Keymap of writing-schedule commands.
Bind it to a prefix of your choice.  For example, when C-c w is your
writing prefix, the following places the commands under C-c w c:

  (keymap-set my-writing-prefix \"c\" writing-schedule-command-map)

The keys are g generate, t template, n new week from template,
f generate from a saved table, s save table as template, b time-block
sheets, o open week, r open recent, e export ics, and a add to agenda.")

(provide 'writing-schedule)
;;; writing-schedule.el ends here
