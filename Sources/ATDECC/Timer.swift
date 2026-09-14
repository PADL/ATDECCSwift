//
// Copyright (c) 2024-2026 PADL Software Pty Ltd
//
// Licensed under the Apache License, Version 2.0 (the License);
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an 'AS IS' BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Dispatch
import Synchronization

// A running timer is a dispatch timer source rather than a task sleeping until its deadline.
// AECP and ACMP timers are almost always stopped long before they expire (the response
// arrives within milliseconds), and a cancelled `Task.sleep` stays enqueued, holding its
// task's memory, until the deadline it was sleeping towards (swiftlang/swift#60441). A
// cancelled source is unregistered at once.
final class Timer: CustomStringConvertible, Sendable {
  typealias Action = @Sendable () async -> ()

  /// One start of the timer: `generation` tells its source's event from that of a start or
  /// stop since.
  private struct Arm {
    let source: any DispatchSourceTimer
    let generation: UInt64
  }

  private struct State {
    var arm: Arm?
    var generation = UInt64(0)
  }

  /// Every timer's events are handled here; a handler only takes a lock and starts a task.
  private static let _queue = DispatchQueue(label: "com.padl.AVDECCSwift.Timer")

  private let _label: String
  private let _onExpiry: Action
  private let _state = Mutex(State())

  var description: String {
    "Timer(\(_label))"
  }

  init(label: String, onExpiry: @escaping Action) {
    _label = label
    _onExpiry = onExpiry
  }

  func start(interval: Duration) {
    let priority = Task.currentPriority
    _state.withLock { state in
      state.arm?.source.cancel()
      state.generation &+= 1
      let generation = state.generation
      let source = DispatchSource.makeTimerSource(queue: Self._queue)
      // weak, so that a timer its owner has released is stopped by deinit rather than kept
      // alive until it fires
      source.setEventHandler { [weak self] in
        self?._fire(generation: generation, priority: priority)
      }
      source.schedule(deadline: ._after(interval))
      source.activate()
      state.arm = Arm(source: source, generation: generation)
    }
  }

  private func _fire(generation: UInt64, priority: TaskPriority) {
    // clear the arm before calling the action, so isRunning is false during it; an event
    // from a start that has since been superseded is ignored
    let isCurrent = _state.withLock { state in
      guard let arm = state.arm, arm.generation == generation else { return false }
      arm.source.cancel()
      state.arm = nil
      return true
    }
    guard isCurrent else { return }

    Task(priority: priority) {
      await _onExpiry()
    }
  }

  func stop() {
    _state.withLock { state in
      state.arm?.source.cancel()
      state.arm = nil
      state.generation &+= 1
    }
  }

  deinit {
    stop()
  }

  var isRunning: Bool {
    _state.withLock { $0.arm != nil }
  }
}

private extension DispatchTime {
  /// `interval` from now, computed in 64-bit nanoseconds because
  /// `DispatchTimeInterval.nanoseconds` takes an `Int`, which overflows after about two
  /// seconds on a 32-bit platform.
  static func _after(_ interval: Duration) -> DispatchTime {
    let now = DispatchTime.now()
    guard interval > .zero else { return now }
    let (seconds, attoseconds) = interval.components
    let (wholeSeconds, overflow) = UInt64(seconds).multipliedReportingOverflow(by: 1_000_000_000)
    let (nanoseconds, subsecondOverflow) = wholeSeconds
      .addingReportingOverflow(UInt64(attoseconds / 1_000_000_000))
    let (deadline, lateOverflow) = now.uptimeNanoseconds.addingReportingOverflow(nanoseconds)
    guard !overflow, !subsecondOverflow, !lateOverflow else { return .distantFuture }
    return DispatchTime(uptimeNanoseconds: deadline)
  }
}
