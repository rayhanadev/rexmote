import Foundation
import IOKit.pwr_mgt

/// Active sharing keeps the desktop awake. It never changes login or lock settings.
final class PowerLease {
    private var display: IOPMAssertionID = 0, system: IOPMAssertionID = 0, wake: IOPMAssertionID = 0
    var active: Bool { display != 0 }
    func begin() {
        guard !active else { return }
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "rexmote active desktop" as CFString, &display)
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "rexmote active desktop" as CFString, &system)
        IOPMAssertionDeclareUserActivity("rexmote desktop requested" as CFString, kIOPMUserActiveLocal, &wake)
    }
    func end() {
        for id in [display, system, wake] where id != 0 { IOPMAssertionRelease(id) }
        display = 0
        system = 0
        wake = 0
    }
    deinit { end() }
}
