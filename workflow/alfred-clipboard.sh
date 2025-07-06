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
MERGED_DB_NAME="${MERGED_DB_NAME:-all.sqlite3}"


# clipboard timestamps are in Mac epoch format (Mac epoch started on 1/1/2001, not 1/1/1970)
# to convert them to standard UTC UNIX timestamps, add 978307200

number_of_backed_up_rows=0
existing_rows=0
merged_rows=0

function backup_alfred_db {
    echo "⏳️ Backing up Alfred Clipboard History DB..."
    cp "$ALFRED_DB" "$BACKUP_DB"
    number_of_backed_up_rows=$(sqlite3 "$BACKUP_DB" 'select count(*) from clipboard;')
    echo "    ✔️ Read     $number_of_original_rows items from $ALFRED_DB_NAME"
    echo "    ✔️ Wrote    $number_of_backed_up_rows items to $BACKUP_DB_NAME"
}

function init_master_db {
    echo -e "\n⏳️ Initializing new clipboard database with $number_of_backed_up_rows items..."
    cp "$BACKUP_DB" "$MERGED_DB"
    echo "    ✔️ Copied new db $MERGED_DB"
    echo
    sqlite3 "$MERGED_DB" ".schema" | sed 's/^/    /'
}

function update_master_db {
    echo -e "\n⏳️ Updating Master Clipboard History DB..."
    existing_rows=$(sqlite3 "$MERGED_DB" 'select count(*) from clipboard;')

    echo "    ✔️ Read     $existing_rows existing items from "$(basename "$MERGED_DB")
    
    local MERGE_QUERY="
        /* Delete any items that are the same in both databases */
        DELETE FROM merged_db.clipboard
        WHERE item IN (SELECT item FROM latest_db.clipboard);

        /* Insert all items from the latest_db backup  */
        INSERT INTO merged_db.clipboard
        SELECT * FROM latest_db.clipboard;
    "
    
    sqlite3 "$MERGED_DB" "
        attach '$MERGED_DB' as merged_db;
        attach '$BACKUP_DB' as latest_db;
        BEGIN;
        $MERGE_QUERY
        COMMIT;
        detach latest_db;
        detach merged_db;
    "
    merged_rows=$(sqlite3 "$MERGED_DB" 'select count(*) from clipboard;')
    new_rows=$(( merged_rows - existing_rows ))
    echo "    ✔️ Incoming $number_of_backed_up_rows items from backup you just created to $MERGED_DB_NAME"
    echo "    ✔️ Merged   $new_rows new items to Master DB"
}

function summary {
    number_of_backed_up_rows=$(sqlite3 "$BACKUP_DB" 'select count(*) from clipboard;')
    existing_rows=$(sqlite3 "$MERGED_DB" 'select count(*) from clipboard;')
    merged_rows=$(sqlite3 "$MERGED_DB" 'select count(*) from clipboard;')
    echo "    Original   $ALFRED_DB ($number_of_original_rows items)"
    echo "    Backup     $BACKUP_DB ($number_of_backed_up_rows items)"
    echo "    Master     $MERGED_DB ($merged_rows items)"
}

function status {
    echo "🎩 Alfred: $ALFRED_DB ($number_of_original_rows items)"
    if [[ -f "$MERGED_DB" ]]; then
        merged_rows=$(sqlite3 "$MERGED_DB" 'select count(*) from clipboard;')
        echo "💾 Master: $MERGED_DB ($merged_rows items)"
    else
        backup_keyword="${history_archive_keyword:-clipboardarchive}"
        echo "💾 Master: No backup data found in $BACKUP_DATA_DIR"
        echo ""
        echo "Please create a backup first by typing '$backup_keyword' in Alfred."
    fi
}

function backup {
    backup_alfred_db
    if [[ -f "$MERGED_DB" ]]; then
        update_master_db
    else
        init_master_db
    fi

    echo -e "\n✅️ Done backing up clipboard history."
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
    MERGED_DB="$BACKUP_DATA_DIR/$MERGED_DB_NAME"

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