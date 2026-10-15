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
- Report someone from a message's menu, their profile or their request, and your iPhone deletes the message
  and blocks them without telling them. Choose Report and Email Knit to send the Knit team what you reported,
  minus any photo.
- Onboarding now asks you to agree to Knit's terms of use, which rule out harassment, sexual content involving
  minors, illegal content and spam. If you set Knit up before the terms existed, you'll see them once at your
  next launch, and About keeps a copy beside a link to Knit's privacy policy.
- Content filtering hides explicit photos from other people until you tap them, and shows an initial in place
  of an explicit profile picture. Your iPhone checks each photo itself, and Knit won't post an explicit photo
  in Nearby or use one as your profile picture.
- Content filtering also hides abusive messages from other people until you tap them, in chats, the chat list
  and notifications. Your iPhone checks each message as it arrives, and Knit won't post abuse or profanity in
  Nearby, where everyone in range reads it.
- Content filtering now catches slurs aimed at a person in direct messages and groups, not only in Nearby. It
  uses the same word list as Knit for Android, so both phones hide the same words.
- Long-press a message to copy or delete it, or swipe a chat or request to delete it and Nearby to clear it.
  Only your iPhone forgets them: other phones keep their copies, and you stay in any group whose chat you
  delete.
- Long-press a message to react with one of six emoji, and see the reactions Android phones send, whichever
  emoji they pick. Reactions travel unencrypted, so phones that pass them on can see who reacted to a message,
  though never what it says.
- Scroll up into a chat's older messages and Knit keeps your place as new ones arrive, with a button in the
  corner that jumps back to the newest. Sending a message still takes you straight down to it.
- GIFs and animated stickers now play in chats and full screen, including ones sent from Android phones, and
  the chat list calls them GIFs. They stay still if you turn off Auto-Play Animated Images in Settings.
- Settings has a Support Knit page that rates Knit on the App Store or shares it with a friend. On the US App
  Store it also links to Ko-fi, Liberapay and GitHub Sponsors, for anyone who wants to leave a tip.
- Swipe a message or choose Reply from its menu to answer it with a quote, and tap the quote to jump back to
  the original. Replies work in Nearby, direct messages and groups, including with Android phones.
- See when someone is typing, at the bottom of a chat in Nearby, direct messages and groups, and let them see
  when you are, on Android phones too. Typing indicators travel unencrypted, and only to the phones linked
  directly to yours.
- Type @ in Nearby, a direct message or a group to mention someone, including people on Android phones. Names
  you mention stand out in the message, and a message that mentions you gets a notification of its own.
- Pick @everyone when you type @ in a group to mention every other member at once. Each of them sees the name
  stand out and gets a mention notification, on Android phones too.
- Each chat in your list now shows how many messages you haven't read, and opening the chat clears the count.
  Knit's icon adds up your direct messages and groups, while Nearby keeps its count on its own row.

### Changed

- Your iPhone now links with any nearby Android phone within about 30 seconds of both opening Knit. Some
  Android phones used to take several minutes to find it, and longer when their screen was off.
- Knit now wears Knit for Android's coral, groups each person's messages with a date over every day, and puts
  your picture at the top of Chats as the way into Settings. On iOS 26 and later its buttons and composer use
  Liquid Glass, and Increase Contrast deepens its text colors.
- Your iPhone now asks nearby phones which of them has a photo and fetches it from just one, straight from
  the phone that posted it whenever that phone still has it. Messages now rarely wait behind several copies
  of the same photo.
- An Android phone sending your iPhone a photo now sees how fast it arrives, so if the copy stalls, others
  waiting for that photo start getting theirs about 15 seconds later. Your iPhone also waits on a photo a
  phone says is coming instead of fetching another copy.
- Fewer spare copies of a photo now hold up your messages. Once your iPhone has a photo, or turns to another
  phone for it, it tells the Android phones it asked to drop any copy they haven't started sending.
- Chats now draws no lines between rows, shows shorter times such as "7m" and "Tue", and drops the second
  ring around your picture. Longer explanations in Settings now sit behind info buttons, and the encryption
  sheet fits its text.
- Photos and GIFs you send now leave at the size Android's do, about half for a photo and usually far less
  for a GIF, so they cross the mesh faster. A photo you send again keeps its quality.
- A photo you save from Knit and send again now goes as the same copy, so phones that already have it don't
  fetch it, and a GIF keeps moving. When someone in a chat shares a photo your iPhone has, it shows its own
  copy.
- A message you send while a photo is going out now arrives in about two seconds instead of minutes, because
  your iPhone paces the photo by what the other phone reports taking in. Until Android phones update to report
  it, photos you send them go more slowly than before.

## About this file

This heading does not match the release-heading grammar, so a consumer skips it, the same way it skips
`## Unreleased` above.

New entries are held to `.agents/rules/changelog.md`: two sentences, about forty words, run through the
`humanizer` skill. Released sections are a published record and are never restyled.

This changelog follows the provisional changelog standard drafted at [whatsnew.fyi](https://whatsnew.fyi):
YAML frontmatter, one `##` heading per release, newest first, and
[Keep a Changelog](https://keepachangelog.com)'s categories.
