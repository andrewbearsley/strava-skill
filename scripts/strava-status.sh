#!/usr/bin/env bash
#
# strava-status.sh - Query activities and stats from the Strava API
#
# Usage: ./strava-status.sh [--raw] [--json] [--days N] [--detail ID] [--stats]
#   --raw        Output raw JSON from the API
#   --json       Output parsed JSON with readable values
#   --days N     Activities from the last N days (default: 7)
#   --detail ID  Detailed view of a specific activity
#   --stats      Athlete lifetime/YTD/recent stats summary
#
# Requires: curl, jq
# Environment: STRAVA_CLIENT_ID, STRAVA_CLIENT_SECRET

set -euo pipefail

for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: Required command '$cmd' not found. Install it and try again." >&2
    exit 1
  fi
done

# --- Configuration ---

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
API_BASE="https://www.strava.com/api/v3"
STRAVA_TOKEN_FILE="${STRAVA_TOKEN_FILE:-$HOME/.strava-tokens}"
MAX_PAGES=50

ACTIVITY_TYPES='{
  "Run":              {"unit": "pace",  "label": "Run"},
  "TrailRun":         {"unit": "pace",  "label": "Trail Run"},
  "VirtualRun":       {"unit": "pace",  "label": "Virtual Run"},
  "Ride":             {"unit": "speed", "label": "Ride"},
  "VirtualRide":      {"unit": "speed", "label": "Virtual Ride"},
  "GravelRide":       {"unit": "speed", "label": "Gravel Ride"},
  "MountainBikeRide": {"unit": "speed", "label": "Mountain Bike"},
  "EBikeRide":        {"unit": "speed", "label": "E-Bike Ride"},
  "Swim":             {"unit": "swim",  "label": "Swim"},
  "Walk":             {"unit": "pace",  "label": "Walk"},
  "Hike":             {"unit": "pace",  "label": "Hike"},
  "NordicSki":        {"unit": "pace",  "label": "Nordic Ski"},
  "AlpineSki":        {"unit": "time",  "label": "Alpine Ski"},
  "Snowboard":        {"unit": "time",  "label": "Snowboard"},
  "WeightTraining":   {"unit": "time",  "label": "Weight Training"},
  "Yoga":             {"unit": "time",  "label": "Yoga"},
  "Workout":          {"unit": "time",  "label": "Workout"}
}'

# --- Argument parsing ---

OUTPUT_MODE="formatted"
DAYS=7
DETAIL_ID=""
SHOW_STATS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --raw)    OUTPUT_MODE="raw"; shift ;;
    --json)   OUTPUT_MODE="json"; shift ;;
    --days)
      shift
      if [[ $# -eq 0 ]] || [[ "$1" == --* ]]; then
        echo "Error: --days requires a numeric value." >&2
        exit 1
      fi
      DAYS="$1"; shift ;;
    --days=*)
      DAYS="${1#--days=}"; shift ;;
    --detail)
      shift
      if [[ $# -eq 0 ]] || [[ "$1" == --* ]]; then
        echo "Error: --detail requires an activity ID." >&2
        exit 1
      fi
      DETAIL_ID="$1"; shift ;;
    --detail=*)
      DETAIL_ID="${1#--detail=}"; shift ;;
    --stats)
      SHOW_STATS=true; shift ;;
    --help|-h)
      echo "Usage: $0 [--raw] [--json] [--days N] [--detail ID] [--stats]"
      echo "  --raw        Output raw JSON from the API"
      echo "  --json       Output parsed JSON with readable values"
      echo "  --days N     Activities from last N days (default: 7)"
      echo "  --detail ID  Detailed view of a specific activity"
      echo "  --stats      Athlete lifetime/YTD/recent stats summary"
      echo ""
      echo "Environment: STRAVA_CLIENT_ID, STRAVA_CLIENT_SECRET"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if ! [[ "$DAYS" =~ ^[0-9]+$ ]] || [ "$DAYS" -eq 0 ]; then
  echo "Error: --days must be a positive integer, got '$DAYS'." >&2
  exit 1
fi

if [ -n "$DETAIL_ID" ]; then
  if ! [[ "$DETAIL_ID" =~ ^[0-9]+$ ]]; then
    echo "Error: --detail must be a numeric activity ID, got '$DETAIL_ID'." >&2
    exit 1
  fi
fi

# --- Helper functions ---

date_seconds_ago() {
  local days="$1"
  if [[ "$OSTYPE" == "darwin"* ]]; then
    date "-v-${days}d" +%s
  else
    date -d "-${days} days" +%s
  fi
}

is_positive() {
  [ "$(echo "$1" | awk '{print ($1 > 0)}')" = "1" ]
}

format_duration() {
  local total_seconds="$1"
  local hours=$((total_seconds / 3600))
  local minutes=$(( (total_seconds % 3600) / 60 ))
  local seconds=$((total_seconds % 60))

  if [ "$hours" -gt 0 ]; then
    printf "%d:%02d:%02d" "$hours" "$minutes" "$seconds"
  else
    printf "%d:%02d" "$minutes" "$seconds"
  fi
}

format_duration_hm() {
  local total_seconds="$1"
  local hours=$((total_seconds / 3600))
  local minutes=$(( (total_seconds % 3600) / 60 ))

  if [ "$hours" -gt 0 ]; then
    printf "%dh %02dm" "$hours" "$minutes"
  else
    printf "%dm" "$minutes"
  fi
}

format_pace() {
  local speed="$1"
  if is_positive "$speed"; then
    local pace_seconds
    pace_seconds=$(echo "$speed" | awk '{printf "%.0f", 1000/$1}')
    local mins=$((pace_seconds / 60))
    local secs=$((pace_seconds % 60))
    printf "%d:%02d /km" "$mins" "$secs"
  else
    echo "N/A"
  fi
}

format_speed() {
  local speed="$1"
  echo "$speed" | awk '{printf "%.1f km/h", $1 * 3.6}'
}

format_swim_pace() {
  local speed="$1"
  if is_positive "$speed"; then
    local pace_seconds
    pace_seconds=$(echo "$speed" | awk '{printf "%.0f", 100/$1}')
    local mins=$((pace_seconds / 60))
    local secs=$((pace_seconds % 60))
    printf "%d:%02d /100m" "$mins" "$secs"
  else
    echo "N/A"
  fi
}

format_distance() {
  local meters="$1"
  if [ "$(echo "$meters" | awk '{print ($1 >= 1000)}')" = "1" ]; then
    echo "$meters" | awk '{printf "%.1f km", $1 / 1000}'
  else
    echo "$meters" | awk '{printf "%.0f m", $1}'
  fi
}

format_distance_stat() {
  local meters="$1"
  echo "$meters" | awk '{printf "%.1f km", $1 / 1000}'
}

format_elevation() {
  local meters="$1"
  echo "$meters" | awk '{printf "%.0fm", $1}'
}

activity_unit() {
  local type="$1"
  echo "$ACTIVITY_TYPES" | jq -r --arg t "$type" '.[$t].unit // "time"'
}

activity_label() {
  local type="$1"
  echo "$ACTIVITY_TYPES" | jq -r --arg t "$type" '.[$t].label // $t'
}

api_get() {
  local url="$1" context="$2"
  local response http_code

  response=$(curl -s -w '\n%{http_code}' -H "Authorization: Bearer ${ACCESS_TOKEN}" "$url" --max-time 30)
  http_code="${response##*$'\n'}"
  response="${response%$'\n'*}"

  if [ "$http_code" -ge 400 ] 2>/dev/null; then
    local msg
    msg=$(echo "$response" | jq -r '.message // empty' 2>/dev/null | head -c 200)
    echo "Error: HTTP $http_code from Strava during $context${msg:+: $msg}" >&2
    return 1
  fi

  if ! echo "$response" | jq empty 2>/dev/null; then
    echo "Error: Invalid response from Strava API during $context" >&2
    return 1
  fi

  echo "$response"
}

format_pace_or_speed() {
  local unit_mode="$1" avg_speed="$2" max_speed="${3:-}"

  case "$unit_mode" in
    pace)
      printf "    %-18s %s\n" "Pace:" "$(format_pace "$avg_speed")"
      if [ -n "$max_speed" ]; then printf "    %-18s %s\n" "Best Pace:" "$(format_pace "$max_speed")"; fi
      ;;
    speed)
      printf "    %-18s %s\n" "Speed:" "$(format_speed "$avg_speed")"
      if [ -n "$max_speed" ]; then printf "    %-18s %s\n" "Max Speed:" "$(format_speed "$max_speed")"; fi
      ;;
    swim)
      printf "    %-18s %s\n" "Pace:" "$(format_swim_pace "$avg_speed")"
      if [ -n "$max_speed" ]; then printf "    %-18s %s\n" "Best Pace:" "$(format_swim_pace "$max_speed")"; fi
      ;;
  esac
}

print_activity_summary() {
  local activity_json="$1" show_max_speed="${2:-false}" skip_header="${3:-false}"

  IFS=$'\t' read -r name sport_type start_raw distance moving_time elapsed_time \
    elevation avg_speed max_speed avg_hr max_hr calories <<< \
    "$(echo "$activity_json" | jq -r '[
      (.name // "Untitled"),
      (.sport_type // .type // "Workout"),
      (.start_date_local // ""),
      (.distance // 0 | tostring),
      (.moving_time // 0 | tostring),
      (.elapsed_time // 0 | tostring),
      (.total_elevation_gain // 0 | tostring),
      (.average_speed // 0 | tostring),
      (.max_speed // 0 | tostring),
      (.average_heartrate // "" | tostring),
      (.max_heartrate // "" | tostring),
      (.calories // 0 | tostring)
    ] | @tsv')"

  local unit_mode
  unit_mode=$(activity_unit "$sport_type")

  if [ "$skip_header" != true ]; then
    local date_fmt
    date_fmt=$(echo "$start_raw" | sed 's/T/ /;s/Z$//' | cut -c1-16)
    echo ""
    echo "  ${date_fmt}  ${name}"
    echo "  ------------------------------------"
  fi

  if is_positive "$distance"; then
    printf "    %-18s %s\n" "Distance:" "$(format_distance "$distance")"
  fi

  printf "    %-18s %s (moving) / %s (elapsed)\n" "Time:" \
    "$(format_duration "$moving_time")" "$(format_duration "$elapsed_time")"

  if is_positive "$avg_speed"; then
    if [ "$show_max_speed" = true ]; then
      format_pace_or_speed "$unit_mode" "$avg_speed" "$max_speed"
    else
      format_pace_or_speed "$unit_mode" "$avg_speed"
    fi
  fi

  if is_positive "$elevation"; then
    printf "    %-18s %s gain\n" "Elevation:" "$(format_elevation "$elevation")"
  fi

  if [ -n "$avg_hr" ] && [ "$avg_hr" != "null" ]; then
    printf "    %-18s %.0f avg / %.0f max bpm\n" "Heart Rate:" "$avg_hr" "$max_hr"
  fi

  if [ "$calories" != "0" ] && [ -n "$calories" ]; then
    printf "    %-18s %.0f\n" "Calories:" "$calories"
  fi
}

# --- Get access token ---

ACCESS_TOKEN=$("$SCRIPT_DIR/strava-auth.sh" token) || exit 1

# --- Stats mode ---

if [ "$SHOW_STATS" = true ]; then
  ATHLETE_ID=$(jq -r '.athlete_id' "$STRAVA_TOKEN_FILE")

  if [ -z "$ATHLETE_ID" ] || [ "$ATHLETE_ID" = "null" ]; then
    echo "Error: athlete_id not found in token file. Re-run strava-auth.sh setup." >&2
    exit 1
  fi

  RESPONSE=$(api_get "${API_BASE}/athletes/${ATHLETE_ID}/stats" "athlete stats") || exit 1

  if [ "$OUTPUT_MODE" = "raw" ]; then
    echo "$RESPONSE" | jq .
    exit 0
  fi

  if [ "$OUTPUT_MODE" = "json" ]; then
    echo "$RESPONSE" | jq '{
      all_run_totals: .all_run_totals,
      all_ride_totals: .all_ride_totals,
      all_swim_totals: .all_swim_totals,
      ytd_run_totals: .ytd_run_totals,
      ytd_ride_totals: .ytd_ride_totals,
      ytd_swim_totals: .ytd_swim_totals,
      recent_run_totals: .recent_run_totals,
      recent_ride_totals: .recent_ride_totals,
      recent_swim_totals: .recent_swim_totals
    }'
    exit 0
  fi

  echo ""
  echo "============================================"
  echo "  Athlete Stats"
  echo "============================================"

  for period in ytd all; do
    if [ "$period" = "ytd" ]; then
      PERIOD_LABEL="YTD"
    else
      PERIOD_LABEL="All Time"
    fi

    for sport in run ride swim; do
      KEY="${period}_${sport}_totals"
      COUNT=$(echo "$RESPONSE" | jq -r ".${KEY}.count // 0")

      if [ "$COUNT" -eq 0 ]; then
        continue
      fi

      DISTANCE=$(echo "$RESPONSE" | jq -r ".${KEY}.distance // 0")
      MOVING_TIME=$(echo "$RESPONSE" | jq -r ".${KEY}.moving_time // 0")
      ELEVATION=$(echo "$RESPONSE" | jq -r ".${KEY}.elevation_gain // 0")

      case "$sport" in
        run)  SPORT_LABEL="Running" ;;
        ride) SPORT_LABEL="Cycling" ;;
        swim) SPORT_LABEL="Swimming" ;;
      esac

      echo ""
      echo "  ${SPORT_LABEL} (${PERIOD_LABEL})"
      echo "  ------------------------------------"
      printf "    %-18s %s\n" "Distance:" "$(format_distance_stat "$DISTANCE")"
      printf "    %-18s %s\n" "Activities:" "$COUNT"
      if is_positive "$ELEVATION"; then
        printf "    %-18s %s gain\n" "Elevation:" "$(format_elevation "$ELEVATION")"
      fi
      printf "    %-18s %s\n" "Moving Time:" "$(format_duration_hm "$MOVING_TIME")"
    done
  done

  echo ""
  echo "============================================"
  echo "  Fetched at: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "============================================"
  exit 0
fi

# --- Detail mode ---

if [ -n "$DETAIL_ID" ]; then
  RESPONSE=$(api_get "${API_BASE}/activities/${DETAIL_ID}" "activity detail") || exit 1

  if [ "$OUTPUT_MODE" = "raw" ]; then
    echo "$RESPONSE" | jq .
    exit 0
  fi

  if [ "$OUTPUT_MODE" = "json" ]; then
    echo "$RESPONSE" | jq '{
      id: .id,
      name: .name,
      type: .type,
      sport_type: .sport_type,
      start_date_local: .start_date_local,
      distance: .distance,
      moving_time: .moving_time,
      elapsed_time: .elapsed_time,
      total_elevation_gain: .total_elevation_gain,
      average_speed: .average_speed,
      max_speed: .max_speed,
      average_heartrate: .average_heartrate,
      max_heartrate: .max_heartrate,
      average_cadence: .average_cadence,
      average_watts: .average_watts,
      calories: .calories,
      suffer_score: .suffer_score,
      splits_metric: .splits_metric,
      laps: .laps,
      description: .description
    }'
    exit 0
  fi

  SPORT_TYPE=$(echo "$RESPONSE" | jq -r '.sport_type // .type // "Workout"')
  LABEL=$(activity_label "$SPORT_TYPE")
  UNIT_MODE=$(activity_unit "$SPORT_TYPE")

  IFS=$'\t' read -r NAME START_DATE <<< "$(echo "$RESPONSE" | jq -r '[
    (.name // "Untitled"),
    (.start_date_local // "" | sub("T"; " ") | sub("Z$"; ""))
  ] | @tsv')"

  echo ""
  echo "============================================"
  echo "  ${START_DATE}  ${NAME}"
  echo "  Type: ${LABEL}"
  echo "============================================"

  print_activity_summary "$RESPONSE" true true

  # Detail-specific fields
  IFS=$'\t' read -r avg_cadence avg_watts suffer description <<< \
    "$(echo "$RESPONSE" | jq -r '[
      (.average_cadence // "" | tostring),
      (.average_watts // "" | tostring),
      (.suffer_score // "" | tostring),
      (.description // "" | tostring)
    ] | @tsv')"

  if [ -n "$avg_cadence" ]; then
    printf "    %-18s %.0f\n" "Cadence:" "$avg_cadence"
  fi

  if [ -n "$avg_watts" ]; then
    printf "    %-18s %.0f W\n" "Power:" "$avg_watts"
  fi

  if [ -n "$suffer" ]; then
    printf "    %-18s %.0f\n" "Suffer Score:" "$suffer"
  fi

  if [ -n "$description" ]; then
    echo ""
    echo "  Description: $description"
  fi

  # Splits (metric)
  SPLITS_COUNT=$(echo "$RESPONSE" | jq '(.splits_metric // []) | length')
  if [ "$SPLITS_COUNT" -gt 0 ]; then
    echo ""
    echo "  Splits (per km)"
    echo "  ------------------------------------"
    printf "    %-4s  %-10s  %-10s  %-8s\n" "km" "Pace" "HR" "Elev"

    while IFS=$'\t' read -r s_dist s_time s_elev s_hr; do
      local_idx=$((${local_idx:-0} + 1))

      if is_positive "$s_dist"; then
        s_speed=$(echo "$s_time $s_dist" | awk '{if ($2 > 0) printf "%.4f", $2/$1; else print 0}')
        s_pace=$(format_pace "$s_speed")
      else
        s_pace="N/A"
      fi

      s_hr_fmt="${s_hr:+$(printf "%.0f" "$s_hr")}"
      s_hr_fmt="${s_hr_fmt:---}"
      s_elev_fmt=$(printf "%+.0fm" "$s_elev")

      printf "    %-4d  %-10s  %-10s  %-8s\n" "$local_idx" "$s_pace" "$s_hr_fmt" "$s_elev_fmt"
    done < <(echo "$RESPONSE" | jq -r '.splits_metric[] | [
      (.distance // 0 | tostring),
      (.moving_time // 0 | tostring),
      (.elevation_difference // 0 | tostring),
      (.average_heartrate // "" | tostring)
    ] | @tsv')
  fi

  # Laps
  LAPS_COUNT=$(echo "$RESPONSE" | jq '(.laps // []) | length')
  if [ "$LAPS_COUNT" -gt 1 ]; then
    echo ""
    echo "  Laps"
    echo "  ------------------------------------"
    printf "    %-4s  %-10s  %-10s  %-10s\n" "Lap" "Distance" "Time" "Pace"

    local_idx=0
    while IFS=$'\t' read -r l_dist l_time l_speed; do
      local_idx=$((local_idx + 1))

      l_dist_fmt=$(format_distance "$l_dist")
      l_time_fmt=$(format_duration "$l_time")

      case "$UNIT_MODE" in
        pace) l_pace_fmt=$(format_pace "$l_speed") ;;
        speed) l_pace_fmt=$(format_speed "$l_speed") ;;
        swim) l_pace_fmt=$(format_swim_pace "$l_speed") ;;
        *) l_pace_fmt="---" ;;
      esac

      printf "    %-4d  %-10s  %-10s  %-10s\n" "$local_idx" "$l_dist_fmt" "$l_time_fmt" "$l_pace_fmt"
    done < <(echo "$RESPONSE" | jq -r '.laps[] | [
      (.distance // 0 | tostring),
      (.moving_time // 0 | tostring),
      (.average_speed // 0 | tostring)
    ] | @tsv')
  fi

  echo ""
  echo "============================================"
  echo "  Fetched at: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "============================================"
  exit 0
fi

# --- Activity list mode (default) ---

START_DATE=$(date_seconds_ago "$DAYS")

ALL_ACTIVITIES="[]"
PAGE=1

while [ "$PAGE" -le "$MAX_PAGES" ]; do
  RESPONSE=$(api_get "${API_BASE}/athlete/activities?after=${START_DATE}&per_page=200&page=${PAGE}" "activity list") || exit 1

  PAGE_COUNT=$(echo "$RESPONSE" | jq 'length')

  if [ "$PAGE_COUNT" -eq 0 ]; then
    break
  fi

  ALL_ACTIVITIES=$(echo "$ALL_ACTIVITIES" "$RESPONSE" | jq -s '.[0] + .[1]')

  if [ "$PAGE_COUNT" -lt 200 ]; then
    break
  fi

  PAGE=$((PAGE + 1))
done

# --- Output ---

if [ "$OUTPUT_MODE" = "raw" ]; then
  echo "$ALL_ACTIVITIES" | jq .
  exit 0
fi

PARSED=$(echo "$ALL_ACTIVITIES" | jq '[
  sort_by(.start_date_local) | reverse[] | {
    id: .id,
    name: .name,
    type: .type,
    sport_type: .sport_type,
    start_date_local: .start_date_local,
    distance: .distance,
    moving_time: .moving_time,
    elapsed_time: .elapsed_time,
    total_elevation_gain: .total_elevation_gain,
    average_speed: .average_speed,
    average_heartrate: .average_heartrate,
    max_heartrate: .max_heartrate,
    calories: (.calories // 0)
  }
]')

if [ "$OUTPUT_MODE" = "json" ]; then
  echo "$PARSED" | jq .
  exit 0
fi

# --- Formatted output ---

ACTIVITY_COUNT=$(echo "$PARSED" | jq 'length')

if [ "$ACTIVITY_COUNT" -eq 0 ]; then
  echo "No activities found in the last ${DAYS} days."
  exit 0
fi

echo ""
echo "============================================"
echo "  Activities (last ${DAYS} days)"
echo "============================================"

for i in $(seq 0 $((ACTIVITY_COUNT - 1))); do
  ACTIVITY=$(echo "$PARSED" | jq ".[$i]")
  print_activity_summary "$ACTIVITY"
done

echo ""
echo "============================================"
echo "  ${ACTIVITY_COUNT} activities | Fetched at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"
