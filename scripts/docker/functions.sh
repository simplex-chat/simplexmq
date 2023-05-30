#!/usr/bin/env sh

print_to_stderr() {
  # Print each argument as a separate line
  printf -- '%s\n' "$@" 1>&2
}

print_arg() {
  printf -- '%s' "$1"
}

print_arg_from_env_addr() {
  # Determine IP or domain name
  case "${ADDR}" in
    '') print_to_stderr 'Please specify $ADDR environment variable.'; return 1 ;;
    *[a-zA-Z]*)
      case "${ADDR}" in
        *:*) print_arg --ip ;;
        *) print_arg -n ;;
      esac
      ;;
    *) print_arg --ip ;;
  esac
  return 0
}

# Uses the UTC (universal) time zone and this
# format: YYYY-mm-dd'T'HH:MM:SS
# year, month, day, letter T, hour, minute, second
#
# This is the ISO 8601 format without the time zone at the end.
backup_file_iso8601() {
  for _file in "$@"; do
    if [ -f "${_file}" ]; then
      _backup_extension="$(date -u '+%Y-%m-%dT%H:%M:%S')"
      cp -v -p "${_file}" "${_file}.${_backup_extension:-date-failed}"
      unset -v _backup_extension
    fi
  done
  unset -v _file
}
