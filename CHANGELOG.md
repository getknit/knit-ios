---
changelog: "0.1"
product:
  name: Knit for iOS
  vendor: Knit
  homepage: https://getknit.app
  id: knit-ios
  description: Offline, serverless, end-to-end encrypted mesh messenger for iPhone.
  platforms: [ios]
  category: Communication
document:
  updated: 2026-09-25T00:00:00Z
  coverage: complete
  canonical: https://source.jeffmixon.com/knit/knit-ios/-/blob/main/CHANGELOG.md
  locale: en
---

# Knit for iOS changelog

## Unreleased

### Added

- Knit for iPhone has its first screens: onboarding, the Nearby room, direct messages and message requests,
  profiles with safety numbers, Settings and Diagnostics. It finds people over Bluetooth while it's open, and
  keeps its open links going in the background.
- Knit stays readable at the largest text sizes, and its text and buttons meet the contrast WCAG AA sets for
  normal text. Chats, message requests and onboarding rearrange as the text grows, so names and buttons keep
  their room.

## About this file

This heading does not match the release-heading grammar, so a consumer skips it, the same way it skips
`## Unreleased` above.

New entries are held to `.agents/rules/changelog.md`: two sentences, about forty words, run through the
`humanizer` skill. Released sections are a published record and are never restyled.

This changelog follows the provisional changelog standard drafted at [whatsnew.fyi](https://whatsnew.fyi):
YAML frontmatter, one `##` heading per release, newest first, and
[Keep a Changelog](https://keepachangelog.com)'s categories.
