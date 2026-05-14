#!/bin/bash

# cleaner - macOS app uninstaller
# Removes apps and all the junk they leave behind

VERSION="0.7.0"

KEY=""
MENU_RESULT=-1
SPINNER_PID=""
MENU_ITEMS=()
MENU_HEADERS=()
MENU_SUBTITLE=""
MENU_COMPACT=0   # 1 = skip logo, show one-line header only
MENU_MULTI=0     # 1 = space toggles checkboxes; Enter with ≥1 checked → MENU_RESULT=-2
MENU_SELECTABLE=() # parallel to MENU_ITEMS: 1 = item can be checked, 0 = cannot
MENU_CHECKED=()    # parallel to MENU_ITEMS: 1 = checked

SEARCH_PATHS=(
    "$HOME/Library/Application Support"
    "$HOME/Library/Application Scripts"
    "$HOME/Library/Caches"
    "$HOME/Library/Preferences"
    "$HOME/Library/HTTPStorages"
    "$HOME/Library/Cookies"
    "$HOME/Library/WebKit"
    "$HOME/Library/Saved Application State"
    "$HOME/Library/Logs"
    "$HOME/Library/Containers"
    "$HOME/Library/Group Containers"
    "$HOME/Library/LaunchAgents"
    "$HOME/Library/PreferencePanes"
    "$HOME/Library/Internet Plug-Ins"
    "/Library/LaunchAgents"
    "/Library/LaunchDaemons"
    "/Library/Application Support"
    "/Library/Preferences"
    "/Library/Caches"
    "/Library/PrivilegedHelperTools"
    "/private/var/db/receipts"
)

ORPHAN_SCAN_PATHS=(
    "$HOME/Library/Application Support"
    "$HOME/Library/Caches"
    "$HOME/Library/Containers"
    "$HOME/Library/Logs"
    "$HOME/Library/Saved Application State"
)

# ---------------------------------------------------------------------------
# cross-cutting: input — all interactive screens use read_key(), never raw read
# ---------------------------------------------------------------------------
read_key() {
    local key esc bracket
    IFS= read -r -s -n1 key
    if [[ "$key" == $'\x1b' ]]; then
        IFS= read -r -s -n1 -t 1 esc || true
        if [[ "$esc" == "[" ]]; then
            IFS= read -r -s -n1 -t 1 bracket || true
            case "$bracket" in
                A) KEY="UP";    return ;;
                B) KEY="DOWN";  return ;;
            esac
        fi
        KEY="ESC"; return
    fi
    if [[ "$key" == "" || "$key" == $'\n' || "$key" == $'\r' ]]; then
        KEY="ENTER"; return
    fi
    KEY="$key"
}

# ---------------------------------------------------------------------------
# cross-cutting: spinner — used in review screens while find_leftovers() runs
# ---------------------------------------------------------------------------
start_spinner() {
    local msg="$1"
    tput civis 2>/dev/null
    (
        local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        local n=${#frames}
        local i=0
        while true; do
            local c="${frames:$((i % n)):1}"
            printf "\r  \033[0;36m%s\033[0m  %s" "$c" "$msg" >&2
            sleep 0.1
            ((i++))
        done
    ) &
    SPINNER_PID=$!
}

stop_spinner() {
    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null
        SPINNER_PID=""
        printf "\r\033[K" >&2
        tput cnorm 2>/dev/null
    fi
}

# ---------------------------------------------------------------------------
# cross-cutting: TUI menu engine
#   Reads:  MENU_ITEMS[], MENU_HEADERS[], MENU_SUBTITLE, MENU_COMPACT
#   Writes: MENU_RESULT (selected index, or -1 if quit/ESC)
#   Uses alternate screen + absolute cursor positioning (no tput cuu drift).
#   All interactive screens (SCREEN 1, 2) go through draw_menu().
# ---------------------------------------------------------------------------

# Pre-compute for each item index how many terminal rows it occupies above it
# (due to section headers). Stored in _ITEM_ROW[i] = row offset within list area.
_build_item_rows() {
    local count=${#MENU_ITEMS[@]}
    _ITEM_ROW=()
    local row=0
    local i=0
    while [[ $i -lt $count ]]; do
        if [[ -n "${MENU_HEADERS[$i]:-}" ]]; then
            row=$((row + 4))  # blank + line + header text + line
        fi
        _ITEM_ROW+=($row)
        row=$((row + 1))
        ((i++))
    done
    _TOTAL_LIST_ROWS=$row
}

draw_menu() {
    local count=${#MENU_ITEMS[@]}
    local selected=0
    local viewport_offset=0  # first item index visible in viewport

    # init checked state
    local checked=()
    local i=0
    while [[ $i -lt $count ]]; do
        checked+=("${MENU_CHECKED[$i]:-0}")
        ((i++))
    done

    _ITEM_ROW=()
    _build_item_rows

    tput smcup 2>/dev/null
    tput civis 2>/dev/null

    local HINT_ROWS=2   # blank line + hint line
    local HEADER_ROWS
    if [[ $MENU_COMPACT -eq 1 ]]; then
        HEADER_ROWS=2  # blank + one-line header
        [[ -n "$MENU_SUBTITLE" ]] && HEADER_ROWS=$((HEADER_ROWS + 1))
    else
        # _print_header_inline: 9 lines; +1 for subtitle if set
        HEADER_ROWS=9
        [[ -n "$MENU_SUBTITLE" ]] && HEADER_ROWS=$((HEADER_ROWS + 1))
    fi

    while true; do
        local term_rows
        term_rows=$(stty size 2>/dev/null | cut -d' ' -f1)
        [[ -z "$term_rows" || ! "$term_rows" =~ ^[0-9]+$ ]] && term_rows=$(tput lines 2>/dev/null)
        [[ -z "$term_rows" || ! "$term_rows" =~ ^[0-9]+$ ]] && term_rows=40
        local list_rows=$((term_rows - HEADER_ROWS - HINT_ROWS))
        [[ $list_rows -lt 3 ]] && list_rows=3

        # Adjust viewport so selected item is always visible
        local sel_row=${_ITEM_ROW[$selected]}
        # account for section header above selected item
        local sel_display_row=$sel_row
        if [[ -n "${MENU_HEADERS[$selected]:-}" ]]; then
            sel_display_row=$((sel_row - 4))
        fi

        # scroll down if selected is below viewport
        if [[ $((sel_display_row - viewport_offset)) -ge $list_rows ]]; then
            viewport_offset=$((sel_display_row - list_rows + 1))
        fi
        # scroll up if selected is above viewport
        if [[ $((sel_display_row - viewport_offset)) -lt 0 ]]; then
            viewport_offset=$sel_display_row
        fi

        # count checked items
        local n_checked=0
        local j=0
        while [[ $j -lt $count ]]; do
            [[ "${checked[$j]}" == "1" ]] && ((n_checked++))
            ((j++))
        done

        # Render
        tput cup 0 0 2>/dev/null
        tput ed 2>/dev/null
        if [[ $MENU_COMPACT -eq 1 ]]; then
            printf "\n  \033[1;36mMAC APP CLEANER\033[0m  \033[2mv%s\033[0m" "$VERSION"
            [[ -n "$MENU_SUBTITLE" ]] && printf "  \033[2m·  %s\033[0m" "$MENU_SUBTITLE"
            printf "\n"
        else
            _print_header_inline
            [[ -n "$MENU_SUBTITLE" ]] && printf "  \033[2m%s\033[0m\n" "$MENU_SUBTITLE"
        fi

        # Print only items whose rows fall within [viewport_offset, viewport_offset+list_rows)
        local i=0
        local rendered=0
        while [[ $i -lt $count ]]; do
            local item_row=${_ITEM_ROW[$i]}
            # print section header if it falls in viewport
            if [[ -n "${MENU_HEADERS[$i]:-}" ]]; then
                local hdr_start=$((item_row - 4))
                if [[ $hdr_start -ge $viewport_offset && $((hdr_start + 3)) -lt $((viewport_offset + list_rows)) ]]; then
                    printf "\n"
                    printf "  \033[0;36m─────────────────────────────────────────────────────────\033[0m\n"
                    printf "  \033[1;37m%s\033[0m\n" "${MENU_HEADERS[$i]}"
                    printf "  \033[0;36m─────────────────────────────────────────────────────────\033[0m\n"
                    rendered=$((rendered + 4))
                elif [[ $hdr_start -lt $viewport_offset && $item_row -ge $viewport_offset ]]; then
                    : # header partly scrolled off, item still visible — skip header
                fi
            fi
            if [[ $item_row -ge $viewport_offset && $item_row -lt $((viewport_offset + list_rows)) ]]; then
                local selectable="${MENU_SELECTABLE[$i]:-0}"
                local chk_prefix=""
                if [[ $MENU_MULTI -eq 1 && "$selectable" == "1" ]]; then
                    [[ "${checked[$i]}" == "1" ]] && chk_prefix="\033[0;32m[x]\033[0m " || chk_prefix="\033[2m[ ]\033[0m "
                fi
                if [[ $i -eq $selected ]]; then
                    printf "  \033[0;36m▶\033[0m ${chk_prefix}\033[1;37m%s\033[0m\n" "${MENU_ITEMS[$i]}"
                else
                    printf "    ${chk_prefix}\033[0;37m%s\033[0m\n" "${MENU_ITEMS[$i]}"
                fi
                rendered=$((rendered + 1))
            fi
            ((i++))
        done

        # Hint line
        if [[ $_TOTAL_LIST_ROWS -gt $list_rows ]]; then
            local pct=$(( (viewport_offset * 100) / (_TOTAL_LIST_ROWS - list_rows + 1) ))
            if [[ $MENU_MULTI -eq 1 && $n_checked -gt 0 ]]; then
                printf "\n  \033[2m↑↓  Space toggle  Enter trash %d selected  q back    %d%%\033[0m\n" "$n_checked" "$pct"
            elif [[ $MENU_MULTI -eq 1 ]]; then
                printf "\n  \033[2m↑↓  Space select  Enter open  q back    %d%%\033[0m\n" "$pct"
            else
                printf "\n  \033[2m↑↓  Enter  q back    %d%%\033[0m\n" "$pct"
            fi
        else
            if [[ $MENU_MULTI -eq 1 && $n_checked -gt 0 ]]; then
                printf "\n  \033[2m↑↓  Space toggle  Enter trash %d selected  q back\033[0m\n" "$n_checked"
            elif [[ $MENU_MULTI -eq 1 ]]; then
                printf "\n  \033[2m↑↓  Space select  Enter open  q back\033[0m\n"
            else
                printf "\n  \033[2m↑↓  Enter  q back\033[0m\n"
            fi
        fi

        read_key
        case "$KEY" in
            UP)   [[ $selected -gt 0 ]] && ((selected--)) ;;
            DOWN) [[ $selected -lt $((count-1)) ]] && ((selected++)) ;;
            " ")
                if [[ $MENU_MULTI -eq 1 && "${MENU_SELECTABLE[$selected]:-0}" == "1" ]]; then
                    [[ "${checked[$selected]}" == "1" ]] && checked[$selected]=0 || checked[$selected]=1
                fi
                ;;
            ENTER)
                tput cnorm 2>/dev/null
                tput rmcup 2>/dev/null
                if [[ $MENU_MULTI -eq 1 && $n_checked -gt 0 ]]; then
                    MENU_CHECKED=("${checked[@]}")
                    MENU_RESULT=-2
                else
                    MENU_RESULT=$selected
                fi
                return 0
                ;;
            q|Q|ESC)
                tput cnorm 2>/dev/null
                tput rmcup 2>/dev/null
                MENU_RESULT=-1
                return 1
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# cross-cutting: progress bar — used by run_scan() during SCREEN 2 load
# ---------------------------------------------------------------------------
show_progress() {
    local step=$1 total=$2 msg="$3"
    local width=20
    local filled=$(( step * width / total ))
    local bar="" i=0
    while [[ $i -lt $width ]]; do
        [[ $i -lt $filled ]] && bar="${bar}█" || bar="${bar}░"
        ((i++))
    done
    printf "\r  \033[0;36m[%s]\033[0m  %s  \033[2m%d/%d\033[0m" "$bar" "$msg" "$step" "$total" >&2
}

clear_progress() {
    printf "\r\033[K" >&2
}

# ---------------------------------------------------------------------------
# cross-cutting: display utilities
#   to_lower         — bash 3.2 compat lowercase (no ${var,,})
#   trap             — restore terminal (cursor, alt screen, spinner) on INT/TERM/EXIT
#   _print_header_inline — ASCII logo, no clear; used by draw_menu + non-interactive screens
#   print_header     — clear + logo; used by non-interactive / about screen
#   print_section    — ─── section divider; used by SCREEN 3a/3b/3c and CLI output
# ---------------------------------------------------------------------------
to_lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

_restore_term() {
    [[ -n "$SPINNER_PID" ]] && kill "$SPINNER_PID" 2>/dev/null
    tput cnorm 2>/dev/null
    tput rmcup 2>/dev/null
}
_FAREWELL_DONE=0
_farewell() {
    [[ $_FAREWELL_DONE -eq 1 ]] && return
    _FAREWELL_DONE=1
    printf "\n  \033[0;36msee you! 🤓\033[0m  \033[2mhttps://github.com/rblyz/mac-app-cleaner\033[0m\n\n"
}
trap '_restore_term; _farewell; exit 130' INT TERM
trap '_restore_term; _farewell' EXIT

_pad() {
    local s="$1" max="$2"
    local chars=${#s}
    if [[ $chars -gt $max ]]; then
        printf '%s..' "${s:0:$((max-2))}"
    else
        printf '%s%*s' "$s" $((max - chars)) ""
    fi
}

_print_header_inline() {
    echo ""
    printf "  \033[1m\033[0;36m ██████╗██╗     ███████╗ █████╗ ███╗   ██╗███████╗██████╗\033[0m\n"
    printf "  \033[1m\033[0;36m██╔════╝██║     ██╔════╝██╔══██╗████╗  ██║██╔════╝██╔══██╗\033[0m\n"
    printf "  \033[1m\033[0;36m██║     ██║     █████╗  ███████║██╔██╗ ██║█████╗  ██████╔╝\033[0m\n"
    printf "  \033[1m\033[0;36m██║     ██║     ██╔══╝  ██╔══██║██║╚██╗██║██╔══╝  ██╔══██╗\033[0m\n"
    printf "  \033[1m\033[0;36m╚██████╗███████╗███████╗██║  ██║██║ ╚████║███████╗██║  ██║\033[0m\n"
    printf "  \033[1m\033[0;36m ╚═════╝╚══════╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝\033[0m\n"
    printf "  \033[0;36mmac app cleaner · v%s · trashes apps and the junk they leave\033[0m\n" "$VERSION"
    echo ""
}

print_header() {
    clear
    _print_header_inline
}

print_section() {
    echo ""
    printf "  \033[0;36m─────────────────────────────────────────────────────────\033[0m\n"
    printf "  \033[1;37m%s\033[0m\n" "$*"
    printf "  \033[0;36m─────────────────────────────────────────────────────────\033[0m\n"
    echo ""
}

move_to_trash() {
    local item="$1"
    [[ -z "$item" || "$item" == "/" || ! -e "$item" ]] && return 1
    local escaped
    escaped=$(printf '%s' "$item" | sed 's/\\/\\\\/g; s/"/\\"/g')
    osascript -e "tell application \"Finder\" to delete POSIX file \"$escaped\"" >/dev/null 2>&1
    [[ ! -e "$item" ]]
}

get_shell_rc() {
    case "$SHELL" in
        */zsh)  echo "$HOME/.zshrc" ;;
        */bash) echo "$HOME/.bashrc" ;;
        *)      echo "$HOME/.profile" ;;
    esac
}

is_installed_in_shell() {
    local rc_file
    rc_file=$(get_shell_rc)
    [[ -f "$rc_file" ]] && grep -q "alias cleaner=" "$rc_file" 2>/dev/null
}

install_to_shell() {
    local rc_file
    rc_file=$(get_shell_rc)
    local script_path
    script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    if is_installed_in_shell; then
        printf "  \033[0;32m✓\033[0m  already installed in \033[0;36m%s\033[0m\n" "$rc_file"
        return
    fi
    echo "" >> "$rc_file"
    echo "# cleaner - macOS app uninstaller" >> "$rc_file"
    echo "alias cleaner=\"$script_path\"" >> "$rc_file"
    printf "  \033[0;32m✓\033[0m  installed — added alias to \033[0;36m%s\033[0m\n" "$rc_file"
    printf "  restart your terminal or run:  \033[1msource %s\033[0m\n" "$rc_file"
}

# ---------------------------------------------------------------------------
# data layer: app discovery, leftover search, orphan grouping
# ---------------------------------------------------------------------------

get_bundle_id() {
    local id
    id=$(mdls -name kMDItemCFBundleIdentifier -raw "$1" 2>/dev/null)
    if [[ -n "$id" && "$id" != "(null)" ]]; then
        echo "$id"
        return
    fi
    local plist="$1/Contents/Info.plist"
    [[ -f "$plist" ]] && /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null || echo ""
}

get_app_name() { basename "$1" .app; }

scan_applications() {
    local results
    results=$(mdfind "kMDItemContentType == 'com.apple.application-bundle'" 2>/dev/null \
        | grep -E "^(/Applications|$HOME/Applications)/")
    if [[ -n "$results" ]]; then
        printf '%s\n' "$results"
    else
        find /Applications -name "*.app" -type d -prune 2>/dev/null
        [[ -d ~/Applications ]] && find ~/Applications -name "*.app" -type d -prune 2>/dev/null
    fi
}

find_leftovers() {
    local app_path="$1"
    local app_name bundle_id
    app_name=$(get_app_name "$app_path")
    bundle_id=$(get_bundle_id "$app_path")
    local patterns=()
    [[ -n "$bundle_id" ]] && patterns+=("$bundle_id")
    [[ -n "$app_name" ]] && patterns+=("$app_name")
    local leftovers=()
    for search_path in "${SEARCH_PATHS[@]}"; do
        [[ ! -d "$search_path" ]] && continue
        for pattern in "${patterns[@]}"; do
            while IFS= read -r -d '' found; do
                local dup=0
                for e in "${leftovers[@]}"; do [[ "$e" == "$found" ]] && dup=1 && break; done
                [[ $dup -eq 0 ]] && leftovers+=("$found")
            done < <(find "$search_path" -maxdepth 2 -iname "*$pattern*" -print0 2>/dev/null)
        done
    done

    # Drop entries that are nested under another entry (parent folder will trash children).
    local filtered=() a b nested
    for a in "${leftovers[@]}"; do
        nested=0
        for b in "${leftovers[@]}"; do
            [[ "$a" == "$b" ]] && continue
            [[ "$a" == "$b"/* ]] && nested=1 && break
        done
        [[ $nested -eq 0 ]] && filtered+=("$a")
    done
    printf '%s\n' "${filtered[@]}"
}

build_app_index() {
    while IFS= read -r app; do
        [[ -z "$app" ]] && continue
        local name bundle_id
        name=$(get_app_name "$app")
        local nl
        nl=$(to_lower "$name")
        echo "$nl"
        echo "$nl" | tr -d ' '
        local word
        for word in $nl; do
            [[ ${#word} -ge 4 ]] && echo "$word"
        done
        bundle_id=$(get_bundle_id "$app")
        if [[ -n "$bundle_id" ]]; then
            to_lower "$bundle_id"
            echo "$bundle_id" | cut -d'.' -f1-2 | tr '[:upper:]' '[:lower:]'
            echo "$bundle_id" | cut -d'.' -f2  | tr '[:upper:]' '[:lower:]'
            echo "$bundle_id" | cut -d'.' -f3  | tr '[:upper:]' '[:lower:]'
        fi
    done < <(scan_applications)
}

is_installed_app() {
    local candidate index_file substr_file
    candidate=$(to_lower "$1")
    index_file="$2"
    substr_file="${3:-}"

    # exact match
    grep -qxiF "$candidate" "$index_file" 2>/dev/null && return 0

    # bundle ID fragment (contains dot)
    case "$candidate" in
        *.*) grep -qiF "$candidate" "$index_file" 2>/dev/null && return 0 ;;
    esac

    # multi-word label: any word ≥4 chars matches an index entry exactly
    # "Telegram Desktop" → "telegram" found → matched
    local word
    for word in $candidate; do
        [[ ${#word} -lt 4 ]] && continue
        grep -qxiF "$word" "$index_file" 2>/dev/null && return 0
    done

    # index entry is substring of candidate (not the other way around — avoids false positives)
    # "resilio" in index → found inside "resilio sync" → matched
    # "code" in candidate → NOT searched inside "visualstudiocode" index entry
    if [[ -n "$substr_file" && -s "$substr_file" ]]; then
        grep -qiFf "$substr_file" <<< "$candidate" 2>/dev/null && return 0
    fi

    return 1
}

is_system_name() {
    local name
    name=$(to_lower "$1")
    case "$name" in
        com.apple*|apple|.ds_store) return 0 ;;
        crashreporter|diagnostics*|siri*|spotlight|dock|finder) return 0 ;;
        safari|mail|facetime|notes|reminders|calendar|contacts) return 0 ;;
        addressbook|animoji|automator|clouddocs|diskimages) return 0 ;;
        callhistory*|networkservice*|fileprovider|knowledge) return 0 ;;
        differentialprivacy|cef|electron*) return 0 ;;
        cloudkit|energykit|gamekit|familycircle*|jetpackcache) return 0 ;;
        passkit|privacypreservingmeasurement|smsmigrator) return 0 ;;
        baseband|assistant|discrecording*|ngl|minilauncher) return 0 ;;
        photos*|installation|geoservices|icloud|icdd) return 0 ;;
        homebrew|sentryscrash|sentrycrash|askpermissiond) return 0 ;;
        homeenergyd|locationaccessstored|mbuseragent) return 0 ;;
        *.log|*.aapbz|*.aapbz.old|*.png|*.jpg) return 0 ;;
        *) return 1 ;;
    esac
}

# Outputs: "label<TAB>path1|path2|..."
find_orphans() {
    local index_file substr_file groups_file
    index_file=$(mktemp /tmp/cleaner_index.XXXXXX)
    substr_file=$(mktemp /tmp/cleaner_substr.XXXXXX)
    groups_file=$(mktemp /tmp/cleaner_groups.XXXXXX)

    build_app_index > "$index_file"
    # substr_file: index entries used as substring matches against orphan candidates.
    # Min 6 chars (shorter ones cause false positives like "mail" → gmail) and
    # exclude entries that look like system names (apple/electron/helper noise).
    while IFS= read -r entry; do
        [[ ${#entry} -lt 6 ]] && continue
        is_system_name "$entry" && continue
        echo "$entry"
    done < "$index_file" > "$substr_file"

    for scan_path in "${ORPHAN_SCAN_PATHS[@]}"; do
        [[ ! -d "$scan_path" ]] && continue
        while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            local label
            label=$(basename "$entry")
            label="${label%.plist}"; label="${label%.savedState}"; label="${label%.app}"
            is_system_name "$label" && continue
            is_installed_app "$label" "$index_file" "$substr_file" && continue
            echo "$label	$entry" >> "$groups_file"
        done < <(find "$scan_path" -maxdepth 1 -mindepth 1 2>/dev/null)
    done

    # /opt/* directories — dev environments (anaconda, R, etc.) excluding homebrew itself
    if [[ -d /opt ]]; then
        while IFS= read -r entry; do
            local label
            label=$(basename "$entry")
            [[ "$label" == "homebrew" ]] && continue
            echo "$label	$entry" >> "$groups_file"
        done < <(find /opt -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
    fi

    # /opt/homebrew/var/* — data dirs for db services (mysql, redis, etc.)
    # only include if the corresponding formula is NOT currently installed
    if [[ -d /opt/homebrew/var ]]; then
        while IFS= read -r entry; do
            local label
            label=$(basename "$entry")
            [[ "$label" == "homebrew" || "$label" == "log" ]] && continue
            brew list "$label" >/dev/null 2>&1 && continue
            echo "$label	$entry" >> "$groups_file"
        done < <(find /opt/homebrew/var -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
    fi

    rm -f "$index_file" "$substr_file"

    [[ ! -s "$groups_file" ]] && rm -f "$groups_file" && return

    # Group by "root": first word of plain name, or vendor part of bundle ID.
    # Prepend root as sort key, sort by it, then merge adjacent same-root entries.
    awk -F'\t' '
    function root(s,    parts, n) {
        if (s ~ /^[a-zA-Z]+\.[a-zA-Z]/) {
            n = split(s, parts, ".")
            return tolower(parts[2])
        }
        n = split(s, parts, " ")
        return tolower(parts[1])
    }
    { print root($1) "\t" $1 "\t" $2 }
    ' "$groups_file" | sort -f -t$'\t' -k1,1 | awk -F'\t' '
    {
        r=$1; label=$2; path=$3
        if (r == prev_root) {
            if (length(label) < length(best_label)) best_label = label
            combined = combined "|" path
        } else {
            if (prev_root != "") print best_label "\t" combined
            prev_root = r; best_label = label; combined = path
        }
    }
    END { if (prev_root != "") print best_label "\t" combined }
    '
    rm -f "$groups_file"
}

# ---------------------------------------------------------------------------
# SCAN: run_scan() populates all SCAN_* globals; called at start of SCREEN 2
#
# Populates globals:
#   SCAN_APPS[]        - app paths (installed)
#   SCAN_APP_NAMES[]   - display names
#   SCAN_APP_SIZES[]   - sizes
#   SCAN_ORP_LABELS[]  - orphan labels (size >= 50K)
#   SCAN_ORP_PATHS[]   - orphan path lists (pipe-separated)
#   SCAN_ORP_COUNTS[]  - file counts
#   SCAN_ORP_SIZES[]   - sizes
#   SCAN_JUNK_LABELS[] - junk labels (empty folders + size < 50K)
#   SCAN_JUNK_PATHS[]  - junk path lists (pipe-separated)
#   SCAN_JUNK_SIZES[]  - sizes
# ---------------------------------------------------------------------------
SCAN_APPS=()
SCAN_APP_NAMES=()
SCAN_APP_SIZES=()
SCAN_ORP_LABELS=()
SCAN_ORP_PATHS=()
SCAN_ORP_COUNTS=()
SCAN_ORP_SIZES=()
SCAN_JUNK_LABELS=()
SCAN_JUNK_PATHS=()
SCAN_JUNK_SIZES=()

_JUNK_THRESHOLD_K=50

run_scan() {
    SCAN_APPS=(); SCAN_APP_NAMES=(); SCAN_APP_SIZES=()
    SCAN_ORP_LABELS=(); SCAN_ORP_PATHS=(); SCAN_ORP_COUNTS=(); SCAN_ORP_SIZES=()
    SCAN_JUNK_LABELS=(); SCAN_JUNK_PATHS=(); SCAN_JUNK_SIZES=()

    show_progress 0 3 "finding installed apps..."

    local raw_apps=()
    while IFS= read -r app; do
        [[ -n "$app" ]] && raw_apps+=("$app")
    done < <(scan_applications | sort)

    show_progress 1 3 "measuring installed apps..."

    local i=0
    while [[ $i -lt ${#raw_apps[@]} ]]; do
        local app="${raw_apps[$i]}"
        local _name
        _name="$(get_app_name "$app")"
        [[ "$app" == *"Chrome Apps.localized"* ]] && _name="$_name [chrome]"
        SCAN_APPS+=("$app")
        SCAN_APP_NAMES+=("$_name")
        SCAN_APP_SIZES+=("$(du -sh "$app" 2>/dev/null | cut -f1)")
        ((i++))
    done

    show_progress 2 3 "scanning for leftover junk..."

    while IFS='	' read -r label path_list; do
        [[ -z "$label" ]] && continue
        local IFS_bak="$IFS"
        IFS='|'; local parts; read -ra parts <<< "$path_list"; IFS="$IFS_bak"
        local real_files
        real_files=$(find "${parts[@]}" -mindepth 1 -not -name ".DS_Store" -not -type d 2>/dev/null | wc -l)
        local sz sz_k
        sz=$(du -sch "${parts[@]}" 2>/dev/null | tail -1 | cut -f1)
        sz_k=$(du -sk "${parts[@]}" 2>/dev/null | awk '{s+=$1} END {print s+0}')
        if [[ "$real_files" -eq 0 || "$sz_k" -lt $_JUNK_THRESHOLD_K ]]; then
            SCAN_JUNK_LABELS+=("$label")
            SCAN_JUNK_PATHS+=("$path_list")
            SCAN_JUNK_SIZES+=("$sz")
        else
            SCAN_ORP_LABELS+=("$label")
            SCAN_ORP_PATHS+=("$path_list")
            SCAN_ORP_COUNTS+=(${#parts[@]})
            SCAN_ORP_SIZES+=("$sz")
        fi
    done < <(find_orphans)

    show_progress 3 3 "done"
    sleep 0.15
    clear_progress
}

# ---------------------------------------------------------------------------
# SCREEN 2 — Scan + Results List
#   Entry: show_main_menu → "scan for apps"
#   Runs scan, builds MENU_ITEMS from SCAN_* globals, calls draw_menu().
#   On select: dispatches to SCREEN 3a / 3b / 3c.
#   On q/ESC: returns to SCREEN 1 (Main Menu).
#   Re-scans only after a successful deletion, not on cancel.
# ---------------------------------------------------------------------------
browse_results() {
    print_header

    printf "  \033[2mmoves to Trash — restore via Trash.app if needed\033[0m\n"
    echo ""

    run_scan

    local total_apps=${#SCAN_APPS[@]}
    local total_orps=${#SCAN_ORP_LABELS[@]}
    local total_junk=${#SCAN_JUNK_LABELS[@]}

    if [[ $total_apps -eq 0 && $total_orps -eq 0 && $total_junk -eq 0 ]]; then
        printf "  \033[0;32mclean — nothing found\033[0m\n\n"
        printf "  \033[2m[any key] back\033[0m "
        read_key ""
        return
    fi

    local _build_menu
    _build_menu() {
        local total_found=$((total_apps + total_orps + total_junk))
        MENU_SUBTITLE="found ${total_found}  ·  ${total_apps} installed  ·  $((total_orps + total_junk)) leftover"
        MENU_COMPACT=1
        MENU_MULTI=1
        MENU_ITEMS=()
        MENU_HEADERS=()
        MENU_SELECTABLE=()
        MENU_CHECKED=()
        item_types=()
        item_idx=()

        if [[ $total_apps -gt 0 ]]; then
            local first_app=1 i=0
            while [[ $i -lt $total_apps ]]; do
                MENU_ITEMS+=("$(_pad "${SCAN_APP_NAMES[$i]}" 40)  $(printf '\033[0;36m%6s\033[0m' "${SCAN_APP_SIZES[$i]}")")
                [[ $first_app -eq 1 ]] && MENU_HEADERS+=("installed apps") || MENU_HEADERS+=("")
                MENU_SELECTABLE+=(1); MENU_CHECKED+=(0)
                first_app=0; item_types+=("app"); item_idx+=("$i"); ((i++))
            done
        fi

        if [[ $total_orps -gt 0 ]]; then
            local first_orp=1 i=0
            while [[ $i -lt $total_orps ]]; do
                local files_str="${SCAN_ORP_COUNTS[$i]} files"
                [[ ${SCAN_ORP_COUNTS[$i]} -eq 1 ]] && files_str="1 file"
                MENU_ITEMS+=("$(_pad "${SCAN_ORP_LABELS[$i]}" 40)  $(printf '\033[0;36m%6s\033[0m  \033[2m%s\033[0m' "${SCAN_ORP_SIZES[$i]}" "$files_str")")
                [[ $first_orp -eq 1 ]] && MENU_HEADERS+=("leftover junk") || MENU_HEADERS+=("")
                MENU_SELECTABLE+=(1); MENU_CHECKED+=(0)
                first_orp=0; item_types+=("orp"); item_idx+=("$i"); ((i++))
            done
        fi

        if [[ $total_junk -gt 0 ]]; then
            local first_junk=1 i=0
            while [[ $i -lt $total_junk ]]; do
                MENU_ITEMS+=("$(_pad "${SCAN_JUNK_LABELS[$i]}" 40)  $(printf '\033[2m%6s\033[0m' "${SCAN_JUNK_SIZES[$i]}")")
                [[ $first_junk -eq 1 ]] && MENU_HEADERS+=("junk") || MENU_HEADERS+=("")
                MENU_SELECTABLE+=(0); MENU_CHECKED+=(0)
                first_junk=0; item_types+=("junk"); item_idx+=("$i"); ((i++))
            done
            MENU_ITEMS+=("$(printf '\033[1;33m%-40s\033[0m' "trash all junk")")
            MENU_HEADERS+=("")
            MENU_SELECTABLE+=(0); MENU_CHECKED+=(0)
            item_types+=("junk_all"); item_idx+=("0")
        fi
    }

    local item_types=()
    local item_idx=()

    while true; do
        _build_menu
        draw_menu
        local result=$MENU_RESULT
        [[ $result -eq -1 ]] && return

        local deleted=0

        if [[ $result -eq -2 ]]; then
            # batch: collect checked app and orp indices
            local batch_apps="" batch_orps=""
            local k=0
            while [[ $k -lt ${#MENU_CHECKED[@]} ]]; do
                if [[ "${MENU_CHECKED[$k]}" == "1" ]]; then
                    local t="${item_types[$k]}"
                    local x="${item_idx[$k]}"
                    [[ "$t" == "app" ]] && batch_apps="$batch_apps $x"
                    [[ "$t" == "orp" ]] && batch_orps="$batch_orps $x"
                fi
                ((k++))
            done
            review_and_batch_delete "$batch_apps" "$batch_orps" && deleted=1
        else
            local sel_type="${item_types[$result]}"
            local sel_idx="${item_idx[$result]}"

            if [[ "$sel_type" == "app" ]]; then
                review_and_uninstall "${SCAN_APPS[$sel_idx]}" && deleted=1
            elif [[ "$sel_type" == "orp" ]]; then
                review_and_trash_orphan "$sel_idx" && deleted=1
            elif [[ "$sel_type" == "junk" ]]; then
                review_and_trash_junk "$sel_idx" && deleted=1
            elif [[ "$sel_type" == "junk_all" ]]; then
                review_and_trash_all_junk && deleted=1
            fi
        fi

        if [[ $deleted -eq 1 ]]; then
            run_scan
            total_apps=${#SCAN_APPS[@]}
            total_orps=${#SCAN_ORP_LABELS[@]}
            total_junk=${#SCAN_JUNK_LABELS[@]}
            [[ $total_apps -eq 0 && $total_orps -eq 0 && $total_junk -eq 0 ]] && return
        fi
    done
}

# ---------------------------------------------------------------------------
# SCREEN 3a — App detail + confirm uninstall
#   Entry: browse_results → installed app selected
#   Shows app path + leftovers, asks [y/N] via read_key.
#   On confirm: trashes all, waits [enter] continue (raw read -r, intentional).
#   On cancel: 1s pause, returns to SCREEN 2.
# ---------------------------------------------------------------------------
review_and_uninstall() {
    local app_path="$1"
    local app_name bundle_id
    app_name=$(get_app_name "$app_path")
    bundle_id=$(get_bundle_id "$app_path")

    print_section "$app_name"
    [[ -n "$bundle_id" ]] && printf "  \033[2m%s\033[0m\n" "$bundle_id"
    echo ""

    start_spinner "searching for leftovers..."
    local leftovers=()
    while IFS= read -r l; do [[ -n "$l" ]] && leftovers+=("$l"); done < <(find_leftovers "$app_path")
    stop_spinner

    if pgrep -f "$app_path/Contents/MacOS/" >/dev/null 2>&1; then
        printf "  \033[1;33m⚠\033[0m  \033[1m%s is running\033[0m — quit it first, then try again\n\n" "$app_name"
        printf "  \033[2m[any key] back\033[0m "
        read_key ""
        return 1
    fi

    local app_size
    app_size=$(du -sh "$app_path" 2>/dev/null | cut -f1)
    printf "  \033[0;31m✗\033[0m  %-50s  \033[0;36m%s\033[0m  \033[1;33mapp\033[0m\n" "$app_path" "$app_size"

    if [[ ${#leftovers[@]} -gt 0 ]]; then
        for lf in "${leftovers[@]}"; do
            local sz; sz=$(du -sh "$lf" 2>/dev/null | cut -f1)
            printf "  \033[0;31m✗\033[0m  %-50s  \033[0;36m%s\033[0m  \033[2mleftover\033[0m\n" "$lf" "$sz"
        done
    else
        printf "  \033[0;32mno leftovers found\033[0m\n"
    fi

    local total=$((1 + ${#leftovers[@]}))
    local total_sz
    total_sz=$(_total_size "$app_path" "${leftovers[@]}")
    echo ""
    printf "  \033[1m%d item(s) → Trash\033[0m  \033[0;36m%s\033[0m  \033[2m(restore via Trash.app)\033[0m\n" "$total" "$total_sz"
    echo ""
    printf "  move to trash? \033[0;36m[y/N]\033[0m "
    read_key "yYnN"
    local confirm="$KEY"
    echo "$confirm"

    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        echo ""
        _do_trash "$app_path"
        for lf in "${leftovers[@]}"; do _do_trash "$lf"; done
        echo ""
        printf "  \033[0;32mdone.\033[0m  \033[2mopen Trash to restore if needed\033[0m\n\n"
        printf "  \033[2m[enter] continue\033[0m "
        read -r
        return 0
    else
        echo ""
        printf "  \033[2mcancelled.\033[0m\n"
        sleep 1
        return 1
    fi
}

# ---------------------------------------------------------------------------
# SCREEN 3b — Leftover junk detail + confirm trash
#   Entry: browse_results → orphan item selected
#   Same confirm pattern as SCREEN 3a.
# ---------------------------------------------------------------------------
review_and_trash_orphan() {
    local idx="$1"
    local label="${SCAN_ORP_LABELS[$idx]}"
    local path_list="${SCAN_ORP_PATHS[$idx]}"

    print_section "$label"

    local IFS_bak="$IFS"
    IFS='|'; local parts; read -ra parts <<< "$path_list"; IFS="$IFS_bak"

    for item in "${parts[@]}"; do
        local sz; sz=$(du -sh "$item" 2>/dev/null | cut -f1)
        printf "  \033[0;31m✗\033[0m  %-50s  \033[0;36m%s\033[0m\n" "$item" "$sz"
    done

    local total_sz
    total_sz=$(_total_size "${parts[@]}")
    echo ""
    printf "  \033[1m%d item(s) → Trash\033[0m  \033[0;36m%s\033[0m  \033[2m(restore via Trash.app)\033[0m\n" "${#parts[@]}" "$total_sz"
    echo ""
    printf "  move to trash? \033[0;36m[y/N]\033[0m "
    read_key "yYnN"
    local confirm="$KEY"
    echo "$confirm"

    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        echo ""
        for item in "${parts[@]}"; do _do_trash "$item"; done
        echo ""
        printf "  \033[0;32mdone.\033[0m  \033[2mopen Trash to restore if needed\033[0m\n\n"
        printf "  \033[2m[enter] continue\033[0m "
        read -r
        return 0
    else
        echo ""
        printf "  \033[2mskipped.\033[0m\n"
        sleep 1
        return 1
    fi
}

# ---------------------------------------------------------------------------
# SCREEN 3c — Junk item detail + confirm trash
#   Entry: browse_results → junk item selected
#   Same confirm pattern as SCREEN 3a.
# ---------------------------------------------------------------------------
review_and_trash_junk() {
    local idx="$1"
    local label="${SCAN_JUNK_LABELS[$idx]}"
    local path_list="${SCAN_JUNK_PATHS[$idx]}"

    print_section "$label"

    local IFS_bak="$IFS"
    IFS='|'; local parts; read -ra parts <<< "$path_list"; IFS="$IFS_bak"

    for item in "${parts[@]}"; do
        local sz; sz=$(du -sh "$item" 2>/dev/null | cut -f1)
        printf "  \033[0;31m✗\033[0m  %-50s  \033[2m%s\033[0m\n" "$item" "$sz"
    done

    local total_sz
    total_sz=$(_total_size "${parts[@]}")
    echo ""
    printf "  \033[1m%d item(s) → Trash\033[0m  \033[0;36m%s\033[0m  \033[2m(restore via Trash.app)\033[0m\n" "${#parts[@]}" "$total_sz"
    echo ""
    printf "  move to trash? \033[0;36m[y/N]\033[0m "
    read_key "yYnN"
    local confirm="$KEY"
    echo "$confirm"

    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        echo ""
        for item in "${parts[@]}"; do _do_trash "$item"; done
        echo ""
        printf "  \033[0;32mdone.\033[0m  \033[2mopen Trash to restore if needed\033[0m\n\n"
        printf "  \033[2m[enter] continue\033[0m "
        read -r
        return 0
    else
        echo ""
        printf "  \033[2mskipped.\033[0m\n"
        sleep 1
        return 1
    fi
}

# ---------------------------------------------------------------------------
# SCREEN 3d — Remove all junk at once
#   Entry: browse_results → "trash all junk" selected
# ---------------------------------------------------------------------------
review_and_trash_all_junk() {
    print_section "trash all junk"

    local all_paths=()
    local i=0
    while [[ $i -lt ${#SCAN_JUNK_LABELS[@]} ]]; do
        local IFS_bak="$IFS"
        IFS='|'; local parts; read -ra parts <<< "${SCAN_JUNK_PATHS[$i]}"; IFS="$IFS_bak"
        for item in "${parts[@]}"; do
            local sz; sz=$(du -sh "$item" 2>/dev/null | cut -f1)
            printf "  \033[0;31m✗\033[0m  %-50s  \033[2m%s\033[0m\n" "$item" "$sz"
            all_paths+=("$item")
        done
        ((i++))
    done

    local total_sz
    total_sz=$(_total_size "${all_paths[@]}")
    echo ""
    printf "  \033[1m%d item(s) → Trash\033[0m  \033[0;36m%s\033[0m  \033[2m(restore via Trash.app)\033[0m\n" "${#all_paths[@]}" "$total_sz"
    echo ""
    printf "  move all to trash? \033[0;36m[y/N]\033[0m "
    read_key "yYnN"
    local confirm="$KEY"
    echo "$confirm"

    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        echo ""
        for item in "${all_paths[@]}"; do _do_trash "$item"; done
        echo ""
        printf "  \033[0;32mdone.\033[0m  \033[2mopen Trash to restore if needed\033[0m\n\n"
        printf "  \033[2m[enter] continue\033[0m "
        read -r
        return 0
    else
        echo ""
        printf "  \033[2mskipped.\033[0m\n"
        sleep 1
        return 1
    fi
}

_total_size() {
    du -sch "$@" 2>/dev/null | tail -1 | cut -f1
}

# ---------------------------------------------------------------------------
# SCREEN 3e — Batch uninstall: apps + orphans selected via multi-select
#   app_indices  - space-separated indices into SCAN_APPS
#   orp_indices  - space-separated indices into SCAN_ORP_*
# ---------------------------------------------------------------------------
review_and_batch_delete() {
    local app_indices="$1"
    local orp_indices="$2"

    # build title from scan globals — no extra work needed
    local joined="" n_apps=0
    for idx in $app_indices; do
        [[ $n_apps -gt 0 ]] && joined="$joined  |  "
        joined="$joined${SCAN_APP_NAMES[$idx]}"
        ((n_apps++))
    done
    local n_orps=0
    for idx in $orp_indices; do ((n_orps++)); done

    local title
    if [[ $n_apps -gt 0 && $n_orps -gt 0 ]]; then
        title="${n_apps} app$([ $n_apps -gt 1 ] && echo s) + ${n_orps} leftover$([ $n_orps -gt 1 ] && echo s) will move to Trash: $joined"
    elif [[ $n_apps -gt 0 ]]; then
        title="${n_apps} app$([ $n_apps -gt 1 ] && echo s) will move to Trash: $joined"
    else
        title="leftover junk will move to Trash"
    fi

    print_section "$title"

    local all_trash=()
    local skipped_running=()

    # --- apps ---
    for idx in $app_indices; do
        local app_path="${SCAN_APPS[$idx]}"
        local app_name="${SCAN_APP_NAMES[$idx]}"

        if pgrep -f "$app_path/Contents/MacOS/" >/dev/null 2>&1; then
            skipped_running+=("$app_name")
            continue
        fi

        local app_size
        app_size=$(du -sh "$app_path" 2>/dev/null | cut -f1)
        printf "  \033[0;31m✗\033[0m  %-50s  \033[0;36m%s\033[0m  \033[1;33mapp\033[0m\n" "$app_path" "$app_size"
        all_trash+=("$app_path")

        start_spinner "searching leftovers for $app_name..."
        local leftovers=()
        while IFS= read -r l; do [[ -n "$l" ]] && leftovers+=("$l"); done < <(find_leftovers "$app_path")
        stop_spinner

        for lf in "${leftovers[@]}"; do
            local sz; sz=$(du -sh "$lf" 2>/dev/null | cut -f1)
            printf "  \033[0;31m✗\033[0m  %-50s  \033[0;36m%s\033[0m  \033[2mleftover\033[0m\n" "$lf" "$sz"
            all_trash+=("$lf")
        done
    done

    # --- orphans ---
    for idx in $orp_indices; do
        local path_list="${SCAN_ORP_PATHS[$idx]}"
        local IFS_bak="$IFS"
        IFS='|'; local parts; read -ra parts <<< "$path_list"; IFS="$IFS_bak"
        for item in "${parts[@]}"; do
            local sz; sz=$(du -sh "$item" 2>/dev/null | cut -f1)
            printf "  \033[0;31m✗\033[0m  %-50s  \033[0;36m%s\033[0m  \033[2mleftover\033[0m\n" "$item" "$sz"
            all_trash+=("$item")
        done
    done

    # warn about skipped running apps
    for name in "${skipped_running[@]}"; do
        printf "  \033[1;33m⚠\033[0m  \033[1m%s is running\033[0m — skipped\n" "$name"
    done

    if [[ ${#all_trash[@]} -eq 0 ]]; then
        echo ""
        printf "  \033[1;33mnothing to delete\033[0m  (all selected apps are running)\n\n"
        printf "  \033[2m[any key] back\033[0m "
        read_key ""
        return 1
    fi

    local total_sz
    total_sz=$(_total_size "${all_trash[@]}")
    echo ""
    printf "  \033[1m%d item(s) → Trash\033[0m  \033[0;36m%s\033[0m  \033[2m(restore via Trash.app)\033[0m\n" "${#all_trash[@]}" "$total_sz"
    echo ""
    printf "  move all to trash? \033[0;36m[y/N]\033[0m "
    read_key "yYnN"
    local confirm="$KEY"
    echo "$confirm"

    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        echo ""
        for item in "${all_trash[@]}"; do _do_trash "$item"; done
        echo ""
        printf "  \033[0;32mdone.\033[0m  \033[2mopen Trash to restore if needed\033[0m\n\n"
        printf "  \033[2m[enter] continue\033[0m "
        read -r
        return 0
    else
        echo ""
        printf "  \033[2mcancelled.\033[0m\n"
        sleep 1
        return 1
    fi
}

_do_trash() {
    local item="$1"
    if move_to_trash "$item"; then
        printf "  \033[0;32m✓\033[0m  %s\n" "$item"
    else
        printf "  \033[0;31m✗\033[0m  failed: %s\n" "$item"
    fi
}

# ---------------------------------------------------------------------------
# SCREEN 4 — Brew & pip package inspector (read-only)
#   Shows brew leaves + pip3 packages with sizes and removal commands.
# ---------------------------------------------------------------------------
show_brew_packages() {
    print_header
    printf "  \033[2mread-only — run the commands below to uninstall\033[0m\n"
    echo ""

    local found_anything=0

    # brew formulae (leaves = top-level, no dependents)
    if command -v brew >/dev/null 2>&1; then
        local leaves=()
        while IFS= read -r pkg; do
            [[ -n "$pkg" ]] && leaves+=("$pkg")
        done < <(brew leaves 2>/dev/null)

        if [[ ${#leaves[@]} -gt 0 ]]; then
            found_anything=1
            printf "  \033[0;36m─── brew formulae (%d) ──────────────────────────────────\033[0m\n" "${#leaves[@]}"
            printf "  \033[2muninstall: brew uninstall <name>\033[0m\n\n"
            for pkg in "${leaves[@]}"; do
                local cellar="/opt/homebrew/Cellar/$pkg"
                local vardir="/opt/homebrew/var/$pkg"
                local sz="?"
                if [[ -d "$cellar" && -d "$vardir" ]]; then
                    sz=$(du -sch "$cellar" "$vardir" 2>/dev/null | tail -1 | cut -f1)
                elif [[ -d "$cellar" ]]; then
                    sz=$(du -sh "$cellar" 2>/dev/null | cut -f1)
                fi
                printf "  \033[0;37m%-40s\033[0m  \033[0;36m%6s\033[0m\n" "$pkg" "$sz"
            done
            echo ""
        fi

        local casks=()
        while IFS= read -r pkg; do
            [[ -n "$pkg" ]] && casks+=("$pkg")
        done < <(brew list --cask 2>/dev/null)

        if [[ ${#casks[@]} -gt 0 ]]; then
            found_anything=1
            printf "  \033[0;36m─── brew casks (%d) ─────────────────────────────────────\033[0m\n" "${#casks[@]}"
            printf "  \033[2muninstall: brew uninstall --cask <name>\033[0m\n\n"
            for pkg in "${casks[@]}"; do
                local caskroom="/opt/homebrew/Caskroom/$pkg"
                local sz="?"
                if [[ -d "$caskroom" ]]; then
                    # Caskroom contains symlinks to real install locations — resolve with du directly
                    local total_sz=0
                    while IFS= read -r lnk; do
                        local target; target=$(readlink "$lnk")
                        if [[ -e "$target" ]]; then
                            local lsz; lsz=$(du -sk "$target" 2>/dev/null | cut -f1)
                            total_sz=$((total_sz + ${lsz:-0}))
                        fi
                    done < <(find "$caskroom" -maxdepth 2 -type l 2>/dev/null)
                    if [[ $total_sz -gt 0 ]]; then
                        sz=$(echo "$total_sz" | awk '{
                            if ($1 >= 1048576) printf "%.1fG", $1/1048576
                            else if ($1 >= 1024) printf "%.1fM", $1/1024
                            else printf "%dK", $1
                        }')
                    else
                        sz=$(du -sh "$caskroom" 2>/dev/null | cut -f1)
                    fi
                fi
                printf "  \033[0;37m%-40s\033[0m  \033[0;36m%6s\033[0m\n" "$pkg" "$sz"
            done
            echo ""
        fi
    fi

    # pip packages
    if command -v pip3 >/dev/null 2>&1; then
        local pip_pkgs=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && pip_pkgs+=("$line")
        done < <(pip3 list --not-required --format=columns 2>/dev/null | tail -n +3)

        local site_packages
        site_packages=$(python3 -c "import site; print(site.getsitepackages()[0])" 2>/dev/null)

        if [[ ${#pip_pkgs[@]} -gt 0 ]]; then
            found_anything=1
            printf "  \033[0;36m─── pip packages (%d) ───────────────────────────────────\033[0m\n" "${#pip_pkgs[@]}"
            printf "  \033[2muninstall: pip3 uninstall <name>\033[0m\n\n"
            for line in "${pip_pkgs[@]}"; do
                local pkg_name
                pkg_name=$(echo "$line" | awk '{print $1}')
                local sz="?"
                if [[ -n "$site_packages" ]]; then
                    local pkg_lower
                    pkg_lower=$(to_lower "$pkg_name" | tr '-' '_')
                    local pkg_dir="$site_packages/$pkg_lower"
                    [[ -d "$pkg_dir" ]] && sz=$(du -sh "$pkg_dir" 2>/dev/null | cut -f1)
                fi
                printf "  \033[0;37m%-40s\033[0m  \033[0;36m%6s\033[0m\n" "$pkg_name" "$sz"
            done
            echo ""
        fi
    fi

    if [[ $found_anything -eq 0 ]]; then
        printf "  \033[0;32mnothing found\033[0m\n\n"
    fi

    printf "  \033[0;36m─────────────────────────────────────────────────────────\033[0m\n"
    printf "  \033[2m[any key] back\033[0m "
    read_key ""
}

# ---------------------------------------------------------------------------
# SCREEN 5 — Help / shell install helper
#   Entry: show_main_menu → "help"
#   Non-TUI screen (no draw_menu). Returns on any key.
# ---------------------------------------------------------------------------
show_about() {
    print_header
    printf "  \033[0;36m─── how to use ──────────────────────────────────────────\033[0m\n"
    printf "  \033[0;36m1\033[0m  pick \033[1mscan for apps\033[0m from the main menu\n"
    printf "  \033[0;36m2\033[0m  browse the list — select an app to inspect\n"
    printf "  \033[0;36m3\033[0m  review what will be trashed, confirm with \033[1mY\033[0m\n"
    printf "  \033[0;36m4\033[0m  restore anything from Trash.app if needed\n"
    echo ""
    printf "  \033[0;36m─── what we find ────────────────────────────────────────\033[0m\n"
    printf "  \033[1;33mapp\033[0m        bundle in /Applications or ~/Applications\n"
    printf "  \033[1;33mleftover\033[0m   caches, prefs, containers, logs, agents (by bundle id + name)\n"
    printf "  \033[1;33mjunk\033[0m       orphaned files, no installed app (<50K or empty)\n"
    echo ""
    printf "  \033[0;36m─── search paths ────────────────────────────────────────\033[0m\n"
    printf "  ~/Library/{Application Support,Caches,Preferences,Containers,\n"
    printf "             Group Containers,LaunchAgents,Logs,Cookies,WebKit,\n"
    printf "             HTTPStorages,Application Scripts,PreferencePanes,\n"
    printf "             Internet Plug-Ins,Saved Application State}\n"
    printf "  /Library/{LaunchAgents,LaunchDaemons,Application Support,\n"
    printf "            Preferences,Caches,PrivilegedHelperTools}\n"
    printf "  /private/var/db/receipts\n"
    echo ""
    if ! is_installed_in_shell; then
        printf "  \033[0;36m─── shell install ───────────────────────────────────────\033[0m\n"
        install_to_shell
    fi
    printf "  \033[0;36m─────────────────────────────────────────────────────────\033[0m\n"
    printf "  \033[2m[any key] back\033[0m "
    read_key ""
}

# ---------------------------------------------------------------------------
# SCREEN 1 — Main Menu
#   Entry point for interactive mode. Full ASCII logo header (MENU_COMPACT=0).
#   Options: scan for apps → SCREEN 2 | help → SCREEN 4 | quit.
# ---------------------------------------------------------------------------
show_main_menu() {
    while true; do
        MENU_ITEMS=("scan for apps" "check brew + pip packages" "help" "quit")
        MENU_HEADERS=("" "" "" "")
        MENU_SUBTITLE=""
        MENU_COMPACT=0
        MENU_MULTI=0
        draw_menu
        case $MENU_RESULT in
            0)  browse_results ;;
            1)  show_brew_packages ;;
            2)  show_about ;;
            3|-1)
                exit 0
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Entry point — launches interactive SCREEN 1
# ---------------------------------------------------------------------------
main() {
    if [[ -n "${1:-}" ]]; then
        printf "\033[0;31munknown option: %s\033[0m\n" "$1"
        printf "  usage: cleaner\n"
        exit 1
    fi
    show_main_menu
}

main "$@"
