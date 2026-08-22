# iPhoneGPSLocationHelper

Windows-only workflow for obtaining the iPhone's real GPS through a USB tunnel.

## Architecture

iPhone GPS Helper:
- Uses Core Location to obtain the real device latitude/longitude.
- Runs a small TCP/HTTP service on port 18181.
- Returns JSON from `/` such as:
  `{"ok":true,"latitude":25.033964,"longitude":121.564468}`

Windows:
- Keeps using the existing stable iOS USB tunnel.
- Forwards the device port 18181 to Windows localhost.
- Reads `http://127.0.0.1:18181/`.

## Build

No Mac is required on your side. GitHub Actions uses a hosted macOS runner to compile the unsigned IPA.

1. Run the workflow `Build unsigned iPhone GPS Helper`.
2. Download artifact `iPhoneGPSLocationHelper-unsigned-ipa`.
3. Sign/install the IPA with Sideloadly or another trusted sideloading tool.
4. Open the Helper on iPhone and grant Location permission.
5. Keep the Helper open while testing the Windows GPS Controller.

## Important

An unsigned IPA cannot be installed directly on an iPhone. It must be signed with your Apple ID by a sideloading tool.

This first version intentionally keeps the iPhone service simple and local: no cloud server and no Mac-side component.
