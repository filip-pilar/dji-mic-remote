import Foundation
import IOKit.hid

/// Enumerates matching devices without opening/seizing their input streams.
/// All callbacks and state changes run on the main run loop.
final class ReceiverMonitor {
    var onWillChange: (() -> Void)?
    var onChange: (() -> Void)?
    var connected: Bool { !devices.isEmpty }
    private var devices: Set<IOHIDDevice> = []
    private var manager: IOHIDManager?
    private var notification: DispatchWorkItem?
    private var generation = 0

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: ReceiverIdentity.vendor, kIOHIDProductIDKey: ReceiverIdentity.product] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, _, device in
            guard let context, result == kIOReturnSuccess else { return }
            let monitor = Unmanaged<ReceiverMonitor>.fromOpaque(context).takeUnretainedValue()
            if monitor.devices.insert(device).inserted { monitor.changed() }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let monitor = Unmanaged<ReceiverMonitor>.fromOpaque(context).takeUnretainedValue()
            if monitor.devices.remove(device) != nil { monitor.changed() }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        // Seed devices already present. Matching callbacks for these are deduplicated.
        devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        changed()
    }

    private func changed() {
        onWillChange?()
        generation += 1
        let token = generation
        notification?.cancel()
        // One receiver can expose several HID interfaces. Let their callbacks
        // settle before reading service mappings; immediately suspend key delivery.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.manager != nil, token == self.generation else { return }
            self.notification = nil
            self.onChange?()
        }
        notification = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    func stop() {
        generation += 1
        notification?.cancel(); notification = nil
        guard let manager else { return }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        self.manager = nil
        devices.removeAll()
    }

    deinit { stop() }
}
