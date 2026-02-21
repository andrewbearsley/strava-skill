# AI agent skill for Strava activity tracking

![Format](https://img.shields.io/badge/format-Agent%20Skill-blue)
![Bash](https://img.shields.io/badge/bash-%23121011?logo=gnu-bash&logoColor=white)
![License](https://img.shields.io/github/license/andrewbearsley/strava-skill)

Monitor activities from [Strava](https://www.strava.com/) (running, cycling, swimming, etc.) via the [Strava API](https://developers.strava.com/). Built as an [OpenClaw](https://openclaw.ai) skill, but the scripts work fine standalone too.

Tracks distance, pace/speed, heart rate, elevation, cadence, and power. Activities sync from GPS watches, bike computers, and phone apps to Strava; the skill queries the API to pull them down.

## Agent quick-start

If you're an AI agent and your user has pointed you at this repo, here's how to install the skill without cloning.

**Requirements:** `curl`, `jq` must be available on the system.

**1. Download the skill and scripts:**

```bash
REPO="https://raw.githubusercontent.com/andrewbearsley/strava-skill/main"
SKILL_DIR="$HOME/.openclaw/skills/activity-tracker"
SCRIPT_DIR="$SKILL_DIR/scripts"

mkdir -p "$SCRIPT_DIR"
curl -fsSL "$REPO/skills/activity-tracker/SKILL.md" -o "$SKILL_DIR/SKILL.md"
curl -fsSL "$REPO/scripts/strava-auth.sh"            -o "$SCRIPT_DIR/strava-auth.sh"
curl -fsSL "$REPO/scripts/strava-status.sh"          -o "$SCRIPT_DIR/strava-status.sh"
chmod +x "$SCRIPT_DIR"/*.sh
```

**2. Set environment variables:**

The skill requires two environment variables. Ask your user for these if they haven't provided them:

| Variable | Required | What it is | Where to find it |
|----------|----------|-----------|-----------------|
| `STRAVA_CLIENT_ID` | Yes | OAuth2 client ID | Strava Settings > My API Application |
| `STRAVA_CLIENT_SECRET` | Yes | OAuth2 client secret | Strava Settings > My API Application |
| `STRAVA_TOKEN_FILE` | No | Path to store tokens (default: `~/.strava-tokens`) | Configurable |

Set them in `~/.openclaw/.env` or in your agent's environment.

**3. Run the OAuth2 setup (one-time, requires user interaction):**

```bash
$SCRIPT_DIR/strava-auth.sh setup
```

The user opens a URL in their browser, authorizes the app, and pastes back the redirect URL.

**4. Verify it works:**

```bash
# Check recent activities
$SCRIPT_DIR/strava-status.sh

# Check JSON output
$SCRIPT_DIR/strava-status.sh --json

# Check athlete stats
$SCRIPT_DIR/strava-status.sh --stats
```

**5. Read the SKILL.md** for full API reference, alert thresholds, and heartbeat behaviour. Everything the agent needs is in that file.

## What it does

- Recent activity summaries (distance, time, pace/speed, HR, elevation, calories)
- Detailed activity view with splits, laps, and power data
- Athlete lifetime and year-to-date stats
- Heartbeat monitoring that stays quiet unless something's noteworthy
- Automatic token refresh (6-hour access tokens, rotated refresh tokens)

## Human setup

You'll need to do these steps before the agent can use the skill.

### 1. Create a Strava API application

1. Go to [Strava API Settings](https://www.strava.com/settings/api)
2. Log in to your Strava account
3. Fill in the form:
   - **Application Name:** whatever you like (e.g. "OpenClaw Activity Tracker")
   - **Category:** choose any
   - **Website:** `http://localhost`
   - **Authorization Callback Domain:** `localhost`
4. Note your **Client ID** and **Client Secret**

### 2. Run the OAuth2 authorization

```bash
export STRAVA_CLIENT_ID=your_client_id
export STRAVA_CLIENT_SECRET=your_client_secret

./scripts/strava-auth.sh setup
```

Follow the prompts: open the URL, log in, authorize, paste the redirect URL back.

### 3. Give your agent the credentials

Add the environment variables to `~/.openclaw/.env`:

```
STRAVA_CLIENT_ID=your_client_id
STRAVA_CLIENT_SECRET=your_client_secret
STRAVA_TOKEN_FILE=~/.strava-tokens
```

Then point your agent at this repo and ask it to install the skill.

## Usage

### Activities

```bash
./scripts/strava-status.sh              # Formatted summary (last 7 days)
./scripts/strava-status.sh --raw        # Raw JSON from the API
./scripts/strava-status.sh --json       # Parsed JSON with readable values
./scripts/strava-status.sh --days 30    # Last 30 days of activities
./scripts/strava-status.sh --detail ID  # Detailed view with splits and laps
./scripts/strava-status.sh --stats      # Athlete lifetime/YTD stats
```

### Token management

```bash
./scripts/strava-auth.sh setup          # One-time OAuth2 authorization
./scripts/strava-auth.sh refresh        # Manually refresh access token
./scripts/strava-auth.sh token          # Get valid access token (auto-refreshes)
```

### Heartbeat

If your agent supports heartbeat checks:

```markdown
- [ ] Check Strava via the activity-tracker skill. If there's a new activity
      since the last check, include a brief summary (type, distance, time,
      pace). Alert me if the API is unreachable or tokens have expired.
      Don't message me if there's nothing new.
```

## What it alerts on

| Condition | Severity |
|-----------|----------|
| Token refresh failure | High |
| No activity in 7 days | Medium |

All thresholds are configurable in `SKILL.md`. The skill stays quiet when everything's normal.

## Troubleshooting

| Problem | What's going on | Fix |
|---------|-----------------|-----|
| "Token file not found" | OAuth setup not completed | Run `strava-auth.sh setup` |
| "Invalid token" on every call | Refresh token was rotated but not saved | Re-run `strava-auth.sh setup` |
| No activities returned | No activities in date range, or wrong account | Check the date range and verify the Strava account |
| "Authorization Error" | App not authorized or scopes missing | Re-run `strava-auth.sh setup` |
| Token refresh keeps failing | Refresh token was lost or app deauthorized | Re-run `strava-auth.sh setup` |

## Rate limits

Strava enforces 200 requests per 15 minutes and 2,000 per day. Not a concern for this use case.

## Files

| File | Purpose |
|------|---------|
| `skills/activity-tracker/SKILL.md` | Skill definition: API reference, alert thresholds, agent instructions |
| `scripts/strava-auth.sh` | OAuth2 setup and token management |
| `scripts/strava-status.sh` | Query activities and athlete stats |
| `HEARTBEAT.md` | Heartbeat config template |

## License

MIT
