# Heartbeat - Activity Tracker

Add the following checklist item to the agent's workspace `HEARTBEAT.md` to enable
automatic activity monitoring on the heartbeat cycle:

```markdown
- [ ] Check Strava via the activity-tracker skill. If there's a new activity
      since the last check, include a brief summary (type, distance, time,
      pace). Alert me if the API is unreachable or tokens have expired.
      Don't message me if there's nothing new.
```

## What the agent will do on each heartbeat

1. Get a valid access token (auto-refreshes if expired)
2. Query recent activities via the Strava API
3. Parse activity type, distance, time, pace/speed, and heart rate
4. Check for alert conditions (token failure, stale data)
5. **Only notify the user if there's a new activity or something is wrong.** Silent otherwise

## Alert thresholds

| Condition | Action |
|-----------|--------|
| Token refresh failed | Alert immediately (will lose API access) |
| No activity in 7 days | Medium alert (no activities synced recently) |
| API error (non-transient) | Alert with error details |
