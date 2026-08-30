// touchid-gate — present a macOS biometric prompt and exit 0 only if the human approves.
//
// This is the approval layer for `opgate`. It exists because 1Password's desktop app
// integration authorizes the CLI per *terminal session*: after the first Touch ID
// prompt, every later `op` call in that session succeeds silently. That is fine for a
// human at a keyboard and wrong for an agent, so we gate each access ourselves.
//
// Exit codes:  0 approved · 1 denied or cancelled · 2 biometrics unavailable
//              64 bad usage

import Foundation
import LocalAuthentication

let args = Array(CommandLine.arguments.dropFirst())
var allowPassword = false
var reason: String?

var i = 0
while i < args.count {
    switch args[i] {
    case "--allow-password":
        allowPassword = true
    case "--reason":
        i += 1
        guard i < args.count else {
            FileHandle.standardError.write(Data("touchid-gate: --reason needs a value\n".utf8))
            exit(64)
        }
        reason = args[i]
    case "-h", "--help":
        print("usage: touchid-gate [--allow-password] --reason <text>")
        exit(0)
    default:
        // Bare argument is treated as the reason, so `touchid-gate "text"` works too.
        if reason == nil { reason = args[i] } else {
            FileHandle.standardError.write(Data("touchid-gate: unexpected argument \(args[i])\n".utf8))
            exit(64)
        }
    }
    i += 1
}

guard let localizedReason = reason, !localizedReason.isEmpty else {
    FileHandle.standardError.write(Data("touchid-gate: --reason is required\n".utf8))
    exit(64)
}

let context = LAContext()

// Without this, macOS reuses a recent unlock and the sheet never appears — which would
// silently defeat the whole point of gating every access.
context.touchIDAuthenticationAllowableReuseDuration = 0

let policy: LAPolicy = allowPassword ? .deviceOwnerAuthentication
                                     : .deviceOwnerAuthenticationWithBiometrics

var policyError: NSError?
guard context.canEvaluatePolicy(policy, error: &policyError) else {
    let detail = policyError?.localizedDescription ?? "unknown reason"
    FileHandle.standardError.write(Data("touchid-gate: unavailable — \(detail)\n".utf8))
    exit(2)
}

let semaphore = DispatchSemaphore(value: 0)
var approved = false
var failure: Error?

context.evaluatePolicy(policy, localizedReason: localizedReason) { success, error in
    approved = success
    failure = error
    semaphore.signal()
}

// A lost callback would otherwise hang the calling shell forever. Ten minutes is
// far longer than any real person needs and still bounded.
if semaphore.wait(timeout: .now() + 600) == .timedOut {
    FileHandle.standardError.write(Data("touchid-gate: timed out waiting for a decision\n".utf8))
    exit(2)
}

if approved { exit(0) }

if let error = failure as NSError?, error.domain == LAErrorDomain {
    // Only these mean the human declined. systemCancel (another app came forward)
    // and appCancel (the context was invalidated) are the prompt never getting a
    // fair chance, so they must read as "unavailable" — otherwise a passing app
    // switch is recorded in the audit log as your refusal.
    let denied = error.code == LAError.userCancel.rawValue
              || error.code == LAError.userFallback.rawValue
              || error.code == LAError.authenticationFailed.rawValue
    FileHandle.standardError.write(Data("touchid-gate: \(error.localizedDescription)\n".utf8))
    exit(denied ? 1 : 2)
}

if let error = failure {
    // Not an LAError at all — we cannot claim this was a refusal.
    FileHandle.standardError.write(Data("touchid-gate: unexpected error — \(error.localizedDescription)\n".utf8))
    exit(2)
}

exit(1)
