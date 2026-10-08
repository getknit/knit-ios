import Foundation

extension Copy {
    /// The terms of use (ADR 2026-10.cgm3): what nobody may send, and what a report does, agreed to in onboarding and
    /// readable in About.
    public enum Terms {
        /// The page's heading, and About's row.
        public static var title: String {
            NSLocalizedString("terms.title", bundle: .main, value: "Terms of use", comment: "Terms: the page's heading and About's row")
        }

        /// What the rules are for, over the list.
        public static var intro: String {
            NSLocalizedString(
                "terms.intro",
                bundle: .main,
                value: "Knit has zero tolerance for objectionable content and abusive people. By using Knit, you agree not to send:",
                comment: "Terms: over the list of rules"
            )
        }

        /// The first rule.
        public static var ruleHarassment: String {
            NSLocalizedString(
                "terms.rule.harassment",
                bundle: .main,
                value: "Harassment, threats or hate aimed at anyone",
                comment: "Terms: a rule, what nobody may send"
            )
        }

        /// The second rule.
        public static var ruleSexual: String {
            NSLocalizedString(
                "terms.rule.sexual",
                bundle: .main,
                value: "Sexual content involving anyone under 18, or sexual content sent to someone who didn't want it",
                comment: "Terms: a rule, what nobody may send"
            )
        }

        /// The third rule.
        public static var ruleIllegal: String {
            NSLocalizedString(
                "terms.rule.illegal",
                bundle: .main,
                value: "Anything illegal, or anything that promotes violence or exploits people",
                comment: "Terms: a rule, what nobody may send"
            )
        }

        /// The fourth rule.
        public static var ruleSpam: String {
            NSLocalizedString(
                "terms.rule.spam",
                bundle: .main,
                value: "Spam, scams or messages pretending to be someone else",
                comment: "Terms: a rule, what nobody may send"
            )
        }

        /// What happens to someone who breaks them, under the list.
        public static var enforcement: String {
            NSLocalizedString(
                "terms.enforcement",
                bundle: .main,
                value: """
                    If someone breaks these rules, report them. Knit deletes their message from your phone and blocks them, and \
                    you can send the report to the Knit team.
                    """,
                comment: "Terms: under the rules, what a report does"
            )
        }

        /// The button that agrees, in onboarding and when the terms change.
        public static var agree: String {
            NSLocalizedString("terms.agree", bundle: .main, value: "Agree and continue", comment: "Terms: the button that agrees to them")
        }
    }
}
