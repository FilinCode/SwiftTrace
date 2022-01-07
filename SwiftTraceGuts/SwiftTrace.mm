//
//  SwiftTrace.m
//  SwiftTrace
//
//  Repo: https://github.com/johnno1962/SwiftTrace
//  $Id: //depot/SwiftTrace/SwiftTraceGuts/SwiftTrace.mm#87 $
//
//  Trampoline code thanks to:
//  https://github.com/OliverLetterer/imp_implementationForwardingToSelector
//
//  imp_implementationForwardingToSelector.m
//  imp_implementationForwardingToSelector
//
//  Created by Oliver Letterer on 22.03.14.
//  Copyright (c) 2014 Oliver Letterer <oliver.letterer@gmail.com>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

#import "SwiftTrace.h"

#import <AssertMacros.h>
#import <libkern/OSAtomic.h>

#import <mach/vm_types.h>
#import <mach/vm_map.h>
#import <mach/mach_init.h>
#import <objc/runtime.h>
#import <os/lock.h>

extern char xt_forwarding_trampoline_page, xt_forwarding_trampolines_start,
            xt_forwarding_trampolines_next, xt_forwarding_trampolines_end;

// trampoline implementation specific stuff...
typedef struct {
#if !defined(__LP64__)
    IMP tracer;
#endif
    void *patch; // Pointer to SwiftTrace.Patch instance retained elsewhere
} SwiftTraceTrampolineDataBlock;

typedef int32_t SPLForwardingTrampolineEntryPointBlock[2];
#if defined(__i386__)
static const int32_t SPLForwardingTrampolineInstructionCount = 8;
#elif defined(_ARM_ARCH_7)
static const int32_t SPLForwardingTrampolineInstructionCount = 12;
#undef PAGE_SIZE
#define PAGE_SIZE (1<<14)
#elif defined(__arm64__)
static const int32_t SPLForwardingTrampolineInstructionCount = 62;
#undef PAGE_SIZE
#define PAGE_SIZE (1<<14)
#elif defined(__LP64__) // x86_64
static const int32_t SPLForwardingTrampolineInstructionCount = 92;
#else
#error SwiftTrace is not supported on this platform
#endif

static const size_t numberOfTrampolinesPerPage = (PAGE_SIZE - SPLForwardingTrampolineInstructionCount * sizeof(int32_t)) / sizeof(SPLForwardingTrampolineEntryPointBlock);

typedef struct {
    union {
        struct {
#if defined(__LP64__)
            IMP onEntry;
            IMP onExit;
#endif
            int32_t nextAvailableTrampolineIndex;
        };
        int32_t trampolineSize[SPLForwardingTrampolineInstructionCount];
    };

    SwiftTraceTrampolineDataBlock trampolineData[numberOfTrampolinesPerPage];

    int32_t trampolineInstructions[SPLForwardingTrampolineInstructionCount];
    SPLForwardingTrampolineEntryPointBlock trampolineEntryPoints[numberOfTrampolinesPerPage];
} SPLForwardingTrampolinePage;

static_assert(sizeof(SPLForwardingTrampolineEntryPointBlock) == sizeof(SwiftTraceTrampolineDataBlock),
              "Inconsistent entry point/data block sizes");
static_assert(sizeof(SPLForwardingTrampolinePage) == 2 * PAGE_SIZE,
              "Incorrect trampoline pages size");
static_assert(offsetof(SPLForwardingTrampolinePage, trampolineInstructions) == PAGE_SIZE,
              "Incorrect trampoline page offset");

static SPLForwardingTrampolinePage *SPLForwardingTrampolinePageAlloc()
{
    vm_address_t trampolineTemplatePage = (vm_address_t)&xt_forwarding_trampoline_page;

    vm_address_t newTrampolinePage = 0;
    kern_return_t kernReturn = KERN_SUCCESS;

    //printf( "%d %d %d %d %d\n", vm_page_size, &xt_forwarding_trampolines_start - &xt_forwarding_trampoline_page, SPLForwardingTrampolineInstructionCount*4, &xt_forwarding_trampolines_end - &xt_forwarding_trampoline_page, &xt_forwarding_trampolines_next - &xt_forwarding_trampolines_start );

    assert( &xt_forwarding_trampolines_start - &xt_forwarding_trampoline_page ==
           SPLForwardingTrampolineInstructionCount * sizeof(int32_t) );
    assert( &xt_forwarding_trampolines_end - &xt_forwarding_trampoline_page == PAGE_SIZE );
    assert( &xt_forwarding_trampolines_next - &xt_forwarding_trampolines_start == sizeof(SwiftTraceTrampolineDataBlock) );

    // allocate two consequent memory pages
    kernReturn = vm_allocate(mach_task_self(), &newTrampolinePage, PAGE_SIZE * 2, VM_FLAGS_ANYWHERE);
    NSCAssert1(kernReturn == KERN_SUCCESS, @"vm_allocate failed", kernReturn);

    // deallocate second page where we will store our trampoline
    vm_address_t trampoline_page = newTrampolinePage + PAGE_SIZE;
    kernReturn = vm_deallocate(mach_task_self(), trampoline_page, PAGE_SIZE);
    NSCAssert1(kernReturn == KERN_SUCCESS, @"vm_deallocate failed", kernReturn);

    // trampoline page will be remapped with implementation of spl_objc_forwarding_trampoline
    vm_prot_t cur_protection, max_protection;
    kernReturn = vm_remap(mach_task_self(), &trampoline_page, PAGE_SIZE, 0, 0, mach_task_self(), trampolineTemplatePage, FALSE, &cur_protection, &max_protection, VM_INHERIT_SHARE);
    NSCAssert1(kernReturn == KERN_SUCCESS, @"vm_remap failed", kernReturn);

    return (SPLForwardingTrampolinePage *)newTrampolinePage;
}

static NSMutableArray *normalTrampolinePages = nil;

static SPLForwardingTrampolinePage *nextTrampolinePage()
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        normalTrampolinePages = [NSMutableArray array];
    });

    NSMutableArray *thisArray = normalTrampolinePages;

    SPLForwardingTrampolinePage *trampolinePage = (SPLForwardingTrampolinePage *)[thisArray.lastObject pointerValue];

    if (!trampolinePage || (trampolinePage->nextAvailableTrampolineIndex == numberOfTrampolinesPerPage) ) {
        trampolinePage = SPLForwardingTrampolinePageAlloc();
        [thisArray addObject:[NSValue valueWithPointer:trampolinePage]];
    }

    return trampolinePage;
}

#if 00
/// Fix for libMainThreadCheck when using trampolines
typedef const char * (*image_path_func)(const void *ptr);
static image_path_func orig_path_func;

static const char *myld_image_path_containing_address(const void* addr) {
    return orig_path_func(addr) ?: "/trampoline";
}
#endif

IMP imp_implementationForwardingToTracer(void *patch, IMP onEntry, IMP onExit)
{
#if 00
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        struct rebinding path_rebinding = {"dyld_image_path_containing_address",
          (void *)myld_image_path_containing_address, (void **)&orig_path_func};
        rebind_symbols(&path_rebinding, 1);
    });
#endif

    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&lock);

    SPLForwardingTrampolinePage *dataPageLayout = nextTrampolinePage();

    int32_t nextAvailableTrampolineIndex = dataPageLayout->nextAvailableTrampolineIndex;

#if !defined(__LP64__)
    dataPageLayout->trampolineData[nextAvailableTrampolineIndex].tracer = onEntry;
#else
    dataPageLayout->onEntry = onEntry;
    dataPageLayout->onExit = onExit;
#endif
    dataPageLayout->trampolineData[nextAvailableTrampolineIndex].patch = patch;
    dataPageLayout->nextAvailableTrampolineIndex++;

    IMP implementation = (IMP)&dataPageLayout->trampolineEntryPoints[nextAvailableTrampolineIndex];
    
    os_unfair_lock_unlock(&lock);
    
    return implementation;
}

// ====================================================================
// From here on additions to the original code for use by "SwiftTrace".
// ====================================================================

#ifndef SWIFTUISUPPORT
// Bridge via NSObject for when SwiftTrace is dynamically loaded
#import "SwiftTrace-Swift.h"

@implementation NSObject(SwiftTrace)
+ (NSString *)swiftTraceDefaultMethodExclusions {
    return [SwiftTrace defaultMethodExclusions];
}
+ (NSString *)swiftTraceMethodExclusionPattern {
    return [SwiftTrace methodExclusionPattern];
}
+ (void)setSwiftTraceMethodExclusionPattern:(NSString *)pattern {
    [SwiftTrace setMethodExclusionPattern:pattern];
}
+ (NSString *)swiftTraceMethodInclusionPattern {
    return [SwiftTrace methodInclusionPattern];
}
+ (void)setSwiftTraceMethodInclusionPattern:(NSString *)pattern {
    [SwiftTrace setMethodInclusionPattern:pattern];
}
+ (NSArray<NSString *> * _Nonnull)swiftTraceFunctionSuffixes {
    return [SwiftTrace swiftFunctionSuffixes];
}
+ (void)setSwiftTraceFunctionSuffixes:(NSArray<NSString *> * _Nonnull)value {
    [SwiftTrace setSwiftFunctionSuffixes:value];
}
+ (BOOL)swiftTracing {
    return [SwiftTrace isTracing];
}
+ (void *)swiftTraceInterposed {
    return [SwiftTrace interposedPointer];
}
+ (BOOL)swiftTraceTypeLookup {
    return [SwiftTrace typeLookup];
}
+ (void)setSwiftTraceTypeLookup:(BOOL)enabled {
    [SwiftTrace setTypeLookup:enabled];
    [SwiftTrace setDecorateAny:enabled];
}
+ (void)swiftTrace {
    [SwiftTrace traceWithAClass:self];
}
+ (void)swiftTraceBundle {
    [self swiftTraceBundleWithSubLevels:0];
}
+ (void)swiftTraceBundleWithSubLevels:(int)subLevels {
    [SwiftTrace traceBundleWithContaining:self subLevels:subLevels];
}
+ (void)swiftTraceMainBundle {
    [self swiftTraceMainBundleWithSubLevels:0];
}
+ (void)swiftTraceMainBundleWithSubLevels:(int)subLevels {
    [SwiftTrace traceMainBundleWithSubLevels:subLevels];
}
+ (void)swiftTraceClassesMatchingPattern:(NSString *)pattern {
    [self swiftTraceClassesMatchingPattern:pattern subLevels:0];
}
+ (void)swiftTraceClassesMatchingPattern:(NSString *)pattern subLevels:(intptr_t)subLevels {
    [SwiftTrace traceClassesMatchingPattern:pattern subLevels:subLevels];
}
+ (NSArray<NSString *> *)swiftTraceMethodNames {
    return [SwiftTrace methodNamesOfClass:self];
}
+ (NSArray<NSString *> *)switTraceMethodsNamesOfClass:(Class)aClass {
    return [SwiftTrace methodNamesOfClass:aClass];
}
+ (BOOL)swiftTraceUndoLastTrace {
    return [SwiftTrace undoLastTrace];
}
+ (void)swiftTraceRemoveAllTraces {
    [SwiftTrace removeAllTraces];
}
+ (void)swiftTraceRevertAllInterposes {
    [SwiftTrace revertInterposes];
}
+ (void)swiftTraceInstances {
    [self swiftTraceInstancesWithSubLevels:0];
}
+ (void)swiftTraceInstancesWithSubLevels:(int)subLevels {
    [SwiftTrace traceInstancesOfClass:self subLevels:subLevels];
}
- (void)swiftTraceInstance {
    [self swiftTraceInstanceWithSubLevels:0];
}
- (void)swiftTraceInstanceWithSubLevels:(int)subLevels {
    [SwiftTrace traceWithAnInstance:self subLevels:subLevels];
}
+ (void)swiftTraceProtocolsInBundle {
    [self swiftTraceProtocolsInBundleWithMatchingPattern:nil subLevels:0];
}
+ (void)swiftTraceProtocolsInBundleWithMatchingPattern:(NSString * _Nullable)pattern {
    [self swiftTraceProtocolsInBundleWithMatchingPattern:pattern subLevels:0];
}
+ (void)swiftTraceProtocolsInBundleWithSubLevels:(int)subLevels {
    [self swiftTraceProtocolsInBundleWithMatchingPattern:nil subLevels:subLevels];
}
+ (void)swiftTraceProtocolsInBundleWithMatchingPattern:(NSString *)pattern subLevels:(int)subLevels {
    [SwiftTrace traceProtocolsInBundleWithContaining:self matchingPattern:pattern subLevels:subLevels];
}
+ (NSInteger)swiftTraceMethodsInFrameworkContaining:(Class _Nonnull)aClass {
    return [SwiftTrace traceMethodsInFrameworkContaining:aClass];
}
+ (NSInteger)swiftTraceMainBundleMethods {
    return [SwiftTrace traceMainBundleMethods];
}
+ (NSInteger)swiftTraceFrameworkMethods {
    return [SwiftTrace traceFrameworkMethods];
}
+ (NSInteger)swiftTraceMethodsInBundle:(const char * _Nonnull)bundlePath
                           packageName:(NSString * _Nullable)packageName {
    return [SwiftTrace interposeMethodsInBundlePath:(const int8_t *)bundlePath
                                        packageName:packageName subLevels:0];
}
+ (void)swiftTraceBundlePath:(const char * _Nonnull)bundlePath {
    [SwiftTrace traceWithBundlePath:(const int8_t *)bundlePath subLevels:0];
}
+ (NSString * _Nullable)swiftTraceFilterInclude {
    return [SwiftTrace traceFilterInclude];
}
+ (void)setSwiftTraceFilterInclude:(NSString * _Nullable)include {
    [SwiftTrace setTraceFilterInclude:include];
}
+ (NSString * _Nullable)swiftTraceFilterExclude {
    return [SwiftTrace traceFilterExclude];
}
+ (void)setSwiftTraceFilterExclude:(NSString * _Nullable)exclude {
    [SwiftTrace setTraceFilterExclude:exclude];
}
+ (STSymbolFilter _Nonnull)swiftTraceSymbolFilter {
    return [SwiftTrace injectableSymbol];
}
+ (void)setSwiftTraceSymbolFilter:(STSymbolFilter _Nonnull)filter {
    [SwiftTrace setInjectableSymbol:filter];
}
+ (NSDictionary<NSString *, NSNumber *> * _Nonnull)swiftTraceElapsedTimes {
    return [SwiftTrace elapsedTimes];
}
+ (NSDictionary<NSString *, NSNumber *> * _Nonnull)swiftTraceInvocationCounts {
    return [SwiftTrace invocationCounts];
}
@end
#endif

#ifdef OBJC_TRACE_TESTER
@implementation ObjcTraceTester: NSObject

- (OSRect)a:(float)a i:(int)i b:(double)b c:(NSString *)c o:o s:(SEL)s {
    return OSMakeRect(1, 2, 3, 4);
}
@end
#endif

NSArray<Class> *objc_classArray() {
    unsigned nc;
    NSMutableArray<Class> *array = [NSMutableArray new];
    if (Class *classes = objc_copyClassList(&nc))
        for (int i=0; i<nc; i++) {
            if (class_getSuperclass(classes[i]))
                [array addObject:classes[i]];
            else {
                const char *name = class_getName(classes[i]);
                printf("%s\n", name);
                if (strcmp(name, "JSExport") && strcmp(name, "_NSZombie_") &&
                    strcmp(name, "__NSMessageBuilder") && strcmp(name, "__NSAtom") &&
                    strcmp(name, "__ARCLite__") && strcmp(name, "__NSGenericDeallocHandler") &&
                    strcmp(name, "CNZombie") && strcmp(name, "_CNZombie_") &&
                    strcmp(name, "NSVB_AnimationFencingSupport"))
                    [array addObject:classes[i]];
            }
        }
    return array;
}

NSMethodSignature *method_getSignature(Method method) {
    const char *encoding = method_getTypeEncoding(method);
    @try {
        return [NSMethodSignature signatureWithObjCTypes:encoding];
    }
    @catch(NSException *err) {
        NSLog(@"*** Unsupported method encoding: %s", encoding);
        return nil;
    }
}

const char *sig_argumentType(id signature, NSUInteger index) {
    return [signature getArgumentTypeAtIndex:index];
}

const char *sig_returnType(id signature) {
    return [signature methodReturnType];
}

const char *swiftUIBundlePath() {
    if (Class AnyText = (__bridge Class)
        dlsym(RTLD_DEFAULT, "$s7SwiftUI14AnyTextStorageCN"))
        return class_getImageName(AnyText);
    return nullptr;
}

id findSwizzleOf(void * _Nonnull trampoline) {
    for (NSValue *allocated in normalTrampolinePages) {
        SPLForwardingTrampolinePage *trampolinePage =
            (SPLForwardingTrampolinePage *)allocated.pointerValue;
        if (trampoline >= trampolinePage->trampolineInstructions && trampoline <
            trampolinePage->trampolineInstructions + numberOfTrampolinesPerPage)
            return *(id const *)(void *)((char *)trampoline - PAGE_SIZE);
    }
    return nil;
}

// https://stackoverflow.com/questions/20481058/find-pathname-from-dlopen-handle-on-osx

#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/arch.h>
#import <mach-o/getsect.h>
#import <mach-o/nlist.h>

#ifdef __LP64__
typedef struct mach_header_64 mach_header_t;
typedef struct segment_command_64 segment_command_t;
typedef struct nlist_64 nlist_t;
typedef uint64_t sectsize_t;
#define getsectdatafromheader_f getsectdatafromheader_64
#else
typedef struct mach_header mach_header_t;
typedef struct segment_command segment_command_t;
typedef struct nlist nlist_t;
typedef uint32_t sectsize_t;
#define getsectdatafromheader_f getsectdatafromheader
#endif

static char includeObjcClasses[] = {"CN"};
static char objcClassPrefix[] = {"_OBJC_CLASS_$_"};

const char *classesIncludingObjc() {
    return includeObjcClasses;
}

void findSwiftSymbols(const char *bundlePath, const char *suffix,
        void (^callback)(const void *symval, const char *symname, void *typeref, void *typeend)) {
    findHiddenSwiftSymbols(bundlePath, suffix, ST_GLOBAL_VISIBILITY, callback);
}

void findHiddenSwiftSymbols(const char *bundlePath, const char *suffix, int visibility,
        void (^callback)(const void *symval, const char *symname, void *typeref, void *typeend)) {
    size_t sufflen = strlen(suffix);
    STSymbolFilter swiftSymbolsWithSuffixOrObjcClass = ^BOOL(const char *symname) {
        return (strncmp(symname, "_$s", 3) == 0 &&
                strcmp(symname+strlen(symname)-sufflen, suffix) == 0) ||
            (suffix == includeObjcClasses && strncmp(symname,
             objcClassPrefix, sizeof objcClassPrefix-1) == 0);
    };
    for (int32_t i = _dyld_image_count()-1; i >= 0 ; i--) {
        const char *imageName = _dyld_get_image_name(i);
        if (!(imageName && (!bundlePath || imageName == bundlePath ||
                            strcmp(imageName, bundlePath) == 0 ||
                            // for when prefixed with /private
                            strcmp(imageName+8, bundlePath) == 0)))
            continue;

        filterImageSymbols(i, (STVisibility)visibility,
                           swiftSymbolsWithSuffixOrObjcClass, callback);
        if (bundlePath)
            return;
    }
}

void filterImageSymbols(uint32_t imageNumber, STVisibility visibility, STSymbolFilter filter,
    void (^ _Nonnull callback)(const void * _Nonnull address, const char * _Nonnull symname,
                               void * _Nonnull typeref, void * _Nonnull typeend)) {
        const mach_header_t *header =
            (const mach_header_t *)_dyld_get_image_header(imageNumber);
        segment_command_t *seg_linkedit = nullptr;
        segment_command_t *seg_text = nullptr;
        struct symtab_command *symtab = nullptr;
        // to filter associated type witness entries
        sectsize_t typeref_size = 0;
        char *typeref_start = getsectdatafromheader_f(header, SEG_TEXT,
                                            "__swift5_typeref", &typeref_size);

        struct load_command *cmd =
            (struct load_command *)((intptr_t)header + sizeof(mach_header_t));
        for (uint32_t i = 0; i < header->ncmds; i++,
             cmd = (struct load_command *)((intptr_t)cmd + cmd->cmdsize)) {
            switch(cmd->cmd) {
                case LC_SEGMENT:
                case LC_SEGMENT_64:
                    if (!strcmp(((segment_command_t *)cmd)->segname, SEG_TEXT))
                        seg_text = (segment_command_t *)cmd;
                    else if (!strcmp(((segment_command_t *)cmd)->segname, SEG_LINKEDIT))
                        seg_linkedit = (segment_command_t *)cmd;
                    break;

                case LC_SYMTAB: {
                    symtab = (struct symtab_command *)cmd;
                    intptr_t file_slide = ((intptr_t)seg_linkedit->vmaddr - (intptr_t)seg_text->vmaddr) - seg_linkedit->fileoff;
                    const char *strings = (const char *)header +
                                               (symtab->stroff + file_slide);
                    nlist_t *sym = (nlist_t *)((intptr_t)header +
                                               (symtab->symoff + file_slide));

                    for (uint32_t i = 0; i < symtab->nsyms; i++, sym++) {
                        const char *symname = strings + sym->n_un.n_strx;
                        void *address;

//                        printf("%d %s %d\n", visibility, symname, sym->n_type);

                        if ((!visibility || sym->n_type == visibility) &&
                            sym->n_sect != NO_SECT && filter(symname) &&
                            (address = (void *)(sym->n_value +
                             (intptr_t)header - (intptr_t)seg_text->vmaddr))) {
                            callback(address, symname+1, typeref_start,
                                     typeref_start + typeref_size);
                        }
                    }
                }
            }
        }
}

void appBundleImages(void (^callback)(const char *imageName, const struct mach_header *, intptr_t slide)) {
    NSBundle *mainBundle = [NSBundle mainBundle];
    const char *mainExecutable = mainBundle.executablePath.UTF8String;
    const char *bundleFrameworks = mainBundle.privateFrameworksPath.UTF8String;
    size_t frameworkPathLength = strlen(bundleFrameworks);

    for (int32_t i = _dyld_image_count()-1; i >= 0 ; i--) {
        const char *imageName = _dyld_get_image_name(i);
//        NSLog(@"findImages: %s", imageName);
        if (strcmp(imageName, mainExecutable) == 0 ||
            strncmp(imageName, bundleFrameworks, frameworkPathLength) == 0 ||
            (strstr(imageName, "/DerivedData/") &&
             strstr(imageName, ".framework/")) ||
            strstr(imageName, "/eval"))
            callback(imageName, _dyld_get_image_header(i),
                     _dyld_get_image_vmaddr_slide(i));
    }
}

const char *callerBundle() {
    void *returnAddress = __builtin_return_address(1);
    Dl_info info;
    if (dladdr(returnAddress, &info))
        return info.dli_fname;
    return nullptr;
}

#if TRY_TO_OPTIMISE_DLADDR
#import <vector>
#import <algorithm>

using namespace std;

class Symbol {
public:
    nlist_t *sym;
    Symbol(nlist_t *sym) {
        this->sym = sym;
    }
};

static bool operator < (Symbol s1, Symbol s2) {
    return s1.sym->n_value < s2.sym->n_value;
}

class Dylib {
    const mach_header_t *header;
    segment_command_t *seg_linkedit = nullptr;
    segment_command_t *seg_text = nullptr;
    struct symtab_command *symtab = nullptr;
    vector<Symbol> symbols;

public:
    char *start = nullptr, *stop = nullptr;
    const char *imageName;

    Dylib(int imageIndex) {
        imageName = _dyld_get_image_name(imageIndex);
        header = (const mach_header_t *)_dyld_get_image_header(imageIndex);
        struct load_command *cmd = (struct load_command *)((intptr_t)header + sizeof(mach_header_t));
        assert(header);

        for (uint32_t i = 0; i < header->ncmds; i++, cmd = (struct load_command *)((intptr_t)cmd + cmd->cmdsize))
        {
            switch(cmd->cmd)
            {
                case LC_SEGMENT:
                case LC_SEGMENT_64:
                    if (!strcmp(((segment_command_t *)cmd)->segname, SEG_TEXT))
                        seg_text = (segment_command_t *)cmd;
                    else if (!strcmp(((segment_command_t *)cmd)->segname, SEG_LINKEDIT))
                        seg_linkedit = (segment_command_t *)cmd;
                    break;

                case LC_SYMTAB:
                    symtab = (struct symtab_command *)cmd;
            }
        }

        const struct section_64 *section = getsectbynamefromheader_64( (const struct mach_header_64 *)header, SEG_TEXT, SECT_TEXT );
        if (section == 0) return;
        start = (char *)(section->addr + _dyld_get_image_vmaddr_slide( (uint32_t)imageIndex ));
        stop = start + section->size;
//        printf("%llx %llx %llx %s\n", section->addr, _dyld_get_image_vmaddr_slide( (uint32_t)imageIndex ), start, imageName);
    }

    bool contains(const void *p) {
        return p >= start && p <= stop;
    }

    int dladdr(const void *ptr, Dl_info *info) {
        intptr_t file_slide = ((intptr_t)seg_linkedit->vmaddr - (intptr_t)seg_text->vmaddr) - seg_linkedit->fileoff;
        const char *strings = (const char *)header + (symtab->stroff + file_slide);
        
        if (symbols.empty()) {
            nlist_t *sym = (nlist_t *)((intptr_t)header + (symtab->symoff + file_slide));

            for (uint32_t i = 0; i < symtab->nsyms; i++, sym++)
                if (sym->n_type == 0xf)
                    symbols.push_back(Symbol(sym));

            sort(symbols.begin(), symbols.end());
        }

        nlist_t nlist;
        nlist.n_value = (intptr_t)ptr - ((intptr_t)header - (intptr_t)seg_text->vmaddr);

        auto it = lower_bound(symbols.begin(), symbols.end(), Symbol(&nlist));
        if (it != symbols.end()) {
            info->dli_fname = imageName;
            info->dli_sname = strings + it->sym->n_un.n_strx + 1;
            return 1;
        }

        return 0;
    }
};

class DylibPtr {
public:
    Dylib *dylib;
    const char *start;
    DylibPtr(Dylib *dylib) {
        if ((this->dylib = dylib))
            this->start = dylib->start;
    }
};

bool operator < (DylibPtr s1, DylibPtr s2) {
    return s1.start < s2.start;
}
#endif

int fast_dladdr(const void *ptr, Dl_info *info) {
#if !TRY_TO_OPTIMISE_DLADDR
    return dladdr(ptr, info);
#else
    static vector<DylibPtr> dylibs;

    if (dylibs.empty()) {
        for (int32_t i = 0; i < _dyld_image_count(); i++)
            dylibs.push_back(DylibPtr(new Dylib(i)));

        sort(dylibs.begin(), dylibs.end());
    }

    if (ptr < dylibs[0].dylib->start)
        return 0;

//    printf("%llx?\n", ptr);
    DylibPtr dylibPtr(NULL);
    dylibPtr.start = (const char *)ptr;
    auto it = lower_bound(dylibs.begin(), dylibs.end(), dylibPtr);
    if (it != dylibs.end()) {
        Dylib *dylib = dylibs[distance(dylibs.begin(), it)-1].dylib;
        if (!dylib || !dylib->contains(ptr))
            return 0;
//        printf("%llx %llx %llx %d %s\n", ptr, dylib->start, dylib->stop, dylib->contains(ptr), info->dli_sname);
        return dylib->dladdr(ptr, info);
    }

    return 0;
#endif
}
