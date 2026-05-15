# MariaDB Database Rename Scripts

This repository contains two scripts to safely "rename" a MariaDB database:

- `rename-mariadb-database.sh` for Linux, macOS, and other Unix-like systems
- `rename-mariadb-database.ps1` for Windows PowerShell

MariaDB does not provide a direct `RENAME DATABASE` command. These scripts therefore use a dump-and-restore workflow:

1. Create a new database.
2. Dump the existing database.
3. Import the dump into the new database.
4. Show a table-count comparison.
5. Let you verify the result before deleting the original database.

## Repository files

| File | Platform | Purpose |
| --- | --- | --- |
| `rename-mariadb-database.sh` | Linux, macOS, Unix-like systems | Bash script |
| `rename-mariadb-database.ps1` | Windows | PowerShell script |


## What the scripts do

Both scripts:

- use the same command-line options;
- ask for the MariaDB password only once;
- avoid passing the password directly on the command line;
- create a temporary MariaDB option file;
- create the target database;
- dump the source database;
- include tables, data, routines, triggers, and events;
- import the dump into the target database;
- show a table-count comparison between the source and target databases;
- keep the original database unless deletion is explicitly enabled.

## Requirements

### Common requirements

You need:

- access to a MariaDB server;
- MariaDB client tools installed;
- a MariaDB user with privileges to:
  - create databases;
  - dump the source database;
  - import data into the target database;
  - read routines, triggers, and events;
  - optionally drop the old database.

On some systems, the dump tool may be called `mysqldump` instead of `mariadb-dump`.

### Bash requirements

For `rename-mariadb-database.sh`:

- Bash
- `mariadb`
- `mariadb-dump`, or `mysqldump` as a fallback

### PowerShell requirements

For `rename-mariadb-database.ps1`:

- PowerShell
- `mariadb.exe`
- `mariadb-dump.exe`, or `mysqldump.exe` as a fallback

## Command-line options

Both scripts support the same database-renaming options.

| Option | Required | Default | Description |
| --- | --- | --- | --- |
| `-OldDb` | Yes | | Source database name |
| `-NewDb` | Yes | | Target database name |
| `-User` | No | `root` | MariaDB user |
| `-Host` | No | `localhost` | MariaDB host |
| `-Port` | No | `3306` | MariaDB port |
| `-DumpFile` | No | Timestamped SQL file | Path of the SQL dump file to create |
| `-MariaDbExe` | No | `mariadb` / `mariadb.exe` | Path to the MariaDB client |
| `-DumpExe` | No | Auto-detected | Path to `mariadb-dump`, `mariadb-dump.exe`, `mysqldump`, or `mysqldump.exe` |
| `-DropOldDatabase` | No | Disabled | Drops the source database after import and verification query |

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

With explicit MariaDB client paths:

```bash
./rename-mariadb-database.sh \
  -OldDb old_database_name \
  -NewDb new_database_name \
  -User root \
  -MariaDbExe /usr/bin/mariadb \
  -DumpExe /usr/bin/mariadb-dump
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

With explicit MariaDB client paths:

```powershell
.\rename-mariadb-database.ps1 `
  -OldDb old_database_name `
  -NewDb new_database_name `
  -User root `
  -MariaDbExe "C:\Program Files\MariaDB 11.4\bin\mariadb.exe" `
  -DumpExe "C:\Program Files\MariaDB 11.4\bin\mariadb-dump.exe"
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

### Grants are not renamed automatically

Database-specific grants for the old database are not automatically transferred to the new database.

For example, a grant on `old_database_name.*` does not automatically become a grant on `new_database_name.*`.

Check grants after migration:

```sql
SHOW GRANTS FOR 'user'@'host';
```

Then recreate the required grants for the new database if needed.

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
