#!/usr/bin/env bash
set -euo pipefail

OLD_DB=""
NEW_DB=""
DB_USER="root"
DB_HOST="localhost"
DB_PORT="3306"
DUMP_FILE=""
GRANTS_FILE=""
CLIENT_EXE=""
DUMP_EXE=""
DROP_OLD_DATABASE=false
COPY_GRANTS=false
DELETE_SQL_FILES=false
GRANTS_FILE_CREATED=false

usage() {
  cat <<'EOF'
Usage:
  ./rename-mariadb-database.sh -OldDb OLD_DB -NewDb NEW_DB [options]

Required:
  -OldDb NAME             Source database name
  -NewDb NAME             Target database name

Options:
  -User USER              MariaDB/MySQL user; default: root
  -Host HOST              MariaDB/MySQL host; default: localhost
  -Port PORT              MariaDB/MySQL port; default: 3306
  -DumpFile PATH          SQL dump file to create; default: OLD_DB-YYYYMMDD-HHMMSS.sql
  -CopyGrants             Copy database, table, and column-level grants to the new database
  -GrantsFile PATH        SQL grants file to create when -CopyGrants is used;
                          default: OLD_DB-to-NEW_DB-grants-YYYYMMDD-HHMMSS.sql
  -DeleteSqlFiles         Delete the dump file and generated grants file after a successful run
  -ClientExe PATH         Path to mariadb or mysql client; default: auto-detect
  -DumpExe PATH           Path to mariadb-dump or mysqldump; default: auto-detect
  -DropOldDatabase        Drop the source database after import and verification query
  -Help                   Show this help message

Examples:
  ./rename-mariadb-database.sh -OldDb oldname -NewDb newname -User root

  ./rename-mariadb-database.sh \
    -OldDb oldname \
    -NewDb newname \
    -User root \
    -CopyGrants

  ./rename-mariadb-database.sh \
    -OldDb oldname \
    -NewDb newname \
    -User root \
    -DumpFile /tmp/oldname.sql \
    -CopyGrants \
    -GrantsFile /tmp/oldname-to-newname-grants.sql

  ./rename-mariadb-database.sh \
    -OldDb oldname \
    -NewDb newname \
    -User root \
    -DeleteSqlFiles

  ./rename-mariadb-database.sh \
    -OldDb oldname \
    -NewDb newname \
    -User root \
    -ClientExe mysql \
    -DumpExe mysqldump

  ./rename-mariadb-database.sh \
    -OldDb oldname \
    -NewDb newname \
    -User root \
    -Host localhost \
    -Port 3306
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

warn() {
  echo "Warning: $*" >&2
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

sql_string_literal() {
  local value="$1"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
}

replace_placeholder() {
  local text="$1"
  local placeholder="$2"
  local replacement="$3"
  printf '%s' "${text//"$placeholder"/$replacement}"
}

require_value() {
  local option="$1"
  local value="${2:-}"

  if [[ -z "$value" || "$value" == -* ]]; then
    die "$option requires a value"
  fi
}

delete_file_if_present() {
  local file_path="$1"
  local description="$2"

  if [[ -f "$file_path" ]]; then
    echo "Deleting $description '$file_path'..."
    rm -f -- "$file_path"
    echo "$description deleted."
  else
    echo "$description '$file_path' was not found; nothing to delete."
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
    -CopyGrants)
      COPY_GRANTS=true
      shift
      ;;
    -GrantsFile)
      require_value "$1" "${2:-}"
      GRANTS_FILE="$2"
      shift 2
      ;;
    -DeleteSqlFiles)
      DELETE_SQL_FILES=true
      shift
      ;;
    -ClientExe)
      require_value "$1" "${2:-}"
      CLIENT_EXE="$2"
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

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

if [[ -z "$DUMP_FILE" ]]; then
  DUMP_FILE="${OLD_DB}-${TIMESTAMP}.sql"
fi

if [[ -z "$GRANTS_FILE" ]]; then
  GRANTS_FILE="${OLD_DB}-to-${NEW_DB}-grants-${TIMESTAMP}.sql"
elif [[ "$COPY_GRANTS" != true ]]; then
  warn "-GrantsFile was provided but -CopyGrants is not enabled; the grants file will not be generated."
fi

if [[ -z "$CLIENT_EXE" ]]; then
  CLIENT_EXE_RESOLVED="$(resolve_executable "mariadb" "mysql")" || die "Could not find mariadb or mysql client. Use -ClientExe to specify it."
  CLIENT_EXE="$CLIENT_EXE_RESOLVED"
else
  CLIENT_EXE_RESOLVED="$(resolve_executable "$CLIENT_EXE")" || die "Could not find database client: $CLIENT_EXE"
  CLIENT_EXE="$CLIENT_EXE_RESOLVED"
fi

if [[ -z "$DUMP_EXE" ]]; then
  DUMP_EXE_RESOLVED="$(resolve_executable "mariadb-dump" "mysqldump")" || die "Could not find mariadb-dump or mysqldump. Use -DumpExe to specify it."
  DUMP_EXE="$DUMP_EXE_RESOLVED"
else
  DUMP_EXE_RESOLVED="$(resolve_executable "$DUMP_EXE")" || die "Could not find dump executable: $DUMP_EXE"
  DUMP_EXE="$DUMP_EXE_RESOLVED"
fi

read -rsp "Database password for $DB_USER: " DB_PASS
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
OLD_DB_LITERAL="$(sql_string_literal "$OLD_DB")"
NEW_DB_IDENTIFIER_LITERAL="$(sql_string_literal "$NEW_DB_QUOTED")"
DEFAULTS_ARG="--defaults-extra-file=$CNF"

SQL_TABLE_COUNT_TEMPLATE=$(cat <<'EOF'
SELECT table_schema, COUNT(*) AS tables
FROM information_schema.tables
WHERE table_schema IN (__OLD_DB_LITERAL__, __NEW_DB_LITERAL__)
GROUP BY table_schema;
EOF
)

NEW_DB_LITERAL="$(sql_string_literal "$NEW_DB")"
SQL_TABLE_COUNT="$(replace_placeholder "$SQL_TABLE_COUNT_TEMPLATE" "__OLD_DB_LITERAL__" "$OLD_DB_LITERAL")"
SQL_TABLE_COUNT="$(replace_placeholder "$SQL_TABLE_COUNT" "__NEW_DB_LITERAL__" "$NEW_DB_LITERAL")"

SQL_COPY_GRANTS_TEMPLATE=$(cat <<'EOF'
SET SESSION group_concat_max_len = 1048576;

SELECT grant_statement
FROM (
  SELECT
    1 AS sort_order,
    GRANTEE AS grantee_sort,
    '' AS object_sort,
    '' AS privilege_sort,
    IS_GRANTABLE AS grantable_sort,
    CONCAT(
      'GRANT ',
      GROUP_CONCAT(PRIVILEGE_TYPE ORDER BY PRIVILEGE_TYPE SEPARATOR ', '),
      ' ON ',
      __NEW_DB_IDENTIFIER_LITERAL__,
      '.* TO ',
      GRANTEE,
      IF(IS_GRANTABLE = 'YES', ' WITH GRANT OPTION', ''),
      ';'
    ) AS grant_statement
  FROM information_schema.SCHEMA_PRIVILEGES
  WHERE TABLE_SCHEMA = __OLD_DB_LITERAL__
  GROUP BY GRANTEE, IS_GRANTABLE

  UNION ALL

  SELECT
    2 AS sort_order,
    GRANTEE AS grantee_sort,
    TABLE_NAME AS object_sort,
    '' AS privilege_sort,
    IS_GRANTABLE AS grantable_sort,
    CONCAT(
      'GRANT ',
      GROUP_CONCAT(PRIVILEGE_TYPE ORDER BY PRIVILEGE_TYPE SEPARATOR ', '),
      ' ON ',
      __NEW_DB_IDENTIFIER_LITERAL__,
      '.`',
      REPLACE(TABLE_NAME, '`', '``'),
      '` TO ',
      GRANTEE,
      IF(IS_GRANTABLE = 'YES', ' WITH GRANT OPTION', ''),
      ';'
    ) AS grant_statement
  FROM information_schema.TABLE_PRIVILEGES
  WHERE TABLE_SCHEMA = __OLD_DB_LITERAL__
  GROUP BY GRANTEE, TABLE_NAME, IS_GRANTABLE

  UNION ALL

  SELECT
    3 AS sort_order,
    GRANTEE AS grantee_sort,
    TABLE_NAME AS object_sort,
    PRIVILEGE_TYPE AS privilege_sort,
    IS_GRANTABLE AS grantable_sort,
    CONCAT(
      'GRANT ',
      PRIVILEGE_TYPE,
      ' (',
      GROUP_CONCAT(CONCAT('`', REPLACE(COLUMN_NAME, '`', '``'), '`') ORDER BY COLUMN_NAME SEPARATOR ', '),
      ') ON ',
      __NEW_DB_IDENTIFIER_LITERAL__,
      '.`',
      REPLACE(TABLE_NAME, '`', '``'),
      '` TO ',
      GRANTEE,
      IF(IS_GRANTABLE = 'YES', ' WITH GRANT OPTION', ''),
      ';'
    ) AS grant_statement
  FROM information_schema.COLUMN_PRIVILEGES
  WHERE TABLE_SCHEMA = __OLD_DB_LITERAL__
  GROUP BY GRANTEE, TABLE_NAME, PRIVILEGE_TYPE, IS_GRANTABLE
) AS generated_grants
ORDER BY sort_order, grantee_sort, object_sort, privilege_sort, grantable_sort;
EOF
)

SQL_COPY_GRANTS="$(replace_placeholder "$SQL_COPY_GRANTS_TEMPLATE" "__OLD_DB_LITERAL__" "$OLD_DB_LITERAL")"
SQL_COPY_GRANTS="$(replace_placeholder "$SQL_COPY_GRANTS" "__NEW_DB_IDENTIFIER_LITERAL__" "$NEW_DB_IDENTIFIER_LITERAL")"

echo "Creating database '$NEW_DB'..."
"$CLIENT_EXE" "$DEFAULTS_ARG" -e "CREATE DATABASE $NEW_DB_QUOTED;"

echo "Dumping '$OLD_DB' to '$DUMP_FILE'..."
"$DUMP_EXE" "$DEFAULTS_ARG" \
  --single-transaction \
  --routines \
  --triggers \
  --events \
  "$OLD_DB" > "$DUMP_FILE"

echo "Importing '$DUMP_FILE' into '$NEW_DB'..."
"$CLIENT_EXE" "$DEFAULTS_ARG" "$NEW_DB" < "$DUMP_FILE"

echo "Comparing table counts..."
"$CLIENT_EXE" "$DEFAULTS_ARG" -e "$SQL_TABLE_COUNT"

if [[ "$COPY_GRANTS" == true ]]; then
  echo "Generating grants file '$GRANTS_FILE'..."
  "$CLIENT_EXE" "$DEFAULTS_ARG" \
    --batch \
    --raw \
    --skip-column-names \
    -e "$SQL_COPY_GRANTS" > "$GRANTS_FILE"
  GRANTS_FILE_CREATED=true

  if grep -q '[^[:space:]]' "$GRANTS_FILE"; then
    echo "Applying copied grants from '$GRANTS_FILE'..."
    "$CLIENT_EXE" "$DEFAULTS_ARG" < "$GRANTS_FILE"
    echo "Copied grants applied."
  else
    echo "No database, table, or column-level grants found for '$OLD_DB'."
  fi
fi

if [[ "$DROP_OLD_DATABASE" == true ]]; then
  echo "Dropping old database '$OLD_DB'..."
  "$CLIENT_EXE" "$DEFAULTS_ARG" -e "DROP DATABASE $OLD_DB_QUOTED;"
  echo "Old database '$OLD_DB' dropped."
else
  echo
  echo "Import completed. The old database '$OLD_DB' was NOT deleted."
  echo "After verification, rerun with -DropOldDatabase or drop it manually."
fi

if [[ "$DELETE_SQL_FILES" == true ]]; then
  delete_file_if_present "$DUMP_FILE" "dump file"

  if [[ "$GRANTS_FILE_CREATED" == true ]]; then
    delete_file_if_present "$GRANTS_FILE" "grants file"
  fi
fi

echo
echo "Done."
