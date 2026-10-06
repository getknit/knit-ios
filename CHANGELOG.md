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
  canonical: https://github.com/getknit/knit-ios/blob/main/CHANGELOG.md
  locale: en
---

# Knit for iOS changelog

## Unreleased

### Added

- Knit for iPhone has its first screens: onboarding, the Nearby room, direct messages and message requests,
  profiles with safety numbers, Settings and Diagnostics. It finds people over Bluetooth while it's open and
  stays linked to them in the background, where phones that can wake it deliver messages at once.
- Knit stays readable at the largest text sizes, and its text and buttons meet the contrast WCAG AA sets for
  normal text. Chats, message requests and onboarding rearrange as the text grows, so names and buttons keep
  their room.
- Tap New message to write to someone you've chatted with or verified, or pick up to seven of them to start a
  group you can rename or leave. Groups started on Android phones work too, and group messages that reached
  your iPhone in the day before you update show up in their chats.
- A person's profile now shows your code, and Scan their code reads theirs with the camera, so you can verify
  someone without reading forty digits aloud. It works with Android phones too, and Knit asks for the camera
  the first time you scan.
- When your iPhone loses its last connection with Knit in the background, it now finds nearby phones and
  reconnects on its own instead of waiting for you to open the app. If the phones it finds won't connect, it
  stops after a few tries until Knit is next open.
- Photos and profile pictures now pass through an iPhone on their way across the mesh. A phone that asks for
  one gets the iPhone's copy, or the iPhone fetches it first, so the picture reaches people its sender never
  meets.
- Chats, profiles and groups now show each person's photo, or their initial on a color that's the same on
  every phone, Android included. Set your own photo in your profile, and tap anyone's photo to see it full
  size. People nearby see your photo, just like your name.
- Send photos in Nearby, direct messages and groups, see the ones Android phones send, and tap any photo to
  view it full size or save it to Photos. Those sent in direct messages and groups are end-to-end encrypted,
  while photos in Nearby are public, like everything posted there.
- Android phones can now show how much of a photo from your iPhone has arrived, with a ring that fills and a
  count such as 84 kB of 204 kB. Photos your iPhone passes on for other people get the ring too, on Android
  versions that have it.
- Block someone from their profile or a message request, and what they send stops showing on your iPhone,
  without them being told. Your iPhone still passes their messages on to others, and Settings lists everyone
  you've blocked so you can unblock them.
- Content filtering hides explicit photos from other people until you tap them, and shows an initial in place
  of an explicit profile picture. Your iPhone checks each photo itself, and Knit asks before you send an
  explicit one and won't post it in Nearby.
- Content filtering also hides abusive messages from other people until you tap them, in chats, the chat list
  and notifications. Your iPhone checks each message as it arrives, and Knit won't send one that looks abusive
  or post profanity in Nearby.
- Long-press a message to copy or delete it, or swipe a chat or request to delete it and Nearby to clear it.
  Only your iPhone forgets them: other phones keep their copies, and you stay in any group whose chat you
  delete.
- Long-press a message to react with one of six emoji, and see the reactions Android phones send, whichever
  emoji they pick. Reactions travel unencrypted, so phones that pass them on can see who reacted to a message,
  though never what it says.
- Scroll up into a chat's older messages and Knit keeps your place as new ones arrive, with a button in the
  corner that jumps back to the newest. Sending a message still takes you straight down to it.

### Changed

- Knit now wears Knit for Android's coral, groups each person's messages with a date over every day, and puts
  your picture at the top of Chats as the way into Settings. On iOS 26 and later its buttons and composer use
  Liquid Glass, and Increase Contrast deepens its text colors.
- Your iPhone now asks the phone that posted a photo for it first, and other nearby phones only if that
  one hasn't started sending within a few seconds. Messages now rarely wait behind several copies of the
  same photo.

## About this file

This heading does not match the release-heading grammar, so a consumer skips it, the same way it skips
`## Unreleased` above.

New entries are held to `.agents/rules/changelog.md`: two sentences, about forty words, run through the
`humanizer` skill. Released sections are a published record and are never restyled.

This changelog follows the provisional changelog standard drafted at [whatsnew.fyi](https://whatsnew.fyi):
YAML frontmatter, one `##` heading per release, newest first, and
[Keep a Changelog](https://keepachangelog.com)'s categories.
