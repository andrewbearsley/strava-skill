---
name: activity-tracker
description: Monitor activities from Strava (running, cycling, swimming, etc.) via the Strava API.
version: 1.0.0
homepage: https://github.com/andrewbearsley/strava-skill
metadata: {"openclaw": {"requires": {"bins": ["curl", "jq"], "env": ["STRAVA_CLIENT_ID", "STRAVA_CLIENT_SECRET"]}, "primaryEnv": "STRAVA_CLIENT_ID"}}
---

# Activity Tracker Skill

You can monitor activities from Strava — running, cycling, swimming, hiking, etc. — via the Strava API. Activities sync from GPS watches, bike computers, and phone apps to Strava; the API lets you query activity history and athlete stats.

**API Base URL:** `https://www.strava.com/api/v3`
**Authentication:** OAuth2 Bearer token. Tokens are managed by `strava-auth.sh`. Use `strava-auth.sh token` to get a valid access token (auto-refreshes if expired).

**Important:** Access tokens expire after 6 hours. Refresh tokens do not expire but are rotated on each refresh. The new refresh token MUST be saved immediately or you lose API access until the user re-authorizes.

**All distances are in meters. All speeds are in meters/second. All times are in seconds.**

---

## Configuration

These are the default alert thresholds. The user may edit them here to suit their preferences.

**Activity staleness:**
- No activity in **7 days**: medium alert

**Token health:**
- Token refresh failure: **high alert** (will lose API access if not fixed)

---

## Error Handling

The API can fail in several ways. Handle each:

### API errors

| Error | Handling |
|-------|----------|
| HTTP 401 (Invalid token) | Refresh the token via `strava-auth.sh refresh` and retry once. If refresh also fails, alert: "Strava token expired, re-run `strava-auth.sh setup`." |
| HTTP 429 (Rate limit) | Wait 15 minutes and retry. Do not alert the user unless it persists. |
| HTTP 503 (Service unavailable) | Wait 60 seconds and retry once. Do not alert the user. |
| Connection timeout / network error | Log and skip this check. Alert if it persists across multiple heartbeats. |

### Common setup issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| "Invalid token" on every call | Refresh token was rotated but not saved | Re-run `strava-auth.sh setup` |
| No activities returned | No activities in the date range, or wrong account | Check the date range and verify the Strava account |
| "Authorization Error" | App not authorized or scopes missing | Re-run `strava-auth.sh setup` |
| Token file not found | OAuth setup not completed | Run `strava-auth.sh setup` |
| "STRAVA_CLIENT_ID environment variable is not set" | Credentials not loaded — the refresh token is likely still valid | Don't tell the user to re-authenticate. Alert: "Strava credentials not available — check that STRAVA_CLIENT_ID and STRAVA_CLIENT_SECRET are set in the environment." |

---

## API Reference

### List Athlete Activities (`GET /athlete/activities`)

Returns a list of activities for the authenticated athlete.

```bash
# Easiest: use the helper script
scripts/strava-status.sh --json --days 7

# Or call the API directly:
ACCESS_TOKEN=$(scripts/strava-auth.sh token)
AFTER=$(date -v-7d +%s)  # macOS; use date -d '-7 days' +%s on Linux
curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
  "https://www.strava.com/api/v3/athlete/activities?after=$AFTER&per_page=200"
```

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `before` | int | Unix timestamp — activities before this time |
| `after` | int | Unix timestamp — activities after this time |
| `page` | int | Page number (default: 1) |
| `per_page` | int | Results per page (max: 200, default: 30) |

**Response (array of summary activities):**

```json
[
  {
    "id": 12345678,
    "name": "Morning Run",
    "type": "Run",
    "sport_type": "Run",
    "start_date_local": "2026-02-22T07:30:00Z",
    "distance": 5200.0,
    "moving_time": 1695,
    "elapsed_time": 1742,
    "total_elevation_gain": 42.0,
    "average_speed": 3.07,
    "max_speed": 4.2,
    "average_heartrate": 152.0,
    "max_heartrate": 178.0,
    "calories": 412.0
  }
]
```

### Get Activity Detail (`GET /activities/{id}`)

Returns detailed information about a specific activity, including splits and laps.

```bash
ACCESS_TOKEN=$(scripts/strava-auth.sh token)
curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
  "https://www.strava.com/api/v3/activities/12345678"
```

**Additional fields in detail response:**
- `splits_metric` — per-km splits with pace, HR, elevation
- `laps` — lap data if the activity was recorded with laps
- `average_cadence` — steps/min (run) or rpm (ride)
- `average_watts` — average power (if power meter)
- `suffer_score` — Strava's relative effort score
- `description` — user-added description

### Get Athlete Stats (`GET /athletes/{id}/stats`)

Returns lifetime, year-to-date, and recent stats for the athlete.

```bash
# Easiest: use the helper script
scripts/strava-status.sh --stats

# Or call the API directly:
ACCESS_TOKEN=$(scripts/strava-auth.sh token)
ATHLETE_ID=$(jq -r '.athlete_id' ~/.strava-tokens)
curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
  "https://www.strava.com/api/v3/athletes/$ATHLETE_ID/stats"
```

**Response structure:**

```json
{
  "ytd_run_totals":  {"count": 28, "distance": 234500.0, "moving_time": 87300, "elevation_gain": 1842.0},
  "ytd_ride_totals": {"count": 12, "distance": 480000.0, "moving_time": 54000, "elevation_gain": 3200.0},
  "ytd_swim_totals": {"count": 5,  "distance": 8000.0,   "moving_time": 5400,  "elevation_gain": 0},
  "all_run_totals":  {"count": 500, "distance": 5200000.0, "moving_time": 1800000, "elevation_gain": 42000.0},
  "all_ride_totals": {"count": 200, "distance": 12000000.0, "moving_time": 900000, "elevation_gain": 85000.0},
  "all_swim_totals": {"count": 50,  "distance": 80000.0,   "moving_time": 54000,  "elevation_gain": 0}
}
```

### OAuth2 Token Refresh (`POST /oauth/token`)

```bash
curl -s -X POST https://www.strava.com/api/v3/oauth/token \
  -d "client_id=$STRAVA_CLIENT_ID" \
  -d "client_secret=$STRAVA_CLIENT_SECRET" \
  -d "refresh_token=$REFRESH_TOKEN" \
  -d "grant_type=refresh_token"
```

**Response:**

```json
{
  "token_type": "Bearer",
  "access_token": "new_access_token",
  "refresh_token": "new_refresh_token",
  "expires_at": 1700000000,
  "expires_in": 21600
}
```

**Critical:** The response contains a NEW `refresh_token`. Save it immediately. The old one is invalidated. If you lose the new one, the user has to re-authorize.

---

## Activity Types

| Type | Unit Mode |
|------|-----------|
| Run, TrailRun, VirtualRun, Walk, Hike, NordicSki | pace (/km) |
| Ride, VirtualRide, GravelRide, MountainBikeRide, EBikeRide | speed (km/h) |
| Swim | pace (/100m) |
| WeightTraining, Yoga, Workout, AlpineSki, Snowboard, etc. | time only |

Use the appropriate unit mode for the activity type. Unknown types default to time-only.

---

## Heartbeat Behaviour

When this skill is invoked during a heartbeat check, follow this procedure:

### 1. Get a valid token

```bash
ACCESS_TOKEN=$(scripts/strava-auth.sh token)
```

This auto-refreshes if expired. If it fails, alert immediately.

### 2. Query recent activities

```bash
scripts/strava-status.sh --json --days 7
```

### 3. Check for errors

If the response indicates an error:
- **Token expired and refresh failed:** Alert the user: "Strava token expired. Re-run `strava-auth.sh setup`."
- **API unavailable / rate limited:** Skip silently, retry next heartbeat.
- **No activities returned:** Check if the last activity is older than 7 days. If so, flag as medium alert.

### 4. Parse and evaluate

From any new activities since the last heartbeat, extract:
- **Activity type** (Run, Ride, Swim, etc.)
- **Distance** — in km (or m for short distances)
- **Moving time** — formatted as H:MM:SS
- **Pace** (runs) or **Speed** (rides) — in the appropriate unit
- **Heart rate** — average and max if available
- **Elevation gain** — if significant

### 5. Alert conditions

| Condition | Severity | Message |
|-----------|----------|---------|
| Token refresh failed | High | Strava token expired — re-run `strava-auth.sh setup` |
| No activity in 7 days | Medium | No Strava activity recorded in the last 7 days |
| API error (non-transient) | Medium | Strava API error: {details} |

### 6. Reporting

- **New activity since last heartbeat:** Include a brief summary: type, distance, time, pace/speed, and HR if available.
- **Nothing new:** Do NOT send a message. No noisy "no update" messages.
- **Alert condition detected:** Send the alert regardless of whether there's a new activity.

---

## Responding to User Queries

When the user asks about their activities (e.g. "how was my run?", "show my stats", "how much have I run this month?"):

### Activity queries

1. For the latest activity: `scripts/strava-status.sh --json --days 1` (expand range if needed)
2. For a specific activity: `scripts/strava-status.sh --detail ID --json`
3. Format a clear summary:

```
Latest Activity: Morning Run (2026-02-22 07:30)
  Distance:    5.2 km
  Time:        28:15 (moving)
  Pace:        5:26 /km
  Elevation:   42m gain
  Heart Rate:  152 avg / 178 max bpm
  Calories:    412
```

### Stats queries

For questions like "show my stats" or "how much have I run this year?":
1. Run `scripts/strava-status.sh --stats --json`
2. Present the relevant stats (YTD or all-time)

### Trend queries

For questions like "how much have I run this month?" or "show my last 30 days":
1. Fetch activities with `scripts/strava-status.sh --json --days N`
2. Filter by activity type if needed
3. Calculate totals: sum distance, count activities, total time
4. Present concisely — don't dump raw data

### Convenience scripts

Two helper scripts in the skill's parent project:

- **`scripts/strava-auth.sh`** OAuth2 setup, token refresh, and token retrieval. Run with `setup`, `refresh`, or `token`.
- **`scripts/strava-status.sh`** Activity queries and stats. Run with `--raw`, `--json`, `--days N`, `--detail ID`, `--stats`.

---

## Tips

- Activities sync from GPS devices and apps to Strava. There may be a delay of a few minutes after finishing an activity.
- The `per_page=200` parameter minimizes API calls for the activity list. Use the `after` parameter for date filtering.
- Activity detail (`/activities/{id}`) returns much more data than the list endpoint, including splits and laps. Only fetch detail when the user asks for it.
- Speed is always in m/s in the API. Convert to pace (/km) for runs, speed (km/h) for rides, and pace (/100m) for swims.
- The token file is at the path specified by `STRAVA_TOKEN_FILE` (default: `~/.strava-tokens`). It's chmod 600 for security.
