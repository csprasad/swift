//===--- LifetimeDependenceScopeFixup.swift ----------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===---------------------------------------------------------------------===//
///
/// LifetimeDependenceScopeFixup pass dependencies:
///
/// - must run after OSSA lifetime completion (and before invalidation)
///
/// - must run after LifetimeDependenceInsertion
///
/// - must run before LifetimeDependenceDiagnostics
///
/// Step 1. LifetimeDependenceInsertion inserts 'mark_dependence [unresolved]' instructions for applies that return a
/// lifetime dependent value.
///
/// Step 2. LifetimeDependenceScopeFixup visits each 'mark_dependence [unresolved]'. If the dependence base is an access
/// scope, then it extends the access and any parent accesses to cover all uses of the dependent value.
///
/// Step 3. DiagnoseStaticExclusivity diagnoses an error for any overlapping access scopes. We prefer to diagnose a
/// static exclusivity violation over a escaping violation. LifetimeDependenceScopeFixup is, therefore, allowed to
/// create overlapping access scopes.
///
/// Step 4. LifetimeDependenceDiagnostics visits each 'mark_dependence [unresolved]' again and will report a violation
/// for any dependent use that was not covered by the access scope.
///
/// This is conceptually a SILGen cleanup pass, because lifetime dependencies are invalid before it runs.
///
//===---------------------------------------------------------------------===//

import SIL

private let verbose = false

private func log(prefix: Bool = true, _ message: @autoclosure () -> String) {
  if verbose {
    debugLog(prefix: prefix, message())
  }
}

/// LifetimeDependenceScopeFixup visits each mark_dependence [unresolved]. It finds the access scope of the dependence
/// base and extends it to cover the dependent uses.
///
/// If the base's access scope ends before a dependent use:
///
///     %dependentVal = mark_dependence [unresolved] %v on %innerAccess
///     end_access %innerAccess
///     apply %f(%dependentVal)
///
/// Then sink the end_access:
///
///     %dependentVal = mark_dependence [unresolved] %v on %innerAccess
///     end_access %innerAccess
///     apply %f(%dependentVal)
///
/// Recursively extend all enclosing access scopes up to an owned value or function argument. If the inner dependence is
/// on a borrow scope, extend it first:
///
///     %outerAccess = begin_access %base
///     %innerAccess = begin_access %outerAccess
///     %innerBorrow = begin_borrow [var_decl] %innerAccess
///     %dependentVal = mark_dependence [unresolved] %v on %innerBorrow
///     end_borrow %innerBorrow
///     end_access %innerAccess
///     end_access %outerAccess
///     apply %f(%dependentVal)
///
/// Is rewritten as:
///
///     apply %f(%dependentVal)
///     end_borrow %innerBorrow
///     end_access %innerAccess
///     end_access %outerAccess
///
/// If the borrow scope is not marked [var_decl], then it has no meaningful scope for diagnostics. Rather than extending
/// such scope, could redirect the dependence base to its operand:
///
///     %dependentVal = mark_dependence [unresolved] %v on %innerAccess
///
/// If a dependent use is on a function return:
///
///     sil @f $(@inout) -> () {
///     bb0(%0: $*T)
///       %outerAccess = begin_access [modify] %0
///       %innerAccess = begin_access %outerAccess
///       %dependentVal = mark_dependence [unresolved] %v on %innerAccess
///       end_access %innerAccess
///       end_access %outerAccess
///       return %dependentVal
///
/// Then rewrite the mark_dependence base operand to a function argument:
///
///       %dependentVal = mark_dependence [unresolved] %v on %0
///
let lifetimeDependenceScopeFixupPass = FunctionPass(
  name: "lifetime-dependence-scope-fixup")
{ (function: Function, context: FunctionPassContext) in
  log(prefix: false, "\n--- Scope fixup for lifetime dependence in \(function.name)")

  let localReachabilityCache = LocalVariableReachabilityCache()

  for instruction in function.instructions {
    guard let markDep = instruction as? MarkDependenceInstruction else {
      continue
    }
    guard let innerLifetimeDep = LifetimeDependence(markDep, context) else {
      continue
    }
    // Redirect the dependence base to ignore irrelevant borrow scopes.
    let newLifetimeDep = markDep.rewriteSkippingBorrow(scope: innerLifetimeDep.scope, context)

    // Recursively sink enclosing end_access, end_borrow, or end_apply.
    let args = extendScopes(dependence: newLifetimeDep, localReachabilityCache, context)

    // Redirect the dependence base to the function arguments. This may create additional mark_dependence instructions.
    markDep.redirectFunctionReturn(to: args, context)
  }
}

private extension MarkDependenceInstruction {
  /// Rewrite the mark_dependence base operand to ignore inner borrow scopes (begin_borrow, load_borrow).
  ///
  /// Note: this could be done as a general simplification, e.g. after inlining. But currently this is only relevant for
  /// diagnostics.
  func rewriteSkippingBorrow(scope: LifetimeDependence.Scope, _ context: FunctionPassContext) -> LifetimeDependence {
    guard let newScope = scope.ignoreBorrowScope(context) else {
      return LifetimeDependence(scope: scope, markDep: self)!
    }
    let newBase = newScope.parentValue
    if newBase != self.baseOperand.value {
      self.baseOperand.set(to: newBase, context)
    }
    return LifetimeDependence(scope: newScope, markDep: self)!
  }

  func redirectFunctionReturn(to args: SingleInlineArray<FunctionArgument>, _ context: FunctionPassContext) {
    var updatedMarkDep: MarkDependenceInstruction?
    for arg in args {
      guard let currentMarkDep = updatedMarkDep else {
        self.baseOperand.set(to: arg, context)
        updatedMarkDep = self
        continue
      }
      switch currentMarkDep {
      case let mdi as MarkDependenceInst:
        updatedMarkDep = mdi.redirectFunctionReturnForward(to: arg, input: mdi, context)
      case let mdi as MarkDependenceAddrInst:
        updatedMarkDep = mdi.redirectFunctionReturnAddress(to: arg, context)
      default:
        fatalError("unexpected MarkDependenceInstruction")
      }
    }
  }
}

private extension MarkDependenceInst {
  /// Rewrite the mark_dependence base operand, setting it to a function argument.
  ///
  /// This is called when the dependent value is returned by the function and the dependence base is in the caller.
  func redirectFunctionReturnForward(to arg: FunctionArgument, input: MarkDependenceInst,
    _ context: FunctionPassContext) -> MarkDependenceInst {
    // To handle more than one function argument, new mark_dependence instructions will be chained.
    let newMarkDep = Builder(after: input, location: input.location, context)
      .createMarkDependence(value: input, base: arg, kind: .Unresolved)
    let uses = input.uses.lazy.filter {
      let inst = $0.instruction
      return inst != newMarkDep
    }
    uses.replaceAll(with: newMarkDep, context)
    return newMarkDep
  }
}

private extension MarkDependenceAddrInst {
  /// Rewrite the mark_dependence_addr base operand, setting it to a function argument.
  ///
  /// This is called when the dependent value is returned by the function and the dependence base is in the caller.
  func redirectFunctionReturnAddress(to arg: FunctionArgument, _ context: FunctionPassContext)
    -> MarkDependenceAddrInst {
    return Builder(after: self, location: self.location, context)
        .createMarkDependenceAddr(value: self.address, base: arg, kind: .Unresolved)
  }
}

/// Transitively extend nested scopes that enclose the dependence base.
///
/// If the parent function returns the dependent value, then this returns the function arguments that represent the
/// caller's scope.
///
/// Note that we cannot simply rewrite the `mark_dependence` to depend on an outer access scope. Although that would be
/// valid for a 'read' access, it would not accomplish anything useful. An inner 'read' can always be extended up to
/// the end of its outer 'read'. A nested 'read' access can never interfere with another access in the same outer
/// 'read', because it is impossible to nest a 'modify' access within a 'read'. For 'modify' accesses, however, the
/// inner scope must be extended for correctness. A 'modify' access can interfere with other 'modify' access in the same
/// scope. We rely on exclusivity diagnostics to report these interferences. For example:
///
///     sil @foo : $(@inout C) -> () {
///       bb0(%0 : $*C):
///         %a1 = begin_access [modify] %0
///         %d = apply @getDependent(%a1)
///         mark_dependence [unresolved] %d on %a1
///         end_access %a1
///         %a2 = begin_access [modify] %0
///         ...
///         end_access %a2
///         apply @useDependent(%d) // exclusivity violation
///         return
///     }
///
// The above call to `@useDependent` is an exclusivity violation because it uses a value that depends on a 'modify'
// access. This scope fixup pass must extend '%a1' to cover the `@useDependent` but must not extend the base of the
// `mark_dependence` to the outer access `%0`. This ensures that exclusivity diagnostics correctly reports the
// violation, and that subsequent optimizations do not shrink the inner access `%a1`.
private func extendScopes(dependence: LifetimeDependence,
                          _ localReachabilityCache: LocalVariableReachabilityCache,
                          _ context: FunctionPassContext) -> SingleInlineArray<FunctionArgument> {
  log("Scope fixup for lifetime dependent instructions: \(dependence)")

  // Each scope extension is a set of nested scopes and an owner. The owner is a value that represents ownerhip of the
  // outermost scope, which cannot be extended; it limits how far the nested scopes can be extended.
  guard let scopeExtensions = dependence.scope.gatherExtensions(context) else {
    return SingleInlineArray()
  }
  var dependsOnArgs = SingleInlineArray<FunctionArgument>()
  for scopeExtension in scopeExtensions {
    var scopeExtension = scopeExtension
    guard var useRange = computeDependentUseRange(of: dependence, within: &scopeExtension, localReachabilityCache,
                                                  context) else {
      continue
    }

    // deinitializes 'useRange'
    guard scopeExtension.tryExtendScopes(over: &useRange, context) else {
      continue
    }
    if scopeExtension.dependsOnCaller, let arg = scopeExtension.dependsOnArg {
      dependsOnArgs.push(arg)
    }
  }
  return dependsOnArgs
}

/// All scopes nested within a single dependence base that require extension.
private struct ScopeExtension {
  /// The ownership lifetime of the dependence base, which cannot be extended.
  let owner: Value

  /// The scopes nested under 'value' that may be extended, in inside-out order. There is always at
  /// least one element, otherwise there is nothing to consider extending.
  let nestedScopes: SingleInlineArray<LifetimeDependence.Scope>

  var innerScope: LifetimeDependence.Scope { get { nestedScopes.first! } }

  /// `dependsOnArg` is set to the function argument that represents the caller's dependency source.
  ///
  /// Note: for non-address owners, this is equivalent to: owner as? FunctionArg?
  var dependsOnArg: FunctionArgument?

  /// `dependsOnCaller` is true if the dependent value is returned by the function.
  /// Initialized during computeDependentUseRange().
  var dependsOnCaller = false
}

private extension LifetimeDependence.Scope {
  /// The instruction that introduces an extendable scope. This returns a non-nil scope introducer for
  /// each scope in ScopeExtension.nestedScopes.
  var extendableBegin: ScopedInstruction? {
    switch self {
    case let .access(beginAccess):
      return beginAccess
    case let .borrowed(beginBorrow):
      return beginBorrow.value.definingInstruction as? ScopedInstruction
    case let .yield(yieldedValue):
      return yieldedValue.definingInstruction as? ScopedInstruction
    case let .initialized(initializer):
      switch initializer {
      case let .store(initializingStore: store, initialAddress: _):
        if let sb = store as? StoreBorrowInst {
          return sb
        }
        return nil
      case .argument, .yield:
        // TODO: extend indirectly yielded scopes.
        return nil
      }
    default:
      return nil
    }
  }

  /// Precondition: the 'self' scope encloses a dependent value. 'innerScopes' are the extendable scopes enclosed by
  /// 'self' that also enclose the dependent value.
  ///
  /// Gather the list of ScopeExtensions. Each extension is a list of scopes, including 'innerScopes', 'self' and,
  /// recursively, any of its enclosing scopes that are extendable. We may have multiple extensions because a scope
  /// introducer may itself depend on multiple operands.
  ///
  /// Return 'nil' if 'self' is not extendable.
  func gatherExtensions(innerScopes: SingleInlineArray<LifetimeDependence.Scope>? = nil, _ context: FunctionPassContext)
    -> SingleInlineArray<ScopeExtension>? {

    // Note: LifetimeDependence.Scope.extend() will assume that all inner scopes begin with a ScopedInstruction.
    var innerScopes = innerScopes ?? SingleInlineArray()
    switch self {
    case let .access(beginAccess):
      return gatherAccessExtension(beginAccess: beginAccess, innerScopes: &innerScopes, context)

    case let .borrowed(beginBorrow):
      // begin_borrow is extendable, so push this scope.
      innerScopes.push(self)
      return gatherBorrowExtension(borrowedValue: beginBorrow.baseOperand!.value, innerScopes: innerScopes, context)

    case let .yield(yieldedValue):
      // A yield is extendable, so push this scope.
      innerScopes.push(self)
      // Create a separate ScopeExtension for each operand that the yielded value depends on.
      var extensions = SingleInlineArray<ScopeExtension>()
      let applySite = yieldedValue.definingInstruction as! BeginApplyInst
      for operand in applySite.parameterOperands {
        guard let dep = applySite.resultDependence(on: operand), dep.isScoped else {
          continue
        }
        // Pass a copy of innerScopes without modifying this one.
        extensions.append(contentsOf: gatherOperandExtension(on: operand, innerScopes: innerScopes, context))
      }
      return extensions
    case let .initialized(initializer):
      switch initializer {
      case let .store(initializingStore: store, initialAddress: _):
        if let sb = store as? StoreBorrowInst {
          innerScopes.push(self)
          // Only follow the source of the store_borrow. The address is always an alloc_stack without any access scope.
          return gatherBorrowExtension(borrowedValue: sb.source, innerScopes: innerScopes, context)
        }
        return nil
      case .argument, .yield:
        // TODO: extend indirectly yielded scopes.
        return nil
      }
    default:
      return nil
    }
  }

  /// Unlike LifetimeDependenceInsertion this does not use gatherVariableIntroducers. The purpose here is to extend
  /// any enclosing OSSA scopes as far as possible to achieve the longest possible owner lifetime, rather than to
  /// find the "dependence root" for a call argument.
  func gatherOperandExtension(on operand: Operand, innerScopes: SingleInlineArray<LifetimeDependence.Scope>,
                              _ context: FunctionPassContext) -> SingleInlineArray<ScopeExtension> {
    let enclosingScope = LifetimeDependence.Scope(base: operand.value, context)
    if let extensions = enclosingScope.gatherExtensions(innerScopes: innerScopes, context) {
      return extensions
    }
    // This is the outermost scope to be extended because gatherExtensions did not find an enclosing scope.
    return SingleInlineArray(element: getOuterExtension(owner: operand.value, nestedScopes: innerScopes, context))
  }

  func getOuterExtension(owner: Value, nestedScopes: SingleInlineArray<LifetimeDependence.Scope>,
                         _ context: FunctionPassContext) -> ScopeExtension {
    let dependsOnArg = owner as? FunctionArgument
    return ScopeExtension(owner: owner, nestedScopes: nestedScopes, dependsOnArg: dependsOnArg)
  }

  // Find the nested access scopes that may be extended as if they are the same access. This includes any combination of
  // read/modify accesses, regardless of whether they may cause an exclusivity violation. The outer accesses will only
  // be extended as far as required such that the innermost access coveres all dependent uses.
  // Set ScopeExtension.dependsOnArg if the nested accesses are all compatible with the argument's convention. Then, if
  // all nested accesses were extended to the return statement, it is valid to logically combine them into a single
  // access for the purpose of diagnostinc lifetime dependence.
  func gatherAccessExtension(beginAccess: BeginAccessInst,
                             innerScopes: inout SingleInlineArray<LifetimeDependence.Scope>,
                             _ context: FunctionPassContext) -> SingleInlineArray<ScopeExtension> {
    // Finding the access base also finds all intermediate nested scopes; there is no need to recursively call
    // gatherExtensions().
    let accessBaseAndScopes = beginAccess.accessBaseWithScopes
    var isCompatibleAccess = true
    for nestedScope in accessBaseAndScopes.scopes {
      switch nestedScope {
      case let .access(nestedBeginAccess):
        innerScopes.push(.access(nestedBeginAccess))
        if nestedBeginAccess.accessKind != beginAccess.accessKind {
          isCompatibleAccess = false
        }
      case .dependence, .base:
        // ignore recursive mark_dependence base for the purpose of extending scopes. This pass will extend the base
        // of that mark_dependence (if it is unresolved) later as a separate LifetimeDependence.Scope.
        break
      }
    }
    guard case let .access(outerBeginAccess) = innerScopes.last else {
      // beginAccess is included in accessBaseWithScopes; so at least one access was added to innerScopes.
      fatalError("missing outer access")
    }
    if case let .argument(arg) = accessBaseAndScopes.base {
      if isCompatibleAccess && beginAccess.accessKind.isCompatible(with: arg.convention) {
        let scopes = ScopeExtension(owner: outerBeginAccess.address, nestedScopes: innerScopes, dependsOnArg: arg)
        return SingleInlineArray(element: scopes)
      }
    }
    /// Recurse in case of indirect yields.
    let enclosingScope = LifetimeDependence.Scope(base: outerBeginAccess.address, context)
    if let extensions = enclosingScope.gatherExtensions(innerScopes: innerScopes, context) {
      return extensions
    }
    // When the owner is an address, the owner's scope is considered the availability of its access base starting at the
    // position of innerScopes.last.
    let scopes = ScopeExtension(owner: outerBeginAccess.address, nestedScopes: innerScopes, dependsOnArg: nil)
    return SingleInlineArray(element: scopes)
  }

  func gatherBorrowExtension(borrowedValue: Value,
                             innerScopes: SingleInlineArray<LifetimeDependence.Scope>,
                             _ context: FunctionPassContext)
    -> SingleInlineArray<ScopeExtension> {

    let enclosingScope = LifetimeDependence.Scope(base: borrowedValue, context)
    if let extensions = enclosingScope.gatherExtensions(innerScopes: innerScopes, context) {
      return extensions
    }
    // This is the outermost scope to be extended because gatherExtensions did not find an enclosing scope.
    return SingleInlineArray(element: getOuterExtension(owner: enclosingScope.parentValue, nestedScopes: innerScopes,
                                                        context))
  }
}

/// Compute the range of the a scope owner. Nested scopes must stay within this range.
///
/// Abstracts over lifetimes for both addresses and values.
extension ScopeExtension {
  enum Range {
    case fullRange
    case addressRange(AddressOwnershipLiveRange)
    case valueRange(InstructionRange)

    func coversUse(_ inst: Instruction) -> Bool {
      switch self {
      case .fullRange:
        return true
      case let .addressRange(range):
        return range.coversUse(inst)
      case let .valueRange(range):
        return range.inclusiveRangeContains(inst)
      }
    }

    mutating func deinitialize() {
      switch self {
      case .fullRange:
        break
      case var .addressRange(range):
        return range.deinitialize()
      case var .valueRange(range):
        return range.deinitialize()
      }
    }
  }

  /// Return nil if the scope's owner is valid across the function, such as a guaranteed function argument.
  func computeRange(_ localReachabilityCache: LocalVariableReachabilityCache, _ context: FunctionPassContext) -> Range?
  {
    if owner.type.isAddress {
      // Get the range of the accessBase lifetime at the point where the outermost extendable scope begins.
      if let range = AddressOwnershipLiveRange.compute(for: owner, at: nestedScopes.last!.extendableBegin!.instruction,
                                                       localReachabilityCache, context) {
        return .addressRange(range)
      }
      return nil
    }
    if owner.ownership == .owned {
      return .valueRange(computeLinearLiveness(for: owner, context))
    }
    // Trivial or guaranted owner.
    //
    // TODO: limit extension to the begin_borrow [var_decl] scope
    return .fullRange
  }
}

/// Return an InstructionRange covering all the dependent uses of 'dependence'.
private func computeDependentUseRange(of dependence: LifetimeDependence, within scopeExtension: inout ScopeExtension,
                                      _ localReachabilityCache: LocalVariableReachabilityCache,
                                      _ context: FunctionPassContext)
  -> InstructionRange? {
  let function = dependence.function
  guard var ownershipRange = scopeExtension.computeRange(localReachabilityCache, context) else {
    return nil
  }
  defer {ownershipRange.deinitialize()}

  // The innermost scope that must be extended must dominate all uses.
  var useRange = InstructionRange(begin: scopeExtension.innerScope.extendableBegin!.instruction, context)
  var walker = LifetimeDependentUseWalker(function, localReachabilityCache, context) {
    // Do not extend the useRange past the ownershipRange.
    let dependentInst = $0.instruction
    if ownershipRange.coversUse(dependentInst) {
      useRange.insert(dependentInst)
    }
    return .continueWalk
  }
  defer {walker.deinitialize()}

  _ = walker.walkDown(dependence: dependence)

  log("Scope fixup for dependent uses:\n\(useRange)")

  scopeExtension.dependsOnCaller = walker.dependsOnCaller

  // Lifetime dependenent uses may not be dominated by the access. The dependent value may be used by a phi or stored
  // into a memory location. The access may be conditional relative to such uses. If any use was not dominated, then
  // `useRange` will include the function entry. There is not way to directly check
  // useRange.isValid. useRange.blockRange.isValid is not a strong enough check because it will always succeed when
  // useRange.begin == entryBlock even if a use if above useRange.begin.
  let firstInst = function.entryBlock.instructions.first!
  if firstInst != useRange.begin, useRange.contains(firstInst) {
    useRange.deinitialize()
    return nil
  }
  return useRange
}

// Extend nested scopes across a use-range within their owner's range.
extension ScopeExtension {
  // Prepare to extend each scope.
  func tryExtendScopes(over useRange: inout InstructionRange, _ context: some MutatingContext) -> Bool {
    var extendedUseRange = InstructionRange(begin: useRange.begin!, ends: useRange.ends, context)
    // Insert the first instruction of the exit blocks to mimic 'useRange'. This is innacurate, but it produces the same
    // result for canExtend() check below, which only checks reachability of end_apply.
    extendedUseRange.insert(contentsOf: useRange.exits)
    for innerScope in nestedScopes {
      guard let beginInst = innerScope.extendableBegin else {
        fatalError("all nested scopes must have a scoped begin instruction")
      }
      // Extend 'extendedUseRange' to to cover this scope's end instructions. The extended scope must at least cover the
      // original scope because the original scope may protect other operations.
      extendedUseRange.insert(contentsOf: beginInst.endInstructions)
      if !innerScope.canExtend(over: &extendedUseRange, context) {
        // Scope ending instructions cannot be inserted at the 'range' boundary. Ignore all nested scopes.
        //
        // Note: We could still extend previously prepared inner scopes up to this 'innerScope'. To do that, we would
        // need to repeat the steps above: treat 'innerScope' as the new owner, and recompute 'useRange'. But this
        // scenario could only happen with nested coroutine, where the range boundary is reachable from the outer
        // coroutine's EndApply and AbortApply--it is vanishingly unlikely if not impossible.
        return false
      }
    }
    extendedUseRange.deinitialize()
    // extend(over:) must receive the original unmodified 'useRange'.
    extend(over: &useRange, context)
    return true
  }
  
  // Extend the scopes that actually required extension.
  //
  // Consumes 'useRange'
  private func extend(over useRange: inout InstructionRange, _ context: some MutatingContext) {
    var deadInsts = [Instruction]()
    for innerScope in nestedScopes {
      guard let beginInst = innerScope.extendableBegin else {
        fatalError("all nested scopes must have a scoped begin instruction")
      }
      let mustExtend = beginInst.endInstructions.contains(where: { useRange.contains($0) })

      // Extend 'useRange' to to cover this scope's end instructions. 'useRange' cannot be extended until the
      // inner scopes have been extended.
      for endInst in beginInst.endInstructions {
        useRange.insert(endInst)
      }
      if mustExtend {
        deadInsts += innerScope.extend(over: &useRange, context)
      }
      // Continue checking enclosing scopes for extension even if 'mustExtend' is false. Multiple ScopeExtensions may
      // share the same inner scope, so this inner scope may already have been extended while handling a previous
      // ScopeExtension. Nonetheless, some enclosing scopes may still require extension. This only happens when a
      // yielded value depends on multiple begin_apply operands.
    }
    // 'useRange' is invalid as soon as instructions are deleted.
    useRange.deinitialize()
    // Delete original end instructions.
    for deadInst in deadInsts {
      context.erase(instruction: deadInst)
    }
  }
}

// Extend a dependence scope to cover the dependent uses.
private extension LifetimeDependence.Scope {
  /// Return true if new scope-ending instruction can be inserted at the range boundary.
  func canExtend(over range: inout InstructionRange, _ context: some Context) -> Bool {
    switch self {
    case let .yield(yieldedValue):
      let beginApply = yieldedValue.definingInstruction as! BeginApplyInst
      let canEndAtBoundary = { (boundaryInst: Instruction) in
        switch beginApply.endReaches(block: boundaryInst.parentBlock, context) {
        case .abortReaches, .endReaches:
          return true
        case .none:
          return false
        }
      }
      for end in range.ends {
        if (!canEndAtBoundary(end)) {
          return false
        }
      }
      for exit in range.exits {
        if (!canEndAtBoundary(exit)) {
          return false
        }
      }
      return true
    default:
      // non-yield scopes can always be ended at any point.
      return true
    }
  }

  /// Extend this scope over the 'range' boundary. Return the old scope ending instructions to be deleted.
  func extend(over range: inout InstructionRange, _ context: some MutatingContext) -> [Instruction] {
    guard let beginInst = extendableBegin else {
      fatalError("all nested scoped must have a scoped begin instruction")
    }
    // Collect the original end instructions and extend the range to to cover them. The resulting access scope
    // must cover the original scope because it may protect other memory operations.
    var endInsts = [Instruction]()
    for end in beginInst.endInstructions {
      assert(range.inclusiveRangeContains(end))
      endInsts.append(end)
    }
    insertBoundaryEnds(range: &range, context)
    return endInsts
  }

  /// Create new scope-ending instructions at the boundary of 'range'.
  func insertBoundaryEnds(range: inout InstructionRange, _ context: some MutatingContext) {
    for end in range.ends {
      let location = end.location.autoGenerated
      if end is ReturnInst {
        // End this inner scope just before the return. The mark_dependence base operand will be redirected to a
        // function argument.
        let builder = Builder(before: end, location: location, context)
        // Insert newEnd so that this scope will be nested in any outer scopes.
        range.insert(createEndInstruction(builder, context))
        continue
      }
      Builder.insert(after: end, location: location, context) {
        range.insert(createEndInstruction($0, context))
      }
    }
    for exitInst in range.exits {
      let location = exitInst.location.autoGenerated
      let builder = Builder(before: exitInst, location: location, context)
      range.insert(createEndInstruction(builder, context))
    }
  }

  /// Create a scope-ending instruction at 'builder's insertion point.
  func createEndInstruction(_ builder: Builder, _ context: some Context) -> Instruction {
    switch self {
    case let .access(beginAccess):
      return builder.createEndAccess(beginAccess: beginAccess)
    case let .borrowed(beginBorrow):
      return builder.createEndBorrow(of: beginBorrow.value)
    case let .yield(yieldedValue):
      let beginApply = yieldedValue.definingInstruction as! BeginApplyInst
      // createEnd() returns non-nil because beginApply.endReaches() was checked by canExtend()
      return beginApply.createEnd(builder, context)!
    case let .initialized(initializer):
      switch initializer {
      case let .store(initializingStore: store, initialAddress: _):
        if let sb = store as? StoreBorrowInst {
          return builder.createEndBorrow(of: sb)
        }
        break
      case .argument, .yield:
        // TODO: extend indirectly yielded scopes.
        break
      }
    default:
      break
    }
    fatalError("Unsupported scoped extension: \(self)")
  }
}

private extension BeginApplyInst {
  /// Create either an end_apply or abort_apply at the builder's insertion point.
  /// Return nil if it isn't possible.
  func createEnd(_ builder: Builder, _ context: some Context) -> Instruction? {
    guard let insertionBlock = builder.insertionBlock else {
      return nil
    }
    switch endReaches(block: insertionBlock, context) {
    case .none:
      return nil
    case .endReaches:
      return builder.createEndApply(beginApply: self)
    case .abortReaches:
      return builder.createAbortApply(beginApply: self)
    }
  }

  enum EndReaches {
    case endReaches
    case abortReaches
  }

  /// Return the single kind of coroutine termination that reaches 'reachableBlock' or nil.
  func endReaches(block reachableBlock: BasicBlock, _ context: some Context) -> EndReaches? {
    var endBlocks = BasicBlockSet(context)
    var abortBlocks = BasicBlockSet(context)
    defer {
      endBlocks.deinitialize()
      abortBlocks.deinitialize()
    }
    for endInst in endInstructions {
      switch endInst {
      case let endApply as EndApplyInst:
        // Cannot extend the scope of a coroutine when the resume produces a value.
        if !endApply.type.isEmpty(in: parentFunction) {
          return nil
        }
        endBlocks.insert(endInst.parentBlock)
      case is AbortApplyInst:
        abortBlocks.insert(endInst.parentBlock)
      default:
        fatalError("invalid begin_apply ending instruction")
      }
    }
    var endReaches: EndReaches?
    var backwardWalk = BasicBlockWorklist(context)
    defer { backwardWalk.deinitialize() }

    let backwardVisit = { (block: BasicBlock) -> WalkResult in
      if endBlocks.contains(block) {
        switch endReaches {
        case .none:
          endReaches = .endReaches
          break
        case .endReaches:
          break
        case .abortReaches:
          return .abortWalk
        }
        return .continueWalk
      }
      if abortBlocks.contains(block) {
        switch endReaches {
        case .none:
          endReaches = .abortReaches
          break
        case .abortReaches:
          break
        case .endReaches:
          return .abortWalk
        }
        return .continueWalk
      }
      if block == self.parentBlock {
        // the insertion point is not dominated by the coroutine
        return .abortWalk
      }
      backwardWalk.pushIfNotVisited(contentsOf: block.predecessors)
      return .continueWalk
    }

    if backwardVisit(reachableBlock) == .abortWalk {
      return nil
    }
    while let block = backwardWalk.pop() {
      if backwardVisit(block) == .abortWalk {
        return nil
      }
    }
    return endReaches
  }
}

/// Visit all dependent uses.
///
/// Set 'dependsOnCaller' if a use escapes the function.
private struct LifetimeDependentUseWalker : LifetimeDependenceDefUseWalker {
  let function: Function
  let context: Context
  let visitor: (Operand) -> WalkResult
  let localReachabilityCache: LocalVariableReachabilityCache
  var visitedValues: ValueSet

  /// Set to true if the dependence is returned from the current function.
  var dependsOnCaller = false

  init(_ function: Function, _ localReachabilityCache: LocalVariableReachabilityCache, _ context: Context,
       visitor: @escaping (Operand) -> WalkResult) {
    self.function = function
    self.context = context
    self.visitor = visitor
    self.localReachabilityCache = localReachabilityCache
    self.visitedValues = ValueSet(context)
  }

  mutating func deinitialize() {
    visitedValues.deinitialize()
  }

  mutating func needWalk(for value: Value) -> Bool {
    visitedValues.insert(value)
  }

  mutating func deadValue(_ value: Value, using operand: Operand?)
  -> WalkResult {
    if let operand {
      return visitor(operand)
    }
    return .continueWalk
  }

  mutating func leafUse(of operand: Operand) -> WalkResult {
    return visitor(operand)
  }

  mutating func escapingDependence(on operand: Operand) -> WalkResult {
    log(">>> Escaping dependence: \(operand)")
    _ = visitor(operand)
    // Make a best-effort attempt to extend the access scope regardless of escapes. It is possible that some mandatory
    // pass between scope fixup and diagnostics will make it possible for the LifetimeDependenceDefUseWalker to analyze
    // this use.
    return .continueWalk
  }

  mutating func inoutDependence(argument: FunctionArgument, on operand: Operand) -> WalkResult {
    dependsOnCaller = true
    return visitor(operand)
  }

  mutating func returnedDependence(result operand: Operand) -> WalkResult {
    dependsOnCaller = true
    return visitor(operand)
  }

  mutating func returnedDependence(address: FunctionArgument,
                                   on operand: Operand) -> WalkResult {
    dependsOnCaller = true
    return visitor(operand)
  }

  mutating func yieldedDependence(result: Operand) -> WalkResult {
    return .continueWalk
  }

  mutating func storeToYieldDependence(address: Value, of operand: Operand) -> WalkResult {
    return .continueWalk
  }
}

