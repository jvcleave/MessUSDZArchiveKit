# MessUSDZArchiveKit

A Swift package for packaging existing USD layers and assets as USDZ on macOS
15.6 or later. The caller supplies an ordered list of regular staged files,
with the root USD layer first, and a fresh destination. The writer uses stored
ZIP32 members, verifies CRCs as it streams, and aligns member payloads to
64 bytes.

```swift
import MessUSDZArchiveKit

let archiveSize = try USDZArchiveWriter.write(
    [
        .init(name: "Scene.usdc", fileURL: rootLayer),
        .init(name: "textures/albedo.png", fileURL: albedo),
    ],
    to: stagedArchive
)
```

Call on a file worker. Keep source files and the destination directory under
the caller's ownership during the write. The caller publishes the staged
archive and manages its source workspace. The writer cleans up its partial
output on failure or cancellation.
