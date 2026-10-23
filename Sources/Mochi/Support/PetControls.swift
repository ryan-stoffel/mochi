import Foundation

/// The pet's settings, as Settings sees them. They live in the pet's `App` (UserDefaults plus side effects like
/// resizing its window), so Settings reads and changes them through this instead of touching either.
///
/// `petState()` is flat: `scale` (Double: 2, 3, 4 or 6), `provider` (claude | codex | antigravity | cursor), and Bools
/// for `roam`, `appAware`, `emoji`, `quiet`, `login`, `visible` and every reminder/agent toggle (`waterReminders`,
/// `walkReminders`, `stretchReminders`, `lunchReminders`, `coffeeReminders`, `bedtimeReminders`, `cheers`, `claudeDone`,
/// `claudeFetch`, `showSessions`, `follow`, `narrate`). `setPet` takes the same keys with "true"/"false", a number, or a
/// provider id, plus `corner` (any value) to bring the pet back to its corner.
@MainActor
protocol PetControls: AnyObject {
    func petState() -> [String: Any]
    func setPet(_ key: String, _ value: String)
}
