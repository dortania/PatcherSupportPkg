// Provider-pinned legacy AMD argument-metadata compatibility adapter.
#include "pinned_llvm.hpp"
#include <stdexcept>
#define EXPORTED __attribute__((visibility("default")))

namespace {
bool key(void *metadata,const char *text) {
    if(!metadata || pinned::field<unsigned char>(metadata)!=0) return false;
    auto value=pinned::api().string(metadata);
    return value.size==std::strlen(text) && !std::memcmp(value.data,text,value.size);
}
bool constantTwo(void *metadata) {
    // Pinned ConstantAsMetadata -> i32 ConstantInt layout, verified in 12.5.
    if(!metadata || pinned::field<unsigned char>(metadata)!=1) return false;
    void *constant=pinned::field<void*>(metadata,0x80);
    return constant && pinned::field<unsigned char>(constant,0x10)==0x12 &&
        pinned::field<unsigned>(constant,0x20)==32 && pinned::field<uint64_t>(constant,0x18)==2;
}
struct Normalize {
    void *context;
    unsigned removed=0,visited=0;
    void validate(void *node,unsigned depth) {
        if(!node || pinned::field<unsigned char>(node)!=4 || pinned::field<unsigned char>(node,1)!=0 ||
           depth>16 || ++visited>4096 || pinned::count(node)>4096) throw std::runtime_error("unsupported metadata shape");
    }
    void *copy(void *original,std::vector<void*> &values) {
        bool same=values.size()==pinned::count(original);
        if(same) for(unsigned i=0;i<values.size();++i) same&=values[i]==pinned::operand(original,i);
        return same?original:pinned::api().tuple(context,{values.data(),values.size()},0,true);
    }
    void *argument(void *node,unsigned depth) {
        validate(node,depth);
        std::vector<void*> values;
        for(unsigned i=0;i<pinned::count(node);++i) {
            void *value=pinned::operand(node,i);
            if(key(value,"air.address_space")) {
                if(i+1>=pinned::count(node)) throw std::runtime_error("missing address-space value");
                if(constantTwo(pinned::operand(node,i+1))) { ++removed; ++i; continue; }
                // Other values retain the original parser behavior.
            }
            values.push_back(value);
            if(key(value,"air.struct_type_info")) {
                if(i+1>=pinned::count(node)) throw std::runtime_error("missing structure description");
                values.push_back(structure(pinned::operand(node,++i),depth+1));
            }
        }
        return copy(node,values);
    }
    void *structure(void *node,unsigned depth) {
        validate(node,depth);
        std::vector<void*> values;
        for(unsigned i=0;i<pinned::count(node);++i) {
            void *value=pinned::operand(node,i); values.push_back(value);
            // Only descend through the actual nested-argument marker. Do not
            // traverse arbitrary debug, alias, type or user-name metadata.
            if(key(value,"air.indirect_argument")) {
                if(i+1>=pinned::count(node)) throw std::runtime_error("missing nested argument");
                values.push_back(argument(pinned::operand(node,++i),depth+1));
            }
        }
        return copy(node,values);
    }
};

void normalize(void *module,void *context) {
    try {
        if(!module || !context || !pinned::api().valid) return;
        auto entry=pinned::api().entry(module);
        if(!entry.node || !entry.stage || (std::strcmp(entry.stage,"air.vertex") &&
            std::strcmp(entry.stage,"air.fragment") && std::strcmp(entry.stage,"air.kernel"))) return;
        Normalize normalizer{context};normalizer.validate(entry.node,0);
        if(pinned::count(entry.node)!=3) return;
        void *arguments=pinned::operand(entry.node,2);normalizer.validate(arguments,0);
        std::vector<void*> values;
        for(unsigned i=0;i<pinned::count(arguments);++i) values.push_back(normalizer.argument(pinned::operand(arguments,i),1));
        if(!normalizer.removed) return;
        void *replacement=normalizer.copy(arguments,values);
        // LLVM's API maintains operand tracking/uniquing. Never overwrite
        // metadata operands or their count directly. Commit only after the
        // complete supported argument subtree has been prepared successfully.
        pinned::api().replace(entry.node,2,replacement);
    } catch(const std::exception &) {
        return;
    }
}
}

// The verified C1 constructor forwards to C2. Preserve vendor ownership,
// parsing and destruction; normalize only after the module has been parsed.
extern "C" EXPORTED void compatibilityHelper(void*,const void*,size_t) asm("__ZN4llvm12amdMtlPlugin14ILPluginHelperC1EPKvm");
extern "C" EXPORTED void compatibilityHelper(void *helper,const void *bytes,size_t size) {
    pinned::originalHelper(helper,bytes,size);
    if(size) normalize(pinned::field<void*>(helper),pinned::field<void*>(helper,8));
}
