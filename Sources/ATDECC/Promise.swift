//
// Copyright (c) 2026 PADL Software Pty Ltd
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

import Synchronization

/// A value that is resolved exactly once, possibly before anyone awaits it. Used to hand a
/// command's response from the receive path to the task that sent the command.
final class Promise<Value: Sendable>: Sendable {
  private enum State {
    case pending([CheckedContinuation<Value, any Error>])
    case resolved(Result<Value, any Error>)
  }

  private let _state = Mutex(State.pending([]))

  init() {}

  /// Resolves the promise, returning false if it was already resolved.
  @discardableResult
  func resolve(_ result: Result<Value, any Error>) -> Bool {
    let continuations: [CheckedContinuation<Value, any Error>]? = _state.withLock { state in
      guard case let .pending(continuations) = state else { return nil }
      state = .resolved(result)
      return continuations
    }
    guard let continuations else { return false }
    for continuation in continuations {
      continuation.resume(with: result)
    }
    return true
  }

  var value: Value {
    get async throws {
      try await withCheckedThrowingContinuation { continuation in
        let result: Result<Value, any Error>? = _state.withLock { state in
          switch state {
          case let .pending(continuations):
            state = .pending(continuations + [continuation])
            return nil
          case let .resolved(result):
            return result
          }
        }
        if let result {
          continuation.resume(with: result)
        }
      }
    }
  }
}
