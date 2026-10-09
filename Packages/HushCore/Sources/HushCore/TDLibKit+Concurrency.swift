@preconcurrency import TDLibKit

// TDLibKit predates Swift concurrency annotations. Its manager and clients route all work
// through their own dispatch queues and locked dictionaries, and its generated models are
// immutable value types, so sharing them across isolation domains is safe.
extension TDLibClientManager: @retroactive @unchecked Sendable {}
extension TDLibClient: @retroactive @unchecked Sendable {}
extension Update: @retroactive @unchecked Sendable {}
