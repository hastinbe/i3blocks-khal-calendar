#!/bin/bash
#
#  khal-calendar
#
#  Display khal calendar popup for polybar
#
#  Dependencies:
#      khal
#      rofi
#
#  Copyright (c) 2024 Beau Hastings. All rights reserved.
#  License: GNU General Public License v2
#
#  Author: Beau Hastings <beau@saweet.net>
#  URL: https://github.com/hastinbe/khal-calendar

export KHAL_CONFIG="$HOME/.config/khal/config"

empty() {
    [[ -z $1 ]]
}

not_empty() {
    [[ -n $1 ]]
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

convert_ansi_color_codes_to_pango() {
    awk '
        {
            if (NF == 0) {
                print ""
                next
            }

            line=$0
            bold_count=0
            highlight_count=0

            # Start markup
            line = "<markup>" line

            # Replace bold markers
            while (match(line, /\x1b\[1m/)) {
                bold_count++
                line=substr(line,1,RSTART-1) "<b>" substr(line,RSTART+RLENGTH)
            }

            # Replace highlight markers (current day)
            while (match(line, /\x1b\[7m/)) {
                highlight_count++
                line=substr(line,1,RSTART-1) "<span background=\"'"$TODAY_BG"'\" foreground=\"'"$TODAY_FG"'\" weight=\"bold\">" substr(line,RSTART+RLENGTH)
            }

            # Replace reset markers
            while (match(line, /\x1b\[0m/)) {
                close_tags = ""
                if (highlight_count > 0) {
                    close_tags = close_tags "</span>"
                    highlight_count--
                }
                if (bold_count > 0) {
                    close_tags = close_tags "</b>"
                    bold_count--
                }
                line=substr(line,1,RSTART-1) close_tags substr(line,RSTART+RLENGTH)
            }

            # Clean up any remaining escape sequences
            gsub(/\x1b\[[0-9;]*[mK]/, "", line)

            # Close any remaining open tags at the end of the line
            while (highlight_count > 0) {
                line = line "</span>"
                highlight_count--
            }
            while (bold_count > 0) {
                line = line "</b>"
                bold_count--
            }

            # Close markup
            line = line "</markup>"

            print line
        }
    '
}

parse_polybar_font() {
    local polybar_font="$1"

    # Polybar font format is typically: "Font Name:size=10" or just "Font Name"
    # For rofi, we need to convert it to a format rofi understands
    # Remove size specification if present
    local rofi_font="${polybar_font%%:size=*}"

    echo "$rofi_font"
}

get_status_line() {
    local -r current_time=$(date "+%H:%M")
    local -r next_event=$(khal_command list --format "$EVENT_FORMAT" today tomorrow | head -n 1)

    if not_empty "$next_event"; then
        echo "$current_time | Next: $next_event"
    else
        echo "$current_time"
    fi
}

add_event() {
    local event_string
    event_string=$(rofi -dmenu -p "Add Event (format: 2024-01-20 14:00 Event Name)" -lines 0)

    if not_empty "$event_string"; then
        local date time title
        date=$(echo "$event_string" | cut -d' ' -f1)
        time=$(echo "$event_string" | cut -d' ' -f2)
        title=$(echo "$event_string" | cut -d' ' -f3-)

        if ! validate_date_format "$date"; then
            return 1
        fi

        if ! validate_time_format "$time"; then
            return 1
        fi

        if empty "$title"; then
            log_error "Event title is required"
            return 1
        fi

        debug "Adding event: $date $time $title"

        khal_command new "$date" "$time" "$title"

        if [[ $? -ne 0 ]]; then
            log_error "Failed to add event"
            return 1
        fi
    fi

    display_date
}

khal_command() {
    local cmd=("$@")
    local result=()
    local found_command=false

    # add KHAL_CONFIG
    # result+=("-c" "$KHAL_CONFIG")

    for arg in "${cmd[@]}"; do
        if [[ $found_command == false && $arg != -* ]]; then
            # First non-option argument (the "command") is found
            result+=("$arg")
            found_command=true

            # Add calendars after the command
            if not_empty "$CALENDARS"; then
                for cal in "${CALENDARS[@]}"; do
                    result+=("-a" "$cal")
                done
            fi
        else
            # Add other arguments as-is
            result+=("$arg")
        fi
    done

    debug "Running khal command: khal ${result[*]}"

    khal "${result[@]}" 2>&1
}


show_calendar() {
    trap "killall rofi" EXIT  # Ensure rofi is killed when the function exits

    local current_month
    local calendar
    local len
    local status_line
    local initial_month  # Add this to store the initial month

    current_month=$(date +%Y-%m-01)
    initial_month=$current_month  # Store initial month
    calendar="$(khal_command --color calendar | convert_ansi_color_codes_to_pango)"
    len=$(echo "$calendar" | wc -l)
    status_line=$(get_status_line)

    debug "Starting calendar display for $current_month"

    while true; do
        echo "$calendar" | rofi \
            -dmenu \
            -font "$FONT" \
            -m -3 \
            -markup-rows \
            -p "$status_line" \
            -theme "$ROFI_CONFIG_FILE" \
            -theme-str "
                * {
                    background-color: $CALENDAR_BG;
                    text-color: $CALENDAR_FG;
                }
                window {
                    padding: 10px;
                    width: $ROFI_WIDTH;
                    anchor: $ANCHOR;
                    location: $ROFI_LOCATION;
                }
                listview {
                    lines: $len;
                    scrollbar: false;
                }" \
            "${ROFI_CALENDAR_OPTIONS[@]}"

        rofi_exit_code=$?
        if [ $rofi_exit_code -eq 1 ]; then
            debug "Exiting calendar display"
            # Reset to initial month before displaying date
            if [[ $current_month != $initial_month ]]; then
                khal_command --color calendar "$initial_month" >/dev/null 2>&1
            fi

            display_date
            return
        fi

        case $rofi_exit_code in
            10) current_month=$(date -d "$current_month next month" +%Y-%m-01) ;; # Alt+n - Next month
            11) current_month=$(date -d "$current_month last month" +%Y-%m-01) ;; # Alt+p - Previous month
            12) add_event ;;                                                      # Alt+a - Add event
            13) show_events "Today's Events" "today" ;;                           # Alt+t - Show today's events
            * ) display_date; return ;;                                          # Any other key (including Enter)
        esac

        calendar="$(khal_command --color calendar "$current_month" | convert_ansi_color_codes_to_pango)"
        len=$(echo "$calendar" | wc -l)
    done

    trap - EXIT
}

display_date() {
    # Polybar format: output text with optional color formatting
    local output
    output=$(date "$DATEFMT")

    # Add color if specified
    if not_empty "$COLOR"; then
        echo "%{F$COLOR}$output%{F-}"
    else
        echo "$output"
    fi
}

show_events() {
    local -r title="$1"
    shift
    debug "Showing events for $*"
    khal_command list "$@" | rofi -dmenu -markup-rows -p "$title"
    # khal list -a "private" "$@" | rofi -dmenu -markup-rows -p "$title"
    display_date
}

validate_date_format() {
    local -r date="$1"
    debug "Validating date format: $date"
    if ! date -d "$date" >/dev/null 2>&1; then
        log_error "Invalid date format: $date"
        return 1
    fi
    return 0
}

validate_time_format() {
    local -r time="$1"
    debug "Validating time format: $time"
    if ! [[ $time =~ ^[0-2][0-9]:[0-5][0-9]$ ]]; then
        log_error "Invalid time format: $time"
        return 1
    fi
    return 0
}

log_error() {
    echo "ERROR: $*" >&2
}

check_dependencies() {
    local -ra dependencies=("khal" "rofi")
    local missing=0

    for dep in "${dependencies[@]}"; do
        if ! command_exists "$dep"; then
            log_error "Error: $dep not found, check your PATH environment variable."
            missing=1
        fi
        debug "Found $dep"
    done

    [[ $missing -eq 1 ]] && exit "$EX_UNAVAILABLE"
}

load_polybar_config() {
    local config_file="${POLYBAR_CONFIG:-$HOME/.config/polybar/config.ini}"

    if [[ ! -f "$config_file" ]]; then
        debug "Polybar config file not found: $config_file, using defaults"
        # Set defaults if config file not found
        empty "$CALENDAR_BG" && CALENDAR_BG="#2E3440"
        empty "$CALENDAR_FG" && CALENDAR_FG="#ECEFF4"
        empty "$TODAY_BG" && TODAY_BG="#5E81AC"
        empty "$TODAY_FG" && TODAY_FG="#ECEFF4"
        empty "$POSITION" && POSITION="top"
        empty "$FONT" && FONT="monospace 10"
        return
    fi

    debug "Loading polybar config from: $config_file"

    # Read polybar config values
    # Polybar config uses INI format: key = value
    # Read from [bar/*] sections, typically [bar/main] or [bar/example]
    local in_bar_section=false
    local in_colors_section=false

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        # Check for [bar/*] section
        if [[ "$line" =~ ^\[bar/ ]]; then
            in_bar_section=true
            in_colors_section=false
            continue
        fi

        # Check for [colors] section
        if [[ "$line" =~ ^\[colors\] ]]; then
            in_colors_section=true
            in_bar_section=false
            continue
        fi

        # Check if we've left a section
        if [[ "$line" =~ ^\[ ]] && [[ "$in_bar_section" == true || "$in_colors_section" == true ]]; then
            in_bar_section=false
            in_colors_section=false
            continue
        fi

        # Parse bar section values
        if [[ "$in_bar_section" == true ]]; then
            if [[ "$line" =~ ^[[:space:]]*position[[:space:]]*=[[:space:]]*(.+) ]]; then
                empty "$POSITION" && POSITION=$(echo "$line" | sed 's/.*=[[:space:]]*//' | sed 's/[[:space:]]*$//')
            elif [[ "$line" =~ ^[[:space:]]*font-[0-9]+[[:space:]]*=[[:space:]]*(.+) ]]; then
                empty "$FONT" && FONT=$(parse_polybar_font "$(echo "$line" | sed 's/.*=[[:space:]]*//' | sed 's/[[:space:]]*$//')")
            fi
        fi

        # Parse colors section values
        if [[ "$in_colors_section" == true ]]; then
            if [[ "$line" =~ ^[[:space:]]*background[[:space:]]*=[[:space:]]*(.+) ]]; then
                empty "$CALENDAR_BG" && CALENDAR_BG=$(echo "$line" | sed 's/.*=[[:space:]]*//' | sed 's/[[:space:]]*$//')
            elif [[ "$line" =~ ^[[:space:]]*foreground[[:space:]]*=[[:space:]]*(.+) ]]; then
                empty "$CALENDAR_FG" && CALENDAR_FG=$(echo "$line" | sed 's/.*=[[:space:]]*//' | sed 's/[[:space:]]*$//')
            elif [[ "$line" =~ ^[[:space:]]*primary[[:space:]]*=[[:space:]]*(.+) ]]; then
                empty "$TODAY_BG" && TODAY_BG=$(echo "$line" | sed 's/.*=[[:space:]]*//' | sed 's/[[:space:]]*$//')
            elif [[ "$line" =~ ^[[:space:]]*foreground-alt[[:space:]]*=[[:space:]]*(.+) ]]; then
                empty "$TODAY_FG" && TODAY_FG=$(echo "$line" | sed 's/.*=[[:space:]]*//' | sed 's/[[:space:]]*$//')
            fi
        fi
    done < "$config_file"

    # Set defaults if not found
    empty "$CALENDAR_BG" && CALENDAR_BG="#2E3440"
    empty "$CALENDAR_FG" && CALENDAR_FG="#ECEFF4"
    empty "$TODAY_BG" && TODAY_BG="#5E81AC"
    empty "$TODAY_FG" && TODAY_FG="#ECEFF4"
    empty "$POSITION" && POSITION="top"
    empty "$FONT" && FONT="monospace 10"

    debug "Position: $POSITION"
    debug "Font: $FONT"
    debug "Calendar BG: $CALENDAR_BG"
    debug "Calendar FG: $CALENDAR_FG"
    debug "Today BG: $TODAY_BG"
    debug "Today FG: $TODAY_FG"
}

check_lock() {
    debug "Checking for lock file $LOCK_FILE"
    if [ -f "$LOCK_FILE" ]; then
        if kill -0 "$(cat "$LOCK_FILE")" 2>/dev/null; then
            return 1
        fi
        rm "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
    return 0
}

debug() {
    [[ $DEBUG -eq 1 ]] && echo "DEBUG: $*" >&2
}

cleanup() {
    rm -f "$LOCK_FILE"
    debug "Cleaning up lock file $LOCK_FILE"
    # Kill rofi processes spawned by this script
    pkill -P "$SCRIPT_PID" rofi 2>/dev/null
    debug "Killed rofi processes"
}

main() {
    declare -ir SCRIPT_PID=$$
    declare -r LOCK_FILE="/tmp/khal-calendar-${USER}.lock"
    declare DEBUG=${DEBUG:-0}

    # Polybar variables
    # Polybar passes button clicks as command-line arguments: $1 = button number
    # Environment variables can also be used for configuration
    declare -g COLOR="${POLYBAR_COLOR:-}"
    declare -g CALENDARS="${CALENDARS:-}"
    declare BUTTON="${1:-}"

    if not_empty "$CALENDARS"; then
        IFS=',' read -r -a CALENDARS <<< "$CALENDARS"
        debug "Found calendars: ${CALENDARS[@]}"
    fi

    declare -ir \
        EX_OK=0 \
        EX_UNAVAILABLE=69 \
        EX_CANTCREAT=73

    check_dependencies

    if ! check_lock; then
        log_error "Another instance is already running."
        exit "$EX_CANTCREAT"
    fi

    # Basic display settings
    declare -r ROFI_CONFIG_FILE="${ROFI_CONFIG_FILE:-/dev/null}"
    declare -r DATEFMT="${DATEFMT:-+%a %d %b %Y}"

    # Event format for khal
    declare -r EVENT_FORMAT="${EVENT_FORMAT:-{start-time} {title}}"

    # Rofi appearance
    declare -r ROFI_WIDTH="${ROFI_WIDTH:-30%}"
    declare -r ROFI_LOCATION="${ROFI_LOCATION:-northwest}"

    # Keyboard shortcuts (using Alt instead of Ctrl to avoid conflicts)
    declare -a ROFI_CALENDAR_OPTIONS=(
        -kb-custom-1 "Alt+n"
        -kb-custom-2 "Alt+p"
        -kb-custom-3 "Alt+a"
        -kb-custom-4 "Alt+t"
    )

    declare POSITION
    declare FONT
    declare CALENDAR_BG
    declare CALENDAR_FG
    declare TODAY_BG
    declare TODAY_FG
    declare ANCHOR="northeast"

    load_polybar_config

    if [[ $POSITION == "top" ]]; then
        ANCHOR="northeast"
    else
        ANCHOR="southeast"
    fi

    # Handle click events
    # Polybar passes button number as first argument: 1=left, 2=middle, 3=right, 4=scroll up, 5=scroll down
    case "$BUTTON" in
        1) show_calendar ;;                                  # Left click - Show calendar
        2) show_events "Today's Events" "today" ;;           # Middle click - Show today's events
        3) show_events "Upcoming Events" "today" "tomorrow" ;; # Right click - Show upcoming events
        *) display_date ;;
    esac

    exit "$EX_OK"
}

main "$@"

trap cleanup EXIT INT TERM
