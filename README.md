# writing-schedule.el

Turn a weekly writing-block table into org agenda events and an iCalendar
file you can import into Outlook Web or any calendar application.

![Emacs](https://img.shields.io/badge/Emacs-27.1%2B-7F5AB6)
![Tests](https://img.shields.io/badge/tests-66%20passing-brightgreen)
![Coverage](https://img.shields.io/badge/coverage-100%25-brightgreen)
![License](https://img.shields.io/badge/license-GPL--3.0-blue)

You keep a weekly plan as an org table. Each row is a time block, each
column after the first is a day, and each filled cell holds a letter (A,
B, C, or D) that names the project worked on during that block. This
package reads that table and writes a schedule file of dated events.
Those events feed the org agenda, and org's own iCalendar exporter turns
them into a file that Outlook Web or any calendar application can import.

The table is a seating chart. You decide who sits where, meaning which
project fills which block. The generator is the usher that walks the
chart, stamps each seat with a real date and time, and hands the guest
list to your calendar.

## Features

- Insert a blank template for one to four projects.
- Parse a filled table into dated, timed org events.
- Prompt for a project code and description per letter, with legend rows
  supplying the defaults.
- Total the weekly hours for each letter in a summary section.
- Keep a library of context templates, and start any week from one in a keystroke.
- Include a command-line script, so people who do not use Emacs can list templates and generate a calendar file.
- Archive each week in its own dated file, such as `writing-2026-01-19.org`.
- Feed the org agenda, optionally as TODO items.
- Export to iCalendar with stable identifiers, so re-imports update
  events rather than duplicating them.
- No external dependencies for normal use. Only Emacs and the built-in
  `org` and `ox-icalendar` libraries are required.

## Related work

[org-timeblock](https://github.com/ichernyshovvv/org-timeblock) gives org-agenda
an interactive timeblock view of scheduled tasks. writing-schedule.el is
complementary: it generates and archives a week from a reusable template and
exports it to iCalendar, rather than viewing timestamps that already exist, so
the two pair well.

## Requirements

- Emacs 27.1 or later.
- Org mode 9.3 or later (bundled with recent Emacs).
- Optional, for coverage and linting only: `undercover`, `package-lint`,
  and the system tools `lcov` and `genhtml`.

## Project layout

```
writing-schedule.el                        The package.
writing-schedule.sh                        Command-line front end for non-Emacs users.
writing-schedule-3-example.org             A filled three-project table.
examples/three-projects.org                An example template to copy into your templates dir.
writing-schedule/                          Archive directory of dated weekly files.
  templates/                               Saved context templates (filled tables).
  tables/                                  This week's working table, copied from a template.
Makefile                                   Test, coverage, and lint targets.
test/
  test-writing-schedule.el                 Unit tests.
  test-writing-schedule-integration.el     Integration tests.
doc/
  writing-schedule.texi                    Texinfo manual.
README.md                                  This file.
```

## Installation

Place `writing-schedule.el` on your load path and require it.

```elisp
(add-to-list 'load-path "~/path/to/writing-schedule")
(require 'writing-schedule)

;; Where the weeks are archived.
(setq writing-schedule-directory "~/org/writing-schedule/")

;; A timezone string keeps exported events anchored correctly.
(setq org-icalendar-timezone "America/Chicago")
```

The template and table directories default to `templates/` and `tables/` under
`writing-schedule-directory`, computed each time they are used, so setting the
base directory is enough and the load order does not matter. Set
`writing-schedule-template-directory` or `writing-schedule-table-directory` only
when you want templates or working tables somewhere else.

## Running the package: a tutorial

### 1. Insert a template

Open a scratch org buffer and run:

```
M-x writing-schedule-insert-template
```

Answer the prompt with the number of projects for the week. A blank
table appears with the default time blocks and one legend row per
project.

### 2. Fill the table

Type a letter into each day cell to assign a project to that block.
Leave a cell empty to skip that block on that day. The table looks like
this once filled.

```
| Time <l>    | M | Tu | W | Th | F | Sa |
|-------------+---+----+---+----+---+----|
| Generative: |   |    |   |    |   |    |
| 04:00-05:30 | A | B  | A | B  | B |    |
| 05:45-07:15 | A | B  | A | B  | B | B  |
|-------------+---+----+---+----+---+----|
| A:          |   |    |   |    |   |    |
| B:          |   |    |   |    |   |    |
```

The parser tolerates irregular spacing and single-digit hours, so
`9:15 - 10:45` and `04:00-5:30` both work. A lower-case cell letter is
normalized to upper case.

### 3. Generate the schedule

Put point anywhere inside the table and run:

```
M-x writing-schedule-generate
```

For each letter you are asked for a project code and a description. If
you typed a description into a legend row, it becomes the default. Then
you pick any day inside the target week, and the command snaps back to
that week's Monday. The command writes a dated file for that week, such as
`writing-2026-01-19.org`, inside `writing-schedule-directory`. It then
adds the file to your agenda and offers to export the iCalendar file.
Each following week lands in its own file, so past weeks are archived
rather than overwritten.

### 4. Sync a calendar

Run `M-x writing-schedule-export-ics` to write the `.ics` file. In
Outlook Web, choose **Add calendar** then **Upload from file**. Because
each headline carries a stable identifier, importing an edited week
updates the matching events rather than duplicating them.

### 5. Browse the archive

Because every week is its own dated file, you can reopen any of them.

```
M-x writing-schedule-open-week
```

This lists the archived weeks with completion, newest first, so a recent
week is one keystroke away. With a prefix argument, `C-u
M-x writing-schedule-open-week`, you instead pick any day from the date
prompt and the command opens the file for the week that contains it. To
jump straight to the latest week, run `M-x writing-schedule-open-recent`.

### 6. Start a week from a saved template

Keep a library of filled tables in `writing-schedule-template-directory`,
one per context, for example `teaching-week.org`, `grant-deadline.org`,
or `writing-retreat.org`. Each already has the letters assigned, so the
weekly half hour of deciding where each project goes is done once. If your
tables live in `~/org/writing-schedule/table`, point the library there with
`(setq writing-schedule-template-directory "~/org/writing-schedule/table/")`,
or use the default `templates/` subdirectory.

```
M-x writing-schedule-new-week-from-template
```

Choose a template. The command copies it to this week's working table in
`writing-schedule-table-directory`, opens that copy, and puts point in
the table so you can adjust a few letters and run
`writing-schedule-generate` right away. Because the copy is separate from
the template, your library stays intact.

If a saved table already matches the coming week and you do not need to
edit it, generate from it in one step:

```
M-x writing-schedule-generate-from-template
```

This lists your saved tables, and after you pick one it generates the
dated schedule of events for the org agenda directly, prompting for the
project mapping and the week. It reads the table without changing it.

### Feeding the agenda

Add your task file, the schedule file, and any project logs to the agenda
so all three become sources of TODO items and timed blocks.

```elisp
(setq org-agenda-files
      '("~/org/tasks.org"
        "~/org/writing-schedule/"   ; the archive directory picks up every dated week
        "~/org/logs/"))
```

## Commands

| Command                            | Purpose                                          |
|------------------------------------|--------------------------------------------------|
| `writing-schedule-insert-template` | Insert a blank table for one to four projects    |
| `writing-schedule-generate`        | Parse the table at point and write the org file  |
| `writing-schedule-export-ics`      | Export the org file to an `.ics` file            |
| `writing-schedule-add-to-agenda`   | Add the generated file to `org-agenda-files`     |
| `writing-schedule-open-week`       | Open an archived week by completion, newest first, or by date with a prefix argument |
| `writing-schedule-open-recent`     | Open the most recent archived week               |
| `writing-schedule-new-week-from-template` | Copy a saved template into this week and open it, ready to generate |
| `writing-schedule-generate-from-template` | Select a saved table and generate the schedule from it directly |

## Key bindings

The package ships a prefix keymap, `writing-schedule-command-map`, that
puts the commands on single keys: `g` generate, `t` template, `n` new
week from template, `f` generate from a saved table, `o` open week, `r`
open recent, `e` export ics, and `a` add to agenda. Bind it
under any prefix you like. When `C-c w` is already your writing prefix,
nest it on a free key such as `c`.

```elisp
(with-eval-after-load 'writing-schedule
  (keymap-set my-writing-prefix "c" writing-schedule-command-map))
```

With `use-package`, the same nesting loads the package on first use and
adds which-key labels.

```elisp
(use-package writing-schedule
  :load-path "~/src/writing-schedule"
  :bind-keymap ("C-c w c" . writing-schedule-command-map)
  :config
  (when (fboundp 'which-key-add-key-based-replacements)
    (which-key-add-key-based-replacements
      "C-c w c"   "writing-schedule"
      "C-c w c g" "generate week"
      "C-c w c t" "insert template"
      "C-c w c n" "new week from template"
      "C-c w c f" "generate from table"
      "C-c w c o" "open week"
      "C-c w c r" "open recent"
      "C-c w c e" "export ics"
      "C-c w c a" "add to agenda")))
```

After that, `C-c w c r` opens the most recent week, and `C-c w c o` opens
a week by completion or, with a prefix argument, by date.

### With straight.el

If you manage packages with `straight.el`, choose one of the two forms
below. Do not combine `:load-path` with a straight recipe, because they
are two different ways to locate the package and they conflict. In both
forms the settings sit in `:init` so they apply before the first `C-c w
c` press, because `:bind-keymap` defers loading until you use the prefix.

A local checkout that you edit yourself. Opt out of straight with
`:straight nil` and load from your directory. This is the right choice
while you are developing the package.

```elisp
(use-package writing-schedule
  :straight nil
  :load-path "~/src/writing-schedule"
  :bind-keymap ("C-c w c" . writing-schedule-command-map)
  :init
  (setq writing-schedule-directory "~/org/writing-schedule/")
  (setq org-icalendar-timezone "America/Chicago"))
```

Managed by straight from a published repository. Drop `:load-path` and
give straight a git recipe (adjust the host and repo to yours).

```elisp
(use-package writing-schedule
  :straight (writing-schedule :type git :host github :repo "MooersLab/writing-schedule")
  :bind-keymap ("C-c w c" . writing-schedule-command-map)
  :init
  (setq writing-schedule-directory "~/org/writing-schedule/")
  (setq org-icalendar-timezone "America/Chicago"))
```

## For non-Emacs users (command line)

You do not need to know Emacs to get a calendar from a template. The
`writing-schedule.sh` script uses Emacs only as an engine, and it produces an
iCalendar (`.ics`) file that you can import into Apple Calendar or Outlook
Calendar.

List the available templates:

```
./writing-schedule.sh list
```

Generate a schedule and an `.ics` file for the week that contains a date:

```
./writing-schedule.sh generate three-projects 2026-01-21
```

The script prints the path of the `.ics` file. Import it:

- Apple Calendar: File > Import..., choose the `.ics`, then pick a calendar.
- Outlook (web): Add calendar > Upload from file, then choose the `.ics`.

Configure paths through the environment:

```
WS_DIR            directory holding writing-schedule.el (default: the script's dir)
WS_OUT_DIR        output directory (default: ~/org/writing-schedule)
WS_TEMPLATE_DIR   templates directory (default: WS_OUT_DIR/templates)
WS_TABLE_DIR      working-table directory (default: WS_OUT_DIR/tables)
WS_TIMEZONE       iCalendar timezone, for example America/Chicago (default: local)
```

Set `WS_OUT_DIR` alone and the templates and tables directories follow it.
Override `WS_TEMPLATE_DIR` or `WS_TABLE_DIR` only to place them elsewhere.

Check dependencies. The script needs only Emacs, because org and ox-icalendar
are built in:

```
./writing-schedule.sh deps
```

An example template is in `examples/three-projects.org`. Copy it into your
templates directory to get started:

```
mkdir -p ~/org/writing-schedule/templates
cp examples/three-projects.org ~/org/writing-schedule/templates/
```

For nicer calendar titles, fill the legend rows of a template with a short
description per letter, because those descriptions become the event titles.

## Testing

### Prerequisites

Running the tests needs only Emacs, because both ERT and the required org
libraries are built in. Coverage and linting need extra tools, installed
with a single target described below.

### Quick start

Run the whole suite from the project root.

```
make test
```

The Makefile finds the tests whether they live in a `test/` subdirectory
or beside the Makefile in a single flat directory. If you keep them
somewhere else, point the Makefile at that directory with
`make test TEST_DIR=path/to/tests`.

### Available make targets

| Target              | Purpose                                          |
|---------------------|--------------------------------------------------|
| `make test`         | Run all tests, unit and integration              |
| `make test-unit`    | Run unit tests only                              |
| `make test-integration` | Run integration tests only                   |
| `make compile`      | Byte-compile the source with warnings as errors  |
| `make lint`         | Run package-lint on the source                   |
| `make checkdoc`     | Check documentation strings                      |
| `make coverage`     | Run tests with a text coverage report            |
| `make coverage-html`| Generate an HTML coverage report in `htmlcov/`   |
| `make coverage-check` | Fail if line coverage is below 90 percent      |
| `make clean`        | Remove byte-compiled and coverage artifacts      |
| `make install-test-deps` | Install undercover and package-lint         |
| `make help`         | Print the target list                            |

### Running a single test

Run one test file, or a single test by name, directly with Emacs.

```bash
# One file.
emacs --batch -L . -L test \
  -l test/test-writing-schedule.el \
  -f ert-run-tests-batch-and-exit

# One test by an exact-name regexp.
emacs --batch -L . -L test \
  -l test/test-writing-schedule.el \
  --eval '(ert-run-tests-batch-and-exit "writing-schedule/parse-time/happy-path")'
```

### Coverage

Install the coverage and lint tools once, then generate a report.

```
make install-test-deps
make coverage
```

These package-based targets run a bare `emacs --batch`, which by default
uses `~/.emacs.d` and its `elpa` store. If your Emacs user directory is
elsewhere, set `EMACS_DIR` so the targets reuse your installed packages
(Emacs 29 or later is required for this).

```
make coverage EMACS_DIR=~/e30fewpackages
```

For an HTML report, run `make coverage-html` and open `htmlcov/index.html`.
The current suite reports 100 percent line coverage across 66 tests. The
`make coverage-check` target fails the build if coverage falls below 90
percent, which suits a continuous-integration gate.

### Writing new tests

Unit tests live in `test/test-writing-schedule.el` and cover the pure
helper functions. Integration tests live in
`test/test-writing-schedule-integration.el` and exercise the full path
through a live org buffer, the interactive commands, and the iCalendar
export. Name a test `writing-schedule/<function>/<behavior>` so its
intent is clear from the report. Tag every integration test with
`:tags '(integration)` so the `test-integration` target can select it.
Use `make-temp-file` and `unwind-protect` for anything that touches the
file system, and stub interactive prompts such as `read-string` and
`org-read-date` with `cl-letf` so the tests run without input.

### Continuous integration

The Makefile targets are pipeline friendly and can be called from any CI
system. A minimal GitHub Actions job looks like this.

```yaml
name: tests
on: [push, pull_request]
jobs:
  ert:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: purcell/setup-emacs@master
        with:
          version: '29.3'
      - run: make install-test-deps
      - run: make test
      - run: make coverage-check
```

## Documentation

A Texinfo manual is in `doc/writing-schedule.texi`. Build the Info and
HTML versions with:

```bash
makeinfo --no-split doc/writing-schedule.texi        # Info
makeinfo --html --no-split doc/writing-schedule.texi # HTML
```

## License

GPL-3.0-or-later.
