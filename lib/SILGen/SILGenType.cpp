//===--- SILGenType.cpp - SILGen for types and their members --------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
//
// This file contains code for emitting code associated with types:
//   - methods
//   - vtables and vtable thunks
//   - witness tables and witness thunks
//
//===----------------------------------------------------------------------===//

#include "ManagedValue.h"
#include "SILGenFunction.h"
#include "SILGenFunctionBuilder.h"
#include "Scope.h"
#include "swift/AST/ASTMangler.h"
#include "swift/AST/ConformanceLookup.h"
#include "swift/AST/GenericEnvironment.h"
#include "swift/AST/PrettyStackTrace.h"
#include "swift/AST/PropertyWrappers.h"
#include "swift/AST/ProtocolConformance.h"
#include "swift/AST/SourceFile.h"
#include "swift/AST/SubstitutionMap.h"
#include "swift/AST/TypeMemberVisitor.h"
#include "swift/Basic/Assertions.h"
#include "swift/SIL/FormalLinkage.h"
#include "swift/SIL/PrettyStackTrace.h"
#include "swift/SIL/SILArgument.h"
#include "swift/SIL/SILDefaultOverrideTable.h"
#include "swift/SIL/SILVTableVisitor.h"
#include "swift/SIL/SILWitnessVisitor.h"
#include "swift/SIL/TypeLowering.h"
#include "clang/AST/Decl.h"

using namespace swift;
using namespace Lowering;

std::optional<SILVTable::Entry>
SILGenModule::emitVTableMethod(ClassDecl *theClass, SILDeclRef derived,
                               SILDeclRef base) {
  assert(base.kind == derived.kind);

  auto *baseDecl = cast<AbstractFunctionDecl>(base.getDecl());
  auto *derivedDecl = cast<AbstractFunctionDecl>(derived.getDecl());

  if (shouldSkipDecl(baseDecl))
    return std::nullopt;

  // Note: We intentionally don't support extension members here.
  //
  // Once extensions can override or introduce new vtable entries, this will
  // all likely change anyway.
  auto *baseClass = cast<ClassDecl>(baseDecl->getDeclContext());
  auto *derivedClass = cast<ClassDecl>(derivedDecl->getDeclContext());

  // Figure out if the vtable entry comes from the superclass, in which
  // case we won't emit it if building a resilient module.
  SILVTable::Entry::Kind implKind;
  if (baseClass == theClass) {
    // This is a vtable entry for a method of the immediate class.
    implKind = SILVTable::Entry::Kind::Normal;
  } else if (derivedClass == theClass) {
    // This is a vtable entry for a method of a base class, but it is being
    // overridden in the immediate class.
    implKind = SILVTable::Entry::Kind::Override;
  } else {
    // This vtable entry is copied from the superclass.
    implKind = SILVTable::Entry::Kind::Inherited;

    // If the override is defined in a class from a different resilience
    // domain, don't emit the vtable entry.
    if (derivedClass->isResilient(M.getSwiftModule(),
                                  ResilienceExpansion::Maximal)) {
      return std::nullopt;
    }
  }

  SILFunction *implFn;

  // If the member is dynamic, reference its dynamic dispatch thunk so that
  // it will be redispatched, funneling the method call through the runtime
  // hook point.
  bool usesObjCDynamicDispatch =
      (derivedDecl->shouldUseObjCDispatch() &&
       derived.kind != SILDeclRef::Kind::Allocator);

  if (usesObjCDynamicDispatch) {
    implFn = getDynamicThunk(
        derived, Types.getConstantInfo(TypeExpansionContext::minimal(), derived)
                     .SILFnType);
  } else if (derived.getDerivativeFunctionIdentifier()) {
    // For JVP/VJP methods, create a vtable entry thunk. The thunk contains an
    // `differentiable_function` instruction, which is later filled during the
    // differentiation transform.
    auto derivedFnType =
        Types.getConstantInfo(TypeExpansionContext::minimal(), derived)
            .SILFnType;
    implFn = getOrCreateDerivativeVTableThunk(derived, derivedFnType);
  } else {
    implFn = getFunction(derived, NotForDefinition);
  }

  // As a fast path, if there is no override, definitely no thunk is necessary.
  if (derived == base)
    return SILVTable::Entry(base, implFn, implKind, false);

  // If the base method is less visible than the derived method, we need
  // a thunk.
  //
  // Note that we check the visibility of the derived method's immediate base
  // here, rather than the ultimate base of the vtable entry, because it is
  // possible through import visibility for an intermediate base class in one
  // file to have public visibility to the ultimate base via a public import,
  // but then in turn be overridden by a derived class in another file in
  // the same module that either doesn't import the ultimate base class's
  // module or else imports it non-publicly in its file.
  bool baseLessVisibleThanDerived =
    (!usesObjCDynamicDispatch &&
     !derivedDecl->isFinal() &&
     derivedDecl->isMoreVisibleThan(derivedDecl->getOverriddenDecl()));

  // Determine the derived thunk type by lowering the derived type against the
  // abstraction pattern of the base.
  auto baseInfo = Types.getConstantInfo(TypeExpansionContext::minimal(), base);
  auto derivedInfo =
      Types.getConstantInfo(TypeExpansionContext::minimal(), derived);
  auto basePattern = AbstractionPattern(baseInfo.LoweredType);

  auto overrideInfo = M.Types.getConstantOverrideInfo(
      TypeExpansionContext::minimal(), derived, base);

  // If base method's generic requirements are not satisfied by the derived
  // method then we need a thunk.
  using Direction = ASTContext::OverrideGenericSignatureReqCheck;
  auto doesNotHaveGenericRequirementDifference =
      getASTContext().overrideGenericSignatureReqsSatisfied(
          baseDecl, derivedDecl, Direction::BaseReqSatisfiedByDerived);

  // The override member type is semantically a subtype of the base
  // member type. If the override is ABI compatible, we do not need
  // a thunk.
  bool compatibleCallingConvention;
  switch (M.Types.checkFunctionForABIDifferences(M,
                                                 derivedInfo.SILFnType,
                                                 overrideInfo.SILFnType)) {
  case TypeConverter::ABIDifference::CompatibleCallingConvention:
  case TypeConverter::ABIDifference::CompatibleRepresentation:
    compatibleCallingConvention = true;
    break;
  case TypeConverter::ABIDifference::NeedsThunk:
    compatibleCallingConvention = false;
    break;
  case TypeConverter::ABIDifference::CompatibleCallingConvention_ThinToThick:
  case TypeConverter::ABIDifference::CompatibleRepresentation_ThinToThick:
    llvm_unreachable("shouldn't be thick methods");
  }
  if (doesNotHaveGenericRequirementDifference
      && !baseLessVisibleThanDerived
      && compatibleCallingConvention)
    return SILVTable::Entry(base, implFn, implKind, false);

  // Generate the thunk name.
  std::string name;
  {
    Mangle::ASTMangler mangler(getASTContext());
    if (isa<FuncDecl>(baseDecl)) {
      name = mangler.mangleVTableThunk(
        cast<FuncDecl>(baseDecl),
        cast<FuncDecl>(derivedDecl));
    } else {
      name = mangler.mangleConstructorVTableThunk(
        cast<ConstructorDecl>(baseDecl),
        cast<ConstructorDecl>(derivedDecl),
        base.kind == SILDeclRef::Kind::Allocator);
    }
    // TODO(TF-685): Use proper autodiff thunk mangling.
    if (auto *derivativeId = derived.getDerivativeFunctionIdentifier()) {
      switch (derivativeId->getKind()) {
      case AutoDiffDerivativeFunctionKind::JVP:
        name += "_jvp";
        break;
      case AutoDiffDerivativeFunctionKind::VJP:
        name += "_vjp";
        break;
      }
    }
  }

  // If we already emitted this thunk, reuse it.
  if (auto existingThunk = M.lookUpFunction(name))
    return SILVTable::Entry(base, existingThunk, implKind, false);

  auto *genericEnv = overrideInfo.FormalType.getOptGenericSignature().getGenericEnvironment();

  // Emit the thunk.
  SILLocation loc(derivedDecl);
  SILGenFunctionBuilder builder(*this);
  auto thunk = builder.createFunction(
      SILLinkage::Private, name, overrideInfo.SILFnType,
      genericEnv, loc,
      IsBare, IsNotTransparent, IsNotSerialized, IsNotDynamic,
      IsNotDistributed, IsNotRuntimeAccessible, ProfileCounter(), IsThunk);
  thunk->setDebugScope(new (M) SILDebugScope(loc, thunk));

  PrettyStackTraceSILFunction trace("generating vtable thunk", thunk);

  SILGenFunction(*this, *thunk, theClass)
    .emitVTableThunk(base, derived, implFn, basePattern,
                     overrideInfo.LoweredType,
                     derivedInfo.LoweredType,
                     baseLessVisibleThanDerived);
  emitLazyConformancesForFunction(thunk);

  return SILVTable::Entry(base, thunk, implKind, false);
}

bool SILGenModule::requiresObjCMethodEntryPoint(FuncDecl *method) {
  // Property accessors should be generated alongside the property unless
  // the @NSManaged attribute is present.
  if (auto accessor = dyn_cast<AccessorDecl>(method)) {
    if (accessor->isGetterOrSetter()) {
      auto asd = accessor->getStorage();
      return asd->isObjC() && !asd->getAttrs().hasAttribute<NSManagedAttr>() &&
             !method->isNativeMethodReplacement();
    }
  }

  if (method->getAttrs().hasAttribute<NSManagedAttr>())
    return false;
  if (!method->isObjC())
    return false;

  // Don't emit the objective c entry point of @_dynamicReplacement(for:)
  // methods in generic classes. There is no way to call it.
  return !method->isNativeMethodReplacement();
}

bool SILGenModule::requiresObjCMethodEntryPoint(ConstructorDecl *constructor) {
  if (!constructor->isObjC())
    return false;
  // Don't emit the objective c entry point of @_dynamicReplacement(for:)
  // methods in generic classes. There is no way to call it.
  return !constructor->isNativeMethodReplacement();
}

namespace {

/// An ASTVisitor for populating SILVTable entries from ClassDecl members.
template <typename T>
class SILGenVTableBase : public SILVTableVisitor<T> {
  T &asDerived() { return *static_cast<T *>(this); }

public:
  SILGenModule &SGM;
  ClassDecl *theClass;
  bool isResilient;

  // Map a base SILDeclRef to the corresponding element in vtableMethods.
  llvm::DenseMap<SILDeclRef, unsigned> baseToIndexMap;

  // A base method and a corresponding override.
  using VTableMethod = std::pair<SILDeclRef, SILDeclRef>;

  // For each base method, store the corresponding override.
  SmallVector<VTableMethod, 8> vtableMethods;

  SILGenVTableBase(SILGenModule &SGM, ClassDecl *theClass)
      : SGM(SGM), theClass(theClass) {
    isResilient = theClass->isResilient();
  }

  /// Populate our list of base methods and overrides.
  void collectMethods() { visitAncestor(theClass); }

  void visitAncestor(ClassDecl *ancestor) {
    // Imported types don't have vtables right now.
    if (ancestor->hasClangNode())
      return;

    auto *superDecl = ancestor->getSuperclassDecl();
    if (superDecl)
      visitAncestor(superDecl);

    asDerived().addVTableEntries(ancestor);
  }

  // Try to find an overridden entry.
  void addMethodOverride(SILDeclRef baseRef, SILDeclRef declRef) {
    auto found = baseToIndexMap.find(baseRef);
    assert(found != baseToIndexMap.end());
    auto &method = vtableMethods[found->second];
    assert(method.first == baseRef);
    method.second = declRef;
  }

  // Add an entry to the vtable.
  void addMethod(SILDeclRef member) {
    unsigned index = vtableMethods.size();
    vtableMethods.push_back(std::make_pair(member, member));
    auto result = baseToIndexMap.insert(std::make_pair(member, index));
    assert(result.second);
    (void)result;
  }

  void addPlaceholder(MissingMemberDecl *m) {
#ifndef NDEBUG
    auto *classDecl = cast<ClassDecl>(m->getDeclContext());
    bool isResilient = classDecl->isResilient(SGM.M.getSwiftModule(),
                                              ResilienceExpansion::Maximal);
    assert(isResilient ||
           m->getNumberOfVTableEntries() == 0 &&
               "Should not be emitting fragile class with missing members");
#endif
  }
};

class SILGenVTable : public SILGenVTableBase<SILGenVTable> {
public:
  SILGenVTable(SILGenModule &SGM, ClassDecl *theClass)
      : SILGenVTableBase(SGM, theClass) {}

  void emitVTable() {
    PrettyStackTraceDecl("silgen emitVTable", theClass);

    collectMethods();

    SmallVector<SILVTable::Entry, 8> vtableEntries;
    vtableEntries.reserve(vtableMethods.size() + 2);

    // For each base method/override pair, emit a vtable thunk or direct
    // reference to the method implementation.
    for (auto method : vtableMethods) {
      SILDeclRef baseRef, derivedRef;
      std::tie(baseRef, derivedRef) = method;

      auto entry = SGM.emitVTableMethod(theClass, derivedRef, baseRef);

      // We might skip emitting entries if the base class is resilient.
      if (entry)
        vtableEntries.push_back(*entry);
    }

    // Add the deallocating destructor to the vtable just for the purpose
    // that it is referenced and cannot be eliminated by dead function removal.
    // In reality, the deallocating destructor is referenced directly from
    // the HeapMetadata for the class.
    {
      auto *dtor = theClass->getDestructor();
      SILDeclRef dtorRef(dtor, SILDeclRef::Kind::Deallocator);
      auto *dtorFn = SGM.getFunction(dtorRef, NotForDefinition);
      vtableEntries.emplace_back(dtorRef, dtorFn,
                                 SILVTable::Entry::Kind::Normal,
                                 false);
    }

    if (SGM.requiresIVarDestroyer(theClass)) {
      SILDeclRef dtorRef(theClass, SILDeclRef::Kind::IVarDestroyer);
      auto *dtorFn = SGM.getFunction(dtorRef, NotForDefinition);
      vtableEntries.emplace_back(dtorRef, dtorFn,
                                 SILVTable::Entry::Kind::Normal,
                                 false);
    }

    SerializedKind_t serialized = IsNotSerialized;
    auto classIsPublic = theClass->getEffectiveAccess() >= AccessLevel::Public;
    // Only public, fixed-layout classes should have serialized vtables.
    if (classIsPublic && !isResilient)
      serialized = IsSerialized;

    // Finally, create the vtable.
    SILVTable::create(SGM.M, theClass, serialized, vtableEntries);
  }
};
} // end anonymous namespace

static void emitTypeMemberGlobalVariable(SILGenModule &SGM,
                                         VarDecl *var) {
  if (var->getDeclContext()->isGenericContext()) {
    assert(var->getDeclContext()->getGenericSignatureOfContext()
              ->areAllParamsConcrete()
           && "generic static vars are not implemented yet");
  }

  if (var->getDeclContext()->getSelfClassDecl()) {
    assert(var->isFinal() && "only 'static' ('class final') stored properties are implemented in classes");
  }

  SGM.addGlobalVariable(var);
}

namespace {

// Is this a free function witness satisfying a static method requirement?
static IsFreeFunctionWitness_t isFreeFunctionWitness(ValueDecl *requirement,
                                                     ValueDecl *witness) {
  if (!witness->getDeclContext()->isTypeContext()) {
    assert(!requirement->isInstanceMember()
           && "free function satisfying instance method requirement?!");
    return IsFreeFunctionWitness;
  }

  return IsNotFreeFunctionWitness;
}

/// A CRTP class for emitting witness thunks for the requirements of a
/// protocol.
///
/// There are two subclasses:
///
/// - SILGenConformance: emits witness thunks for a conformance of a
///   a concrete type to a protocol
/// - SILGenDefaultWitnessTable: emits default witness thunks for
///   default implementations of protocol requirements
///
template<typename T> class SILGenWitnessTable : public SILWitnessVisitor<T> {
  T &asDerived() { return *static_cast<T*>(this); }

public:
  void addMethod(SILDeclRef requirementRef) {
    auto reqDecl = requirementRef.getDecl();

    // Static functions can be witnessed by enum cases with payload
    if (!(isa<AccessorDecl>(reqDecl) || isa<ConstructorDecl>(reqDecl))) {
      auto FD = cast<FuncDecl>(reqDecl);
      if (auto witness = asDerived().getWitness(FD)) {
        if (auto EED = dyn_cast<EnumElementDecl>(witness.getDecl())) {
          return addMethodImplementation(
              requirementRef, SILDeclRef(EED, SILDeclRef::Kind::EnumElement),
              witness);
        }
      }
    }

    auto reqAccessor = dyn_cast<AccessorDecl>(reqDecl);
    /// If it is an accessor, or distributed_thunk that is witnessing an
    /// accessor, we need to use the storage to get the witness.
    ValueDecl *storage = nullptr;

    // If it's not an accessor, just look for the witness.
    if (!reqAccessor) {
      if (auto witness = asDerived().getWitness(reqDecl)) {
        auto newDecl = requirementRef.withDecl(witness.getDecl());
        // Only import C++ methods as foreign. If the following
        // Objective-C function is imported as foreign:
        //   () -> String
        // It will be imported as the following type:
        //   () -> NSString
        // But the first is correct, so make sure we don't mark this witness
        // as foreign.
        const auto *clangDecl = witness.getDecl()->getClangDecl();
        if (clangDecl &&
            (dyn_cast<clang::CXXMethodDecl>(clangDecl) ||
             (isa<clang::FunctionDecl>(clangDecl) &&
              cast<clang::FunctionDecl>(clangDecl)->isOverloadedOperator())))
          newDecl = newDecl.asForeign();
        return addMethodImplementation(
            requirementRef, getWitnessRef(newDecl, witness), witness);
      }
      return asDerived().addMissingMethod(requirementRef);
    } else {
      // Otherwise, we need to map the storage declaration and then get
      // the appropriate accessor for it.
      storage = reqAccessor->getStorage();
    }

    auto witness = asDerived().getWitness(storage);
    if (!witness)
      return asDerived().addMissingMethod(requirementRef);

    // Static properties can be witnessed by enum cases without payload
    if (auto EED = dyn_cast<EnumElementDecl>(witness.getDecl())) {
      return addMethodImplementation(
          requirementRef, SILDeclRef(EED, SILDeclRef::Kind::EnumElement),
          witness);
    }

    auto witnessStorage = cast<AbstractStorageDecl>(witness.getDecl());
    if (reqAccessor->isSetter() && !witnessStorage->supportsMutation()) {
      return asDerived().addMissingMethod(requirementRef);
    }

    // Here we notice a `distributed var` thunk requirement,
    // and witness it with the distributed thunk -- the "getter thunk".
    if (requirementRef.isDistributedThunk()) {
      return addMethodImplementation(
          requirementRef, getWitnessRef(requirementRef, witnessStorage->getDistributedThunk()),
          witness);
    }

    auto witnessAccessor =
      witnessStorage->getSynthesizedAccessor(reqAccessor->getAccessorKind());

    return addMethodImplementation(
        requirementRef, getWitnessRef(requirementRef, witnessAccessor),
        witness);
  }

private:
  void addMethodImplementation(SILDeclRef requirementRef,
                               SILDeclRef witnessRef,
                               Witness witness) {
    // Free function witnesses have an implicit uncurry layer imposed on them by
    // the inserted metatype argument.
    auto isFree =
      isFreeFunctionWitness(requirementRef.getDecl(), witnessRef.getDecl());
    asDerived().addMethodImplementation(requirementRef, witnessRef,
                                        isFree, witness);
  }

  SILDeclRef getWitnessRef(SILDeclRef requirementRef, Witness witness) {
    auto witnessRef = requirementRef.withDecl(witness.getDecl());
    // If the requirement/witness is a derivative function, we need to
    // substitute the witness's derivative generic signature in its derivative
    // function identifier.
    if (requirementRef.isAutoDiffDerivativeFunction()) {
      auto *reqrDerivativeId = requirementRef.getDerivativeFunctionIdentifier();
      auto *witnessDerivativeId = AutoDiffDerivativeFunctionIdentifier::get(
          reqrDerivativeId->getKind(), reqrDerivativeId->getParameterIndices(),
          witness.getDerivativeGenericSignature(), witnessRef.getASTContext());
      witnessRef = witnessRef.asAutoDiffDerivativeFunction(witnessDerivativeId);
    }

    return witnessRef;
  }
};

static SerializedKind_t getConformanceSerializedKind(RootProtocolConformance *conf) {
  return SILWitnessTable::conformanceSerializedKind(conf);
}

/// Emit a witness table for a protocol conformance.
class SILGenConformance : public SILGenWitnessTable<SILGenConformance> {
  using super = SILGenWitnessTable<SILGenConformance>;

public:
  SILGenModule &SGM;
  NormalProtocolConformance *Conformance;
  std::vector<SILWitnessTable::Entry> Entries;
  std::vector<ProtocolConformanceRef> ConditionalConformances;
  SILLinkage Linkage;
  SerializedKind_t SerializedKind;

  SILGenConformance(SILGenModule &SGM, NormalProtocolConformance *C)
    : SGM(SGM), Conformance(C),
      Linkage(getLinkageForProtocolConformance(Conformance,
                                               ForDefinition)),
      SerializedKind(getConformanceSerializedKind(Conformance))
  {
    auto *proto = Conformance->getProtocol();

    // Not all protocols use witness tables; in this case we just skip
    // all of emit() below completely.
    if (!Lowering::TypeConverter::protocolRequiresWitnessTable(proto))
      Conformance = nullptr;
  }

  SILWitnessTable *emit() {
    // Nothing to do if this wasn't a normal conformance.
    if (!Conformance)
      return nullptr;

    PrettyStackTraceConformance trace("generating SIL witness table",
                                      Conformance);

    Conformance->resolveValueWitnesses();
    auto *proto = Conformance->getProtocol();
    visitProtocolDecl(proto);

    addConditionalRequirements();

    // Check if we already have a declaration or definition for this witness
    // table.
    if (auto *wt = SGM.M.lookUpWitnessTable(Conformance)) {
      // If we have a definition already, just return it.
      //
      // FIXME: I am not sure if this is possible, if it is not change this to an
      // assert.
      if (wt->isDefinition())
        return wt;

      // If we have a declaration, convert the witness table to a definition.
      if (wt->isDeclaration()) {
        wt->convertToDefinition(Entries, ConditionalConformances, SerializedKind);

        // Since we had a declaration before, its linkage should be external,
        // ensure that we have a compatible linkage for soundness. *NOTE* we are ok
        // with both being shared since we do not have a shared_external
        // linkage.
        assert(stripExternalFromLinkage(wt->getLinkage()) == Linkage &&
               "Witness table declaration has inconsistent linkage with"
               " silgen definition.");

        // And then override the linkage with the new linkage.
        wt->setLinkage(Linkage);
        return wt;
      }
    }

    // Otherwise if we have no witness table yet, create it.
    return SILWitnessTable::create(SGM.M, Linkage, SerializedKind, Conformance,
                                   Entries, ConditionalConformances, /*specialized=*/false);
  }

  void addProtocolConformanceDescriptor() {
  }


  void addOutOfLineBaseProtocol(ProtocolDecl *baseProtocol) {
    assert(Lowering::TypeConverter::protocolRequiresWitnessTable(baseProtocol));

    auto conformance = Conformance->getInheritedConformance(baseProtocol);

    Entries.push_back(SILWitnessTable::BaseProtocolWitness{
      baseProtocol,
      conformance,
    });

    // Emit the witness table for the base conformance if it is shared.
    SGM.useConformance(nullptr, ProtocolConformanceRef(conformance));
  }

  Witness getWitness(ValueDecl *decl) {
    return Conformance->getWitness(decl);
  }

  // Treat placeholders and missing methods as no-ops. These may be encountered
  // during lazy typechecking when SILGen triggers witness resolution and
  // discovers and invalid conformance. The diagnostics emitted during witness
  // resolution should cause compilation to fail.
  void addPlaceholder(MissingMemberDecl *placeholder) {}
  void addMissingMethod(SILDeclRef requirement) {}

  void addMethodImplementation(SILDeclRef requirementRef,
                               SILDeclRef witnessRef,
                               IsFreeFunctionWitness_t isFree,
                               Witness witness) {
    // Emit the witness thunk and add it to the table.
    auto witnessLinkage = witnessRef.getLinkage(ForDefinition);
    auto witnessSerializedKind = SerializedKind;
    if (witnessSerializedKind != IsNotSerialized &&
        // If package optimization is enabled, this is false;
        // witness thunk should get a `shared` linkage in the
        // else block below.
        fixmeWitnessHasLinkageThatNeedsToBePublic(
            witnessRef,
            witnessRef.getASTContext().SILOpts.EnableSerializePackage)) {
      witnessLinkage = SILLinkage::Public;
      witnessSerializedKind = IsNotSerialized;
    } else {
      // This is the "real" rule; the above case should go away once we
      // figure out what's going on.

      // Normally witness thunks can be private.
      witnessLinkage = SILLinkage::Private;

      // Unless the witness table is going to be serialized.
      if (witnessSerializedKind != IsNotSerialized)
        witnessLinkage = SILLinkage::Shared;

      // Or even if its not serialized, it might be for an imported
      // conformance in which case it can be emitted multiple times.
      if (Linkage == SILLinkage::Shared)
        witnessLinkage = SILLinkage::Shared;
    }

    if (isa<EnumElementDecl>(witnessRef.getDecl())) {
      assert(witnessRef.isEnumElement() && "Witness decl, but different kind?");
    }

    SILFunction *witnessFn = SGM.emitProtocolWitness(
        ProtocolConformanceRef(Conformance), witnessLinkage, witnessSerializedKind,
        requirementRef, witnessRef, isFree, witness);
    Entries.push_back(
                    SILWitnessTable::MethodWitness{requirementRef, witnessFn});
  }

  void addAssociatedType(AssociatedTypeDecl *assocType) {
    // Find the substitution info for the witness type.
    Type witness = Conformance->getTypeWitness(assocType);

    // Emit the record for the type itself.
    Entries.push_back(SILWitnessTable::AssociatedTypeWitness{assocType,
                                                witness->getCanonicalType()});
  }

  void addAssociatedConformance(AssociatedConformance req) {
    auto assocConformance =
      Conformance->getAssociatedConformance(req.getAssociation(),
                                            req.getAssociatedRequirement());
    SGM.useConformance(nullptr, assocConformance);
    Entries.push_back(SILWitnessTable::AssociatedConformanceWitness{
        req.getAssociation(), assocConformance});
  }

  void addConditionalRequirements() {
    SILWitnessTable::enumerateWitnessTableConditionalConformances(
        Conformance, [&](unsigned, CanType type, ProtocolDecl *protocol) {
          auto conformance = lookupConformance(type, protocol,
                                               /*allowMissing=*/true);
          assert(conformance &&
                 "unable to find conformance that should be known");

          ConditionalConformances.push_back(conformance);

          return /*finished?*/ false;
        });
  }
};

} // end anonymous namespace

SILWitnessTable *
SILGenModule::getWitnessTable(NormalProtocolConformance *conformance) {
  // If we've already emitted this witness table, return it.
  auto found = emittedWitnessTables.find(conformance);
  if (found != emittedWitnessTables.end())
    return found->second;

  SILWitnessTable *table = SILGenConformance(*this, conformance).emit();
  emittedWitnessTables.insert({conformance, table});

  return table;
}

/// Phase 3.F slice 6: synthesize a per-leaf dispatch body for
/// `Equatable.==` on a narrowed-Any type.
///
/// On entry `entry` already has the three SILFunctionArguments
/// [lhs: $*τ_0_0, rhs: $*τ_0_0, selfMeta: $@thick τ_0_0.Type]. We
/// emit, for each declared leaf L:
///   1. alloc_stack a slot for L
///   2. checked_cast_addr_br copy_on_success τ_0_0 → L on lhs
///   3. on lhs-success: alloc_stack rhs slot, try cast rhs → L
///      - both-success: witness_method on L's Equatable conformance,
///        apply, br exit(result)
///      - rhs-fail: cleanup, br false-exit (different leaves are
///        never equal)
///   4. on lhs-fail: dealloc, br next leaf (or false-exit if last)
///
/// Returns true if dispatch was emitted; false if the requirement
/// is not Equatable.== (caller should fall back to trap-stub).
static bool tryEmitNarrowedAnyEquatableEqDispatch(
    SILGenModule &SGM, SILFunction *thunk, SILBasicBlock *entry,
    BuiltinProtocolConformance *conformance, SILDeclRef reqRef) {
  ASTContext &ctx = SGM.getASTContext();
  auto *equatable = ctx.getProtocol(KnownProtocolKind::Equatable);
  if (conformance->getProtocol() != equatable)
    return false;

  // Detect Equatable's `==` (only single requirement of the protocol
  // in v1 stdlib that is a static operator; identified by `isOperator`
  // + base identifier "==").
  auto *funcReq = dyn_cast_or_null<AbstractFunctionDecl>(reqRef.getDecl());
  if (!funcReq || !funcReq->isOperator() ||
      funcReq->getBaseIdentifier().str() != "==")
    return false;

  Type peeled = conformance->getType();
  if (auto *ext = peeled->getAs<ExistentialType>())
    peeled = ext->getConstraintType();
  auto *narrowedAny = peeled->getAs<NarrowedAnyType>();
  if (!narrowedAny)
    return false;
  auto leaves = narrowedAny->getAlternatives();
  if (leaves.empty())
    return false;

  auto loc = RegularLocation::getModuleLocation();

  auto fnArgs = entry->getArguments();
  assert(fnArgs.size() == 3 &&
         "Equatable.== thunk should have lhs/rhs/selfMeta args");
  SILValue lhsAddr = fnArgs[0];
  SILValue rhsAddr = fnArgs[1];
  // fnArgs[2] (selfMeta) unused — we synthesize per-leaf metatypes.

  // Bool / i1 SIL types.
  auto *boolDecl = ctx.getBoolDecl();
  auto silBoolTy = SILType::getPrimitiveObjectType(
      boolDecl->getDeclaredInterfaceType()->getCanonicalType());
  auto i1Ty = SILType::getBuiltinIntegerType(1, ctx);

  // Source archetype for τ_0_0 in this thunk's environment.
  auto sig = thunk->getLoweredFunctionType()->getInvocationGenericSignature();
  auto srcArchetype = thunk->getGenericEnvironment()
      ->mapTypeIntoEnvironment(sig.getGenericParams()[0])
      ->getCanonicalType();

  // Exit block — phi takes Bool result.
  auto *exitBB = thunk->createBasicBlock();
  auto *resultPhi =
      exitBB->createPhiArgument(silBoolTy, OwnershipKind::None);
  {
    SILBuilder B(exitBB);
    B.createReturn(loc, resultPhi);
  }

  // False-exit block: build false Bool, br exit.
  auto *falseExitBB = thunk->createBasicBlock();
  {
    SILBuilder B(falseExitBB);
    auto *zero = B.createIntegerLiteral(loc, i1Ty, 0);
    auto *boolStruct = B.createStruct(loc, silBoolTy, {zero});
    B.createBranch(loc, exitBB, {boolStruct});
  }

  // SIL signature for Equatable.== — used to type witness_method.
  auto eqInfo = SGM.Types.getConstantInfo(
      TypeExpansionContext::minimal(), reqRef);
  auto eqSILTy = SILType::getPrimitiveObjectType(eqInfo.SILFnType);

  SILBasicBlock *currentBB = entry;
  for (size_t i = 0; i < leaves.size(); i++) {
    auto leafTy = leaves[i]->getCanonicalType();
    auto silLeafAddrTy = SILType::getPrimitiveAddressType(leafTy);

    SILBuilder B(currentBB);
    auto *lhsLeafSlot = B.createAllocStack(loc, silLeafAddrTy);

    auto *lhsOkBB = thunk->createBasicBlock();
    auto *lhsFailBB = thunk->createBasicBlock();

    B.createCheckedCastAddrBranch(loc, CheckedCastInstOptions(),
        CastConsumptionKind::CopyOnSuccess,
        lhsAddr, srcArchetype,
        lhsLeafSlot, leafTy,
        lhsOkBB, lhsFailBB);

    // lhsOk: try rhs.
    SILBuilder okB(lhsOkBB);
    auto *rhsLeafSlot = okB.createAllocStack(loc, silLeafAddrTy);
    auto *bothOkBB = thunk->createBasicBlock();
    auto *rhsFailBB = thunk->createBasicBlock();
    okB.createCheckedCastAddrBranch(loc, CheckedCastInstOptions(),
        CastConsumptionKind::CopyOnSuccess,
        rhsAddr, srcArchetype,
        rhsLeafSlot, leafTy,
        bothOkBB, rhsFailBB);

    // bothOk: witness_method dispatch.
    SILBuilder bothB(bothOkBB);
    auto leafConf = swift::lookupConformance(leafTy, equatable);
    assert(leafConf && "leaf was checked to conform at lookup time");
    // Slice 15: trigger lazy emission of inner builtin conformances (nested narrowed-Any).
    SGM.useConformance(nullptr, leafConf);

    auto witness = bothB.createWitnessMethod(loc, leafTy, leafConf,
                                             reqRef, eqSILTy);

    auto subs = SubstitutionMap::getProtocolSubstitutions(
        equatable, leafTy, leafConf);

    auto metaTy = SILType::getPrimitiveObjectType(
        CanMetatypeType::get(leafTy, MetatypeRepresentation::Thick));
    auto *metaVal = bothB.createMetatype(loc, metaTy);

    auto *applyResult = bothB.createApply(loc, witness, subs,
        {lhsLeafSlot, rhsLeafSlot, metaVal});

    bothB.createDestroyAddr(loc, lhsLeafSlot);
    bothB.createDestroyAddr(loc, rhsLeafSlot);
    bothB.createDeallocStack(loc, rhsLeafSlot);
    bothB.createDeallocStack(loc, lhsLeafSlot);
    bothB.createBranch(loc, exitBB, {applyResult});

    // rhsFail: lhs is owned (copied by lhs cast), rhs slot is uninit.
    // Different leaves are never equal — return false.
    SILBuilder rhsFB(rhsFailBB);
    rhsFB.createDestroyAddr(loc, lhsLeafSlot);
    rhsFB.createDeallocStack(loc, rhsLeafSlot);
    rhsFB.createDeallocStack(loc, lhsLeafSlot);
    rhsFB.createBranch(loc, falseExitBB);

    // lhsFail: lhs slot uninit (copy_on_success leaves source alone).
    SILBuilder lhsFB(lhsFailBB);
    lhsFB.createDeallocStack(loc, lhsLeafSlot);
    if (i + 1 < leaves.size()) {
      auto *nextBB = thunk->createBasicBlock();
      lhsFB.createBranch(loc, nextBB);
      currentBB = nextBB;
    } else {
      lhsFB.createBranch(loc, falseExitBB);
    }
  }

  return true;
}

/// Phase 3.F slice 14: synthesize per-leaf dispatch for
/// `Decodable.init(from:)` on a narrowed-Any type. Untagged JSON.
/// SIL signature:
///   `(@in any Decoder, @thick Self.Type) -> (@out Self, @error any Error)`.
/// Entry args: [@out Self, @in Decoder, @thick Self.Type].
///
/// For each leaf L: copy decoder, try_apply leaf's init, on
/// success widen leaf to narrowed-Any via init_existential_addr
/// (using collectExistentialConformances to build the right
/// conformances list), on error try next leaf. Last failed
/// leaf's error is rethrown.
static bool tryEmitNarrowedAnyDecodableDispatch(
    SILGenModule &SGM, SILFunction *thunk, SILBasicBlock *entry,
    BuiltinProtocolConformance *conformance, SILDeclRef reqRef) {
  ASTContext &ctx = SGM.getASTContext();
  auto *decodable = ctx.getProtocol(KnownProtocolKind::Decodable);
  if (conformance->getProtocol() != decodable)
    return false;

  auto *ctorReq = dyn_cast_or_null<ConstructorDecl>(reqRef.getDecl());
  if (!ctorReq)
    return false;

  Type peeled = conformance->getType();
  if (auto *ext = peeled->getAs<ExistentialType>())
    peeled = ext->getConstraintType();
  auto *narrowedAny = peeled->getAs<NarrowedAnyType>();
  if (!narrowedAny)
    return false;
  auto leaves = narrowedAny->getAlternatives();
  if (leaves.empty())
    return false;

  auto loc = RegularLocation::getModuleLocation();

  auto fnArgs = entry->getArguments();
  if (fnArgs.size() != 3)
    return false;
  SILValue outAddr = fnArgs[0];
  SILValue decoderAddr = fnArgs[1];

  // Build the existential SIL type for narrowed-Any. We use the
  // canonical ExistentialType(NarrowedAnyType) form — that's what
  // SILGen sees in the standard `let v: Int|String = leafValue`
  // path (which lowers init_existential_addr correctly).
  auto narrowedAnyCan = conformance->getType()->getCanonicalType();
  auto narrowedAnySIL = SILType::getPrimitiveAddressType(narrowedAnyCan);

  auto sig = thunk->getLoweredFunctionType()->getInvocationGenericSignature();
  auto srcArchetype = thunk->getGenericEnvironment()
      ->mapTypeIntoEnvironment(sig.getGenericParams()[0])
      ->getCanonicalType();
  (void)srcArchetype;

  auto decoderSILTy = decoderAddr->getType();

  auto *exitBB = thunk->createBasicBlock();
  {
    SILBuilder B(exitBB);
    auto voidVal = B.createTuple(loc, {});
    B.createReturn(loc, voidVal);
  }

  auto errorTy = thunk->getLoweredFunctionType()
      ->getErrorResult().getSILStorageType(thunk->getModule(),
          thunk->getLoweredFunctionType(),
          thunk->getTypeExpansionContext());
  auto *throwBB = thunk->createBasicBlock();
  auto *errorPhi =
      throwBB->createPhiArgument(errorTy, OwnershipKind::Owned);
  {
    SILBuilder B(throwBB);
    B.createDestroyAddr(loc, decoderAddr);
    B.createThrow(loc, errorPhi);
  }

  auto reqInfo = SGM.Types.getConstantInfo(
      TypeExpansionContext::minimal(), reqRef);
  auto reqSILTy = SILType::getPrimitiveObjectType(reqInfo.SILFnType);

  SILBasicBlock *currentBB = entry;
  for (size_t i = 0; i < leaves.size(); i++) {
    auto leafTy = leaves[i]->getCanonicalType();
    auto silLeafAddrTy = SILType::getPrimitiveAddressType(leafTy);

    SILBuilder B(currentBB);
    auto *leafSlot = B.createAllocStack(loc, silLeafAddrTy);
    auto *decoderCopy = B.createAllocStack(loc, decoderSILTy);
    B.createCopyAddr(loc, decoderAddr, decoderCopy,
                     IsNotTake, IsInitialization);

    auto metaTy = SILType::getPrimitiveObjectType(
        CanMetatypeType::get(leafTy, MetatypeRepresentation::Thick));
    auto *metaVal = B.createMetatype(loc, metaTy);

    auto leafConf = swift::lookupConformance(leafTy, decodable);
    assert(leafConf && "leaf was checked to conform at lookup time");
    // Slice 15: trigger lazy emission of inner builtin conformances (nested narrowed-Any).
    SGM.useConformance(nullptr, leafConf);
    auto witness = B.createWitnessMethod(loc, leafTy, leafConf,
                                         reqRef, reqSILTy);
    auto subs = SubstitutionMap::getProtocolSubstitutions(
        decodable, leafTy, leafConf);

    auto *normalBB = thunk->createBasicBlock();
    auto *errBB = thunk->createBasicBlock();
    auto voidTy = SILType::getPrimitiveObjectType(
        ctx.TheEmptyTupleType);
    normalBB->createPhiArgument(voidTy, OwnershipKind::None);
    errBB->createPhiArgument(errorTy, OwnershipKind::Owned);

    B.createTryApply(loc, witness, subs,
                     {leafSlot, decoderCopy, metaVal},
                     normalBB, errBB);

    // normal: cast outAddr to narrowed-Any existential SIL type,
    // init_existential_addr it as $L (use the type's conformance
    // lookup for the conformances list — should be empty for
    // narrowed-Any since it has Any layout), copy leaf in.
    SILBuilder normalB(normalBB);
    auto *castedOut = normalB.createUncheckedAddrCast(
        loc, outAddr, narrowedAnySIL);
    auto conformancesArr = swift::collectExistentialConformances(
        leafTy, narrowedAnyCan, /*allowMissing=*/false);
    auto *innerAddr = normalB.createInitExistentialAddr(
        loc, castedOut, leafTy, silLeafAddrTy, conformancesArr);
    normalB.createCopyAddr(loc, leafSlot, innerAddr,
                           IsTake, IsInitialization);
    normalB.createDestroyAddr(loc, decoderAddr);
    normalB.createDeallocStack(loc, decoderCopy);
    normalB.createDeallocStack(loc, leafSlot);
    normalB.createBranch(loc, exitBB);

    auto *errVal = errBB->getArgument(0);
    SILBuilder errB(errBB);
    if (i + 1 < leaves.size()) {
      errB.createDestroyValue(loc, errVal);
      errB.createDeallocStack(loc, decoderCopy);
      errB.createDeallocStack(loc, leafSlot);
      auto *nextBB = thunk->createBasicBlock();
      errB.createBranch(loc, nextBB);
      currentBB = nextBB;
    } else {
      errB.createDeallocStack(loc, decoderCopy);
      errB.createDeallocStack(loc, leafSlot);
      errB.createBranch(loc, throwBB, {errVal});
    }
  }

  return true;
}

/// Phase 3.F slice 13: synthesize per-leaf dispatch for
/// `Encodable.encode(to:)` on a narrowed-Any type.
/// Signature: `(@in_guaranteed any Encoder, @in_guaranteed Self) -> @error any Error`.
///
/// Body: for each leaf, try cast self -> leaf; on success
/// `try_apply` leaf's `encode(to:)`; on apply-success: cleanup +
/// return; on apply-error: cleanup + propagate the error via
/// `throw`. All-fail trap-stub is unreachable (Sema gates).
static bool tryEmitNarrowedAnyEncodableDispatch(
    SILGenModule &SGM, SILFunction *thunk, SILBasicBlock *entry,
    BuiltinProtocolConformance *conformance, SILDeclRef reqRef) {
  ASTContext &ctx = SGM.getASTContext();
  auto *encodable = ctx.getProtocol(KnownProtocolKind::Encodable);
  if (conformance->getProtocol() != encodable)
    return false;

  auto *funcReq = dyn_cast_or_null<AbstractFunctionDecl>(reqRef.getDecl());
  if (!funcReq || funcReq->getBaseIdentifier().str() != "encode")
    return false;

  Type peeled = conformance->getType();
  if (auto *ext = peeled->getAs<ExistentialType>())
    peeled = ext->getConstraintType();
  auto *narrowedAny = peeled->getAs<NarrowedAnyType>();
  if (!narrowedAny)
    return false;
  auto leaves = narrowedAny->getAlternatives();
  if (leaves.empty())
    return false;

  auto loc = RegularLocation::getModuleLocation();

  auto fnArgs = entry->getArguments();
  // Encodable.encode(to:): (@in_guaranteed any Encoder, @in_guaranteed Self) -> @error
  // 2 args (no implicit metatype for instance method).
  if (fnArgs.size() != 2)
    return false;
  SILValue encoderArg = fnArgs[0];
  SILValue selfAddr = fnArgs[1];

  auto sig = thunk->getLoweredFunctionType()->getInvocationGenericSignature();
  auto srcArchetype = thunk->getGenericEnvironment()
      ->mapTypeIntoEnvironment(sig.getGenericParams()[0])
      ->getCanonicalType();

  // Exit-success block (no return value, just `return ()`).
  auto *exitBB = thunk->createBasicBlock();
  {
    SILBuilder B(exitBB);
    auto voidVal = B.createTuple(loc, {});
    B.createReturn(loc, voidVal);
  }

  // Common throw block: takes the error value, throws.
  auto errorTy = thunk->getLoweredFunctionType()
      ->getErrorResult().getSILStorageType(thunk->getModule(),
          thunk->getLoweredFunctionType(),
          thunk->getTypeExpansionContext());
  auto *throwBB = thunk->createBasicBlock();
  auto *errorPhi =
      throwBB->createPhiArgument(errorTy, OwnershipKind::Owned);
  {
    SILBuilder B(throwBB);
    B.createThrow(loc, errorPhi);
  }

  auto *trapBB = thunk->createBasicBlock();
  {
    SILBuilder B(trapBB);
    B.createUnreachable(loc);
  }

  auto reqInfo = SGM.Types.getConstantInfo(
      TypeExpansionContext::minimal(), reqRef);
  auto reqSILTy = SILType::getPrimitiveObjectType(reqInfo.SILFnType);

  SILBasicBlock *currentBB = entry;
  for (size_t i = 0; i < leaves.size(); i++) {
    auto leafTy = leaves[i]->getCanonicalType();
    auto silLeafAddrTy = SILType::getPrimitiveAddressType(leafTy);

    SILBuilder B(currentBB);
    auto *leafSlot = B.createAllocStack(loc, silLeafAddrTy);

    auto *okBB = thunk->createBasicBlock();
    auto *failBB = thunk->createBasicBlock();
    B.createCheckedCastAddrBranch(loc, CheckedCastInstOptions(),
        CastConsumptionKind::CopyOnSuccess,
        selfAddr, srcArchetype,
        leafSlot, leafTy,
        okBB, failBB);

    SILBuilder okB(okBB);
    auto leafConf = swift::lookupConformance(leafTy, encodable);
    assert(leafConf && "leaf was checked to conform at lookup time");
    // Slice 15: trigger lazy emission of inner builtin conformances (nested narrowed-Any).
    SGM.useConformance(nullptr, leafConf);
    auto witness = okB.createWitnessMethod(loc, leafTy, leafConf,
                                           reqRef, reqSILTy);
    auto subs = SubstitutionMap::getProtocolSubstitutions(
        encodable, leafTy, leafConf);

    // try_apply needs normal_block + error_block.
    auto *normalBB = thunk->createBasicBlock();
    auto *errBB = thunk->createBasicBlock();
    // Compute the substituted result type for normal_block's phi.
    auto witnessFnTy = reqInfo.SILFnType->substGenericArgs(
        SGM.M, subs, thunk->getTypeExpansionContext());
    SILFunctionConventions wConv(witnessFnTy, SGM.M);
    auto normalResultTy = wConv.getSILResultType(
        thunk->getTypeExpansionContext());
    normalBB->createPhiArgument(normalResultTy,
                                 OwnershipKind::None);
    errBB->createPhiArgument(errorTy, OwnershipKind::Owned);

    okB.createTryApply(loc, witness, subs,
                       {encoderArg, leafSlot},
                       normalBB, errBB);

    // normal_block: cleanup, br exit_success.
    SILBuilder normalB(normalBB);
    normalB.createDestroyAddr(loc, leafSlot);
    normalB.createDeallocStack(loc, leafSlot);
    normalB.createBranch(loc, exitBB);

    // error_block: cleanup, forward error to throw_block.
    SILBuilder errB(errBB);
    auto errVal = errBB->getArgument(0);
    errB.createDestroyAddr(loc, leafSlot);
    errB.createDeallocStack(loc, leafSlot);
    errB.createBranch(loc, throwBB, {errVal});

    SILBuilder failB(failBB);
    failB.createDeallocStack(loc, leafSlot);
    if (i + 1 < leaves.size()) {
      auto *nextBB = thunk->createBasicBlock();
      failB.createBranch(loc, nextBB);
      currentBB = nextBB;
    } else {
      failB.createBranch(loc, trapBB);
    }
  }

  return true;
}

/// Phase 3.F slice 12: synthesize per-leaf dispatch for
/// `CustomStringConvertible.description` getter on narrowed-Any.
/// Signature: `(@in_guaranteed Self) -> @owned String` (instance
/// property getter, no implicit metatype).
///
/// Body: for each leaf L, try cast self -> L; on success
/// witness_method on leaf's getter, apply, return its String.
/// All-fail fallback: trap (every leaf was checked to conform at
/// lookup time, so this branch is unreachable).
static bool tryEmitNarrowedAnyDescriptionGetterDispatch(
    SILGenModule &SGM, SILFunction *thunk, SILBasicBlock *entry,
    BuiltinProtocolConformance *conformance, SILDeclRef reqRef) {
  auto *protocol = conformance->getProtocol();
  if (protocol->getName().str() != "CustomStringConvertible")
    return false;
  auto *module = protocol->getModuleContext();
  if (!module || !module->isStdlibModule())
    return false;

  // Detect the `description` getter accessor.
  auto *accessor = dyn_cast_or_null<AccessorDecl>(reqRef.getDecl());
  if (!accessor || accessor->getAccessorKind() != AccessorKind::Get)
    return false;
  auto *storage = accessor->getStorage();
  if (storage->getBaseIdentifier().str() != "description")
    return false;

  Type peeled = conformance->getType();
  if (auto *ext = peeled->getAs<ExistentialType>())
    peeled = ext->getConstraintType();
  auto *narrowedAny = peeled->getAs<NarrowedAnyType>();
  if (!narrowedAny)
    return false;
  auto leaves = narrowedAny->getAlternatives();
  if (leaves.empty())
    return false;

  auto loc = RegularLocation::getModuleLocation();

  auto fnArgs = entry->getArguments();
  if (fnArgs.size() != 1)
    return false;
  SILValue selfAddr = fnArgs[0];

  auto sig = thunk->getLoweredFunctionType()->getInvocationGenericSignature();
  auto srcArchetype = thunk->getGenericEnvironment()
      ->mapTypeIntoEnvironment(sig.getGenericParams()[0])
      ->getCanonicalType();

  auto stringSILTy = thunk->getLoweredFunctionType()
      ->getDirectFormalResultsType(thunk->getModule(),
                                   thunk->getTypeExpansionContext());

  // Exit block — phi takes String result (owned).
  auto *exitBB = thunk->createBasicBlock();
  auto *resultPhi =
      exitBB->createPhiArgument(stringSILTy, OwnershipKind::Owned);
  {
    SILBuilder B(exitBB);
    B.createReturn(loc, resultPhi);
  }

  // Trap-fallback (unreachable in practice). Don't try to construct
  // an empty String here — leaving it as `unreachable` keeps the
  // helper minimal and correct: Sema gates conformance on every
  // leaf conforming, so one of the casts always succeeds.
  auto *trapBB = thunk->createBasicBlock();
  {
    SILBuilder B(trapBB);
    B.createUnreachable(loc);
  }

  auto reqInfo = SGM.Types.getConstantInfo(
      TypeExpansionContext::minimal(), reqRef);
  auto reqSILTy = SILType::getPrimitiveObjectType(reqInfo.SILFnType);

  SILBasicBlock *currentBB = entry;
  for (size_t i = 0; i < leaves.size(); i++) {
    auto leafTy = leaves[i]->getCanonicalType();
    auto silLeafAddrTy = SILType::getPrimitiveAddressType(leafTy);

    SILBuilder B(currentBB);
    auto *leafSlot = B.createAllocStack(loc, silLeafAddrTy);

    auto *okBB = thunk->createBasicBlock();
    auto *failBB = thunk->createBasicBlock();
    B.createCheckedCastAddrBranch(loc, CheckedCastInstOptions(),
        CastConsumptionKind::CopyOnSuccess,
        selfAddr, srcArchetype,
        leafSlot, leafTy,
        okBB, failBB);

    SILBuilder okB(okBB);
    auto leafConf = swift::lookupConformance(leafTy, protocol);
    assert(leafConf && "leaf was checked to conform at lookup time");
    // Slice 15: trigger lazy emission of inner builtin conformances (nested narrowed-Any).
    SGM.useConformance(nullptr, leafConf);
    auto witness = okB.createWitnessMethod(loc, leafTy, leafConf,
                                           reqRef, reqSILTy);
    auto subs = SubstitutionMap::getProtocolSubstitutions(
        protocol, leafTy, leafConf);
    auto *strResult = okB.createApply(loc, witness, subs, {leafSlot});
    okB.createDestroyAddr(loc, leafSlot);
    okB.createDeallocStack(loc, leafSlot);
    okB.createBranch(loc, exitBB, {strResult});

    SILBuilder failB(failBB);
    failB.createDeallocStack(loc, leafSlot);
    if (i + 1 < leaves.size()) {
      auto *nextBB = thunk->createBasicBlock();
      failB.createBranch(loc, nextBB);
      currentBB = nextBB;
    } else {
      failB.createBranch(loc, trapBB);
    }
  }

  return true;
}

/// Phase 3.F slice 11: synthesize per-leaf dispatch for
/// `Comparable.<` on a narrowed-Any type. Same shape as
/// Equatable.== (static op, 3 args, returns Bool):
///   - Both leaves match: dispatch to leaf's `<`, return its result
///   - Different leaves: returns true iff lhs's leaf-index <
///     rhs's leaf-index (declaration order). This gives a stable
///     total order on the closed leaf set; together with same-leaf
///     `<` it forms a strict total order across narrowed-Any.
static bool tryEmitNarrowedAnyComparableLessThanDispatch(
    SILGenModule &SGM, SILFunction *thunk, SILBasicBlock *entry,
    BuiltinProtocolConformance *conformance, SILDeclRef reqRef) {
  ASTContext &ctx = SGM.getASTContext();
  auto *comparable = ctx.getProtocol(KnownProtocolKind::Comparable);
  if (conformance->getProtocol() != comparable)
    return false;

  auto *funcReq = dyn_cast_or_null<AbstractFunctionDecl>(reqRef.getDecl());
  if (!funcReq || !funcReq->isOperator() ||
      funcReq->getBaseIdentifier().str() != "<")
    return false;

  Type peeled = conformance->getType();
  if (auto *ext = peeled->getAs<ExistentialType>())
    peeled = ext->getConstraintType();
  auto *narrowedAny = peeled->getAs<NarrowedAnyType>();
  if (!narrowedAny)
    return false;
  auto leaves = narrowedAny->getAlternatives();
  if (leaves.empty())
    return false;

  auto loc = RegularLocation::getModuleLocation();

  auto fnArgs = entry->getArguments();
  assert(fnArgs.size() == 3 &&
         "Comparable.< thunk should have lhs/rhs/selfMeta args");
  SILValue lhsAddr = fnArgs[0];
  SILValue rhsAddr = fnArgs[1];

  auto *boolDecl = ctx.getBoolDecl();
  auto silBoolTy = SILType::getPrimitiveObjectType(
      boolDecl->getDeclaredInterfaceType()->getCanonicalType());
  auto i1Ty = SILType::getBuiltinIntegerType(1, ctx);

  auto sig = thunk->getLoweredFunctionType()->getInvocationGenericSignature();
  auto srcArchetype = thunk->getGenericEnvironment()
      ->mapTypeIntoEnvironment(sig.getGenericParams()[0])
      ->getCanonicalType();

  // Exit block — phi takes Bool result.
  auto *exitBB = thunk->createBasicBlock();
  auto *resultPhi =
      exitBB->createPhiArgument(silBoolTy, OwnershipKind::None);
  {
    SILBuilder B(exitBB);
    B.createReturn(loc, resultPhi);
  }

  // True/false return blocks (for cross-leaf order resolution).
  auto buildBoolExit = [&](bool value) -> SILBasicBlock * {
    auto *bb = thunk->createBasicBlock();
    SILBuilder B(bb);
    auto *bit = B.createIntegerLiteral(loc, i1Ty, value ? 1 : 0);
    auto *boolStruct = B.createStruct(loc, silBoolTy, {bit});
    B.createBranch(loc, exitBB, {boolStruct});
    return bb;
  };
  auto *trueExitBB = buildBoolExit(true);
  auto *falseExitBB = buildBoolExit(false);

  auto eqInfo = SGM.Types.getConstantInfo(
      TypeExpansionContext::minimal(), reqRef);
  auto eqSILTy = SILType::getPrimitiveObjectType(eqInfo.SILFnType);

  // For each leaf L_i, emit: try cast lhs -> L_i;
  //   on success: alloc rhs slot, try cast rhs -> L_i;
  //     both: dispatch leaf's <
  //     rhs-fail: try rhs against later leaves (j > i): if rhs is
  //       L_j, then lhs (L_i) < rhs (L_j) — true. If none of the
  //       later leaves match, rhs is one of L_<i, so lhs < rhs is
  //       false.
  //   on lhs-fail: try next leaf
  //
  // To keep the cascade simple we encode the cross-leaf order
  // resolution as: rhs-fail at L_i implies rhs is some L_j with
  // j != i. We can't easily distinguish j<i from j>i in a single
  // cascade pass without a metadata-compare; instead, emit a
  // secondary cascade that classifies rhs's leaf index, then
  // returns (i < rhsIdx).
  SILBasicBlock *currentBB = entry;
  for (size_t i = 0; i < leaves.size(); i++) {
    auto leafTy = leaves[i]->getCanonicalType();
    auto silLeafAddrTy = SILType::getPrimitiveAddressType(leafTy);

    SILBuilder B(currentBB);
    auto *lhsLeafSlot = B.createAllocStack(loc, silLeafAddrTy);

    auto *lhsOkBB = thunk->createBasicBlock();
    auto *lhsFailBB = thunk->createBasicBlock();
    B.createCheckedCastAddrBranch(loc, CheckedCastInstOptions(),
        CastConsumptionKind::CopyOnSuccess,
        lhsAddr, srcArchetype,
        lhsLeafSlot, leafTy,
        lhsOkBB, lhsFailBB);

    // lhsOk: rhs needs to also be L_i for a same-leaf dispatch.
    SILBuilder okB(lhsOkBB);
    auto *rhsLeafSlot = okB.createAllocStack(loc, silLeafAddrTy);
    auto *bothOkBB = thunk->createBasicBlock();
    auto *rhsFailBB = thunk->createBasicBlock();
    okB.createCheckedCastAddrBranch(loc, CheckedCastInstOptions(),
        CastConsumptionKind::CopyOnSuccess,
        rhsAddr, srcArchetype,
        rhsLeafSlot, leafTy,
        bothOkBB, rhsFailBB);

    // bothOk: dispatch leaf's <
    SILBuilder bothB(bothOkBB);
    auto leafConf = swift::lookupConformance(leafTy, comparable);
    assert(leafConf && "leaf was checked to conform at lookup time");
    // Slice 15: trigger lazy emission of inner builtin conformances (nested narrowed-Any).
    SGM.useConformance(nullptr, leafConf);
    auto witness = bothB.createWitnessMethod(loc, leafTy, leafConf,
                                             reqRef, eqSILTy);
    auto subs = SubstitutionMap::getProtocolSubstitutions(
        comparable, leafTy, leafConf);
    auto metaTy = SILType::getPrimitiveObjectType(
        CanMetatypeType::get(leafTy, MetatypeRepresentation::Thick));
    auto *metaVal = bothB.createMetatype(loc, metaTy);
    auto *applyResult = bothB.createApply(loc, witness, subs,
        {lhsLeafSlot, rhsLeafSlot, metaVal});
    bothB.createDestroyAddr(loc, lhsLeafSlot);
    bothB.createDestroyAddr(loc, rhsLeafSlot);
    bothB.createDeallocStack(loc, rhsLeafSlot);
    bothB.createDeallocStack(loc, lhsLeafSlot);
    bothB.createBranch(loc, exitBB, {applyResult});

    // rhsFail: lhs is L_i, rhs is some L_j (j != i). Cross-leaf
    // order: lhs<rhs iff i<j. Try rhs against leaves L_{i+1}, ...
    // L_{n-1}; on first match: i<j → true. If none match (rhs is
    // a leaf < i): i>j → false.
    {
      SILBuilder rhsFB(rhsFailBB);
      rhsFB.createDestroyAddr(loc, lhsLeafSlot);
      rhsFB.createDeallocStack(loc, rhsLeafSlot);
      rhsFB.createDeallocStack(loc, lhsLeafSlot);
    }
    SILBasicBlock *currentScanBB = rhsFailBB;
    for (size_t j = i + 1; j < leaves.size(); j++) {
      auto rhsLeafTy = leaves[j]->getCanonicalType();
      auto rhsSilTy = SILType::getPrimitiveAddressType(rhsLeafTy);
      SILBuilder scanB(currentScanBB);
      auto *probeSlot = scanB.createAllocStack(loc, rhsSilTy);
      auto *matchBB = thunk->createBasicBlock();
      auto *missBB = thunk->createBasicBlock();
      scanB.createCheckedCastAddrBranch(loc,
          CheckedCastInstOptions(),
          CastConsumptionKind::CopyOnSuccess,
          rhsAddr, srcArchetype,
          probeSlot, rhsLeafTy,
          matchBB, missBB);

      // match: i<j, lhs<rhs is true.
      SILBuilder matchB(matchBB);
      matchB.createDestroyAddr(loc, probeSlot);
      matchB.createDeallocStack(loc, probeSlot);
      matchB.createBranch(loc, trueExitBB);

      // miss: probeSlot uninit (copy_on_success), continue.
      SILBuilder missB(missBB);
      missB.createDeallocStack(loc, probeSlot);
      currentScanBB = missBB;
    }
    // Out of higher leaves — rhs is some L_<i, so lhs>rhs (false).
    {
      SILBuilder finalB(currentScanBB);
      finalB.createBranch(loc, falseExitBB);
    }

    // lhsFail: lhs slot uninit, dealloc, try next leaf.
    SILBuilder lhsFB(lhsFailBB);
    lhsFB.createDeallocStack(loc, lhsLeafSlot);
    if (i + 1 < leaves.size()) {
      auto *nextBB = thunk->createBasicBlock();
      lhsFB.createBranch(loc, nextBB);
      currentBB = nextBB;
    } else {
      // Should be unreachable (every leaf was tried), but emit
      // a safe fallback.
      lhsFB.createBranch(loc, falseExitBB);
    }
  }

  return true;
}

/// Phase 3.F slice 7: synthesize per-leaf dispatch for
/// `Hashable._rawHashValue(seed:)` on a narrowed-Any type.
/// Signature: `(Int seed, @in_guaranteed Self) -> Int`.
/// Body: for each leaf, try cast self -> leaf; on success
/// witness_method(_rawHashValue) on leaf's conformance, apply,
/// return its Int result; on all-fail return the seed unchanged.
static bool tryEmitNarrowedAnyHashableRawHashValueDispatch(
    SILGenModule &SGM, SILFunction *thunk, SILBasicBlock *entry,
    BuiltinProtocolConformance *conformance, SILDeclRef reqRef) {
  ASTContext &ctx = SGM.getASTContext();
  auto *hashable = ctx.getProtocol(KnownProtocolKind::Hashable);
  if (conformance->getProtocol() != hashable)
    return false;

  auto *funcReq = dyn_cast_or_null<AbstractFunctionDecl>(reqRef.getDecl());
  if (!funcReq || funcReq->getBaseIdentifier().str() != "_rawHashValue")
    return false;

  Type peeled = conformance->getType();
  if (auto *ext = peeled->getAs<ExistentialType>())
    peeled = ext->getConstraintType();
  auto *narrowedAny = peeled->getAs<NarrowedAnyType>();
  if (!narrowedAny)
    return false;
  auto leaves = narrowedAny->getAlternatives();
  if (leaves.empty())
    return false;

  auto loc = RegularLocation::getModuleLocation();

  auto fnArgs = entry->getArguments();
  if (fnArgs.size() != 2)
    return false;
  SILValue seedVal = fnArgs[0];
  SILValue selfAddr = fnArgs[1];

  auto sig = thunk->getLoweredFunctionType()->getInvocationGenericSignature();
  auto srcArchetype = thunk->getGenericEnvironment()
      ->mapTypeIntoEnvironment(sig.getGenericParams()[0])
      ->getCanonicalType();

  // Int return type — read from the function signature.
  auto intSILTy = thunk->getLoweredFunctionType()
      ->getDirectFormalResultsType(thunk->getModule(),
                                   thunk->getTypeExpansionContext());

  // Exit block — phi takes Int result.
  auto *exitBB = thunk->createBasicBlock();
  auto *resultPhi =
      exitBB->createPhiArgument(intSILTy, OwnershipKind::None);
  {
    SILBuilder B(exitBB);
    B.createReturn(loc, resultPhi);
  }

  // Seed-fallback block: forward the input seed unchanged.
  auto *fallbackBB = thunk->createBasicBlock();
  {
    SILBuilder B(fallbackBB);
    B.createBranch(loc, exitBB, {seedVal});
  }

  auto reqInfo = SGM.Types.getConstantInfo(
      TypeExpansionContext::minimal(), reqRef);
  auto reqSILTy = SILType::getPrimitiveObjectType(reqInfo.SILFnType);

  SILBasicBlock *currentBB = entry;
  for (size_t i = 0; i < leaves.size(); i++) {
    auto leafTy = leaves[i]->getCanonicalType();
    auto silLeafAddrTy = SILType::getPrimitiveAddressType(leafTy);

    SILBuilder B(currentBB);
    auto *leafSlot = B.createAllocStack(loc, silLeafAddrTy);

    auto *okBB = thunk->createBasicBlock();
    auto *failBB = thunk->createBasicBlock();
    B.createCheckedCastAddrBranch(loc, CheckedCastInstOptions(),
        CastConsumptionKind::CopyOnSuccess,
        selfAddr, srcArchetype,
        leafSlot, leafTy,
        okBB, failBB);

    SILBuilder okB(okBB);
    auto leafConf = swift::lookupConformance(leafTy, hashable);
    assert(leafConf && "leaf was checked to conform at lookup time");
    // Slice 15: trigger lazy emission of inner builtin conformances (nested narrowed-Any).
    SGM.useConformance(nullptr, leafConf);

    auto witness = okB.createWitnessMethod(loc, leafTy, leafConf,
                                           reqRef, reqSILTy);
    auto subs = SubstitutionMap::getProtocolSubstitutions(
        hashable, leafTy, leafConf);

    auto *hashResult = okB.createApply(loc, witness, subs,
                                       {seedVal, leafSlot});
    okB.createDestroyAddr(loc, leafSlot);
    okB.createDeallocStack(loc, leafSlot);
    okB.createBranch(loc, exitBB, {hashResult});

    SILBuilder failB(failBB);
    failB.createDeallocStack(loc, leafSlot);
    if (i + 1 < leaves.size()) {
      auto *nextBB = thunk->createBasicBlock();
      failB.createBranch(loc, nextBB);
      currentBB = nextBB;
    } else {
      failB.createBranch(loc, fallbackBB);
    }
  }

  return true;
}

/// Phase 3.F slice 7: synthesize per-leaf dispatch for
/// `Hashable.hash(into:)` on a narrowed-Any type.
///
/// On entry `entry` already has the SILFunctionArguments
/// [hasher: $*Hasher (inout), self: $*τ_0_0, selfMeta: $@thick τ_0_0.Type].
/// For each declared leaf L:
///   1. alloc_stack a slot for L, try cast self -> L
///   2. on success: witness_method on L's Hashable.hash(into:)
///      with the same hasher, apply, br exit
///   3. on fail: try next leaf
/// All leaves miss → no-op br exit (Hasher gets nothing combined,
/// semantically wrong but doesn't crash; rare since Sema gates the
/// conformance to "all leaves conform to Hashable").
///
/// Returns true if dispatch was emitted; false otherwise (caller
/// falls back to trap-stub).
static bool tryEmitNarrowedAnyHashableHashIntoDispatch(
    SILGenModule &SGM, SILFunction *thunk, SILBasicBlock *entry,
    BuiltinProtocolConformance *conformance, SILDeclRef reqRef) {
  ASTContext &ctx = SGM.getASTContext();
  auto *hashable = ctx.getProtocol(KnownProtocolKind::Hashable);
  if (conformance->getProtocol() != hashable)
    return false;

  // Detect Hashable's `hash(into:)` instance method.
  auto *funcReq = dyn_cast_or_null<AbstractFunctionDecl>(reqRef.getDecl());
  if (!funcReq || funcReq->getBaseIdentifier().str() != "hash")
    return false;

  Type peeled = conformance->getType();
  if (auto *ext = peeled->getAs<ExistentialType>())
    peeled = ext->getConstraintType();
  auto *narrowedAny = peeled->getAs<NarrowedAnyType>();
  if (!narrowedAny)
    return false;
  auto leaves = narrowedAny->getAlternatives();
  if (leaves.empty())
    return false;

  auto loc = RegularLocation::getModuleLocation();

  auto fnArgs = entry->getArguments();
  // Hashable.hash(into:) is an instance method, lowered as
  //   (@inout Hasher, @in_guaranteed Self) -> ()
  // — 2 args, no implicit @thick Self.Type (that only appears for
  // static witness methods like Equatable.==). The witness_method
  // convention's Self metadata is passed via the implicit %Self
  // parameter at the LLVM level, but at SIL level the function has
  // exactly 2 args.
  if (fnArgs.size() != 2)
    return false;
  SILValue hasherInout = fnArgs[0];
  SILValue selfAddr = fnArgs[1];

  // Source archetype for τ_0_0.
  auto sig = thunk->getLoweredFunctionType()->getInvocationGenericSignature();
  auto srcArchetype = thunk->getGenericEnvironment()
      ->mapTypeIntoEnvironment(sig.getGenericParams()[0])
      ->getCanonicalType();

  // Exit block — empty Void return.
  auto *exitBB = thunk->createBasicBlock();
  {
    SILBuilder B(exitBB);
    auto voidVal = B.createTuple(loc, {});
    B.createReturn(loc, voidVal);
  }

  auto reqInfo = SGM.Types.getConstantInfo(
      TypeExpansionContext::minimal(), reqRef);
  auto reqSILTy = SILType::getPrimitiveObjectType(reqInfo.SILFnType);

  SILBasicBlock *currentBB = entry;
  for (size_t i = 0; i < leaves.size(); i++) {
    auto leafTy = leaves[i]->getCanonicalType();
    auto silLeafAddrTy = SILType::getPrimitiveAddressType(leafTy);

    SILBuilder B(currentBB);
    auto *leafSlot = B.createAllocStack(loc, silLeafAddrTy);

    auto *okBB = thunk->createBasicBlock();
    auto *failBB = thunk->createBasicBlock();
    B.createCheckedCastAddrBranch(loc, CheckedCastInstOptions(),
        CastConsumptionKind::CopyOnSuccess,
        selfAddr, srcArchetype,
        leafSlot, leafTy,
        okBB, failBB);

    // ok: dispatch leaf's hash(into:).
    SILBuilder okB(okBB);
    auto leafConf = swift::lookupConformance(leafTy, hashable);
    assert(leafConf && "leaf was checked to conform at lookup time");
    // Slice 15: trigger lazy emission of inner builtin conformances (nested narrowed-Any).
    SGM.useConformance(nullptr, leafConf);

    auto witness = okB.createWitnessMethod(loc, leafTy, leafConf,
                                           reqRef, reqSILTy);
    auto subs = SubstitutionMap::getProtocolSubstitutions(
        hashable, leafTy, leafConf);

    okB.createApply(loc, witness, subs,
                    {hasherInout, leafSlot});
    okB.createDestroyAddr(loc, leafSlot);
    okB.createDeallocStack(loc, leafSlot);
    okB.createBranch(loc, exitBB);

    // fail: dealloc, try next leaf or br exit.
    SILBuilder failB(failBB);
    failB.createDeallocStack(loc, leafSlot);
    if (i + 1 < leaves.size()) {
      auto *nextBB = thunk->createBasicBlock();
      failB.createBranch(loc, nextBB);
      currentBB = nextBB;
    } else {
      failB.createBranch(loc, exitBB);
    }
  }

  return true;
}

SILWitnessTable *SILGenModule::getNarrowedAnyDispatchWitnessTable(
    BuiltinProtocolConformance *conformance) {
  // Phase 3.F slice 1-14: synthesize the SILWitnessTable for a
  // narrowed-Any conformance to a per-method-witness protocol
  // (Equatable, Hashable, Comparable, CustomStringConvertible,
  // Encodable, Decodable today). Layout:
  //   * One BaseProtocolWitness entry per refined protocol
  //     (e.g. Hashable.Equatable) — IRGen fills the slot via
  //     getNarrowedAnyDispatchBaseConfAccessor.
  //   * One Method entry per protocol method/property requirement,
  //     pointing at a [shared] [thunk] SIL function whose body is
  //     emitted by tryEmitNarrowedAnyXxxDispatch (per-leaf
  //     checked_cast_addr_br + witness_method on the leaf's own
  //     conformance, with a final trap-stub fallback for
  //     requirements not yet covered by a dedicated dispatch
  //     helper).
  // The witness table is `[shared]` so multiple translation units
  // naming the same `(A | B, P)` pair coalesce.
  assert(conformance->getBuiltinConformanceKind() ==
             BuiltinConformanceKind::NarrowedAnyDispatch &&
         "unexpected builtin conformance kind");

  if (auto *cached = emittedBuiltinWitnessTables.lookup(conformance))
    return cached;

  SmallVector<SILWitnessTable::Entry, 4> entries;
  SmallVector<ProtocolConformanceRef, 0> conditional;
  SILGenFunctionBuilder funcBuilder(*this);

  auto *protocol = conformance->getProtocol();
  ASTContext &ctx = getASTContext();

  // Slice 7: emit BaseProtocolWitness entries first (matching the
  // SILWitnessVisitor canonical layout — base protocols come before
  // method requirements). For each refined protocol that requires
  // a witness table (e.g. Hashable refines Equatable), construct
  // a sibling NarrowedAnyDispatch builtin conformance for the same
  // narrowed-Any type and reference it.
  for (const auto &reqt : protocol->getRequirementSignature().getRequirements()) {
    if (reqt.getKind() != RequirementKind::Conformance)
      continue;
    auto type = reqt.getFirstType()->getCanonicalType();
    auto parameter = dyn_cast<GenericTypeParamType>(type);
    if (!parameter || parameter->getDepth() != 0 ||
        parameter->getIndex() != 0)
      continue;
    auto *baseProto = reqt.getProtocolDecl();
    if (!Lowering::TypeConverter::protocolRequiresWitnessTable(baseProto))
      continue;

    auto baseConf = ctx.getBuiltinConformance(
        conformance->getType()->getCanonicalType(), baseProto,
        BuiltinConformanceKind::NarrowedAnyDispatch);
    entries.push_back(SILWitnessTable::BaseProtocolWitness{
        baseProto, baseConf});
    // Trigger sibling WT emission via the same lazy path.
    useConformance(nullptr, ProtocolConformanceRef(baseConf));
  }

  // Collect SILDeclRefs for every concrete requirement that needs
  // a witness-table slot. AbstractFunctionDecl maps directly;
  // AbstractStorageDecl (var/subscript) expands to its accessors.
  // This scaffolding is what future protocol extensions
  // (CustomStringConvertible.description getter, etc.) will need.
  SmallVector<SILDeclRef, 4> reqRefs;
  for (auto *req : protocol->getProtocolRequirements()) {
    if (auto *funcReq = dyn_cast<AbstractFunctionDecl>(req)) {
      reqRefs.push_back(SILDeclRef(funcReq));
      continue;
    }
    if (auto *storage = dyn_cast<AbstractStorageDecl>(req)) {
      if (auto *getter = storage->getOpaqueAccessor(AccessorKind::Get))
        reqRefs.push_back(SILDeclRef(getter, SILDeclRef::Kind::Func));
      if (auto *setter = storage->getOpaqueAccessor(AccessorKind::Set))
        reqRefs.push_back(SILDeclRef(setter, SILDeclRef::Kind::Func));
    }
  }

  for (auto reqRef : reqRefs) {
    auto reqInfo = Types.getConstantInfo(
        TypeExpansionContext::minimal(), reqRef);
    auto reqSILFnType = reqInfo.SILFnType;

    // Mangle a stable per-(conformance, requirement) name. Reusing
    // ASTMangler keeps the symbol in a recognizable shape; "Tnaw"
    // suffix marks "narrowed-any-dispatch witness, trap-stub" so the
    // demangler / debugger can distinguish.
    Mangle::ASTMangler mangler(getASTContext());
    auto thunkName = mangler.mangleWitnessThunk(conformance,
                                                reqRef.getDecl()) +
                     "Tnaw";

    auto *thunk = funcBuilder.getOrCreateSharedFunction(
        RegularLocation::getModuleLocation(),
        thunkName, reqSILFnType,
        IsBare, IsNotTransparent, IsNotSerialized,
        ProfileCounter(), IsThunk, IsNotDynamic, IsNotDistributed,
        IsNotRuntimeAccessible);
    if (thunk->empty()) {
      // Trap-stub body: an entry block with all SILFunctionArguments
      // matching the requirement's signature, then `unreachable`.
      // Real per-leaf dispatch synth (the follow-up) replaces the
      // unreachable with a body that opens the existential operands
      // and dispatches to leaf witnesses.
      //
      // The SIL function type is polymorphic in the protocol's
      // requirement signature (e.g. `<τ_0_0: Equatable>`); the
      // verifier requires a matching generic environment on the
      // function and entry-block args mapped through that env.
      auto sig = reqSILFnType->getInvocationGenericSignature();
      thunk->setGenericEnvironment(sig.getGenericEnvironment());
      thunk->setBare(IsBare);
      auto *entry = thunk->createBasicBlock();

      SILFunctionConventions fnConv(reqSILFnType, M);
      auto expansion = thunk->getTypeExpansionContext();
      for (auto resultTy :
           fnConv.getIndirectSILResultTypes(expansion))
        entry->createFunctionArgument(thunk->mapTypeIntoEnvironment(resultTy));
      if (fnConv.hasIndirectSILErrorResults())
        entry->createFunctionArgument(thunk->mapTypeIntoEnvironment(
            fnConv.getIndirectErrorResultType(expansion)));
      for (auto paramTy :
           fnConv.getParameterSILTypes(expansion))
        entry->createFunctionArgument(thunk->mapTypeIntoEnvironment(paramTy));

      // Phase 3.F slice 6 / 7: try real per-leaf dispatch for the
      // protocol's known requirements (Equatable.==, Hashable.hash,
      // Hashable._rawHashValue). Falls through to trap-stub for any
      // other requirement.
      if (!tryEmitNarrowedAnyEquatableEqDispatch(*this, thunk, entry,
                                                 conformance, reqRef) &&
          !tryEmitNarrowedAnyHashableHashIntoDispatch(*this, thunk, entry,
                                                      conformance, reqRef) &&
          !tryEmitNarrowedAnyHashableRawHashValueDispatch(*this, thunk, entry,
                                                          conformance, reqRef) &&
          !tryEmitNarrowedAnyComparableLessThanDispatch(*this, thunk, entry,
                                                        conformance, reqRef) &&
          !tryEmitNarrowedAnyDescriptionGetterDispatch(*this, thunk, entry,
                                                       conformance, reqRef) &&
          !tryEmitNarrowedAnyEncodableDispatch(*this, thunk, entry,
                                               conformance, reqRef) &&
          !tryEmitNarrowedAnyDecodableDispatch(*this, thunk, entry,
                                               conformance, reqRef)) {
        SILBuilder builder(entry);
        builder.createUnreachable(RegularLocation::getModuleLocation());
      }
    }

    entries.push_back(SILWitnessTable::MethodWitness{reqRef, thunk});
  }

  // Best-effort linkage: shared so multiple modules naming the same
  // (A | B, P) pair coalesce. Not serialized — definitions are
  // intentionally trivial today.
  auto *table = SILWitnessTable::create(
      M, SILLinkage::Shared, IsNotSerialized, conformance, entries,
      conditional, /*specialized=*/false);
  emittedBuiltinWitnessTables.insert({conformance, table});
  return table;
}

SILFunction *SILGenModule::emitProtocolWitness(
    ProtocolConformanceRef origConformance, SILLinkage linkage,
    SerializedKind_t serializedKind, SILDeclRef requirement,
    SILDeclRef witnessRef, IsFreeFunctionWitness_t isFree, Witness witness) {
  auto requirementInfo =
      Types.getConstantInfo(TypeExpansionContext::minimal(), requirement);

  auto shouldUseDistributedThunkWitness =
      // always use a distributed thunk for distributed requirements:
      requirement.isDistributedThunk() ||
      // for non-distributed requirements, which are however async/throws,
      // and have a proper witness (passed typechecking), we can still invoke
      // them on the distributed actor; but must do so through the distributed
      // thunk as the call "through an existential" we never statically know
      // if the actor is local or not.
      (requirement.hasDecl() && requirement.getFuncDecl() && requirement.hasAsync() &&
       !requirement.getFuncDecl()->isDistributed() &&
       witnessRef.hasDecl() && witnessRef.getFuncDecl() &&
       witnessRef.getFuncDecl()->isDistributed());
  if (shouldUseDistributedThunkWitness) {
    // we may not have a thunk if we're in a protocol?
    if (auto thunk = witnessRef.getFuncDecl()->getDistributedThunk()) {
      auto thunkDeclRef = SILDeclRef(thunk, SILDeclRef::Kind::Func);
      witnessRef = thunkDeclRef.asDistributed();
    }
  }

  // Work out the lowered function type of the SIL witness thunk.
  auto reqtOrigTy = cast<GenericFunctionType>(requirementInfo.LoweredType);

  // Mapping from the requirement's generic signature to the witness
  // thunk's generic signature.
  auto reqtSubMap = witness.getRequirementToWitnessThunkSubs();

  // The generic environment for the witness thunk.
  auto *genericEnv = witness.getWitnessThunkSignature().getGenericEnvironment();
  auto genericSig = witness.getWitnessThunkSignature().getCanonicalSignature();

  // The type of the witness thunk.
  auto reqtSubstTy = cast<AnyFunctionType>(
    reqtOrigTy->substGenericArgs(reqtSubMap)
              ->mapTypeOutOfEnvironment()
              ->getCanonicalType());

  // Rewrite the conformance in terms of the requirement environment's Self
  // type, which might have a different generic signature than the type
  // itself.
  //
  // For example, if the conforming type is a class and the witness is defined
  // in a protocol extension, the generic signature will have an additional
  // generic parameter representing Self, so the generic parameters of the
  // class will all be shifted down by one.
  auto conformance = origConformance;
  ProtocolConformance *manglingConformance = nullptr;
  if (conformance.isConcrete()) {
    conformance = reqtSubMap.lookupConformance(M.getASTContext().TheSelfType,
                                               origConformance.getProtocol())
        .mapConformanceOutOfEnvironment();
    ASSERT(!conformance.isAbstract());

    manglingConformance = conformance.getConcrete();
    if (auto *inherited = dyn_cast<InheritedProtocolConformance>(manglingConformance)) {
      manglingConformance = inherited->getInheritedConformance();
      conformance = ProtocolConformanceRef(manglingConformance);
    }
  }

  // Generic signatures where all parameters are concrete are lowered away
  // at the SILFunctionType level.
  if (genericSig && genericSig->areAllParamsConcrete()) {
    genericSig = nullptr;
    genericEnv = nullptr;
  }

  reqtSubstTy =
    CanAnyFunctionType::get(genericSig,
                            reqtSubstTy->getParams(),
                            reqtSubstTy.getResult(),
                            reqtSubstTy->getExtInfo());

  // Coroutine lowering requires us to provide these substitutions
  // in order to recreate the appropriate yield types for the accessor
  // because they aren't reflected in the accessor's AST type.
  // But this is expensive, so we only do it for coroutine lowering.
  // When they're part of the AST function type, we can remove this
  // parameter completely.
  bool allowDuplicateThunk = false;
  std::optional<SubstitutionMap> witnessSubsForTypeLowering;
  if (auto accessor = dyn_cast<AccessorDecl>(requirement.getDecl())) {
    if (accessor->isCoroutine()) {
      witnessSubsForTypeLowering =
        witness.getSubstitutions().mapReplacementTypesOutOfEnvironment();
      if (accessor->isRequirementWithSynthesizedDefaultImplementation())
        allowDuplicateThunk = true;
    }
  }

  // Lower the witness thunk type with the requirement's abstraction level.
  auto witnessSILFnType = getNativeSILFunctionType(
      M.Types, TypeExpansionContext::minimal(), AbstractionPattern(reqtOrigTy),
      reqtSubstTy, requirementInfo.SILFnType->getExtInfo(), requirement,
      witnessRef, witnessSubsForTypeLowering, conformance);

  // Mangle the name of the witness thunk.
  Mangle::ASTMangler NewMangler(M.getASTContext());
  std::string nameBuffer =
      NewMangler.mangleWitnessThunk(manglingConformance, requirement.getDecl());
  // TODO(TF-685): Proper mangling for derivative witness thunks.
  if (auto *derivativeId = requirement.getDerivativeFunctionIdentifier()) {
    std::string kindString;
    switch (derivativeId->getKind()) {
    case AutoDiffDerivativeFunctionKind::JVP:
      kindString = "jvp";
      break;
    case AutoDiffDerivativeFunctionKind::VJP:
      kindString = "vjp";
      break;
    }
    nameBuffer = "AD__" + nameBuffer + "_" + kindString + "_" +
                 derivativeId->getParameterIndices()->getString();
  }

  if (requirement.isDistributedThunk()) {
    nameBuffer = nameBuffer + "TE";
  }

  // If the thunked-to function is set to be always inlined, do the
  // same with the witness, on the theory that the user wants all
  // calls removed if possible, e.g. when we're able to devirtualize
  // the witness method call. Otherwise, use the default inlining
  // setting on the theory that forcing inlining off should only
  // effect the user's function, not otherwise invisible thunks.
  Inline_t InlineStrategy = InlineDefault;
  if (witnessRef.isUnderscoredAlwaysInline())
    InlineStrategy = HeuristicAlwaysInline;
  // We don't guarantee @inline(always) will inline devirtualized thunks. But we
  // want to make an best-effort attempt to inline.
  else if (witnessRef.isAlwaysInline())
    InlineStrategy = HeuristicAlwaysInline;


  SILFunction *f = M.lookUpFunction(nameBuffer);
  if (allowDuplicateThunk && f)
    return f;
  ASSERT(!f);

  // Distributed: Carry the distributed thunk kind from the requirement.
  // Distributed accessors dispatch through the witness table at runtime,
  // so `DeadFunctionElimination` must keep these entries alive even though
  // they have no SIL callers.
  auto thunkKind = requirement.isDistributedThunk() ? IsDistributedThunk : IsThunk;

  SILGenFunctionBuilder builder(*this);
  f = builder.createFunction(
      linkage, nameBuffer, witnessSILFnType, genericEnv,
      SILLocation(witnessRef.getDecl()), IsNotBare, IsTransparent,
      serializedKind, IsNotDynamic, IsNotDistributed, IsNotRuntimeAccessible,
      ProfileCounter(), thunkKind, SubclassScope::NotApplicable, InlineStrategy);

  f->setDebugScope(new (M)
                   SILDebugScope(RegularLocation(witnessRef.getDecl()), f));

  PrettyStackTraceSILFunction trace("generating protocol witness thunk", f);

  // Create the witness.
  SILGenFunction SGF(*this, *f, SwiftModule);

  // Substitutions mapping the generic parameters of the witness to
  // archetypes of the witness thunk generic environment.
  auto witnessSubs = witness.getSubstitutions();

  // If the conformance is marked as `@preconcurrency` instead of
  // emitting a hop to the executor (when needed) emit a dynamic check
  // to make sure that witness has been unsed in the expected context.
  bool isPreconcurrency = false;
  if (conformance.isConcrete()) {
    if (auto *C =
          dyn_cast<NormalProtocolConformance>(
            conformance.getConcrete()->getRootConformance()))
      isPreconcurrency = C->isPreconcurrency();
  }

  SGF.emitProtocolWitness(AbstractionPattern(reqtOrigTy), reqtSubstTy,
                          requirement, reqtSubMap, witnessRef,
                          witnessSubs, isFree,
                          /*isSelfConformance*/ false,
                          isPreconcurrency,
                          witness.getEnterIsolation());

  emitLazyConformancesForFunction(f);

  if (auto isolation = getSILFunctionTypeActorIsolation(
          reqtSubstTy, requirement, witnessRef)) {
    f->setActorIsolation(*isolation);
  }

  return f;
}

namespace {

static SILFunction *emitSelfConformanceWitness(SILGenModule &SGM,
                                           SelfProtocolConformance *conformance,
                                               SILLinkage linkage,
                                               SILDeclRef requirement) {
  auto requirementInfo =
      SGM.Types.getConstantInfo(TypeExpansionContext::minimal(), requirement);

  // Work out the lowered function type of the SIL witness thunk.
  auto reqtOrigTy = cast<GenericFunctionType>(requirementInfo.LoweredType);

  // The transformations we do here don't work for generic requirements.
  GenericEnvironment *genericEnv = nullptr;

  // A mapping from the requirement's generic signature to the type parameters
  // of the witness thunk (which is non-generic).
  auto protocol = conformance->getProtocol();
  auto protocolType = protocol->getDeclaredInterfaceType();
  auto reqtSubs = SubstitutionMap::getProtocolSubstitutions(protocol,
                                          protocolType,
                                          ProtocolConformanceRef(conformance));

  // Open the protocol type.
  auto openedType = ExistentialArchetypeType::get(
      protocol->getDeclaredExistentialType()->getCanonicalType());
  auto openedConf = ProtocolConformanceRef::forAbstract(openedType, protocol);

  // Form the substitutions for calling the witness.
  auto witnessSubs = SubstitutionMap::getProtocolSubstitutions(protocol,
                                          openedType,
                                          openedConf);

  // Substitute to get the formal substituted type of the thunk.
  auto reqtSubstTy = reqtOrigTy.substGenericArgs(reqtSubs);

  // Substitute into the requirement type to get the type of the thunk.
  auto witnessSILFnType = requirementInfo.SILFnType->substGenericArgs(
      SGM.M, reqtSubs, TypeExpansionContext::minimal());

  // Mangle the name of the witness thunk.
  std::string name = [&] {
    Mangle::ASTMangler mangler(requirement.getASTContext());
    return mangler.mangleWitnessThunk(conformance, requirement.getDecl());
  }();

  SILGenFunctionBuilder builder(SGM);
  auto *f = builder.createFunction(
      linkage, name, witnessSILFnType, genericEnv,
      SILLocation(requirement.getDecl()), IsNotBare, IsTransparent,
      IsSerialized, IsNotDynamic, IsNotDistributed, IsNotRuntimeAccessible,
      ProfileCounter(), IsThunk, SubclassScope::NotApplicable, InlineDefault);

  f->setDebugScope(new (SGM.M)
                   SILDebugScope(RegularLocation(requirement.getDecl()), f));

  PrettyStackTraceSILFunction trace("generating protocol witness thunk", f);

  // Create the witness.
  SILGenFunction SGF(SGM, *f, SGM.SwiftModule);

  auto isFree = isFreeFunctionWitness(requirement.getDecl(),
                                      requirement.getDecl());

  SGF.emitProtocolWitness(AbstractionPattern(reqtOrigTy), reqtSubstTy,
                          requirement, reqtSubs, requirement, witnessSubs,
                          isFree, /*isSelfConformance*/ true,
                          /*isPreconcurrency*/ false, std::nullopt);

  SGM.emitLazyConformancesForFunction(f);

  return f;
}

/// Emit a witness table for a self-conformance.
class SILGenSelfConformanceWitnessTable
       : public SILWitnessVisitor<SILGenSelfConformanceWitnessTable> {
  using super = SILWitnessVisitor<SILGenSelfConformanceWitnessTable>;

  SILGenModule &SGM;
  SelfProtocolConformance *conformance;
  SILLinkage linkage;
  SerializedKind_t serialized;

  SmallVector<SILWitnessTable::Entry, 8> entries;
public:
  SILGenSelfConformanceWitnessTable(SILGenModule &SGM,
                                    SelfProtocolConformance *conformance)
    : SGM(SGM), conformance(conformance),
      linkage(getLinkageForProtocolConformance(conformance, ForDefinition)),
      serialized(getConformanceSerializedKind(conformance)) {
  }

  void emit() {
    PrettyStackTraceConformance trace("generating SIL witness table",
                                      conformance);

    // Add entries for all the requirements.
    visitProtocolDecl(conformance->getProtocol());

    // Create the witness table.
    (void) SILWitnessTable::create(SGM.M, linkage, serialized, conformance,
                                   entries, /*conditional*/ {}, /*specialized=*/false);
  }

  void addProtocolConformanceDescriptor() {}

  void addOutOfLineBaseProtocol(ProtocolDecl *protocol) {
    // This is an unnecessary restriction that's just not necessary for Error.
    llvm_unreachable("base protocols not supported in self-conformance");
  }

  // These are real semantic restrictions.
  void addAssociatedConformance(AssociatedConformance conformance) {
    llvm_unreachable("associated conformances not supported in self-conformance");
  }
  void addAssociatedType(AssociatedTypeDecl *assocType) {
    llvm_unreachable("associated types not supported in self-conformance");
  }
  void addPlaceholder(MissingMemberDecl *placeholder) {
    llvm_unreachable("placeholders not supported in self-conformance");
  }

  void addMethod(SILDeclRef requirement) {
    auto witness = emitSelfConformanceWitness(SGM, conformance, linkage,
                                              requirement);
    entries.push_back(SILWitnessTable::MethodWitness{requirement, witness});
  }
};
}

void SILGenModule::emitSelfConformanceWitnessTable(ProtocolDecl *protocol) {
  auto conformance = getASTContext().getSelfConformance(protocol);
  SILGenSelfConformanceWitnessTable(*this, conformance).emit();
}

namespace {

/// Emit a default witness table for a resilient protocol definition.
class SILGenDefaultWitnessTable
    : public SILGenWitnessTable<SILGenDefaultWitnessTable> {
  using super = SILGenWitnessTable<SILGenDefaultWitnessTable>;

public:
  SILGenModule &SGM;
  ProtocolDecl *Proto;
  SILLinkage Linkage;

  SmallVector<SILDefaultWitnessTable::Entry, 8> DefaultWitnesses;

  SILGenDefaultWitnessTable(SILGenModule &SGM, ProtocolDecl *proto,
                            SILLinkage linkage)
      : SGM(SGM), Proto(proto), Linkage(linkage) { }

  void addMissingDefault() {
    DefaultWitnesses.push_back(SILDefaultWitnessTable::Entry());
  }

  void addProtocolConformanceDescriptor() { }

  void addOutOfLineBaseProtocol(ProtocolDecl *baseProto) {
    // Check if there is a reparented base protocol conformance.
    auto local = Proto->getLocalConformances();
    for (auto conf : local) {
      if (conf->getProtocol() != baseProto)
        continue;

      if (isa<SelfProtocolConformance>(conf))
        continue;

      ASSERT(conf->isReparented());
      DefaultWitnesses.push_back(
          SILWitnessTable::BaseProtocolWitness{baseProto, conf});

      // Ensure the witness table is emitted for this conformance.
      SGM.useConformance(/*inst=*/nullptr, ProtocolConformanceRef(conf));
      return;
    }

    // Otherwise, there is no default conformance for this base protocol.
    addMissingDefault();
  }

  void addMissingMethod(SILDeclRef ref) {
    addMissingDefault();
  }

  void addPlaceholder(MissingMemberDecl *placeholder) {
    llvm_unreachable("generating a witness table with placeholders in it");
  }

  Witness getWitness(ValueDecl *decl) {
    return Proto->getDefaultWitness(decl);
  }

  void addMethodImplementation(SILDeclRef requirementRef,
                               SILDeclRef witnessRef,
                               IsFreeFunctionWitness_t isFree,
                               Witness witness) {
    if (!cast<AbstractFunctionDecl>(witnessRef.getDecl())->hasBody()) {
      addMissingDefault();
      return;
    }

    auto Conf = ProtocolConformanceRef::forAbstract(
        Proto->getSelfInterfaceType()->getCanonicalType(), Proto);
    SILFunction *witnessFn = SGM.emitProtocolWitness(
        Conf, SILLinkage::Private, IsNotSerialized,
        requirementRef, witnessRef, isFree, witness);
    auto entry = SILWitnessTable::MethodWitness{requirementRef, witnessFn};
    DefaultWitnesses.push_back(entry);
  }

  void addAssociatedType(AssociatedTypeDecl *assocType) {
    Type witness = Proto->getDefaultTypeWitness(assocType);
    if (!witness)
      return addMissingDefault();

    Type witnessInContext = Proto->mapTypeIntoEnvironment(witness);
    auto entry = SILWitnessTable::AssociatedTypeWitness{
                                          assocType,
                                          witnessInContext->getCanonicalType()};
    DefaultWitnesses.push_back(entry);
  }

  void addAssociatedConformance(const AssociatedConformance &req) {
    auto witness =
        Proto->getDefaultAssociatedConformanceWitness(
          req.getAssociation(),
          req.getAssociatedRequirement());
    if (witness.isInvalid())
      return addMissingDefault();

    auto entry = SILWitnessTable::AssociatedConformanceWitness{
        req.getAssociation(), witness};
    DefaultWitnesses.push_back(entry);
  }
};

} // end anonymous namespace

void SILGenModule::emitDefaultWitnessTable(ProtocolDecl *protocol) {
  SILLinkage linkage =
      getSILLinkage(getDeclLinkage(protocol), ForDefinition);

  SILGenDefaultWitnessTable builder(*this, protocol, linkage);
  builder.visitProtocolDecl(protocol);

  SILDefaultWitnessTable *defaultWitnesses =
      M.createDefaultWitnessTableDeclaration(protocol, linkage);
  defaultWitnesses->convertToDefinition(builder.DefaultWitnesses);
}

namespace {

std::optional<AccessorKind>
originalAccessorKindForReplacementKind(AccessorKind kind) {
  switch (kind) {
  case AccessorKind::YieldingBorrow:
    return {AccessorKind::Read};
  case AccessorKind::YieldingMutate:
    return {AccessorKind::Modify};
  case AccessorKind::Get:
  case AccessorKind::DistributedGet:
  case AccessorKind::Set:
  case AccessorKind::Read:
  case AccessorKind::Modify:
  case AccessorKind::WillSet:
  case AccessorKind::DidSet:
  case AccessorKind::Address:
  case AccessorKind::MutableAddress:
  case AccessorKind::Init:
  case AccessorKind::Borrow:
  case AccessorKind::Mutate:
    return std::nullopt;
  }
}

/// Emit a default witness table for a resilient protocol definition.
class SILGenDefaultOverrideTable
    : public SILGenVTableBase<SILGenDefaultOverrideTable> {
  using super = SILGenVTableBase<SILGenDefaultOverrideTable>;

public:
  SILLinkage linkage;
  SILGenDefaultOverrideTable(SILGenModule &SGM, ClassDecl *decl,
                             SILLinkage linkage)
      : super(SGM, decl), linkage(linkage) {}

  std::optional<SILDefaultOverrideTable::Entry>
  entryForMethod(VTableMethod method) {
    // Determine whether `method` semantically "replaces" some other member (in
    // the sense that calls that previously resolved to that other member will
    // now resolve to that new member).  If it does, produce a default override
    // table entry which describes that replacement, including a thunk (to be
    // installed at runtime) in subclasses which overrode only that other
    // replaced member.
    auto declRef = method.first;
    auto *decl = declRef.getAbstractFunctionDecl();
    if (decl->getEffectiveAccess() != AccessLevel::Open) {
      // Only methods which can be overridden in different resilience domains
      // need an entry.
      return std::nullopt;
    }
    // Currently, only accessors can be replacements.
    auto *accessor = dyn_cast_or_null<AccessorDecl>(decl);
    if (!accessor) {
      return std::nullopt;
    }
    // Specifically, `yielding borrow` can replace _read and
    // `yielding mutate` can replace _modify.
    auto originalKind =
        originalAccessorKindForReplacementKind(accessor->getAccessorKind());
    if (!originalKind) {
      return std::nullopt;
    }
    auto *originalDecl = accessor->getStorage()->getAccessor(*originalKind);
    if (!originalDecl) {
      return std::nullopt;
    }
    auto original = SILDeclRef(originalDecl);
    auto *impl = SGM.emitDefaultOverride(declRef, original);
    return {SILDefaultOverrideTable::Entry{declRef, original, impl}};
  }

  void emitTable() {
    PrettyStackTraceDecl("silgen emitDefaultOverrideTable", theClass);

    if (!theClass->isResilient()) {
      // Only resilient classes need such tables.
      return;
    }
    if (theClass->getEffectiveAccess() != AccessLevel::Open) {
      // Only classes whose methods could be overridden in different resilience
      // domains need an entry.
      return;
    }

    collectMethods();

    SmallVector<SILDefaultOverrideTable::Entry, 8> entries;

    for (auto method : vtableMethods) {
      auto entry = entryForMethod(method);
      if (!entry) {
        continue;
      }
      entries.push_back(*entry);
    }

    if (entries.size() == 0) {
      // Don't emit empty tables.
      return;
    }

    SGM.M.createDefaultOverrideTableDefinition(theClass, linkage, entries);
  }
};

} // end anonymous namespace

void SILGenModule::emitDefaultOverrideTable(ClassDecl *decl) {
  SILLinkage linkage = getSILLinkage(getDeclLinkage(decl), ForDefinition);

  SILGenDefaultOverrideTable builder(*this, decl, linkage);
  builder.emitTable();
}

SILFunction *SILGenModule::emitDefaultOverride(SILDeclRef replacement,
                                               SILDeclRef original) {
  SILGenFunctionBuilder builder(*this);
  // Add the "default override of" suffix.
  auto name = replacement.mangle() + "Twd";
  auto replacementTy =
      Types.getConstantInfo(TypeExpansionContext::minimal(), replacement)
          .SILFnType;
  auto loc = replacement.getAsRegularLocation();
  auto *function = builder.getOrCreateFunction(
      loc, name, SILLinkage::Shared, replacementTy, IsBare, IsNotTransparent,
      IsSerialized, IsNotDynamic, IsNotDistributed, IsNotRuntimeAccessible,
      ProfileCounter(), IsNotThunk);

  if (!function->empty())
    return function;

  // A shim from yield_once_2 (replacement) to yield_once (original).
  // sil @shim : $@convention(method) @yield_once_2 (As...) -> (@yields Ys...) {
  // entry(%as... : $As...):
  //   %method = class_method
  //   (%ys... : $Ys..., %token) = begin_apply %method(%as...) 
  //                               : $@convention(method) @yield_once (As...) -> (@yields Ys...)
  //   yield %ys : $Ys..., normal normal_block, error error_block
  // normal_block:
  //   %retval = end_apply %token
  //   return %retval : $()
  // error_block:
  //   abort_apply %token
  //   unwind
  // }

  auto sig = replacementTy->getSubstGenericSignature();
  auto *env = sig.getGenericEnvironment();
  auto subs = env ? env->getForwardingSubstitutionMap() : SubstitutionMap();
  function->setGenericEnvironment(env);
  SILGenFunction SGF(*this, *function, SwiftModule);
  SmallVector<ManagedValue, 4> params;
  SmallVector<ManagedValue, 4> indirectResults;
  SmallVector<ManagedValue, 4> indirectErrors;
  ManagedValue implicitIsolationParam;
  SGF.collectThunkParams(replacement.getDecl(), params, &indirectResults,
                         &indirectErrors, &implicitIsolationParam);

  auto self = params.back();

  auto originalTy =
      Types.getConstantInfo(TypeExpansionContext::minimal(), original)
          .SILFnType;
  auto originalFn =
      SGF.emitClassMethodRef(loc, self.getValue(), original, originalTy);
  auto originalConvention = SILFunctionConventions(originalTy, M);
  assert(indirectErrors.size() == 0 &&
         "coroutine accessor with indirect error!?");
  SmallVector<SILValue> args;
  for (auto result : indirectResults) {
    args.push_back(result.forward(SGF));
  }
  // Indirect errors would go here, but we don't currently support
  // throwing coroutines.
  if (implicitIsolationParam.isValid()) {
    args.push_back(implicitIsolationParam.forward(SGF));
  }
  for (auto param : params) {
    args.push_back(param.forward(SGF));
  }
  auto *bai = SGF.B.createBeginApply(loc, originalFn, subs, args);
  auto *token = bai->getTokenResult();
  auto yieldedValues = bai->getYieldedValues();
  auto *normalBlock = function->createBasicBlockAfter(SGF.B.getInsertionBB());
  auto *errorBlock = function->createBasicBlockAfter(normalBlock);
  SmallVector<SILValue> yields;
  for (auto yielded : yieldedValues) {
    yields.push_back(yielded);
  }
  SGF.B.createYield(loc, yields, normalBlock, errorBlock);

  SGF.B.setInsertionPoint(normalBlock);
  llvm::SmallVector<TupleTypeElt> directResultTypes;

  for (auto result : originalConvention.getDirectSILResults()) {
    auto ty = originalConvention.getSILType(
        result, function->getTypeExpansionContext());
    ty = function->mapTypeIntoEnvironment(ty);
    directResultTypes.push_back(ty.getASTType());
  }
  SILType resultTy;
  switch (directResultTypes.size()) {
  case 0:
    resultTy = SILType::getEmptyTupleType(getASTContext());
    break;
  case 1:
    resultTy = SILType::getPrimitiveObjectType(
        directResultTypes.front().getType()->getCanonicalType());
    break;
  default: {
    ASSERT(directResultTypes.size() > 1);
    auto tupleTy =
        TupleType::get(directResultTypes, getASTContext())->getCanonicalType();
    resultTy = SILType::getPrimitiveObjectType(tupleTy);
    break;
  }
  }
  SGF.B.createEndApply(loc, token, resultTy);
  auto *retval = SGF.B.createTuple(loc, {});
  SGF.B.createReturn(loc, retval);

  SGF.B.setInsertionPoint(errorBlock);
  SGF.B.createAbortApply(loc, token);
  SGF.B.createUnwind(loc);
  return function;
}

void SILGenModule::emitNonCopyableTypeDeinitTable(NominalTypeDecl *nom) {
  auto *dd = nom->getValueTypeDestructor();
  if (!dd)
    return;

  SILDeclRef constant(dd, SILDeclRef::Kind::Deallocator);
  SILFunction *f = getFunction(constant, NotForDefinition);
  auto serialized = SerializedKind_t::IsNotSerialized;
  bool nomIsPublic = nom->getEffectiveAccess() >= AccessLevel::Public;
  // We only serialize the deinit if the type is public and not resilient.
  if (nomIsPublic && !nom->isResilient())
    serialized = IsSerialized;
  SILMoveOnlyDeinit::create(f->getModule(), nom, serialized, f);
}

namespace {

/// An ASTVisitor for generating SIL from method declarations
/// inside nominal types.
class SILGenType : public TypeMemberVisitor<SILGenType> {
public:
  SILGenModule &SGM;
  NominalTypeDecl *theType;

  SILGenType(SILGenModule &SGM, NominalTypeDecl *theType)
    : SGM(SGM), theType(theType) {}

  /// Emit SIL functions for all the members of the type.
  void emitType() {
    PrettyStackTraceDecl("silgen emitType", theType);

    SGM.emitLazyConformancesForType(theType);

    for (Decl *member : theType->getABIMembers()) {
      visit(member);
    }

    // Build a vtable if this is a class.
    if (auto theClass = dyn_cast<ClassDecl>(theType)) {
      if (!theClass->hasClangNode()) {
        SILGenVTable genVTable(SGM, theClass);
        genVTable.emitVTable();
      }
      if (!theClass->hasClangNode() && theClass->isResilient()) {
        auto *sourceFile = theClass->getParentSourceFile();
        if (!sourceFile || sourceFile->Kind != SourceFileKind::Interface)
          SGM.emitDefaultOverrideTable(theClass);
      }
    }

    // If this is a nominal type that is move only, emit a deinit table for it.
    if (auto *nom = dyn_cast<NominalTypeDecl>(theType)) {
      if (!nom->canBeCopyable()) {
        SGM.emitNonCopyableTypeDeinitTable(nom);
      }
    }

    // Build a default witness table if this is a protocol that needs one.
    if (auto protocol = dyn_cast<ProtocolDecl>(theType)) {
      if (!protocol->isObjC() && protocol->isResilient()) {
        auto *SF = protocol->getParentSourceFile();
        if (!SF || SF->Kind != SourceFileKind::Interface)
          SGM.emitDefaultWitnessTable(protocol);
      }
      if (protocol->requiresSelfConformanceWitnessTable()) {
        SGM.emitSelfConformanceWitnessTable(protocol);
      }
      return;
    }

    // Emit witness tables for conformances of concrete types. Protocol types
    // are existential and do not have witness tables.
    for (auto *conformance : theType->getLocalConformances(
                               ConformanceLookupKind::NonInherited)) {
      if (auto *normal = dyn_cast<NormalProtocolConformance>(conformance))
        (void)SGM.getWitnessTable(normal);
    }
  }

  //===--------------------------------------------------------------------===//
  // Visitors for subdeclarations
  //===--------------------------------------------------------------------===//
  void visit(Decl *D) {
    if (SGM.shouldSkipDecl(D))
      return;

    TypeMemberVisitor::visit(D);
  }

  void visitTypeAliasDecl(TypeAliasDecl *tad) {}
  void visitOpaqueTypeDecl(OpaqueTypeDecl *otd) {}
  void visitGenericTypeParamDecl(GenericTypeParamDecl *d) {}
  void visitAssociatedTypeDecl(AssociatedTypeDecl *d) {}
  void visitModuleDecl(ModuleDecl *md) {}
  void visitMissingMemberDecl(MissingMemberDecl *) {}
  void visitNominalTypeDecl(NominalTypeDecl *ntd) {
    SILGenType(SGM, ntd).emitType();
  }
  void visitFuncDecl(FuncDecl *fd) {
    SGM.emitFunction(fd);
    // FIXME: Default implementations in protocols.
    if (SGM.requiresObjCMethodEntryPoint(fd) &&
        !isa<ProtocolDecl>(fd->getDeclContext()))
      SGM.emitObjCMethodThunk(fd);
  }
  void visitConstructorDecl(ConstructorDecl *cd) {
    SGM.emitConstructor(cd);

    if (SGM.requiresObjCMethodEntryPoint(cd) &&
        !isa<ProtocolDecl>(cd->getDeclContext()))
      SGM.emitObjCConstructorThunk(cd);
  }

  void visitDestructorDecl(DestructorDecl *dd) {
    if (isa<ClassDecl>(theType))
      return SGM.emitDestructor(cast<ClassDecl>(theType), dd);
    if (auto *nom = dyn_cast<NominalTypeDecl>(theType)) {
      if (!nom->canBeCopyable()) {
        return SGM.emitMoveOnlyDestructor(nom, dd);
      }
    }
    assert(isa<ClassDecl>(theType) &&
           "destructor in a non-class, non-moveonly type");
  }

  void visitEnumCaseDecl(EnumCaseDecl *ecd) {}
  void visitEnumElementDecl(EnumElementDecl *EED) {
    if (!EED->hasAssociatedValues())
      return;

    // Emit any default argument generators.
    SGM.emitArgumentGenerators(EED, EED->getParameterList());
  }

  void visitPatternBindingDecl(PatternBindingDecl *pd) {
    // Emit initializers.
    for (auto i : range(pd->getNumPatternEntries())) {
      if (pd->getExecutableInit(i)) {
        if (pd->isStatic())
          SGM.emitGlobalInitialization(pd, i);
        else
          SGM.emitStoredPropertyInitialization(pd, i);
      }
    }
  }

  void visitVarDecl(VarDecl *vd) {
    // Collect global variables for static properties.
    if (vd->isStatic() && vd->hasStorage()) {
      emitTypeMemberGlobalVariable(SGM, vd);
      visitAccessors(vd);
      SGM.tryEmitPropertyDescriptor(vd);
      return;
    }

    // If this variable has an attached property wrapper with an initialization
    // function, emit the backing initializer function.
    auto initInfo = vd->getPropertyWrapperInitializerInfo();
    if (initInfo.hasInitFromWrappedValue() && !vd->isStatic()) {
      SGM.emitPropertyWrapperBackingInitializer(vd);
      // Output this unconditionally, SIL optimizer will remove it if not needed
      SGM.emitPropertyWrappedFieldInitAccessor(vd);
    }

    visitAbstractStorageDecl(vd);
  }

  void visitSubscriptDecl(SubscriptDecl *sd) {
    SGM.emitArgumentGenerators(sd, sd->getIndices());
    visitAbstractStorageDecl(sd);
  }

  void visitAbstractStorageDecl(AbstractStorageDecl *asd) {
    // FIXME: Default implementations in protocols.
    if (asd->isObjC() && !isa<ProtocolDecl>(asd->getDeclContext()))
      SGM.emitObjCPropertyMethodThunks(asd);

    SGM.tryEmitPropertyDescriptor(asd);
    visitAccessors(asd);
  }

  void visitAccessors(AbstractStorageDecl *asd) {
    SGM.visitEmittedAccessors(asd, [&](AccessorDecl *accessor) {
      visitFuncDecl(accessor);
    });
  }

  void visitMissingDecl(MissingDecl *missing) {
    llvm_unreachable("missing decl in SILGen");
  }

  void visitMacroDecl(MacroDecl *md) {
    llvm_unreachable("macros aren't allowed in types");
  }
};

} // end anonymous namespace

void SILGenModule::visitNominalTypeDecl(NominalTypeDecl *ntd) {
  SILGenType(*this, ntd).emitType();
}

void SILGenModule::visitImportedNontrivialNoncopyableType(
  NominalTypeDecl *nominal) {
  emitNonCopyableTypeDeinitTable(nominal);
  SILGenType(*this, nominal)
      .visitDestructorDecl(nominal->getValueTypeDestructor());
}

/// SILGenExtension - an ASTVisitor for generating SIL from method declarations
/// and protocol conformances inside type extensions.
class SILGenExtension : public TypeMemberVisitor<SILGenExtension> {
public:
  SILGenModule &SGM;

  SILGenExtension(SILGenModule &SGM)
    : SGM(SGM) {}

  /// Emit SIL functions for all the members of the extension.
  void emitExtension(ExtensionDecl *e) {
    PrettyStackTraceDecl("silgen emitExtension", e);

    // Arguably, we should divert to SILGenType::emitType() here if it's an
    // @_objcImplementation extension, but we don't actually need to do any of
    // the stuff that it currently does.

    for (Decl *member : e->getABIMembers()) {
      visit(member);
    }

    // If this is a main-interface @_objcImplementation extension and the class
    // has a synthesized destructor, emit it now.
    if (auto cd = dyn_cast_or_null<ClassDecl>(e->getImplementedObjCDecl())) {
      auto dd = cd->getDestructor();
      if (dd->getDeclContext() == cd)
        visit(dd);
    }

    if (!isa<ProtocolDecl>(e->getExtendedNominal())) {
      // Emit witness tables for protocol conformances introduced by the
      // extension.
      for (auto *conformance : e->getLocalConformances(
                                 ConformanceLookupKind::All)) {
        if (auto *normal =dyn_cast<NormalProtocolConformance>(conformance))
          (void)SGM.getWitnessTable(normal);
      }
    }
  }

  //===--------------------------------------------------------------------===//
  // Visitors for subdeclarations
  //===--------------------------------------------------------------------===//
  void visit(Decl *D) {
    if (SGM.shouldSkipDecl(D))
      return;

    TypeMemberVisitor::visit(D);
  }

  void visitTypeAliasDecl(TypeAliasDecl *tad) {}
  void visitOpaqueTypeDecl(OpaqueTypeDecl *tad) {}
  void visitGenericTypeParamDecl(GenericTypeParamDecl *d) {}
  void visitAssociatedTypeDecl(AssociatedTypeDecl *d) {}
  void visitModuleDecl(ModuleDecl *md) {}
  void visitMissingMemberDecl(MissingMemberDecl *) {}
  void visitNominalTypeDecl(NominalTypeDecl *ntd) {
    SILGenType(SGM, ntd).emitType();
  }
  void visitFuncDecl(FuncDecl *fd) {
    // Don't emit other accessors for a dynamic replacement of didSet inside of
    // an extension. We only allow such a construct to allow definition of a
    // didSet/willSet dynamic replacement. Emitting other accessors is
    // problematic because there is no storage.
    //
    // extension SomeStruct {
    //   @_dynamicReplacement(for: someProperty)
    //   var replacement : Int {
    //     didSet {
    //     }
    //   }
    // }
    if (auto *accessor = dyn_cast<AccessorDecl>(fd)) {
      auto *storage = accessor->getStorage();
      bool hasDidSetOrWillSetDynamicReplacement =
          storage->hasDidSetOrWillSetDynamicReplacement();

      if (hasDidSetOrWillSetDynamicReplacement &&
          isa<ExtensionDecl>(storage->getDeclContext()) &&
          fd != storage->getParsedAccessor(AccessorKind::WillSet) &&
          fd != storage->getParsedAccessor(AccessorKind::DidSet))
        return;
    }
    SGM.emitFunction(fd);
    if (SGM.requiresObjCMethodEntryPoint(fd))
      SGM.emitObjCMethodThunk(fd);
  }
  void visitConstructorDecl(ConstructorDecl *cd) {
    SGM.emitConstructor(cd);
    if (SGM.requiresObjCMethodEntryPoint(cd))
      SGM.emitObjCConstructorThunk(cd);
  }
  void visitDestructorDecl(DestructorDecl *dd) {
    auto contextInterface = dd->getDeclContext()->getImplementedObjCContext();
    if (auto cd = dyn_cast<ClassDecl>(contextInterface)) {
      SGM.emitDestructor(cd, dd);
      return;
    }
    llvm_unreachable("destructor in extension?!");
  }

  void visitPatternBindingDecl(PatternBindingDecl *pd) {
    // Emit initializers for static variables.
    for (auto i : range(pd->getNumPatternEntries())) {
      if (pd->getExecutableInit(i)) {
        if (pd->isStatic())
          SGM.emitGlobalInitialization(pd, i);
        else if (isa<ExtensionDecl>(pd->getDeclContext()) &&
                 cast<ExtensionDecl>(pd->getDeclContext())
                     ->isObjCImplementation())
          SGM.emitStoredPropertyInitialization(pd, i);
      }
    }
  }

  void visitVarDecl(VarDecl *vd) {
    if (vd->hasStorage()) {
      if (!vd->isStatic()) {
        // Is this a stored property of an @_objcImplementation extension?
        auto ed = cast<ExtensionDecl>(vd->getDeclContext());
        if (auto cd =
                dyn_cast_or_null<ClassDecl>(ed->getImplementedObjCDecl())) {
          // Act as though we declared it on the class.
          SILGenType(SGM, cd).visitVarDecl(vd);
          return;
        }
      }

      bool hasDidSetOrWillSetDynamicReplacement =
          vd->hasDidSetOrWillSetDynamicReplacement();
      assert((vd->isStatic() || hasDidSetOrWillSetDynamicReplacement) &&
             "stored property in extension?!");
      if (!hasDidSetOrWillSetDynamicReplacement) {
        emitTypeMemberGlobalVariable(SGM, vd);
        visitAccessors(vd);
        return;
      }
    }

    visitAbstractStorageDecl(vd);
  }

  void visitSubscriptDecl(SubscriptDecl *sd) {
    SGM.emitArgumentGenerators(sd, sd->getIndices());
    visitAbstractStorageDecl(sd);
  }

  void visitEnumCaseDecl(EnumCaseDecl *ecd) {}
  void visitEnumElementDecl(EnumElementDecl *ed) {
    llvm_unreachable("enum elements aren't allowed in extensions");
  }

  void visitAbstractStorageDecl(AbstractStorageDecl *asd) {
    if (asd->isObjC())
      SGM.emitObjCPropertyMethodThunks(asd);
    
    SGM.tryEmitPropertyDescriptor(asd);
    visitAccessors(asd);
  }

  void visitAccessors(AbstractStorageDecl *asd) {
    SGM.visitEmittedAccessors(asd, [&](AccessorDecl *accessor) {
      visitFuncDecl(accessor);
    });
  }

  void visitMissingDecl(MissingDecl *missing) {
    llvm_unreachable("missing decl in SILGen");
  }

  void visitMacroDecl(MacroDecl *md) {
    llvm_unreachable("macros aren't allowed in extensions");
  }
};

void SILGenModule::visitExtensionDecl(ExtensionDecl *ed) {
  SILGenExtension(*this).emitExtension(ed);
}
