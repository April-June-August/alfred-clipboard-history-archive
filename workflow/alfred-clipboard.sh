#!/usr/bin/env bash
# This is a script that provides infinite history to get around Alfred’s 3-month limit.
# It works by regularly backing up and appending the items in the alfred db to a
# sqlite database in the workflow’s data folder.

shopt -s extglob
set +o pipefail

# Config Options
ALFRED_DATA_DIR="${ALFRED_DATA_DIR:-$HOME/Library/Application Support/Alfred/Databases}"
ALFRED_DB_NAME="${ALFRED_DB_NAME:-clipboard.alfdb}"
BACKUP_DB_NAME="${BACKUP_DB_NAME:-$(date +'%Y-%m-%d_%H:%M:%S').sqlite3}"
MASTER_DB_NAME="${MASTER_DB_NAME:-all.sqlite3}"



number_of_backed_up_rows=0
existing_rows=0
merged_rows=0

function backup_alfred_db {
    echo "⏳️ Backing up Alfred Clipboard History DB..." >&2
    cp "$ALFRED_DB" "$BACKUP_DB"
    number_of_backed_up_rows=$(sqlite3 "$BACKUP_DB" 'select count(*) from clipboard;')
    echo "    ✔️ Read     $number_of_original_rows items from $ALFRED_DB_NAME" >&2
    echo "    ✔️ Wrote    $number_of_backed_up_rows items to $BACKUP_DB_NAME" >&2
}

function init_master_db {
    echo -e "\n⏳️ Initializing new clipboard database with $number_of_backed_up_rows items..." >&2
    cp "$BACKUP_DB" "$MASTER_DB"
    echo "    ✔️ Copied new db $MASTER_DB" >&2
    echo >&2
    sqlite3 "$MASTER_DB" ".schema" | sed 's/^/    /' >&2
}

function update_master_db {
    echo -e "\n⏳️ Updating Master Clipboard History DB..." >&2
    existing_rows=$(sqlite3 "$MASTER_DB" 'select count(*) from clipboard;')

    echo "    ✔️ Read     $existing_rows existing items from "$(basename "$MASTER_DB") >&2
    
    local MERGE_QUERY="
        /* Delete any items that are the same in both databases */
        DELETE FROM master_db.clipboard
        WHERE item IN (SELECT item FROM latest_db.clipboard);

        /* Insert all items from the latest_db backup  */
        INSERT INTO master_db.clipboard
        SELECT * FROM latest_db.clipboard;
    "
    
    sqlite3 "$MASTER_DB" "
        attach '$MASTER_DB' as master_db;
        attach '$BACKUP_DB' as latest_db;
        BEGIN;
        $MERGE_QUERY
        COMMIT;
        detach latest_db;
        detach master_db;
    "
    master_rows=$(sqlite3 "$MASTER_DB" 'select count(*) from clipboard;')
    new_rows=$(( master_rows - existing_rows ))
    echo "    ✔️ Incoming $number_of_backed_up_rows items from backup you just created to $MASTER_DB_NAME" >&2
    echo "    ✔️ Merged   $new_rows new items to Master DB" >&2
}

function summary {
    number_of_backed_up_rows=$(sqlite3 "$BACKUP_DB" 'select count(*) from clipboard;')
    existing_rows=$(sqlite3 "$MASTER_DB" 'select count(*) from clipboard;')
    master_rows=$(sqlite3 "$MASTER_DB" 'select count(*) from clipboard;')
    echo "    Original   $ALFRED_DB ($number_of_original_rows items)" >&2
    echo "    Backup     $BACKUP_DB ($number_of_backed_up_rows items)" >&2
    echo "    Master     $MASTER_DB ($master_rows items)" >&2
}

function status {
    echo "🎩 Alfred: $ALFRED_DB ($number_of_original_rows items)" >&2
    if [[ -f "$MASTER_DB" ]]; then
        master_rows=$(sqlite3 "$MASTER_DB" 'select count(*) from clipboard;')
        backup_count=$(find "$BACKUP_DATA_DIR" -name "*.sqlite3" ! -name "all.sqlite3" 2>/dev/null | wc -l)
        echo "💾 Master: $MASTER_DB ($master_rows items)" >&2
        echo "📦 Backups: $backup_count total backups created" >&2
        ./notificator --message "Alfred: $number_of_original_rows items | Archive: $master_rows items | $backup_count backups found." --title "Clipboard Archive Status"
    else
        backup_keyword="${history_archive_keyword:-clipboardarchive}"
        echo "💾 Master: No backup data found in $BACKUP_DATA_DIR" >&2
        echo "" >&2
        echo "Please create a backup first by typing ‘$backup_keyword’ in Alfred." >&2
        ./notificator --message "No backup found. Create one with ‘$backup_keyword’" --title "Clipboard Status"
    fi
}

function backup {
    backup_alfred_db
    if [[ -f "$MASTER_DB" ]]; then
        existing_rows_before=$(sqlite3 "$MASTER_DB" 'select count(*) from clipboard;')
        update_master_db
        master_rows=$(sqlite3 "$MASTER_DB" 'select count(*) from clipboard;')
        new_rows=$(( master_rows - existing_rows_before ))
        ./notificator --message "✅ Backup complete: +$new_rows new items ($master_rows total)" --title "Clipboard Archive"
    else
        init_master_db
        master_rows=$(sqlite3 "$MASTER_DB" 'select count(*) from clipboard;')
        ./notificator --message "✅ Backup complete: $master_rows items in new archive" --title "Clipboard Archive"
    fi

    echo -e "\n✅️ Done backing up clipboard history." >&2
    summary
}

function main {
    COMMAND=''
    BACKUP_DATA_DIR=''

    while (( "$#" )); do
        case "$1" in
            -d|--directory|-d=*|--directory=*)
                if [[ "$1" == *'='* ]]; then
                    BACKUP_DATA_DIR="${1#*=}"
                else
                    shift
                    BACKUP_DATA_DIR="$1"
                fi
                shift;;
            +([a-z]))
                COMMAND="$1"
                shift;;
            *)
                echo "Error: Unrecognized argument $1" >&2
                exit 2;;
        esac
    done

    if [ ! -d "$BACKUP_DATA_DIR" ]; then
        mkdir -p "$BACKUP_DATA_DIR"
    fi

    ALFRED_DB="$ALFRED_DATA_DIR/$ALFRED_DB_NAME"
    BACKUP_DB="$BACKUP_DATA_DIR/$BACKUP_DB_NAME"
    MASTER_DB="$BACKUP_DATA_DIR/$MASTER_DB_NAME"

    number_of_original_rows=$(sqlite3 "$ALFRED_DB" 'select count(*) from clipboard;')

    if [[ "$COMMAND" == "status" ]]; then
        status
    elif [[ "$COMMAND" == "backup" ]]; then
        backup
    else
        echo "Error: Unrecognized command $COMMAND" >&2
        exit 2
    fi
}

main "$@"