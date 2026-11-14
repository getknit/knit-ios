// The notes under a name or status the name screen refused (knit-next ADR 2026-11.y4pc), apart so `AccessibilityID`
// stays under the lint's length.
extension AccessibilityID {
    /// What the name page says under the field when it refused a name.
    public static let onboardingNameRefused = "onboarding_name_refused"
    /// What the profile says under the name when Save refused it. Android has no tag here.
    public static let profileNameRefused = "profile_name_refused"
    /// What the profile says under the status when Save refused it. Android has no tag here.
    public static let profileStatusRefused = "profile_status_refused"
}
