# Watch Together

A Flutter browser shell that will grow into a watch-together app.

![Watch Together browser shell](docs/home.jpeg)

## Milestones 1 & 2 — the browser

- Back / forward / home / reload controls
- Address bar that accepts a URL, a bare domain, or a search query
- Bookmark bar with default shortcuts, add-current-page, and long-press to remove (with undo)
- Custom dark start page
- WebView powered by `flutter_inappwebview`
- **Ad blocker, on by default** — see below

### Ad blocker & tap protection

The shield chip at the start of the bookmark bar shows `Ads: blocked` by
default. Tap it to switch to `Ads: allowed`. It works in five ways:

1. Network requests to known ad, popunder and tracker hosts are dropped.
2. Navigation to those hosts (including popup links) is cancelled.
3. An injected style sheet hides ad-like elements.
4. `window.open` is only followed when it points at the same site or at the
   link the user just tapped; unrelated popups are counted and discarded.
5. **Tap-hijack protection**: a click on a real link goes straight to that
   link, so invisible overlays or click-tracking scripts cannot redirect a
   movie poster to an unrelated site. Links that would normally open in a new
   tab are loaded in the same page instead.

The small number on the chip counts how many requests/popups/redirects were
blocked in the current session. This is a lightweight, conservative blocker
rather than a full EasyList-style filter engine. It resets to **on** each time
the app starts.

## Run it

```powershell
# Web preview (Edge)
flutter run -d edge

# Android (phone or emulator connected)
flutter run

# Checks
flutter analyze
flutter test
```

## Watch Together (rooms)

The app opens on a **home page**:

- Your display name is shown and can be edited and saved. New users get a random name automatically.
- **Create room** generates a room code (copied to the clipboard) and opens the room.
- **Join group** lets you enter a friend's room code.
- **Previous rooms** lists rooms you created or joined; tap one to re-enter it.

Inside the room:

- Top bar: copy room code (left), browser button, and back/leave (right).
- A 16:9 video area, then a controller bar for the host.
- Below that: chat message preview, full chat and a message input box.

Tap the browser button to open the ad-blocked browser we built; from there you
can visit video websites, then use **Back to room** to return.

In the browser, the top-right **cast** button is a trigger: it sends the
current page itself to the room. Everyone's 16:9 screen loads that page and
injected CSS/JS keeps only the player portion (a `<video>` element, or the
player `<iframe>` when the video lives in another frame) — all other page UI
is hidden. Viewers do not need to open a browser — they simply wait in the room.

Supabase Realtime powers chat, reactions, presence and playback events.

### Supabase setup

The included build is already connected to a Supabase project through
`lib/config.dart`. To use your own project, paste its **Project URL** and
**anon/public (publishable) key** from Project Settings -> API into that file.
No database tables or RLS policies are needed — rooms use Supabase Realtime
broadcast, which was verified with a host -> viewer delivery test.

Never put the `service_role` key in this file.

## Downloads

Ready-made, split APKs are available in the
[v0.3.7 release](https://github.com/liton021/watch-together/releases/tag/v0.3.7).

## Build APKs

```powershell
# One slim APK per CPU architecture
flutter build apk --release --split-per-abi
```

Outputs in `build/app/outputs/flutter-apk/`:

| APK | Use |
|---|---|
| `app-arm64-v8a-release.apk` (16.5 MB) | Almost all modern phones |
| `app-armeabi-v7a-release.apk` (14.0 MB) | Older 32-bit phones |
| `app-x86_64-release.apk` (17.8 MB) | Emulators / Chromebooks |

All three support **Android 7.0+** (`minSdk 24`) and target Android 16
(`targetSdk 36`). They are currently signed with the debug key for
side-loading. Add a release keystore before publishing to a store. For Google
Play, build an app bundle instead (`flutter build appbundle`); Play then serves
the right split automatically.

Install one with:

```powershell
C:\Users\Liton\Android\Sdk\platform-tools\adb.exe install -r build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
```

## Notes

- On the web build the page is an **iframe**, so cross-origin sites cannot
  report their URL or load state back to the toolbar, and sites that send
  `X-Frame-Options` will not render. Android uses a real WebView where all
  controls work normally.
- Android needs the internet permission, already added in
  `android/app/src/main/AndroidManifest.xml`.
- Bookmark order and edits currently live in memory only (they reset on restart).

## Next up

- Persist bookmarks
- Multiple tabs
- Rooms, synced playback and chat
