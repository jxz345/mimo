extension DaemonService {
    // Test-only admission boundary; production queue/dispatch/storage are intact.
    func rapidIntentTestHoldMutation(_ held: Bool) { mutationInProgress = held }
}
