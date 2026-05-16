# MariaDB / MySQL Database Rename Scripts

This repository contains two scripts to safely "rename" a MariaDB or MySQL database:

- `rename-mariadb-database.sh` for Linux, macOS, and other Unix-like systems
- `rename-mariadb-database.ps1` for Windows PowerShell

MariaDB and MySQL do not provide a direct `RENAME DATABASE` command. These scripts therefore use a dump-and-restore workflow:

1. Create a new database.
2. Dump the existing database.
3. Optionally store the dump as a gzip-compressed SQL file.
4. Import the dump into the new database.
5. Optionally copy database, table, and column-level grants from the old database to the new one.
6. Show a table-count comparison.
7. Optionally delete the generated SQL files.
8. Let you verify the result before deleting the original database.

## Repository files

| File | Platform | Purpose |
| --- | --- | --- |
| `rename-mariadb-database.sh` | Linux, macOS, Unix-like systems | Bash script |
| `rename-mariadb-database.ps1` | Windows | PowerShell script |

## What the scripts do

Both scripts:

- use the same database-renaming command-line options;
- ask for the database password only once;
- avoid passing the password directly on the command line;
- create a temporary MariaDB/MySQL option file;
- create the target database;
- dump the source database;
- optionally compress the dump as a `.sql.gz` file;
- include tables, data, routines, triggers, and events in the dump;
- import the dump into the target database, decompressing it automatically when needed;
- optionally copy database, table, and column-level grants to the target database;
- optionally delete the generated dump and grants SQL files;
- show a table-count comparison between the source and target databases;
- keep the original database unless deletion is explicitly enabled.

## Requirements

### Common requirements

You need:

- access to a MariaDB or MySQL server;
- MariaDB or MySQL client tools installed;
- a database user with privileges to:
  - create databases;
  - dump the source database;
  - import data into the target database;
  - read routines, triggers, events, and privilege metadata;
  - grant privileges on the target database if `-CopyGrants` is used;
  - optionally drop the old database.

### Bash requirements

For `rename-mariadb-database.sh`:

- Bash
- `mariadb` or `mysql`
- `mariadb-dump` or `mysqldump`
- `gzip` when `-CompressDump` is used

### PowerShell requirements

For `rename-mariadb-database.ps1`:

- PowerShell
- `mariadb.exe` or `mysql.exe`
- `mariadb-dump.exe` or `mysqldump.exe`

The PowerShell script uses .NET's built-in gzip streams for compressed dumps, so it does not require an external `gzip.exe`.

## Command-line options

Both scripts support the same main options, except `-GzipExe`, which is Bash-only.

| Option | Required | Default | Description |
| --- | --- | --- | --- |
| `-OldDb` | Yes | | Source database name |
| `-NewDb` | Yes | | Target database name |
| `-User` | No | `root` | Database user |
| `-Host` | No | `localhost` | Database host |
| `-Port` | No | `3306` | Database port |
| `-DumpFile` | No | Timestamped SQL file | Path of the SQL dump file to create. With `-CompressDump`, the default extension is `.sql.gz` |
| `-CompressDump` | No | Disabled | Store the dump as a gzip-compressed SQL file and decompress it automatically during import |
| `-GzipExe` | No | Auto-detected | Bash-only path to `gzip`, used when `-CompressDump` is enabled |
| `-CopyGrants` | No | Disabled | Generate and apply equivalent database, table, and column-level grants for the target database |
| `-GrantsFile` | No | Timestamped SQL file | Path of the generated grants SQL file when `-CopyGrants` is used |
| `-DeleteSqlFiles` | No | Disabled | Delete the dump file and generated grants file after a successful run |
| `-ClientExe` | No | Auto-detected | Path to `mariadb`, `mysql`, `mariadb.exe`, or `mysql.exe` |
| `-DumpExe` | No | Auto-detected | Path to `mariadb-dump`, `mariadb-dump.exe`, `mysqldump`, or `mysqldump.exe` |
| `-DropOldDatabase` | No | Disabled | Drops the source database after import and verification query |

The Bash script also supports `-Help`, `--help`, and `-h`.

## Using the Bash script

Make the script executable:

```bash
chmod +x rename-mariadb-database.sh
```

Run it:

```bash
./rename-mariadb-database.sh -OldDb old_database_name -NewDb new_database_name -User root
```

Show Bash usage help:

```bash
./rename-mariadb-database.sh -Help
```

With host and port:

```bash
./rename-mariadb-database.sh -OldDb old_database_name -NewDb new_database_name -User root -Host localhost -Port 3306
```

With an explicit dump file:

```bash
./rename-mariadb-database.sh -OldDb old_database_name -NewDb new_database_name -User root -DumpFile /tmp/old_database_name.sql
```

Create and import a compressed dump:

```bash
./rename-mariadb-database.sh -OldDb old_database_name -NewDb new_database_name -User root -CompressDump
```

Create a compressed dump with an explicit path:

```bash
./rename-mariadb-database.sh \
  -OldDb old_database_name \
  -NewDb new_database_name \
  -User root \
  -CompressDump \
  -DumpFile /tmp/old_database_name.sql.gz
```

Use a specific `gzip` executable:

```bash
./rename-mariadb-database.sh \
  -OldDb old_database_name \
  -NewDb new_database_name \
  -User root \
  -CompressDump \
  -GzipExe /usr/bin/gzip
```

Copy grants from the old database to the new database:

```bash
./rename-mariadb-database.sh -OldDb old_database_name -NewDb new_database_name -User root -CopyGrants
```

Copy grants and keep the generated grants SQL file at a specific path:

```bash
./rename-mariadb-database.sh \
  -OldDb old_database_name \
  -NewDb new_database_name \
  -User root \
  -CopyGrants \
  -GrantsFile /tmp/copied-grants.sql
```

Delete generated SQL files after a successful run:

```bash
./rename-mariadb-database.sh -OldDb old_database_name -NewDb new_database_name -User root -DeleteSqlFiles
```

Use MariaDB client tools explicitly:

```bash
./rename-mariadb-database.sh \
  -OldDb old_database_name \
  -NewDb new_database_name \
  -User root \
  -ClientExe /usr/bin/mariadb \
  -DumpExe /usr/bin/mariadb-dump
```

Use MySQL client tools explicitly:

```bash
./rename-mariadb-database.sh \
  -OldDb old_database_name \
  -NewDb new_database_name \
  -User root \
  -ClientExe /usr/bin/mysql \
  -DumpExe /usr/bin/mysqldump
```

Delete the old database after the import and verification query:

```bash
./rename-mariadb-database.sh -OldDb old_database_name -NewDb new_database_name -User root -DropOldDatabase
```

## Using the PowerShell script

Run it from PowerShell:

```powershell
.\rename-mariadb-database.ps1 -OldDb old_database_name -NewDb new_database_name -User root
```

With host and port:

```powershell
.\rename-mariadb-database.ps1 -OldDb old_database_name -NewDb new_database_name -User root -Host localhost -Port 3306
```

With an explicit dump file:

```powershell
.\rename-mariadb-database.ps1 -OldDb old_database_name -NewDb new_database_name -User root -DumpFile "C:\Temp\old_database_name.sql"
```

Create and import a compressed dump:

```powershell
.\rename-mariadb-database.ps1 -OldDb old_database_name -NewDb new_database_name -User root -CompressDump
```

Create a compressed dump with an explicit path:

```powershell
.\rename-mariadb-database.ps1 `
  -OldDb old_database_name `
  -NewDb new_database_name `
  -User root `
  -CompressDump `
  -DumpFile "C:\Temp\old_database_name.sql.gz"
```

Copy grants from the old database to the new database:

```powershell
.\rename-mariadb-database.ps1 -OldDb old_database_name -NewDb new_database_name -User root -CopyGrants
```

Copy grants and keep the generated grants SQL file at a specific path:

```powershell
.\rename-mariadb-database.ps1 `
  -OldDb old_database_name `
  -NewDb new_database_name `
  -User root `
  -CopyGrants `
  -GrantsFile "C:\Temp\copied-grants.sql"
```

Delete generated SQL files after a successful run:

```powershell
.\rename-mariadb-database.ps1 -OldDb old_database_name -NewDb new_database_name -User root -DeleteSqlFiles
```

Use MariaDB client tools explicitly:

```powershell
.\rename-mariadb-database.ps1 `
  -OldDb old_database_name `
  -NewDb new_database_name `
  -User root `
  -ClientExe "C:\Program Files\MariaDB 11.4\bin\mariadb.exe" `
  -DumpExe "C:\Program Files\MariaDB 11.4\bin\mariadb-dump.exe"
```

Use MySQL client tools explicitly:

```powershell
.\rename-mariadb-database.ps1 `
  -OldDb old_database_name `
  -NewDb new_database_name `
  -User root `
  -ClientExe "C:\Program Files\MySQL\MySQL Server 8.4\bin\mysql.exe" `
  -DumpExe "C:\Program Files\MySQL\MySQL Server 8.4\bin\mysqldump.exe"
```

Delete the old database after the import and verification query:

```powershell
.\rename-mariadb-database.ps1 -OldDb old_database_name -NewDb new_database_name -User root -DropOldDatabase
```

### PowerShell execution policy

If Windows blocks the script, allow script execution for the current PowerShell session only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Then run the script again.

## Compressed dump behavior

Use `-CompressDump` to store the dump as a gzip-compressed SQL file.

With `-CompressDump`:

- the default dump filename ends with `.sql.gz`;
- the dump is compressed while it is being created;
- the dump is decompressed automatically while it is being imported;
- the Bash script requires `gzip`;
- the PowerShell script uses .NET gzip streams and does not require an external compressor.

This avoids keeping a large uncompressed `.sql` dump on disk.

## MySQL compatibility

The scripts now support both MariaDB and MySQL.

The relevant changes are:

- `-ClientExe` replaces the previous MariaDB-specific client option;
- the scripts auto-detect `mariadb` first, then `mysql`;
- the dump tool auto-detection checks `mariadb-dump` first, then `mysqldump`;
- the temporary option file uses the `[client]` group, which is understood by both MariaDB and MySQL client tools;
- the dump command uses options supported by both MariaDB and MySQL dump tools: `--single-transaction`, `--routines`, `--triggers`, and `--events`;
- grant copying uses `information_schema.SCHEMA_PRIVILEGES`, `information_schema.TABLE_PRIVILEGES`, and `information_schema.COLUMN_PRIVILEGES`.

Use `-ClientExe` to select either a MariaDB or MySQL client explicitly.

## Grant-copying behavior

When `-CopyGrants` is used, the scripts generate a SQL file containing `GRANT` statements for the target database and then apply it.

The generated grants are based on:

- `information_schema.SCHEMA_PRIVILEGES`;
- `information_schema.TABLE_PRIVILEGES`;
- `information_schema.COLUMN_PRIVILEGES`.

This covers database-level, table-level, and column-level privileges that explicitly refer to the source database.

It does not copy:

- global privileges;
- roles themselves;
- user accounts themselves;
- privileges unrelated to the source database;
- privileges that are not exposed through the three `information_schema` privilege views listed above.

The generated grants file is kept on disk by default so that you can inspect what was applied. Use `-DeleteSqlFiles` to remove it automatically after a successful run.

## SQL file deletion behavior

When `-DeleteSqlFiles` is used, the scripts delete generated SQL files only after the complete operation succeeds.

The dump file, compressed or uncompressed, is deleted after:

- the new database is created;
- the dump is created;
- the dump is imported;
- table counts are shown;
- grants are copied, if `-CopyGrants` is used;
- the old database is dropped, if `-DropOldDatabase` is used.

The grants file is deleted only if it was generated during the current run.

If the script fails before the final cleanup step, the SQL files are kept.

## Important notes

### Stop application writes first

For production databases, stop application writes before running either script.

The scripts use `--single-transaction`, which is appropriate for transactional tables such as InnoDB, but it does not replace a proper maintenance window for busy production systems.

### Verify the new database before deleting the old one

Before deleting the original database, check at least:

- table counts;
- application connectivity;
- views;
- stored procedures and functions;
- triggers;
- events;
- user permissions.

### Character set and collation

The scripts create the new database with the server's default character set and collation.

If the source database uses a specific character set or collation, create the target database manually before running the import, or adapt the script to include the required character set and collation.

You can check the source database settings with:

```sql
SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME
FROM information_schema.SCHEMATA
WHERE SCHEMA_NAME = 'old_database_name';
```

### Password handling

Both scripts avoid passing the password directly on the command line.

The Bash script creates a temporary option file with `mktemp`, restricts it with `chmod 600`, and removes it when the script exits.

The PowerShell script creates a temporary option file, tries to restrict it to the current Windows user, and removes it when the script exits.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
