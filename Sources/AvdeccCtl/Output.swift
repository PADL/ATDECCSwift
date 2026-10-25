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

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Where a command's results and diagnostics go.
public protocol OutputSink: Sendable {
  func write(_ text: String)
  func error(_ text: String)
}

/// Standard output and standard error.
public struct StandardOutput: OutputSink {
  public init() {}

  public func write(_ text: String) {
    print(text)
  }

  public func error(_ text: String) {
    let bytes = Array((text + "\n").utf8)
    _ = bytes.withUnsafeBytes { systemWrite(STDERR_FILENO, $0.baseAddress, $0.count) }
  }
}

#if canImport(Glibc)
private let systemWrite = Glibc.write
#elseif canImport(Darwin)
private let systemWrite = Darwin.write
#endif

/// A value in a command's result, printed as text or as JSON.
indirect enum Value: Sendable {
  case string(String)
  case number(Int64)
  case bool(Bool)
  case array([Value])
  case object([Field])

  static func strings(_ strings: [String]) -> Value {
    .array(strings.map(Value.string))
  }

  static func uint(_ value: some BinaryInteger) -> Value {
    .number(Int64(value))
  }
}

typealias Field = (key: String, value: Value)

/// One thing a command reports, such as a descriptor or an entity. Text output prints `heading`
/// and then `fields`; JSON output prints `keys`, which identify the record, and then `fields`.
struct Record: Sendable {
  var heading: String
  var keys: [Field] = []
  var fields: [Field]
}

/// Renders `records` as text: each heading, and its fields indented beneath it.
func renderText(_ records: [Record]) -> String {
  var lines = [String]()
  for record in records {
    lines.append(record.heading)
    appendText(record.fields, indent: "  ", to: &lines)
  }
  return lines.joined(separator: "\n")
}

private func appendText(_ fields: [Field], indent: String, to lines: inout [String]) {
  for (key, value) in fields {
    let label = key.replacingUnderscores()
    switch value {
    case let .object(nested) where nested.count <= 4 && !nested.contains(where: \.value.isCompound):
      lines.append("\(indent)\(label): \(value.text)")
    case let .object(nested):
      lines.append("\(indent)\(label):")
      appendText(nested, indent: indent + "  ", to: &lines)
    case let .array(elements) where elements.contains(where: \.isCompound):
      lines.append("\(indent)\(label):")
      for element in elements {
        if case let .object(nested) = element {
          lines.append("\(indent)  -")
          appendText(nested, indent: indent + "    ", to: &lines)
        } else {
          lines.append("\(indent)  - \(element.text)")
        }
      }
    case let .array(elements) where value.text.count > 72:
      lines.append("\(indent)\(label):")
      for element in elements {
        lines.append("\(indent)  \(element.text)")
      }
    default:
      lines.append("\(indent)\(label): \(value.text)")
    }
  }
}

/// Renders `records` as JSON: an object for one record, otherwise an array of them.
func renderJSON(_ records: [Record], single: Bool) -> String {
  let objects = records.map { Value.object($0.keys + $0.fields) }
  return (single && objects.count == 1 ? objects[0] : .array(objects)).json
}

private extension Value {
  var isCompound: Bool {
    switch self {
    case .array, .object: true
    default: false
    }
  }

  var text: String {
    switch self {
    case let .string(string): string
    case let .number(number): String(number)
    case let .bool(bool): bool ? "yes" : "no"
    case let .array(elements): elements.isEmpty ? "-" : elements.map(\.text).joined(separator: ", ")
    case let .object(fields): fields.map { "\($0.key)=\($0.value.text)" }.joined(separator: " ")
    }
  }

  var json: String {
    switch self {
    case let .string(string): jsonString(string)
    case let .number(number): String(number)
    case let .bool(bool): bool ? "true" : "false"
    case let .array(elements): "[" + elements.map(\.json).joined(separator: ",") + "]"
    case let .object(fields):
      "{" + fields.map { jsonString($0.key) + ":" + $0.value.json }.joined(separator: ",") + "}"
    }
  }
}

private func jsonString(_ string: String) -> String {
  var result = "\""
  for scalar in string.unicodeScalars {
    switch scalar {
    case "\"": result += "\\\""
    case "\\": result += "\\\\"
    case "\n": result += "\\n"
    case "\r": result += "\\r"
    case "\t": result += "\\t"
    case _ where scalar.value < 0x20:
      let digits = String(scalar.value, radix: 16)
      result += "\\u" + String(repeating: "0", count: 4 - digits.count) + digits
    default: result.unicodeScalars.append(scalar)
    }
  }
  return result + "\""
}

private extension String {
  /// `snake_case` keys as words; the standard's `UPPER_CASE` names as they are.
  func replacingUnderscores() -> String {
    contains(where: \.isUppercase) ? self : String(map { $0 == "_" ? " " : $0 })
  }
}
