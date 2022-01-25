//
//  fast_dladdr.mm
//  
//  Created by John Holdsworth on 21/01/2022.
//  Repo: https://github.com/johnno1962/SwiftTrace
//  $Id: //depot/SwiftTrace/SwiftTraceGuts/fast_dladdr.mm#3 $
//

#import "include/SwiftTrace.h"

#import <mach-o/dyld.h>
#import <mach-o/arch.h>
#import <mach-o/nlist.h>
#import <mach-o/getsect.h>
#import <dlfcn.h>

// A "pseudo image" is read into InjectionScratch rather than by using dlopen().
static std::vector<PseudoImage> loadedPseudoImages;

void pushPseudoImage(const char *path, const void *header) {
    loadedPseudoImages.push_back(PseudoImage(strdup(path),
                   (const struct mach_header *)header));
}

const struct mach_header * _Nullable lastPseudoImage() {
    if (loadedPseudoImages.empty())
        return nullptr;
    return loadedPseudoImages.back().second;
}

const std::vector<PseudoImage> &getLoadedPseudoImages(void) {
    return loadedPseudoImages;
}

// We need a version of dladdr() and co. that supports pseudo images.
#define TRY_TO_OPTIMISE_DLADDR 1
#if TRY_TO_OPTIMISE_DLADDR
#import <algorithm>

using namespace std;

class DySymbol {
public:
    const nlist_t *sym;
    DySymbol(const nlist_t *sym) : sym(sym) {}
};

static bool operator < (const DySymbol &s1, const DySymbol &s2) {
    return s1.sym->n_value < s2.sym->n_value;
}

// See: https://stackoverflow.com/questions/20481058/find-pathname-from-dlopen-handle-on-osx

class Dylib {
    segment_command_t *seg_linkedit = nullptr;
protected:
    struct symtab_command *symtab = nullptr;
    vector<DySymbol> symsByValue;
    intptr_t file_slide;
    const nlist_t *symbols;
public:
    const mach_header_t *header;
    const segment_command_t *seg_text = nullptr;
    const char *imageName, *start, *end, *strings;
    sectsize_t typeref_size = 0;
    char *typeref_start;

    Dylib(const char *imageName, const struct mach_header *header) {
        this->imageName = imageName; // = _dyld_get_image_name(imageIndex);
        this->header = (const mach_header_t *)header; //_dyld_get_image_header(imageIndex);
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

//        const struct section_64 *section = getsectbynamefromheader_64( (const struct mach_header_64 *)header, SEG_TEXT, SECT_TEXT );
        if (!seg_text) return;
        start = (char *)header;
        file_slide = ((intptr_t)seg_linkedit->vmaddr -
                      (intptr_t)seg_text->vmaddr) - seg_linkedit->fileoff;
        symbols = (nlist_t *)((intptr_t)header + (symtab->symoff + file_slide));
        end = strings = (char *)header + (symtab->stroff + file_slide);
        typeref_start = getsectdatafromheader_f(this->header, SEG_TEXT,
                                                "__swift5_typeref", &typeref_size);
    }

    void dump(const char *prefix) {
        printf("%s %p %p %s\n", prefix, start, end, imageName);
    }

    bool contains(const void *p) {
        return p >= start && p < end;
    }

    const vector<DySymbol> &populate() {
        if (symsByValue.empty()) {
            const nlist_t *sym = symbols;

            for (uint32_t i = 0; i < symtab->nsyms; i++, sym++)
                if (sym->n_sect != NO_SECT)
    //                    if (!(sym->n_type & N_STAB))
                        symsByValue.push_back(DySymbol(sym));
            sort(symsByValue.begin(), symsByValue.end());
        }
        return symsByValue;
    }

    int dladdr(const void *ptr, Dl_info *info) {
        populate();

        nlist_t nlist;
        nlist.n_value = (intptr_t)ptr - ((intptr_t)header - (intptr_t)seg_text->vmaddr);

        auto it = upper_bound(symsByValue.begin(), symsByValue.end(), DySymbol(&nlist));
        if (it == symsByValue.end()) {
            info->dli_sname = "fast_dladdr: symbol not found";
            return 0;
        }

        size_t bound = distance(symsByValue.begin(), it);
        if (!bound) return 0;
//        for (int i=-15; i<15; i++)
//            printf("%ld %d %x %s\n", distance(symbols.begin(), it),
//                   i, symbols[found+i].sym->n_type,
//                   strings + symbols[found+i].sym->n_un.n_strx);
        info->dli_sname = strings + symsByValue[bound-1].sym->n_un.n_strx;
        info->dli_saddr = (void *)(symsByValue[bound-1].sym->n_value +
                                   ((intptr_t)header - (intptr_t)seg_text->vmaddr));
        if (!*info->dli_sname) // Some symbols not located at found-1??
            info->dli_sname = strings + symsByValue[bound-2].sym->n_un.n_strx;
        if (*info->dli_sname == '_')
            info->dli_sname++;
        return 1;
    }
};

class DySymName: public DySymbol {
public:
    const char *name;
    DySymName(const nlist_t *sym, const char *name) : DySymbol(sym) {
        this->name = name;
    }
};

static bool operator < (const DySymName &s1, const DySymName &s2) {
//    printf("%s %s\n", s1.name, s2.name);
    return strcmp(s1.name, s2.name) < 0;
}

class DyHandle: public Dylib {
    vector<DySymName> symsByName;
    void populate() {
        if (symsByName.empty()) {
            const nlist_t *sym = symbols;
            for (uint32_t i = 0; i < symtab->nsyms; i++, sym++)
                if (sym->n_sect != NO_SECT)
                    if (const char *symname = strings+sym->n_un.n_strx) {
                        if (*symname == '_')
                            symname++;
                        symsByName.push_back(DySymName(sym, symname));
                    }
#if 0 // C++11 not possible inside an imported Swift package :(
            auto cmp = [&] (const DySymbol &l, const DySymbol &r) {
                return strcmp(strs+r.sym->n_un.n_strx, strs+r.sym->n_un.n_strx) < 0;
            };
#endif
            sort(symsByName.begin(), symsByName.end());
        }
    }
public:
    DyHandle(const char *imageName, const struct mach_header *header) :
        Dylib(imageName, header) {}

    void *dlsym(const char *symname) {
        populate();
        auto it = upper_bound(symsByName.begin(), symsByName.end(),
                              DySymName(nullptr, symname));
        if (it == symsByName.end()) {
            return nullptr;
        }

        size_t bound = distance(symsByName.begin(), it);
        if (!bound || strcmp(symsByName[bound-1].name, symname) != 0)
            return nullptr;
        return (void *)(symsByName[bound-1].sym->n_value +
                        ((intptr_t)header - (intptr_t)seg_text->vmaddr));
    }
};

class DylibPtr {
public:
    DyHandle *dylib;
    const char *start;
    DylibPtr(DyHandle *dylib) {
        if ((this->dylib = dylib))
            this->start = dylib->start;
    }
    DylibPtr(const char *start) {
        this->start = start;
    }
};

bool operator < (DylibPtr s1, DylibPtr s2) {
    return s1.start < s2.start;
}

class DyLookup {
    vector<DylibPtr> dylibs;
    int nimages = 0, pseudos = 0, nscratch = 0;
public:
    void populate() {
        int nextnimages = _dyld_image_count();
        for (int i = nimages; i < nextnimages; i++)
            if (!strstr(_dyld_get_image_name(i), "InjectionScratch"))
                dylibs.push_back(DylibPtr(new DyHandle(
                    _dyld_get_image_name(i),
                    _dyld_get_image_header(i))));
            else
                nscratch++;

        int nextpseudos = (int)loadedPseudoImages.size();
        for (int p = pseudos; p < nextpseudos; p++)
            dylibs.push_back(DylibPtr(new
                DyHandle(loadedPseudoImages[p].first,
                         loadedPseudoImages[p].second)));

//            dylibs[dylibs.size()-1].dylib->dump("?");
        if (nimages + pseudos != dylibs.size() + nscratch) {
//            printf("Adding %d -> %d %d -> %d\n", nimages, nextnimages, pseudos, nextpseudos);
            sort(dylibs.begin(), dylibs.end());
            nimages = nextnimages;
            pseudos = nextpseudos;
        }
    }

    DyHandle *dlhandle(const void *ptr, Dl_info *info) {
        populate();
//        info->dli_fname = "/fast_dladdr: symbol not found";
        if (ptr < dylibs[0].dylib->start) {
            if (info)
                info->dli_sname = "fast_dladdr: address too low";
            return nullptr;
        }

        DylibPtr dylibPtr((const char *)ptr);
        auto it = upper_bound(dylibs.begin(), dylibs.end(), dylibPtr);
//        printf("%llx %d?????\n", ptr, dist);
        if (it == dylibs.end()) {
            if (info)
                info->dli_sname = "fast_dladdr: address too high";
            return nullptr;
        }

        size_t bound = distance(dylibs.begin(), it);
        return bound ? dylibs[bound-1].dylib : nullptr;
    }

    int dladdr(const void *ptr, Dl_info *info) {
        Dylib *dylib = dlhandle(ptr, info);
        if (!dylib)
            return 0;
        info->dli_fname = dylib->imageName;
        info->dli_fbase = (void *)dylib->start;
        if (!dylib || !dylib->contains(ptr)) {
//            dylib->dump("????");
            info->dli_sname = "fast_dladdr: address not in image";
            return 0;
        }
//            printf("%llx %llx %llx %d %s\n", ptr, dylib->start, dylib->stop, dylib->contains(ptr), info->dli_sname);
        return dylib->dladdr(ptr, info);
    }
};
#endif

static DyLookup lookup;

int fast_dladdr(const void *ptr, Dl_info *info) {
#if TRY_TO_OPTIMISE_DLADDR
    return lookup.dladdr(ptr, info);
#else
    return dladdr(ptr, info);
#endif
}

void *fast_dlsym(const void *ptr, const char *symname) {
    Dl_info info;
    DyHandle *dylib = lookup.dlhandle(ptr, &info);
    return dylib ? dylib->dlsym(symname) : nullptr;
}

void fast_dlscan(const void *header, STVisibility visibility, STSymbolFilter filter, STSymbolCallback callback) {
    Dylib *dylib = lookup.dlhandle(header, NULL);
    const char *symname; void *address;
    for (auto &sym : dylib->populate()) {
        if ((visibility == STVisibilityAny || sym.sym->n_type == visibility) &&
            (symname = dylib->strings+sym.sym->n_un.n_strx) && filter(symname++) &&
            (address = (void *)(sym.sym->n_value + (intptr_t)dylib->header -
                                (intptr_t)dylib->seg_text->vmaddr))) {
            #if DEBUG && 0
            Dl_info info;
            if (dladdr(address, &info) &&
                strcmp(info.dli_sname, "injected_code") != 0 &&
                !strstr(info.dli_sname, symname))
                printf("SwiftTrace: dladdr %p does not verify! %s %s\n",
                       address, symname, describeImageInfo(&info).UTF8String);
            if (!fast_dladdr(address, &info) || !strstr(info.dli_sname, symname))
                printf("SwiftTrace: fast_dladdr %p does not verify: %s %s\n",
                       address, symname, describeImageInfo(&info).UTF8String);
            const void *ptr = fast_dlsym(header, symname);
            if (ptr != address)
                printf("SwiftTrace: fast_dlsym %s does not verify: %p %p\n",
                       symname, ptr, address);
            if (ptr != info.dli_saddr)
                printf("SwiftTrace: round trip %s does not verify: %p %p\n",
                       symname, ptr, info.dli_saddr);
            #endif
            callback(address, symname, dylib->typeref_start,
                     dylib->typeref_start+dylib->typeref_size);
        }
    }
}

@implementation DYLookup
- (instancetype)init {
    return [super init];
}
- (int)dladdr:(void *)pointer info:(Dl_info *)info {
    if (!dyLookup)
        dyLookup = new DyLookup();
    return ((class DyLookup *)dyLookup)->dladdr(pointer, info);
}
- (void)dealloc {
    if (dyLookup)
        delete (class DyLookup *)dyLookup;
}
@end

NSString *describeImageSymbol(const char *symname) {
    if (NSString *description = [NSObject swiftTraceDemangle:symname])
        return [description stringByAppendingFormat:@" %s", symname];
    return [NSString stringWithUTF8String:symname];
}

NSString *describeImageInfo(const Dl_info *info) {
    return [describeImageSymbol(info->dli_sname)
            stringByAppendingFormat:@"%s %p",
            rindex(info->dli_fname, '/'), info->dli_saddr];
}

NSString *describeImagePointer(const void *pointer) {
    Dl_info info;
    if (!fast_dladdr(pointer, &info))
        return [NSString stringWithFormat:@"%p??", pointer];
    return describeImageInfo(&info);
}

void injection_stack(void) {
    Dl_info info, info2;
    int level = 0;
    for (NSValue *value in [NSThread.callStackReturnAddresses reverseObjectEnumerator]) {
        void *pointer = value.pointerValue;
        printf("#%d %p", level++, pointer);
        info.dli_fname = "/bad image";
        if (!dladdr(pointer, &info))  {
            printf(" %p", pointer);
            info.dli_sname = "?";
        }
        if (!fast_dladdr(pointer, &info2))
            printf(" %p?", pointer);
        else
            info = info2;
        if (strcmp(info.dli_sname, "injection_scratch") == 0)
            printf(" injection_scratch:");
        else if (strcmp(info2.dli_sname, info.dli_sname) != 0 &&
                 strcmp(info2.dli_sname, "redacted>") != 0 && info.dli_sname[0] != '?')
            printf("%s: %s WTF? %s ", info2.dli_fname, info2.dli_sname, info.dli_sname);
        printf(" %s\n", describeImageInfo(&info).UTF8String);
    }
}
