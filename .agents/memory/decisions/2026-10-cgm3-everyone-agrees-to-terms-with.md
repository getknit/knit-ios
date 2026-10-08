---
id: "2026-10.cgm3"
slug: everyone-agrees-to-terms-with
title: "Everyone agrees to terms with zero tolerance before using Knit"
date: 2026-10-07
topics: [moderation, onboarding, ui]
---

# ADR 2026-10.cgm3 — Everyone agrees to terms with zero tolerance before using Knit

Status: Accepted (2026-10-07)

**Context:** App Store reviewers check guideline 1.2 against a checklist, and its first item is to "require that
users agree to terms (EULA) and these terms must make it clear that there is no tolerance for objectionable content
or abusive users". The checklist appears in rejections quoted on Apple's developer forums in 2025 and 2026. Knit had
filtering, block and report (ADR 2026-10.rpmq, ADR 2026-10.e4kz, ADR 2026-10.5wgg, ADR 2026-10.f6kf), but no terms.
Onboarding went from welcome to the name. Knit for Android has no terms either.

Apple's standard EULA, which applies when an app sets none, says nothing about content between users.

**Decision:** a terms page in the app, which everyone agrees to before using Knit.

- **In onboarding**, between the welcome and the name: `OnboardingStep.terms`, so the progress line reads "Step 1 of
  3". Its one button is Agree and continue (`OnboardingModel.acceptTerms`). There is no Decline: anyone who does not
  agree stops there, as in other apps' onboarding.
- **Versioned:** `Terms.version` is 1. `AppPreferences.acceptedTerms` keeps the version agreed to, in UserDefaults
  under `acceptedTerms`, where a key never written reads 0. An install that onboarded before the terms existed, or
  before they last changed, sees the terms page alone before the app opens (`ReadyView`). Raise the version only when
  the rules change.
- **The text** names zero tolerance for objectionable content and abusive people, then four rules: no harassment,
  threats or hate; no sexual content involving anyone under 18, or sent to someone who did not want it; nothing
  illegal, violent or exploitative; no spam, scams or impersonation. A footer says what to do about someone who
  breaks them: report them, which deletes the message and blocks them on your phone and can go to the Knit team. It
  promises no removal Knit cannot do.
- **In About**, Terms of use opens the same rules, read-only.
- **The tests' launches:** the demo agrees for an onboarded launch and not for `-demoOnboarding`. The lab iPhone's
  `LiveKnit.launch` passes `-acceptedTerms 1` in UserDefaults' argument domain, so a device test opens on the app.
  `PermissionTests` still walks the terms in onboarding.

The alternatives:

- **A custom EULA in App Store Connect alone:** the user never sees it in the app, and the checklist says "agree".
  The same rules can still go in that field.
- **A link to terms on the website:** that would make a page outside the repo part of what passes review, and Knit
  needs no network to work.
- **Terms on the welcome page:** that page sells what Knit does, and its button reads Get started. Agreeing to rules
  belongs on a page whose button says so.

**Consequences / limits:**

- **The rules are user-facing copy, and they are also a commitment.** They went through the copy editors. A lawyer
  should read them before the store submission, as `.agents/rules/copy.md` asks for legal text.
- **Nothing enforces them centrally.** The terms say what a report does and no more. The review notes have to
  explain that.
- **Changing a rule's wording without raising the version** leaves everyone's agreement in place. That is right for a
  typo fix, and wrong for a new rule.
- **Android has no terms.** A paired change can bring the same page to Android.
- **The trap:** a test that launches with `hasOnboarded` set but no `acceptedTerms` lands on the terms page instead
  of the app. `MemoryPreferences` defaults `acceptedTerms` to 0 on purpose, so a test states which it means.
- **The guards:** `TermsTests` (onboarding's order, the gate for an install that onboarded earlier, a newer version
  asking again, and `LiveKnit`'s argument matching `Terms.version`), `OnboardingAndSettingsTests`' step order,
  `CopyCatalogTests`' terms strings, and `KnitUITests`' onboarding walk, which audits the terms page, and its
  Settings walk, which audits About's terms.
