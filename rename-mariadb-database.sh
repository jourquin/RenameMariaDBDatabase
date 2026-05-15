\
#!/usr/bin/env bash
set -euo pipefail

OLD_DB=""
NEW_DB=""
DB_USER="root"
DB_HOST="localhost"
DB_PORT="3306"
DUMP_FILE=""
MARIADB_EXE="mariadb"
DUMP_EXE=""
DROP_OLD_DATABASE=false

usage() {
  cat <<'EOF'
Usage:
  ./rename-mariadb-database.sh -OldDb OLD_DB -NewDb NEW_DB [options]

Required:
  -OldDb NAME             Source database name
  -NewDb NAME             Target database name

Options:
  -User USER              MariaDB user; default: root
  -Host HOST              MariaDB host; default: localhost
  -Port PORT              MariaDB port; default: 3306
  -DumpFile PATH          SQL dump file to create; default: OLD_DB-YYYYMMDD-HHMMSS.sql
  -MariaDbExe PATH        Path to mariadb client; default: mariadb
  -DumpExe PATH           Path to mariadb-dump or mysqldump; default: auto-detect
  -DropOldDatabase        Drop the source database after import and verification query
  -Help                   Show this help message

Examples:
  ./rename-mariadb-database.sh -OldDb oldname -NewDb newname -User root

  ./rename-mariadb-database.sh \
    -OldDb oldname \
    -NewDb newname \
    -User root \
    -Host localhost \
    -Port 3306

  ./rename-mariadb-database.sh \
    -OldDb oldname \
    -NewDb newname \
    -User root \
    -DumpFile /tmp/oldname.sql

  ./rename-mariadb-database.sh \
    -OldDb oldname \
    -NewDb newname \
    -User root \
    -MariaDbExe /usr/bin/mariadb \
    -DumpExe /usr/bin/mariadb-dump
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

resolve_executable() {
  local candidate

  for candidate in "$@"; do
    if [[ -z "$candidate" ]]; then
      continue
    fi

    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi

    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

quote_identifier() {
  local name="$1"
  local escaped="${name//\`/\`\`}"
  printf '`%s`' "$escaped"
}

require_value() {
  local option="$1"
  local value="${2:-}"

  if [[ -z "$value" || "$value" == -* ]]; then
    die "$option requires a value"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -OldDb)
      require_value "$1" "${2:-}"
      OLD_DB="$2"
      shift 2
      ;;
    -NewDb)
      require_value "$1" "${2:-}"
      NEW_DB="$2"
      shift 2
      ;;
    -User)
      require_value "$1" "${2:-}"
      DB_USER="$2"
      shift 2
      ;;
    -Host)
      require_value "$1" "${2:-}"
      DB_HOST="$2"
      shift 2
      ;;
    -Port)
      require_value "$1" "${2:-}"
      DB_PORT="$2"
      shift 2
      ;;
    -DumpFile)
      require_value "$1" "${2:-}"
      DUMP_FILE="$2"
      shift 2
      ;;
    -MariaDbExe)
      require_value "$1" "${2:-}"
      MARIADB_EXE="$2"
      shift 2
      ;;
    -DumpExe)
      require_value "$1" "${2:-}"
      DUMP_EXE="$2"
      shift 2
      ;;
    -DropOldDatabase)
      DROP_OLD_DATABASE=true
      shift
      ;;
    -Help|--help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1. Use -Help for usage."
      ;;
  esac
done

if [[ -z "$OLD_DB" ]]; then
  die "-OldDb is required. Use -Help for usage."
fi

if [[ -z "$NEW_DB" ]]; then
  die "-NewDb is required. Use -Help for usage."
fi

if [[ -z "$DUMP_FILE" ]]; then
  DUMP_FILE="${OLD_DB}-$(date +%Y%m%d-%H%M%S).sql"
fi

MARIADB_EXE_RESOLVED="$(resolve_executable "$MARIADB_EXE")" || die "Could not find MariaDB client: $MARIADB_EXE"
MARIADB_EXE="$MARIADB_EXE_RESOLVED"

if [[ -z "$DUMP_EXE" ]]; then
  DUMP_EXE_RESOLVED="$(resolve_executable "mariadb-dump" "mysqldump")" || die "Could not find mariadb-dump or mysqldump"
  DUMP_EXE="$DUMP_EXE_RESOLVED"
else
  DUMP_EXE_RESOLVED="$(resolve_executable "$DUMP_EXE")" || die "Could not find dump executable: $DUMP_EXE"
  DUMP_EXE="$DUMP_EXE_RESOLVED"
fi

read -rsp "MariaDB password for $DB_USER: " DB_PASS
echo

CNF="$(mktemp)"
chmod 600 "$CNF"

cleanup() {
  rm -f "$CNF"
}

trap cleanup EXIT

cat > "$CNF" <<EOF
[client]
user=$DB_USER
password=$DB_PASS
host=$DB_HOST
port=$DB_PORT
EOF

unset DB_PASS

OLD_DB_QUOTED="$(quote_identifier "$OLD_DB")"
NEW_DB_QUOTED="$(quote_identifier "$NEW_DB")"
DEFAULTS_ARG="--defaults-extra-file=$CNF"

SQL_TABLE_COUNT=$(cat <<EOF
SELECT table_schema, COUNT(*) AS tables
FROM information_schema.tables
WHERE table_schema IN ('$OLD_DB', '$NEW_DB')
GROUP BY table_schema;
EOF
)

echo "Creating database '$NEW_DB'..."
"$MARIADB_EXE" "$DEFAULTS_ARG" -e "CREATE DATABASE $NEW_DB_QUOTED;"

echo "Dumping '$OLD_DB' to '$DUMP_FILE'..."
"$DUMP_EXE" "$DEFAULTS_ARG" \
  --single-transaction \
  --routines \
  --triggers \
  --events \
  "$OLD_DB" > "$DUMP_FILE"

echo "Importing '$DUMP_FILE' into '$NEW_DB'..."
"$MARIADB_EXE" "$DEFAULTS_ARG" "$NEW_DB" < "$DUMP_FILE"

echo "Comparing table counts..."
"$MARIADB_EXE" "$DEFAULTS_ARG" -e "$SQL_TABLE_COUNT"

if [[ "$DROP_OLD_DATABASE" == true ]]; then
  echo "Dropping old database '$OLD_DB'..."
  "$MARIADB_EXE" "$DEFAULTS_ARG" -e "DROP DATABASE $OLD_DB_QUOTED;"
  echo "Old database '$OLD_DB' dropped."
else
  echo
  echo "Import completed. The old database '$OLD_DB' was NOT deleted."
  echo "After verification, rerun with -DropOldDatabase or drop it manually."
fi

echo
echo "Done."
