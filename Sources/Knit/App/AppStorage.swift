#if os(iOS)
    import Foundation
    import KnitMesh
    import KnitStore
    import KnitStoreSQL

    /// Where a live launch keeps what it stores on disk: the database's directory, and the kept prefixes beside its blobs.
    internal enum AppStorage {
        /// The database's own directory, under Application Support, which is backed up unless told otherwise; the
        /// store excludes it (ADR 2026-09.nyya).
        static func databaseDirectory() throws -> URL {
            try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: "Database", directoryHint: .isDirectory)
        }

        /// The bounds of the in-memory fallback: two prefixes and a quarter of the disk's bytes, so a suspended app holds
        /// at most 8 MiB of them beside the 16 MiB its live files share. Android's 32 MiB in memory is what ADR
        /// 2026-10.w6rn turned down.
        private static let inMemoryLimits = PartialBlobBook.Limits(
            maxCount: inMemoryCount, maxBytes: PartialBlobBook.maxBytes / inMemoryShareOfDisk
        )
        private static let inMemoryCount = 2
        private static let inMemoryShareOfDisk = 4

        /// The kept prefixes of cut attachments, in `Partials/` beside `Blobs/` with the database's protection class and
        /// backup exclusion (knit-ios #2), or in memory when that directory cannot be made: a resume is worth no failed
        /// launch. Their lines are the mesh's, in Android's words (`partial <h12> kept <n>B`).
        static func partials(in directory: URL, database: KnitDatabase, log: any KnitLog) -> any PartialBlobStore {
            let line: @Sendable (String) -> Void = { log.log(.info, "mesh \($0)") }
            do {
                let partials = directory.appending(path: FilePartialBlobStore.directoryName, directoryHint: .isDirectory)
                return try FilePartialBlobStore(database, directory: partials, log: line)
            } catch {
                log.log(.warning, "store failed: \(error); kept prefixes stay in memory")
                return MemoryPartialBlobStore(limits: inMemoryLimits, log: line)
            }
        }
    }
#endif
