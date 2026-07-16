#!/usr/bin/env bash
# writing-schedule.sh - a command-line front end for writing-schedule.el
#
# It lets people who do not use Emacs list the available schedule templates
# and generate an iCalendar (.ics) file that they can import into Apple
# Calendar or Outlook Calendar. Emacs is used only as the engine; you do not
# need to know Emacs to use this script.

set -euo pipefail

# --- Configuration (override any of these through the environment) ---
EMACS="${EMACS:-emacs}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_DIR="${WS_DIR:-$SCRIPT_DIR}"
WS_OUT_DIR="${WS_OUT_DIR:-$HOME/org/writing-schedule}"
# WS_TEMPLATE_DIR and WS_TABLE_DIR are empty by default and derive from
# WS_OUT_DIR, so WS_OUT_DIR is the single directory knob.  Set either one
# only to place templates or working tables somewhere else.
WS_TEMPLATE_DIR="${WS_TEMPLATE_DIR:-}"
WS_TABLE_DIR="${WS_TABLE_DIR:-}"
WS_TIMEZONE="${WS_TIMEZONE:-}"

# Effective directories used for path resolution and messages.
TEMPLATE_DIR="${WS_TEMPLATE_DIR:-$WS_OUT_DIR/templates}"
TABLE_DIR="${WS_TABLE_DIR:-$WS_OUT_DIR/tables}"

usage() {
  cat <<EOF
writing-schedule.sh - generate a writing schedule and a calendar file

Usage:
  writing-schedule.sh list
  writing-schedule.sh weeks
  writing-schedule.sh template <1-4> [file]
  writing-schedule.sh generate <template-or-file> <date>
  writing-schedule.sh export <schedule.org>
  writing-schedule.sh save <table-file> <name>
  writing-schedule.sh deps [--install]
  writing-schedule.sh help

Commands:
  list                          List the available templates (tables).
  weeks                         List the archived weekly schedules, newest first.
  template <1-4> [file]         Print a blank template for that many projects,
                                or write it to <file> when given.
  generate <template> <date>    Generate a schedule and an .ics file for the
                                week that contains <date> (YYYY-MM-DD).
                                <template> is a name from 'list' or a path to
                                an .org table file.
  export <schedule.org>         Export an existing schedule file to .ics.
  save <table-file> <name>      Save a table file into the template library
                                under <name>.
  deps [--install]              Check dependencies. With --install, try to
                                install Emacs with your system package manager.
  help                          Show this help.

Environment:
  EMACS            Emacs binary (default: emacs)
  WS_DIR           Directory holding writing-schedule.el (default: this script's dir)
  WS_OUT_DIR       Output directory (default: ~/org/writing-schedule)
  WS_TEMPLATE_DIR  Templates directory (default: WS_OUT_DIR/templates)
  WS_TABLE_DIR     Working-table directory (default: WS_OUT_DIR/tables)
  WS_TIMEZONE      iCalendar timezone, for example America/Chicago (default: local)

After generating, import the .ics file into your calendar:
  Apple Calendar: File > Import..., choose the .ics, then pick a calendar.
  Outlook (web):  Add calendar > Upload from file, then choose the .ics.
  Outlook (new):  Add calendar > Upload from file.
EOF
}

# Escape a string for embedding inside an Emacs Lisp double-quoted string.
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

have_emacs() { command -v "$EMACS" >/dev/null 2>&1; }

install_emacs_hint() {
  echo "Emacs was not found (looked for: $EMACS)." >&2
  case "$(uname -s)" in
    Darwin) echo "  Install it with: brew install emacs" >&2 ;;
    Linux)  echo "  Install it with: sudo apt-get install emacs-nox   (Debian/Ubuntu)" >&2
            echo "               or: sudo dnf install emacs-nox        (Fedora)" >&2 ;;
    *)      echo "  Install Emacs 27.1 or newer from https://www.gnu.org/software/emacs/" >&2 ;;
  esac
  echo "  Generating the .ics needs only Emacs, because org and ox-icalendar are built in." >&2
  echo "  To run the package test suite, developers can use: make install-test-deps" >&2
}

try_install_emacs() {
  case "$(uname -s)" in
    Darwin)
      if command -v brew >/dev/null 2>&1; then brew install emacs && return 0; fi ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update && sudo apt-get install -y emacs-nox && return 0
      elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y emacs-nox && return 0
      fi ;;
  esac
  return 1
}

run_emacs() {
  # $1 = an Emacs Lisp expression to evaluate.
  local expr="$1"
  local -a args=( -Q --batch -L "$WS_DIR"
    --eval "(require 'writing-schedule)"
    --eval "(setq writing-schedule-directory \"$(esc "$WS_OUT_DIR")\")" )
  # Set the derived directories only when the user pinned them, so that an
  # unset value derives from writing-schedule-directory (WS_OUT_DIR).
  if [ -n "$WS_TEMPLATE_DIR" ]; then
    args+=( --eval "(setq writing-schedule-template-directory \"$(esc "$WS_TEMPLATE_DIR")\")" )
  fi
  if [ -n "$WS_TABLE_DIR" ]; then
    args+=( --eval "(setq writing-schedule-table-directory \"$(esc "$WS_TABLE_DIR")\")" )
  fi
  if [ -n "$WS_TIMEZONE" ]; then
    args+=( --eval "(setq org-icalendar-timezone \"$(esc "$WS_TIMEZONE")\")" )
  fi
  args+=( --eval "$expr" )
  "$EMACS" "${args[@]}"
}

check_deps() {
  local install="${1:-}"
  if have_emacs; then
    echo "Emacs found: $("$EMACS" --version 2>/dev/null | head -1)"
  else
    if [ "$install" = "--install" ]; then
      echo "Trying to install Emacs..."
      if try_install_emacs; then echo "Emacs installed."; else install_emacs_hint; return 1; fi
    else
      install_emacs_hint
      return 1
    fi
  fi
  if run_emacs "(princ \"ok\")" >/dev/null 2>&1; then
    echo "writing-schedule.el loads correctly (org and ox-icalendar are available)."
  else
    echo "writing-schedule.el failed to load from: $WS_DIR" >&2
    echo "  Point WS_DIR at the directory that holds writing-schedule.el." >&2
    return 1
  fi
}

resolve_table() {
  # Resolve a template name or path to an absolute .org file path.
  local arg="$1"
  if [ -f "$arg" ]; then
    printf '%s/%s\n' "$(cd "$(dirname "$arg")" && pwd)" "$(basename "$arg")"; return 0
  fi
  if [ -f "$TEMPLATE_DIR/$arg" ]; then printf '%s/%s\n' "$TEMPLATE_DIR" "$arg"; return 0; fi
  if [ -f "$TEMPLATE_DIR/$arg.org" ]; then printf '%s/%s.org\n' "$TEMPLATE_DIR" "$arg"; return 0; fi
  return 1
}

cmd_list() {
  have_emacs || { install_emacs_hint; exit 1; }
  run_emacs "(writing-schedule-batch-list-templates)"
}

cmd_weeks() {
  have_emacs || { install_emacs_hint; exit 1; }
  run_emacs "(writing-schedule-batch-list-weeks)"
}

cmd_template() {
  have_emacs || { install_emacs_hint; exit 1; }
  local n="${1:-}"
  local file="${2:-}"
  if [ -z "$n" ]; then
    echo "Usage: writing-schedule.sh template <1-4> [file]" >&2
    echo "  With no file, the blank template is printed to standard output." >&2
    exit 2
  fi
  run_emacs "(writing-schedule-batch-insert-template $(esc "$n") \"$(esc "$file")\")"
}

cmd_generate() {
  have_emacs || { install_emacs_hint; exit 1; }
  local table_arg="${1:-}"
  local week="${2:-}"
  if [ -z "$table_arg" ] || [ -z "$week" ]; then
    echo "Usage: writing-schedule.sh generate <template-or-file> <date YYYY-MM-DD>" >&2
    exit 2
  fi
  local table
  if ! table="$(resolve_table "$table_arg")"; then
    echo "Could not find template or file: $table_arg" >&2
    echo "Run 'writing-schedule.sh list' to see the templates in:" >&2
    echo "  $TEMPLATE_DIR" >&2
    exit 1
  fi
  run_emacs "(writing-schedule-batch-generate \"$(esc "$table")\" \"$(esc "$week")\")"
  echo
  echo "Import the .ics into your calendar:"
  echo "  Apple Calendar: File > Import..., choose the .ics file."
  echo "  Outlook (web):  Add calendar > Upload from file."
}

cmd_export() {
  have_emacs || { install_emacs_hint; exit 1; }
  local sched="${1:-}"
  if [ -z "$sched" ]; then
    echo "Usage: writing-schedule.sh export <schedule.org>" >&2
    exit 2
  fi
  if [ ! -f "$sched" ]; then
    echo "No such schedule file: $sched" >&2
    exit 1
  fi
  local abs
  abs="$(cd "$(dirname "$sched")" && pwd)/$(basename "$sched")"
  run_emacs "(writing-schedule-export-ics \"$(esc "$abs")\")"
}

cmd_save() {
  have_emacs || { install_emacs_hint; exit 1; }
  local file="${1:-}"
  local name="${2:-}"
  if [ -z "$file" ] || [ -z "$name" ]; then
    echo "Usage: writing-schedule.sh save <table-file> <name>" >&2
    exit 2
  fi
  if [ ! -f "$file" ]; then
    echo "No such table file: $file" >&2
    exit 1
  fi
  local abs
  abs="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"
  run_emacs "(writing-schedule-batch-save-template \"$(esc "$abs")\" \"$(esc "$name")\")"
}

main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    list)           cmd_list "$@" ;;
    weeks)          cmd_weeks "$@" ;;
    template)       cmd_template "$@" ;;
    generate)       cmd_generate "$@" ;;
    export)         cmd_export "$@" ;;
    save)           cmd_save "$@" ;;
    deps)           check_deps "${1:-}" ;;
    help|-h|--help) usage ;;
    *) echo "Unknown command: $cmd" >&2; echo >&2; usage; exit 2 ;;
  esac
}

main "$@"
