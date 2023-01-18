//
//  SwiftMeta.swift
//  SwiftTwaceApp
//
//  Created by John Holdsworth on 20/04/2020.
//  Copyright © 2020 John Holdsworth. All rights reserved.
//
//  Repo: https://github.com/johnno1962/SwiftTrace
//  $Id: //depot/SwiftTrace/SwiftTrace/SwiftMeta.swift#106 $
//
//  Requires https://github.com/johnno1962/StringIndex.git
//
//  Assumptions made about Swift MetaData
//  =====================================
//

import Foundation
#if SWIFT_PACKAGE
import SwiftTraceGuts
#endif

/**
 Shenaniggans to be able to decorate any type linked into an app.
 These functions have the SwiftMeta.FunctionTakingGenericValue
 signature from a C perspective if you can find the address.
 They need to be public at the top level when app is stripped.
 */

/// generic function to find the Optional type for a wrapped type
public func getOptionalType<Type>(value: Type, out: inout Any.Type?) {
    out = Optional<Type>.self
}

/// generic function to find the Array type for an element type
public func getArrayType<Type>(value: Type, out: inout Any.Type?) {
    out = Array<Type>.self
}

/// generic function to find the Array type for an element type
public func getPointerType<Type>(value: Type, out: inout Any.Type?) {
    out = UnsafePointer<Type>.self
}

/// generic function to find the Array type for an element type
public func getMetaType<Type>(value: Type, out: inout Any.Type?) {
    out = type(of: Type.self)
}

/// generic function to find the ArraySlice slice type for an element type
public func getArraySliceType<Type>(value: Type, out: inout Any.Type?) {
    out = ArraySlice<Type>.self
}

/// generic function to find the Dictionary with String key for an element type
public func getDictionaryType<Type>(value: Type, out: inout Any.Type?) {
    out = Dictionary<String, Type>.self
}

// generic function to find the MixedProperties type for a Type
public func getMixedType<Type>(value: Type, out: inout Any.Type?) {
    out = SwiftMeta.MixedProperties<Type>.self
}

// generic function to find the MixedProperties type for a Type
public func getEnumType<Type>(value: Type, out: inout Any.Type?) {
    out = SwiftMeta.EnumProperties<Type>.self
}

// generic function to find the Set type for a Hashable wrapped type
public func getSetType<Type: Hashable>(value: Type, out: inout Any.Type?) {
    out = Set<Type>.self
}

/// generic function to find the Array type for an element type
public func getRangeType<Type: Comparable>(value: Type, out: inout Any.Type?) {
    out = Range<Type>.self
}

// generic function to find the Foundation.Measurement type for a Unit
@available(OSX 10.12, iOS 10.0, tvOS 10.0, *)
public func getMeasurementType<Type: Unit>(value: Type, out: inout Any.Type?) {
    out = Foundation.Measurement<Type>.self
}

@objc(SwiftMeta)
open class SwiftMeta: NSObject {

    /// All types have this structure generated by the compiler
    /// from which you can extract the size and stride.
    public struct ValueWitnessTable {
        let initializeBufferWithCopyOfBuffer: IMP, destroy: IMP,
            initializeWithCopy: IMP, assignWithCopy: IMP,
            initializeWithTake: IMP, assignWithTake: IMP,
            getEnumTagSinglePayload: IMP, storeEnumTagSinglePayload: IMP
        let size: size_t, stride: size_t
        let flags: uintptr_t
    }

    /**
     Pointer to value witness is just before nominal type information.
     */
    typealias ValueWitnessPointer =
        UnsafeMutablePointer<UnsafePointer<ValueWitnessTable>?>

    /**
     Get the size in bytes of a type
     */
    open class func sizeof(anyType: Any.Type) -> size_t {
        let metaData = unsafeBitCast(anyType, to: ValueWitnessPointer.self)
        return metaData[-1]?.pointee.size ?? 0
    }

    /**
     Get the stride in bytes of a type
     */
    open class func strideof(anyType: Any.Type) -> size_t {
        let metaData = unsafeBitCast(anyType, to: ValueWitnessPointer.self)
        return metaData[-1]?.pointee.stride ?? 0
    }

    open class func cloneValueWitness(from: Any.Type, onto: Any.Type) {
        let original = unsafeBitCast(from, to: ValueWitnessPointer.self)
        let injected = unsafeBitCast(onto, to: ValueWitnessPointer.self)
        injected[-1] = original[-1]
    }

    /**
     The signature of a function taking a generic type and an inout pointer.
     The witnessTable is for when the type is constrained by a protocol.
     */
    public typealias FunctionTakingGenericValue = @convention(c) (
        _ valuePtr : UnsafeRawPointer?, _ outPtr: UnsafeMutableRawPointer,
        _ metaType: UnsafeRawPointer, _ witnessTable: UnsafeRawPointer?) -> ()

    /**
     This can be used to call a Swift function with a generic value
     argument when you have a pointer to the value and its type.
     See: https://www.youtube.com/watch?v=ctS8FzqcRug
     */
    open class func thunkToGeneric(funcPtr: FunctionTakingGenericValue,
        valuePtr: UnsafeRawPointer?, outPtr: UnsafeMutableRawPointer,
        type: Any.Type, witnessTable: UnsafeRawPointer? = nil) {
        funcPtr(valuePtr, outPtr, autoBitCast(type), witnessTable)
    }

    /**
     Definitions related to auto-traceability of types
     */
    public static let RTLD_NEXT = UnsafeMutableRawPointer(bitPattern: -1)!
    public static let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)!
    public static let RTLD_SELF = UnsafeMutableRawPointer(bitPattern: -3)!
    public static let RTLD_MAIN_ONLY = UnsafeMutableRawPointer(bitPattern: -5)!
    open class func mangle(_ name: String) -> String {
        return "\(name.utf8.count)\(name)"
    }

    /**
     Find pointer for function processing type as generic
     */
    open class func bindGeneric(name: String,
                                   owner: Any.Type = SwiftMeta.self,
                                   args: String = returnAnyType)
                                   -> FunctionTakingGenericValue {
        let module = _typeName(owner).components(separatedBy: ".")[0]
        let symbol = "$s\(mangle(module))\(mangle(name))5value3outyx_\(args)lF"
        guard let genericFunctionPtr = dlsym(RTLD_DEFAULT, symbol) else {
            fatalError("Could lot locate generic function for symbol \(symbol)")
        }
        return autoBitCast(genericFunctionPtr)
    }

    /**
     Generic function pointers that can be used to convert a type
     into the Optional/Array/Set/Dictionary for that type.
     */
    public static let returnAnyType = "ypXpSgzt"

    static var getOptionalTypeFptr = bindGeneric(name: "getOptionalType")
    static var getMixedTypeFptr = bindGeneric(name: "getMixedType")
    static var getEnumTypeFptr = bindGeneric(name: "getEnumType")
    static var getMetaTypeFptr = bindGeneric(name: "getMetaType")

    /// Handled container types
    public static var wrapperHandlers = [
        "Swift.Optional<": getOptionalTypeFptr,
        "Swift.Array<": bindGeneric(name: "getArrayType"),
        "Swift.ArraySlice<": bindGeneric(name: "getArraySliceType"),
        "Swift.Set<": bindGeneric(name: "getSetType",
                                  args: "ypXpSgztSHRz"),
        "Swift.Range<": bindGeneric(name: "getRangeType",
                                    args: "ypXpSgztSLRz"),
        "Swift.UnsafePointer<": bindGeneric(name: "getPointerType"),
        "Swift.UnsafeMutablePointer<": bindGeneric(name: "getPointerType"),
        "Swift.Dictionary<Swift.String, ": bindGeneric(name: "getDictionaryType"),
        "Foundation.Measurement<": bindGeneric(name: "getMeasurementType",
                                               args: "ypXpSgztSo6NSUnitCRbz"),
    ]

    public static var conformanceManglings = [
        "Swift.Set<": "H",
        "Swift.Range<": "L"
    ]

    static func convert(type: Any.Type, handler: FunctionTakingGenericValue,
                        witnessTable: UnsafeRawPointer? = nil) -> Any.Type? {
        var out: Any.Type?
        thunkToGeneric(funcPtr: handler, valuePtr: nil, outPtr: &out,
                       type: type, witnessTable: witnessTable)
        return out
    }

    public static var nameAbbreviations = [
        "Swift": "s"
    ]

    public static var typeLookupCache: [String: Any.Type?] = [
        // These types have non-standard manglings
        "Swift.String": String.self,
        "Swift.Double": Double.self,
        "Swift.Float": Float.self,

        // Special cases
        "Any": Any.self, // not reliable
        "Any.Type": Any.Type.self,
        "Swift.AnyObject": AnyObject.self,
        "Swift.AnyObject.Type": AnyClass.self,
        "Swift.Optional<Swift.Error>": Error?.self,
        "Swift.Dictionary<Swift.AnyHashable, Any>": [AnyHashable: Any].self,
        "Swift.Error": Error.self,
        "()": Void.self,
        "some": nil,

        // Has private enum property containg a Locale
        "Fruta.ContentView" : nil,
        "Fruta_iOS.ContentView" : nil,
        // Also uses resilient Foundation type inside enum
        "Kingfisher.ExpirationExtending": nil,
    ]
    static var typeLookupCacheLock = OS_SPINLOCK_INIT

    /**
     Fake types used to prevent decorating when unsupported
     */
    public struct MixedProperties<Type>: UnsupportedTyping,
        CustomStringConvertible {
        public var description: String {
            return _typeName(Type.self)+"()"
        }
    }
    public struct EnumProperties<Type>: UnsupportedTyping,
        CustomStringConvertible {
        public var description: String {
            return _typeName(Type.self)+"()"
        }
    }

    /**
     Best effort recovery of type from a qualified name
     */
    open class func lookupType(named: String, protocols: Bool = false,
                           exclude: NSRegularExpression? = nil) -> Any.Type? {
        OSSpinLockLock(&typeLookupCacheLock)
        defer { OSSpinLockUnlock(&typeLookupCacheLock) }
        return lockedType(named: named, protocols: protocols, exclude: exclude)
    }

    static func lockedType(named: String, protocols: Bool,
                           exclude: NSRegularExpression? = nil) -> Any.Type? {
        if exclude?.matches(named) == true {
            return nil
        }
        if let type = typeLookupCache[named] {
            return type
        }

        var out: Any.Type?
        for (prefix, handler) in wrapperHandlers where named.hasPrefix(prefix) {
            if let wrapped = named[safe: .start+prefix.count ..< .end-1],
                let wrappedType = lockedType(named: wrapped,
                                             protocols: true, exclude: exclude) {
                if let enc = conformanceManglings[prefix] {
                    if let witnessTable =
                        getWitnessTable(enc: enc, for: wrappedType) {
                        out = convert(type: wrappedType, handler: handler,
                                      witnessTable: witnessTable)
                    }
                } else {
                    out = convert(type: wrappedType, handler: handler)
                }
            }
            break
        }

        if named.hasSuffix("..."),
            let element = named[safe: ..<(.end-3)] {
            out = lockedType(named: "Swift.Array<\(element)>", protocols: true)
        } else if named.hasSuffix(".Type"),
            let element = named[safe: ..<(.end-5)],
            let elementType = lockedType(named: element, protocols: false) {
            out = convert(type: elementType, handler: getMetaTypeFptr)
        } else if out == nil {
            var mangled = ""
            var first = true
            for name in named.components(separatedBy: ".") {
                mangled += nameAbbreviations[name] ?? mangle(name)
                out = nil
                if first {
                    first = false
                    continue
                }
                if let type = _typeByName(mangled+"C") {
                    mangled += "C" // class type
                    out = type
                } else if let type = _typeByName(mangled+"V") {
                    mangled += "V" // value type
                    out = type
                } else if let type = _typeByName(mangled+"O") {
                    mangled += "O" // enum type
                    out = type
                } else if protocols, let type = _typeByName(mangled+"P") {
                    mangled += "P" // protocol
                    out = type
                } else {
                    break
                }
            }
        }
        typeLookupCache[named] = out
        return out
    }

    /**
     Take the symbol name for the metaType address and remove the "N" suffix
     */
    open class func mangledName(for type: Any.Type) -> String? {
        var info = Dl_info()
        if dladdr(autoBitCast(type), &info) != 0,
            let metaTypeSymbol = info.dli_sname {
            return String(cString: metaTypeSymbol)[safe: ..<(.end-1)]
        }
        return nil
    }

    /**
     Find the witness table for the conformance of elementType to Hashable
     */
    static func getWitnessTable(enc: String, for elementType: Any.Type)
        -> UnsafeRawPointer? {
        var witnessTable: UnsafeRawPointer?
        if let mangledName = mangledName(for: elementType) {
            if let theEasyWay = dlsym(RTLD_DEFAULT, mangledName+"S\(enc)sWP") {
                witnessTable = UnsafeRawPointer(theEasyWay)
            } else {
                let witnessSuffix = "ACS\(enc)AAWl"
                (mangledName + witnessSuffix).withCString { getWitnessSymbol in
                    typealias GetWitness = @convention(c) () -> UnsafeRawPointer
                    findHiddenSwiftSymbols(searchAllImages(), witnessSuffix, .hidden) {
                        (address, symbol, _, _) in
                        if strcmp(symbol, getWitnessSymbol) == 0,
                            let witnessFptr: GetWitness = autoBitCast(address) {
                            witnessTable = witnessFptr()
                        }
                    }
                }
            }
        }
        return witnessTable
    }

    /**
     Information about a field of a struct or class
     */
    public struct FieldInfo {
        let name: String
        let type: Any.Type
        let offset: size_t
    }

    /**
     Get approximate nformation about the fields of a type
     */
    open class func fieldInfo(forAnyType: Any.Type) -> [FieldInfo]? {
        _ = structsPassedByReference
        return approximateFieldInfoByTypeName[_typeName(forAnyType)]
    }

    static var approximateFieldInfoByTypeName = [String: [FieldInfo]]()
    static var doesntHaveStorage = Set<String>()

    public static var structsPassedByReference: Set<UnsafeRawPointer> = {
        var problemTypes = Set<UnsafeRawPointer>()
        func passedByReference(_ type: Any.Type) {
            problemTypes.insert(autoBitCast(type))
            if let type = convert(type: type, handler: getOptionalTypeFptr) {
                problemTypes.insert(autoBitCast(type))
            }
        }

        for type: Any.Type in [URL.self, UUID.self, Date.self,
                               IndexPath.self, IndexSet.self, URLRequest.self] {
            passedByReference(type)
        }

        for iOS15ResilientTypeName in ["Foundation.AttributedString",
                                       "Foundation.AttributedString.Index"] {
            if let resilientType = lookupType(named: iOS15ResilientTypeName) {
                passedByReference(resilientType)
            }
        }

        #if true // Attempts to determine which getters have storage
        // properties that have key path getters are not stored??
        findHiddenSwiftSymbols(searchAllImages(), "pACTK",
                               .hidden) { (_, symbol, _, _) in
            doesntHaveStorage.insert(String(cString: symbol)
                .replacingOccurrences(of: "pACTK", with: "g"))
        }
        // ...unless they have a field offset
        // ...or property wrapper backing initializer ??
        for suffix in ["pWvd", "pfP"] {
            findSwiftSymbols(searchAllImages(), suffix) {
                (_, symbol, _, _) in
                doesntHaveStorage.remove(String(cString: symbol)
                    .replacingOccurrences(of: suffix, with: "g"))
            }
        }
//        print(doesntHaveStorage)
        #endif
        
        if let swiftUIFramework = swiftUIBundlePath() {
            process(bundlePath: swiftUIFramework, problemTypes: &problemTypes)
        }

        appBundleImages { bundlePath, _, _ in
            process(bundlePath: bundlePath, problemTypes: &problemTypes)
        }

        passedByReference(Any.self)
//        print(problemTypes.map {unsafeBitCast($0, to: Any.Type.self)}, approximateFieldInfoByTypeName)
        return problemTypes
    }()

    /**
     Structs that have only fields that conform to .SwiftTraceFloatArg
     */
    static var structsAllFloats = Set<UnsafeRawPointer>()

    /**
     Ferforms a one time scan of all property getters at a bundlePath to
     look out for structs that are or contain bridged(?) values such as URL
     or UUID and are passed by reference by the compiler for some reason.
     */
    open class func process(bundlePath: UnsafePointer<Int8>,
                   problemTypes: UnsafeMutablePointer<Set<UnsafeRawPointer>>) {
        var offset = 0
        var currentType = ""
        var wasFloatType = false

        var symbols = [(symval: UnsafeRawPointer, symname: UnsafePointer<Int8>)]()
        findSwiftSymbols(bundlePath, "g") { (symval, symbol, _, _) in
            symbols.append((symval, symbol))
        }

        // Need to process symbols in emitted order if we are
        // to have any hope of recovering type memory layout.
        let debugPassedByReference = getenv("DEBUG_BYREFERENCE") != nil
        for (_, symbol) in symbols.sorted(by: { $0.symval < $1.symval }) {
            guard let demangled = SwiftMeta.demangle(symbol: symbol) else {
                print("Could not demangle: \(String(cString: symbol))")
                continue
            }
            func debug(_ str: @autoclosure () -> String) {
                if !debugPassedByReference { return }
                print(demangled)
                print(str())
            }
            guard let fieldStart = demangled.index(of: .first(of: " : ")+3),
               let nameEnd = demangled.index(of: fieldStart + .last(of: ".")),
               let typeEnd = demangled.index(of: nameEnd + .last(of: ".")),
               let typeName = demangled[..<typeEnd][safe:
                                     (.last(of: ":")+1 || .start)...],
               let fieldName = demangled[safe: typeEnd+1 ..< nameEnd],
               let fieldTypeName = demangled[safe: (fieldStart+0)...] else {
                 debug("Could not parse: \(demangled)")
                 continue
            }

            guard let type = SwiftMeta.lookupType(named: typeName) else {
                 debug("Could not lookup type: \(typeName)")
                 continue
             }

//            debug("\(typeName).\(fieldName): \(fieldTypeName)")
            let typeIsClass = type is AnyClass
            let symend = symbol+strlen(symbol)
            if strcmp(symend-3, "Ovg") == 0 || // enum
                strcmp(symend-5, "OSgvg") == 0, !typeIsClass {
                debug("\(typeName) enum prop \(fieldTypeName)")
                if let _ = typeLookupCache[typeName] {} else {
                    if !(type is UnsupportedTyping.Type) {
                        typeLookupCache[typeName] =
                            convert(type: type, handler: getEnumTypeFptr)
                    }
                }
                continue
            }

            func nextType(floatField: Bool) {
                if currentType != typeName {
                    currentType = typeName
                    wasFloatType = floatField
                    approximateFieldInfoByTypeName[typeName] = [FieldInfo]()
                    offset = type is AnyClass ? 8 * 3 : 0
                    if floatField && !typeIsClass {
                        structsAllFloats.insert(autoBitCast(type))
                    }
                }
            }

            guard let fieldType = SwiftMeta.lookupType(named: fieldTypeName) else {
                debug("Could not lookup field type: \"\(fieldTypeName)\", \(demangled) ")
                nextType(floatField: false)
                continue
            }

            let isFloatField = fieldType is SwiftTraceFloatArg.Type
            nextType(floatField: isFloatField)

            // Ignore non stored properties
            if doesntHaveStorage.contains(String(cString: symbol)) {
                debug("No Storage \(typeName).\(fieldName)")
                continue
            }

            let strideMinus1 = strideof(anyType: fieldType) - 1
            offset = (offset + strideMinus1) & ~strideMinus1
            approximateFieldInfoByTypeName[typeName]?.append(
                FieldInfo(name: fieldName, type: fieldType, offset: offset))
            offset += sizeof(anyType: fieldType)

            if !isFloatField {
                structsAllFloats.remove(autoBitCast(type))
            }

            if typeIsClass {
                continue
            }

            if isFloatField != wasFloatType &&
                !(type is SwiftTraceFloatArg.Type) &&
                !problemTypes.pointee.contains(autoBitCast(type)) {
                debug("\(typeName) Mixed properties")
                if !(type is UnsupportedTyping.Type) {
                    typeLookupCache[typeName] =
                        convert(type: type, handler: getMixedTypeFptr)
                }
            }

            func passedByReference(_ type: Any.Type) {
                if !_typeName(type).hasPrefix("Swift.") &&
                    problemTypes.pointee.insert(autoBitCast(type)).inserted {
                    debug("\(_typeName(type)) passed by reference")
                }
            }

            if problemTypes.pointee.contains(autoBitCast(fieldType)) ||
                fieldTypeName.hasPrefix("Foundation.Measurement<") {
                debug("\(typeName) Reference prop \(fieldTypeName)")
//                            typeLookupCache[typeName] = PreventLookup
                passedByReference(type)
                passedByReference(fieldType)
            } else if let optional = fieldType as? OptionalTyping.Type,
                problemTypes.pointee.contains(autoBitCast(optional.wrappedType)) {
                debug("\(typeName) Reference optional prop \(fieldTypeName)")
                passedByReference(type)
                passedByReference(fieldType)
            }
        }
    }

    /** pointer to a function implementing a Swift method */
    public typealias SIMP = @convention(c) () -> Void

    /**
     Value that crops up as a ClassSize since 5.2 runtime
     */
    static let invalidClassSize = 0x50AF17B0

    /**
     Layout of a class instance. Needs to be kept in sync with ~swift/include/swift/Runtime/Metadata.h
     */
    public struct TargetClassMetadata {

        let MetaClass: uintptr_t = 0, SuperClass: uintptr_t = 0
        let CacheData1: uintptr_t = 0, CacheData2: uintptr_t = 0

        public let Data: uintptr_t = 0

        /// Swift-specific class flags.
        public let Flags: UInt32 = 0

        /// The address point of instances of this type.
        public let InstanceAddressPoint: UInt32 = 0

        /// The required size of instances of this type.
        /// 'InstanceAddressPoint' bytes go before the address point;
        /// 'InstanceSize - InstanceAddressPoint' bytes go after it.
        public let InstanceSize: UInt32 = 0

        /// The alignment mask of the address point of instances of this type.
        public let InstanceAlignMask: UInt16 = 0

        /// Reserved for runtime use.
        public let Reserved: UInt16 = 0

        /// The total size of the class object, including prefix and suffix
        /// extents.
        public let ClassSize: UInt32 = 0

        /// The offset of the address point within the class object.
        public let ClassAddressPoint: UInt32 = 0

        /// An out-of-line Swift-specific description of the type, or null
        /// if this is an artificial subclass.  We currently provide no
        /// supported mechanism for making a non-artificial subclass
        /// dynamically.
        public let Description: uintptr_t = 0

        /// A function for destroying instance variables, used to clean up
        /// after an early return from a constructor.
        public var IVarDestroyer: SIMP? = nil

        // After this come the class members, laid out as follows:
        //   - class members for the superclass (recursively)
        //   - metadata reference for the parent, if applicable
        //   - generic parameters for this class
        //   - class variables (if we choose to support these)
        //   - "tabulated" virtual methods

    }

    /**
     Convert a executable symbol name "mangled" according to Swift's
     conventions into a human readable Swift language form
     */
    @objc open class func demangle(symbol: UnsafePointer<Int8>) -> String? {
        if let demangledNamePtr = _stdlib_demangleImpl(
            symbol, mangledNameLength: UInt(strlen(symbol)),
            outputBuffer: nil, outputBufferSize: nil, flags: 0) {
            let demangledName = String(cString: demangledNamePtr)
            free(demangledNamePtr)
            return demangledName
        }
        return nil
    }
}

// Taken from stdlib, not public Swift3+
@_silgen_name("swift_demangle")
private
func _stdlib_demangleImpl(
    _ mangledName: UnsafePointer<CChar>?,
    mangledNameLength: UInt,
    outputBuffer: UnsafeMutablePointer<UInt8>?,
    outputBufferSize: UnsafeMutablePointer<UInt>?,
    flags: UInt32
    ) -> UnsafeMutablePointer<CChar>?

/**
 Used to deocrate optioanals without wrapping value in Opotional()
 */
protocol OptionalTyping {
    static var wrappedType: Any.Type { get }
    static func describe(optionalPtr: UnsafeRawPointer, out: inout String)
}
extension Optional: OptionalTyping {
    static var wrappedType: Any.Type { return Wrapped.self }
    static func describe(optionalPtr: UnsafeRawPointer, out: inout String) {
        if var value = optionalPtr.load(as: Wrapped?.self) {
            // Slight coupling to SwiftArgs.swift here alas
            SwiftTrace.Decorated.describe(&value, type: Wrapped.self, out: &out)
        } else {
            out += "nil"
        }
    }
}

protocol UnsupportedTyping {}

/**
 Convenience extension to trap regex errors and report them
 */
extension NSRegularExpression {

    convenience init(regexp: String) {
        do {
            try self.init(pattern: regexp)
        }
        catch let error as NSError {
            fatalError("Invalid regexp: \(regexp): \(error.localizedDescription)")
        }
    }

    func matches(_ string: String) -> Bool {
        return rangeOfFirstMatch(in: string,
            range: NSMakeRange(0, string.utf16.count)).location != NSNotFound
    }
}
