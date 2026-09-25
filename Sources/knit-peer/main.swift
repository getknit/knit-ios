import Foundation

#if os(Linux)
    import KnitBlueZ

    // P4 turns this into the headless peer. Until then it proves the Linux-only link line builds.
    FileHandle.standardError.write(Data("knit-peer: libdbus \(KnitBlueZ.libdbusVersion())\n".utf8))
#else
    FileHandle.standardError.write(Data("knit-peer drives BlueZ, so it runs on Linux only.\n".utf8))
    exit(1)
#endif
