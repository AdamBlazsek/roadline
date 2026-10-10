# Roadline — one-time iPhone edition

Native SwiftUI port of Roadline Android 1.4.2, for iPhone and iPad running iOS 17 or newer. This is an independent iOS project. Android remains the main application; no Android source, version or APK has been changed for this port.

## Included

- GPS journey recording, drift rejection, accuracy and gap filtering, background location configuration, separate driving, idle and total elapsed time.
- Large responsive dashboard with tap toggles for current/average speed, covered/remaining distance, current/average consumption and used/remaining fuel. Spring transitions, numerical text transitions, haptics, Reduce Motion support, accessible labels and text fitting.
- Stops and numbered legs; measured fuel to 0.01 L, cumulative or per-leg entry, separate pump refills, completion while paused, maps, leg speed and fuel charts, persistent history and deletion.
- Tank capacity, default starting fuel, estimated remaining fuel/range, editable remaining distance, ETA based on the latest five minutes of time-weighted speed including stationary intervals.
- Experimental E32 M30B30 manual fuel curves matching the Android app; idle fuel and shifts at 34/52/72/95 km/h. Predictions are estimates, not engine readings.
- Roadline, Ocean, Sunset and BMW Night themes; System, Classic, Technical and licensed BMW-style Barlow Condensed font choices. Adjustable text, speed panel width and supporting panel sizes. Keep-screen-on setting outside recording mode.
- Existing Roadline Live service, compatible browser links, per-trip sharing consent, independent 256-bit view/write tokens, stable-link retries and Keychain persistence. Coordinates are never in the sharing payload.

The visual system carries Roadline's Material-inspired color, rounded shapes and motion into native SwiftUI controls. It does not claim to be Google's Android Material component implementation.

## Build without a Mac

The repository contains a manually runnable GitHub Actions workflow using a hosted Mac. It also runs on relevant changes to `main` for this initial build. No Apple credentials are required to compile and test or produce an **unsigned** device IPA.

1. Open the repository's **Actions → Roadline one-time iOS build**.
2. Run the workflow and wait for both the simulator tests and device build to pass.
3. Download the **Roadline-iOS-1.4.2-unsigned** artifact and extract the IPA.
4. Sign and install it using AltStore Classic/AltServer on Windows and your own Apple account. Follow the official setup guide: https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows . Enter your Apple credentials only in your chosen signing tool, never in this repository or chat.

An unsigned IPA cannot be installed directly by tapping it. Free-account signing has Apple's expiry and active-app limits; check the signing tool's current instructions. For TestFlight/App Store distribution, an Apple Developer Program account and distribution signing are required: https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases . Signing/provisioning and physical iPhone testing are separate from the cloud compile.

Once this one-time build is complete, future work returns to Android/APKs. You may disable the iOS workflow in GitHub Actions to prevent later runs.

## Build with Xcode

Open `Roadline.xcodeproj`, select scheme **Roadline**, select an iPhone simulator, and run tests. For a connected iPhone, choose your own team in Signing & Capabilities, use an available bundle identifier, enable Developer Mode when asked, and run. Automatic signing is configured, but no team or private credentials are supplied.

Command-line equivalents on a Mac:

```sh
bash build-ios.sh test
bash build-ios.sh device
```

The second command intentionally creates an unsigned device build for subsequent signing. It does not create a TestFlight archive.

## Recording and privacy

Enable Precise Location and permit background location for active journeys. GPS coordinates and trip histories are stored in the app's protected local data file. Locking the screen can preserve an active recording; force-quitting the app stops updates. Reopening checks authorization before resuming. Route gaps are not counted as distance, and no fuel is inferred during an unobserved gap.

Live statistics use `https://roadline-live-journeys.fabledduck.chatgpt.site` only after per-trip consent. Each viewing URL contains a private fragment token; the separate publishing secret stays in a device-only Keychain item. A restored phone does not recover publishing credentials. Links expire after seven days. Retry does not deliberately replace a confirmed URL; Stop sharing clears credentials only after the server accepts revocation. Local trip deletion waits for active sharing revocation.

Foreground sharing attempts run approximately every ten seconds; while moving in the background, GPS callbacks drive updates. iOS may suspend the app when paused, so paused elapsed time can appear stale to a friend until the next update. The viewer shows update freshness. The app does not pretend to have an unrestricted background timer.

Fuel-used entry and fuel-added entry are distinct. Tank level and range are estimates; measured-leg fuel replaces that leg's estimated use. Unknown current readings and speeds outside the supplied E32 curves display a dash. A pause assumes engine off; stationary recording assumes engine on.

## Validation

`RoadlineTests/JourneyTests.swift` exercises drift rejection, poor accuracy, jumps, gaps, movement, rolling ETA, idle fuel, pause behavior, measured-leg economy, refills, E32 interpolation, persistence, timestamp units, sharing payload privacy, explicit unavailable-reading nulls, sharing error wording and corrupt/unreadable file protection. An integration test creates a synthetic trip on the approved live relay, verifies token roles and native updates, then revokes it. Hosted build results are the authority for compilation and test status. The workflow captures native home/dashboard/BMW screenshots using simulator-only synthetic fixtures; that fixture code is excluded from device Release builds. Real-device GPS, screen lock behavior, accessibility and installation still require an iPhone check.

Fonts are distributed under the SIL Open Font License in `Roadline/fonts/Barlow-OFL.txt`. Barlow Condensed approximates the late-1980s cluster reference; it is not the original BMW font. There are no third-party code packages or embedded tracking SDKs.

The Xcode project can be regenerated deterministically with `python3 tools/generate-project.py` after source files are added. That script does not download dependencies.
