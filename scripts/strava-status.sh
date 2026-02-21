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

# --- Dependency checks ---

for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: Required command '$cmd' not found. Install it and try again." >&2
    exit 1
  fi
done

# --- Configuration ---

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
API_BASE="https://www.strava.com/api/v3"

# Activity type display names (fallback handles anything not listed)
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

# Validate --days is a positive integer
if ! [[ "$DAYS" =~ ^[0-9]+$ ]] || [ "$DAYS" -eq 0 ]; then
  echo "Error: --days must be a positive integer, got '$DAYS'." >&2
  exit 1
fi

# Validate --detail is a positive integer if set
if [ -n "$DETAIL_ID" ]; then
  if ! [[ "$DETAIL_ID" =~ ^[0-9]+$ ]]; then
    echo "Error: --detail must be a numeric activity ID, got '$DETAIL_ID'." >&2
    exit 1
  fi
fi

# --- Helper functions ---

# Portable date helpers
date_seconds_ago() {
  local days="$1"
  if [[ "$OSTYPE" == "darwin"* ]]; then
    date "-v-${days}d" +%s
  else
    date -d "-${days} days" +%s
  fi
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
  if [ "$(echo "$speed" | awk '{print ($1 > 0)}')" = "1" ]; then
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
  if [ "$(echo "$speed" | awk '{print ($1 > 0)}')" = "1" ]; then
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

check_api_response() {
  local response="$1" context="$2"

  if ! echo "$response" | jq empty 2>/dev/null; then
    echo "Error: Invalid response from Strava API during $context (network error?)" >&2
    return 1
  fi

  local msg
  msg=$(echo "$response" | jq -r '.message // empty')
  if [ -n "$msg" ]; then
    echo "Error: Strava API error during $context: $msg" >&2
    return 1
  fi
}

# --- Get access token ---

ACCESS_TOKEN=$("$SCRIPT_DIR/strava-auth.sh" token) || exit 1

# --- Stats mode ---

if [ "$SHOW_STATS" = true ]; then
  STRAVA_TOKEN_FILE="${STRAVA_TOKEN_FILE:-$HOME/.strava-tokens}"
  ATHLETE_ID=$(jq -r '.athlete_id' "$STRAVA_TOKEN_FILE")

  if [ -z "$ATHLETE_ID" ] || [ "$ATHLETE_ID" = "null" ]; then
    echo "Error: athlete_id not found in token file. Re-run strava-auth.sh setup." >&2
    exit 1
  fi
  if ! [[ "$ATHLETE_ID" =~ ^[0-9]+$ ]]; then
    echo "Error: athlete_id in token file is not a valid numeric ID. Re-run strava-auth.sh setup." >&2
    exit 1
  fi

  RESPONSE=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    "${API_BASE}/athletes/${ATHLETE_ID}/stats" \
    --max-time 30)

  check_api_response "$RESPONSE" "athlete stats" || exit 1

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
      if [ "$(echo "$ELEVATION" | awk '{print ($1 > 0)}')" = "1" ]; then
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
  RESPONSE=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    "${API_BASE}/activities/${DETAIL_ID}" \
    --max-time 30)

  check_api_response "$RESPONSE" "activity detail" || exit 1

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

  NAME=$(echo "$RESPONSE" | jq -r '.name // "Untitled"')
  SPORT_TYPE=$(echo "$RESPONSE" | jq -r '.sport_type // .type // "Workout"')
  START_DATE=$(echo "$RESPONSE" | jq -r '.start_date_local // empty' | sed 's/T/ /;s/Z$//')
  DISTANCE=$(echo "$RESPONSE" | jq -r '.distance // 0')
  MOVING_TIME=$(echo "$RESPONSE" | jq -r '.moving_time // 0')
  ELAPSED_TIME=$(echo "$RESPONSE" | jq -r '.elapsed_time // 0')
  ELEVATION=$(echo "$RESPONSE" | jq -r '.total_elevation_gain // 0')
  AVG_SPEED=$(echo "$RESPONSE" | jq -r '.average_speed // 0')
  MAX_SPEED=$(echo "$RESPONSE" | jq -r '.max_speed // 0')
  AVG_HR=$(echo "$RESPONSE" | jq -r '.average_heartrate // empty')
  MAX_HR=$(echo "$RESPONSE" | jq -r '.max_heartrate // empty')
  AVG_CADENCE=$(echo "$RESPONSE" | jq -r '.average_cadence // empty')
  AVG_WATTS=$(echo "$RESPONSE" | jq -r '.average_watts // empty')
  CALORIES=$(echo "$RESPONSE" | jq -r '.calories // empty')
  SUFFER=$(echo "$RESPONSE" | jq -r '.suffer_score // empty')
  DESCRIPTION=$(echo "$RESPONSE" | jq -r '.description // empty')

  UNIT_MODE=$(activity_unit "$SPORT_TYPE")
  LABEL=$(activity_label "$SPORT_TYPE")

  echo ""
  echo "============================================"
  echo "  ${START_DATE}  ${NAME}"
  echo "  Type: ${LABEL}"
  echo "============================================"
  echo ""

  if [ "$(echo "$DISTANCE" | awk '{print ($1 > 0)}')" = "1" ]; then
    printf "    %-18s %s\n" "Distance:" "$(format_distance "$DISTANCE")"
  fi

  printf "    %-18s %s (moving) / %s (elapsed)\n" "Time:" "$(format_duration "$MOVING_TIME")" "$(format_duration "$ELAPSED_TIME")"

  if [ "$(echo "$AVG_SPEED" | awk '{print ($1 > 0)}')" = "1" ]; then
    case "$UNIT_MODE" in
      pace)
        printf "    %-18s %s\n" "Pace:" "$(format_pace "$AVG_SPEED")"
        printf "    %-18s %s\n" "Best Pace:" "$(format_pace "$MAX_SPEED")"
        ;;
      speed)
        printf "    %-18s %s\n" "Speed:" "$(format_speed "$AVG_SPEED")"
        printf "    %-18s %s\n" "Max Speed:" "$(format_speed "$MAX_SPEED")"
        ;;
      swim)
        printf "    %-18s %s\n" "Pace:" "$(format_swim_pace "$AVG_SPEED")"
        printf "    %-18s %s\n" "Best Pace:" "$(format_swim_pace "$MAX_SPEED")"
        ;;
    esac
  fi

  if [ "$(echo "$ELEVATION" | awk '{print ($1 > 0)}')" = "1" ]; then
    printf "    %-18s %s gain\n" "Elevation:" "$(format_elevation "$ELEVATION")"
  fi

  if [ -n "$AVG_HR" ]; then
    printf "    %-18s %.0f avg / %.0f max bpm\n" "Heart Rate:" "$AVG_HR" "$MAX_HR"
  fi

  if [ -n "$AVG_CADENCE" ]; then
    printf "    %-18s %.0f\n" "Cadence:" "$AVG_CADENCE"
  fi

  if [ -n "$AVG_WATTS" ]; then
    printf "    %-18s %.0f W\n" "Power:" "$AVG_WATTS"
  fi

  if [ -n "$CALORIES" ] && [ "$CALORIES" != "0" ]; then
    printf "    %-18s %.0f\n" "Calories:" "$CALORIES"
  fi

  if [ -n "$SUFFER" ]; then
    printf "    %-18s %.0f\n" "Suffer Score:" "$SUFFER"
  fi

  if [ -n "$DESCRIPTION" ]; then
    echo ""
    echo "  Description: $DESCRIPTION"
  fi

  # Splits (metric)
  SPLITS_COUNT=$(echo "$RESPONSE" | jq '(.splits_metric // []) | length')
  if [ "$SPLITS_COUNT" -gt 0 ] && [ "$SPLITS_COUNT" -le 100 ]; then
    echo ""
    echo "  Splits (per km)"
    echo "  ------------------------------------"
    printf "    %-4s  %-10s  %-10s  %-8s\n" "km" "Pace" "HR" "Elev"
    for i in $(seq 0 $((SPLITS_COUNT - 1))); do
      SPLIT=$(echo "$RESPONSE" | jq ".splits_metric[$i]")
      S_DIST=$(echo "$SPLIT" | jq -r '.distance // 0')
      S_TIME=$(echo "$SPLIT" | jq -r '.moving_time // 0')
      S_ELEV=$(echo "$SPLIT" | jq -r '.elevation_difference // 0')
      S_HR=$(echo "$SPLIT" | jq -r '.average_heartrate // empty')

      if [ "$(echo "$S_DIST" | awk '{print ($1 > 0)}')" = "1" ]; then
        S_SPEED=$(echo "$S_TIME $S_DIST" | awk '{if ($2 > 0) printf "%.4f", $2/$1; else print 0}')
        S_PACE=$(format_pace "$S_SPEED")
      else
        S_PACE="N/A"
      fi

      if [ -n "$S_HR" ]; then
        S_HR_FMT=$(printf "%.0f" "$S_HR")
      else
        S_HR_FMT="—"
      fi

      S_ELEV_FMT=$(printf "%+.0fm" "$S_ELEV")

      printf "    %-4d  %-10s  %-10s  %-8s\n" "$((i + 1))" "$S_PACE" "$S_HR_FMT" "$S_ELEV_FMT"
    done
  fi

  # Laps
  LAPS_COUNT=$(echo "$RESPONSE" | jq '(.laps // []) | length')
  if [ "$LAPS_COUNT" -gt 1 ] && [ "$LAPS_COUNT" -le 100 ]; then
    echo ""
    echo "  Laps"
    echo "  ------------------------------------"
    printf "    %-4s  %-10s  %-10s  %-10s\n" "Lap" "Distance" "Time" "Pace"
    for i in $(seq 0 $((LAPS_COUNT - 1))); do
      LAP=$(echo "$RESPONSE" | jq ".laps[$i]")
      L_DIST=$(echo "$LAP" | jq -r '.distance // 0')
      L_TIME=$(echo "$LAP" | jq -r '.moving_time // 0')
      L_SPEED=$(echo "$LAP" | jq -r '.average_speed // 0')

      L_DIST_FMT=$(format_distance "$L_DIST")
      L_TIME_FMT=$(format_duration "$L_TIME")

      case "$UNIT_MODE" in
        pace) L_PACE_FMT=$(format_pace "$L_SPEED") ;;
        speed) L_PACE_FMT=$(format_speed "$L_SPEED") ;;
        swim) L_PACE_FMT=$(format_swim_pace "$L_SPEED") ;;
        *) L_PACE_FMT="—" ;;
      esac

      printf "    %-4d  %-10s  %-10s  %-10s\n" "$((i + 1))" "$L_DIST_FMT" "$L_TIME_FMT" "$L_PACE_FMT"
    done
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

while true; do
  RESPONSE=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    "${API_BASE}/athlete/activities?after=${START_DATE}&per_page=200&page=${PAGE}" \
    --max-time 30)

  check_api_response "$RESPONSE" "activity list" || exit 1

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

  NAME=$(echo "$ACTIVITY" | jq -r '.name // "Untitled"')
  SPORT_TYPE=$(echo "$ACTIVITY" | jq -r '.sport_type // .type // "Workout"')
  START_DATE_RAW=$(echo "$ACTIVITY" | jq -r '.start_date_local // empty')
  DISTANCE=$(echo "$ACTIVITY" | jq -r '.distance // 0')
  MOVING_TIME=$(echo "$ACTIVITY" | jq -r '.moving_time // 0')
  ELAPSED_TIME=$(echo "$ACTIVITY" | jq -r '.elapsed_time // 0')
  ELEVATION=$(echo "$ACTIVITY" | jq -r '.total_elevation_gain // 0')
  AVG_SPEED=$(echo "$ACTIVITY" | jq -r '.average_speed // 0')
  AVG_HR=$(echo "$ACTIVITY" | jq -r '.average_heartrate // empty')
  MAX_HR=$(echo "$ACTIVITY" | jq -r '.max_heartrate // empty')
  CALORIES=$(echo "$ACTIVITY" | jq -r '.calories // 0')

  DATE_FMT=$(echo "$START_DATE_RAW" | sed 's/T/ /;s/Z$//' | cut -c1-16)

  UNIT_MODE=$(activity_unit "$SPORT_TYPE")

  echo ""
  echo "  ${DATE_FMT}  ${NAME}"
  echo "  ------------------------------------"

  if [ "$(echo "$DISTANCE" | awk '{print ($1 > 0)}')" = "1" ]; then
    printf "    %-18s %s\n" "Distance:" "$(format_distance "$DISTANCE")"
  fi

  printf "    %-18s %s (moving) / %s (elapsed)\n" "Time:" "$(format_duration "$MOVING_TIME")" "$(format_duration "$ELAPSED_TIME")"

  if [ "$(echo "$AVG_SPEED" | awk '{print ($1 > 0)}')" = "1" ]; then
    case "$UNIT_MODE" in
      pace)  printf "    %-18s %s\n" "Pace:" "$(format_pace "$AVG_SPEED")" ;;
      speed) printf "    %-18s %s\n" "Speed:" "$(format_speed "$AVG_SPEED")" ;;
      swim)  printf "    %-18s %s\n" "Pace:" "$(format_swim_pace "$AVG_SPEED")" ;;
    esac
  fi

  if [ "$(echo "$ELEVATION" | awk '{print ($1 > 0)}')" = "1" ]; then
    printf "    %-18s %s gain\n" "Elevation:" "$(format_elevation "$ELEVATION")"
  fi

  if [ -n "$AVG_HR" ]; then
    printf "    %-18s %.0f avg / %.0f max bpm\n" "Heart Rate:" "$AVG_HR" "$MAX_HR"
  fi

  if [ "$CALORIES" != "0" ]; then
    printf "    %-18s %.0f\n" "Calories:" "$CALORIES"
  fi
done

echo ""
echo "============================================"
echo "  ${ACTIVITY_COUNT} activities | Fetched at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"
