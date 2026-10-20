import Foundation

extension Copy {
    /// The sheet that scans another person's verify code (ADR 2026-10.65xx).
    public enum Scan {
        /// What to point the camera at.
        public static var hint: String {
            NSLocalizedString(
                "scan.hint",
                bundle: .main,
                value: "Point the camera at the code on their phone. They'll find it in Knit, under Add contact.",
                comment: "Scanner: over the camera, what to scan"
            )
        }

        /// The camera permission was refused.
        public static var denied: String {
            NSLocalizedString(
                "scan.denied",
                bundle: .main,
                value: "Knit needs the camera to scan a code. Allow it in Settings.",
                comment: "Scanner: the camera permission is refused"
            )
        }

        /// This device has no scanner Knit can use.
        public static var unsupported: String {
            NSLocalizedString(
                "scan.unsupported",
                bundle: .main,
                value: "This device can't scan codes. You can still show yours for the other person to scan.",
                comment: "Scanner: the device cannot scan codes"
            )
        }

        /// The camera failed to start.
        public static var unavailable: String {
            NSLocalizedString(
                "scan.unavailable",
                bundle: .main,
                value: "The camera couldn't start. Try again in a moment.",
                comment: "Scanner: the camera failed to start"
            )
        }
    }
}
