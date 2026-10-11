// ABI bridge pinned to the inspected AMDShared 12.5 LLVM instance.
// Resolves local symbols by name from its own Mach-O, never edits code pages.
#pragma once
#include <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <cstdint>
#include <cstddef>
#include <cstring>
#include <fstream>
#include <vector>

namespace pinned {
constexpr const char *library="/System/Library/Extensions/AMDShared.bundle/Contents/PlugIns/libAMDIL902.dylib";
template<class T> T field(const void *p, ptrdiff_t offset=0) {
    T result; std::memcpy(&result,static_cast<const char*>(p)+offset,sizeof(result)); return result;
}
struct Array { void **data; size_t size; };
struct String { const char *data; size_t size; };
struct Entry { void *node; const char *stage; };
extern "C" void originalHelper(void*,const void*,size_t) asm("__ZN4llvm12amdMtlPlugin14ILPluginHelperC2EPKvm");
struct API {
    bool valid=false;
    String(*string)(const void*)=nullptr;
    void*(*tuple)(void*,Array,unsigned,bool)=nullptr;
    void(*replace)(void*,unsigned,void*)=nullptr;
    Entry(*entry)(void*)=nullptr;
    API() {
        Dl_info info{};
        if (!dladdr(reinterpret_cast<void*>(originalHelper),&info) || !info.dli_fname || std::strcmp(info.dli_fname,library)) return;
        std::ifstream input(library,std::ios::binary | std::ios::ate);
        const auto size=input.tellg();
        if (size<static_cast<std::streamoff>(sizeof(mach_header_64)) || size>64*1024*1024) return;
        std::vector<char> bytes(static_cast<size_t>(size));
        input.seekg(0);
        if (!input.read(bytes.data(),size)) return;
        unsigned char hash[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(bytes.data(),static_cast<CC_LONG>(bytes.size()),hash);
        const unsigned char expectedHash[]={0x62,0xc8,0x3e,0x55,0xde,0xc1,0x2b,0x84,0x9f,0x98,0xa6,0xdf,0x6f,0x01,0x2f,0xc0,0xc9,0xde,0xf8,0x33,0x11,0xed,0x89,0x68,0x5b,0xff,0x76,0x84,0x3e,0xa3,0xee,0x37};
        if (std::memcmp(hash,expectedHash,sizeof(hash))) return;
        auto *header=reinterpret_cast<const mach_header_64*>(bytes.data());
        if(header->magic!=MH_MAGIC_64 || header->cputype!=CPU_TYPE_X86_64) return;
        const symtab_command *table=nullptr; uintptr_t textAddress=0; bool uuid=false;
        size_t offset=sizeof(*header);
        const unsigned char expectedUUID[]={0xd5,0xcf,0x00,0x07,0x89,0x35,0x31,0x93,0xb3,0xf1,0xd0,0xb3,0xdd,0x0d,0xcc,0x91};
        for(unsigned i=0;i<header->ncmds;++i) {
            if(offset+sizeof(load_command)>bytes.size()) return;
            auto *command=reinterpret_cast<const load_command*>(bytes.data()+offset);
            if(command->cmdsize<sizeof(*command) || offset+command->cmdsize>bytes.size()) return;
            if(command->cmd==LC_SYMTAB) table=reinterpret_cast<const symtab_command*>(command);
            if(command->cmd==LC_SEGMENT_64) {
                auto *segment=reinterpret_cast<const segment_command_64*>(command);
                if(!std::strcmp(segment->segname,SEG_TEXT)) textAddress=segment->vmaddr;
            }
            if(command->cmd==LC_UUID) uuid=!std::memcmp(reinterpret_cast<const uuid_command*>(command)->uuid,expectedUUID,16);
            offset+=command->cmdsize;
        }
        if(!uuid || !table || !textAddress || table->symoff+size_t(table->nsyms)*sizeof(nlist_64)>bytes.size() ||
           table->stroff+size_t(table->strsize)>bytes.size()) return;
        auto resolve=[&](const char *name)->void* {
            auto *symbols=reinterpret_cast<const nlist_64*>(bytes.data()+table->symoff);
            for(unsigned i=0;i<table->nsyms;++i) {
                auto &symbol=symbols[i];
                if((symbol.n_type&N_TYPE)!=N_SECT || (symbol.n_type&N_STAB) || symbol.n_un.n_strx>=table->strsize) continue;
                const char *text=bytes.data()+table->stroff+symbol.n_un.n_strx;
                if(!std::memchr(text,0,table->strsize-symbol.n_un.n_strx)) return nullptr;
                if(!std::strcmp(text,name)) return static_cast<char*>(info.dli_fbase)+(symbol.n_value-textAddress);
            }
            return nullptr;
        };
        string=reinterpret_cast<decltype(string)>(resolve("__ZNK4llvm8MDString9getStringEv"));
        tuple=reinterpret_cast<decltype(tuple)>(resolve("__ZN4llvm7MDTuple7getImplERNS_11LLVMContextENS_8ArrayRefIPNS_8MetadataEEENS4_11StorageTypeEb"));
        replace=reinterpret_cast<decltype(replace)>(resolve("__ZN4llvm6MDNode18replaceOperandWithEjPNS_8MetadataE"));
        // A compiler plugin may be loaded RTLD_LOCAL. Resolve from this exact
        // provider image instead of relying on process-global symbol visibility.
        entry=reinterpret_cast<decltype(entry)>(resolve("__ZN4llvm11ILEntryFunc13getFuncMDNodeERNS_6ModuleE"));
        valid=string && tuple && replace && entry;
    }
};
inline API &api() { static API instance; return instance; }
// Pinned MDTuple layout: kind/storage bytes at 0/1, operand count at 8;
// tracked operands precede the node. Helper module/context are at 0/8.
inline unsigned count(const void *node) { return field<unsigned>(node,8); }
inline void *operand(const void *node,unsigned index) {
    return field<void*>(node,(static_cast<ptrdiff_t>(index)-count(node))*8);
}
}
