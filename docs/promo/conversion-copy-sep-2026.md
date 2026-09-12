# OpenClient conversion copy — Sep 2026

Goal: Pro conversions from current traffic before Lifetime launch price rises **September 30, 2026** ($19.99 → $29.99).

## App Store — What’s New (paste into next version / promotional window)

```
Lifetime Pro is $19.99 through September 30 (then $29.99).

Unlock unlimited prompts, unlimited sessions, and Project Actions — and keep OpenClient growing.

Free still includes 5 prompts/day and 1 session so you can try it on your own OpenCode server.
```

Shorter variant (if character-tight):

```
Lifetime Pro $19.99 through Sep 30 (then $29.99). Unlimited prompts, sessions, and Project Actions.
```

## In-app review prompt (SKStoreReviewController)

Trigger only after a clear win — never on first launch or on the paywall.

**Best moments (pick one primary):**
1. User successfully answers a permission or question prompt from an active session
2. User returns to an ongoing session via Live Activity / widget and sends a follow-up that succeeds
3. After 3rd successful prompt send in a day (still under free limit) — soft ask before they hit the wall

**Copy if you show a custom pre-prompt (optional; system dialog has no custom title):**
- Title: Enjoying OpenClient?
- Body: A quick rating helps other OpenCode users find the native client.
- Primary: Rate OpenClient
- Secondary: Not now

**Rules:** Max once per version; respect Apple’s quota; never after a failed connection or purchase error.

## Soft Pro nudge (Settings / post-limit adjacent — not the hard paywall)

When free user has used ≥3/5 prompts today and still has sessions:

```
You’re using OpenClient like a daily driver. Pro Lifetime is $19.99 through Sep 30 — unlimited prompts and sessions, plus Project Actions.
```

CTA: Unlock Pro · Dismiss

## X / Discord / OpenCode community post (no spend)

```
If you already run OpenCode and use OpenClient on iPhone/iPad:

Pro Lifetime is $19.99 through Sep 30, then $29.99.

Unlimited prompts + sessions, Project Actions, and it supports the App Store build.

Free stays 5 prompts/day and 1 session.

https://apps.apple.com/us/app/openclient-for-opencode/id6763641767
https://open-client.com/#pricing
```

## GitHub README blurb (optional one-liner under Why OpenClient)

```
App Store build includes optional OpenClient Pro (Lifetime launch pricing through Sep 30) for unlimited prompts/sessions and Project Actions.
```
