Mermaid offline fallback bundle

Version: 10.9.8
Bundle: mermaid.min.js
Source: https://cdn.jsdelivr.net/npm/mermaid@10.9.8/dist/mermaid.min.js
Repository: https://github.com/mermaid-js/mermaid
License: MIT (see ../ThirdPartyNotices/Mermaid.txt)
Size: 3337857 bytes
SHA-256: 8d607d7ef1d077a8aa202e18e62212bfa992c68bfeabc5cf45d51a128fe6675d

Why 10.x:
- MT Agent supports iOS 15/16 WebKit.
- Mermaid 12.x targets Safari 17.4+ / ES2024.
- Mermaid 11 has known compatibility failures on older Safari/iOS.
- The 10.x IIFE bundle remains suitable for the legacy WebKit fallback path.

Runtime policy:
- Native UIKit/CoreGraphics flowchart and sequenceDiagram renderers stay the fast path.
- This bundle is loaded only when the native renderer does not support the
  standard Mermaid diagram family.
- The fallback WKWebView is non-persistent and network access is blocked.
- structuredClone/Object.hasOwn compatibility polyfills are injected before
  Mermaid for older iOS WebKit.

Upgrade rule:
Do not replace this bundle only because a newer Mermaid release exists. Verify
the minimum supported Safari/iOS version first, then update this file, SHA-256,
license notice and real-device coverage for iOS 15/16.
