/// Knit's terms of use (ADR 2026-10.cgm3): rules with no tolerance for objectionable content or abusive people, which
/// everyone agrees to before using Knit, as App Store reviewers ask under guideline 1.2.
public enum Terms {
    /// The version of the terms in this build. Raising it asks everyone to agree again at their next launch, onboarded
    /// or not, so raise it only when the rules themselves change.
    public static let version = 1

    /// The rules, one line each, in the order the page lists them.
    public static var rules: [String] {
        [Copy.Terms.ruleHarassment, Copy.Terms.ruleSexual, Copy.Terms.ruleIllegal, Copy.Terms.ruleSpam]
    }
}
