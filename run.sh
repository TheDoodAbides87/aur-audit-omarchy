#!/bin/bash
# Open a floating terminal and run one aur-audit action in it.
#
#   run.sh system              free system scan
#   run.sh ai-system           system scan, then AI review (asks before sending)
#   run.sh check PKG           audit an AUR package before installing it
#   run.sh ai PKG|DIR          AI review of a blocked package
#   run.sh ai-installed PKG    AI review of an installed package
#   run.sh view REPORT         read a saved aur-audit report
#
# Only these actions are accepted, and every argument is checked before use,
# so the panel can never be made to run anything else. Arguments are passed
# as separate words all the way through; nothing is re-parsed by a shell.

pkg_re='^[a-z0-9@_+][a-z0-9@._+-]*$'
path_re='^[A-Za-z0-9@._+/~-]+$'
report_re='^aur-audit-[a-z0-9@._+-]+-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}\.txt$'

fail() {
  notify-send -u critical "AUR Audit" "$1" 2>/dev/null || echo "$1" >&2
  exit 2
}

check_args() {
  case "$1" in
    system | ai-system)
      (( $# == 1 )) || fail "Unexpected arguments for $1"
      ;;
    check | ai-installed)
      (( $# == 2 )) && [[ $2 =~ $pkg_re ]] || fail "\"$2\" is not a valid package name"
      ;;
    ai)
      (( $# == 2 )) || fail "Missing package for AI review"
      [[ $2 =~ $pkg_re ]] ||
        { [[ $2 =~ $path_re && $2 == /* && $2 != *..* ]]; } ||
        fail "\"$2\" is not a valid package name or build folder"
      ;;
    view)
      (( $# == 2 )) && [[ $(dirname -- "$2") == "$HOME" && $(basename -- "$2") =~ $report_re && -f $2 ]] ||
        fail "Not an aur-audit report: $2"
      ;;
    *)
      fail "Unknown action: $1"
      ;;
  esac
}

if [[ $1 != --in-terminal ]]; then
  check_args "$@"
  exec setsid uwsm-app -- xdg-terminal-exec --app-id=org.omarchy.terminal --title="AUR Audit" \
    -e "$0" --in-terminal "$@"
fi

shift
check_args "$@"

case "$1" in
  system) aur-audit system ;;
  ai-system) aur-audit ai --system ;;
  check) aur-audit check "$2" ;;
  ai) aur-audit ai "$2" ;;
  ai-installed) aur-audit ai --installed "$2" ;;
  view) exec less -- "$2" ;;
esac

echo
omarchy-show-done 2>/dev/null || read -rsn1 -p "Press any key to close..."
