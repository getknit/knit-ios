import Foundation

/// Every string a person reads in the app, in one place (`.agents/rules/copy.md`). Views never hold text of their
/// own: they read it here, so a change of wording is one edit, and the product-language pass sees all of it.
///
/// Each string is a literal `NSLocalizedString` call, which Xcode extracts into a String Catalog. The catalog uses
/// `NSLocalizedString(_:value:comment:)` rather than `String(localized:)`, because Foundation on Linux has no
/// `LocalizationValue` and KnitAppCore builds and tests there. Counts come as two keys, `.one` and `.other`, until
/// a translation needs the catalog's plural rules.
public enum Copy {
    /// The product name, which is never translated.
    public static let productName = "Knit"

    /// `template` filled with `arguments` in the current locale, so counts group their digits.
    static func format(_ template: String, _ arguments: any CVarArg...) -> String {
        String(format: template, locale: .current, arguments: arguments)
    }

    /// The singular or plural form of a count, filled with the count.
    static func count(_ count: Int, one: String, other: String) -> String {
        format(count == 1 ? one : other, count)
    }
}

extension Copy {
    /// Words many screens share.
    public enum Common {
        /// A button that closes a sheet without changing anything.
        public static var cancel: String {
            NSLocalizedString("common.cancel", bundle: .main, value: "Cancel", comment: "Button: close without changing anything")
        }

        /// A button that saves an edit.
        public static var save: String {
            NSLocalizedString("common.save", bundle: .main, value: "Save", comment: "Button: save an edit")
        }

        /// A button that closes a sheet once it has done its job.
        public static var done: String {
            NSLocalizedString("common.done", bundle: .main, value: "Done", comment: "Button: close a finished sheet")
        }

        /// A button that opens this app's page in the Settings app.
        public static var openSettings: String {
            NSLocalizedString(
                "common.open-settings",
                bundle: .main,
                value: "Open Settings",
                comment: "Button: open Knit's page in the Settings app"
            )
        }

        /// How our own messages and name read in a list: "You: see you there".
        public static var you: String {
            NSLocalizedString(
                "common.you",
                bundle: .main,
                value: "You",
                comment: "Stands for the user in a message preview or sender line"
            )
        }
    }

    /// Text the system shows on the app's behalf. `App/Info.plist` holds a copy, and a test keeps the two equal.
    public enum System {
        /// `NSBluetoothAlwaysUsageDescription`: why Knit asks for Bluetooth.
        public static var bluetoothUsage: String {
            NSLocalizedString(
                "system.bluetooth-usage",
                bundle: .main,
                value: """
                    Knit uses Bluetooth to find people nearby and pass messages from phone to phone, so you can chat without internet or \
                    cell service.
                    """,
                comment: "The system's Bluetooth permission prompt"
            )
        }

        /// `NSCameraUsageDescription`: why Knit asks for the camera.
        public static var cameraUsage: String {
            NSLocalizedString(
                "system.camera-usage",
                bundle: .main,
                value: """
                    Knit uses the camera to scan the code on someone's phone and check that no one is intercepting your direct \
                    messages with them.
                    """,
                comment: "The system's camera permission prompt"
            )
        }
    }
}

extension Copy {
    /// The screen shown until the app can read its keys.
    public enum Launch {
        /// Its heading.
        public static var waitingTitle: String {
            NSLocalizedString("launch.waiting.title", bundle: .main, value: "Unlock to start Knit", comment: "Launch: the keys are locked")
        }

        /// Why Knit waits.
        public static var waitingBody: String {
            NSLocalizedString(
                "launch.waiting.body",
                bundle: .main,
                value: """
                    Knit keeps its keys locked until this phone has been unlocked once since it was turned on. It starts on its own after \
                    that.
                    """,
                comment: "Launch: why Knit waits for the first unlock"
            )
        }

        /// The button that tries again.
        public static var retry: String {
            NSLocalizedString("launch.retry", bundle: .main, value: "Try Again", comment: "Launch: button that tries to start again")
        }
    }
}
