#include "ControlBridge.h"
#include "Client.hpp"
#include "MOTUDSP.hpp"
#include <mutex>
#include <unordered_map>
using namespace cute;
namespace {std::mutex mutex;uint32_t nextConnection=1;std::unordered_map<uint32_t,std::unique_ptr<Client>> clients;
xpc_object_t call(uint32_t id,const char* op){auto it=clients.find(id);return it==clients.end()?nullptr:it->second->call(op);}
uint32_t finish(xpc_object_t r){auto s=status(r);if(r)xpc_release(r);return s;}}
uint32_t cueOpen(uint32_t* connection){if(!connection)return 0xe00002c2;*connection=0;std::lock_guard<std::mutex> lock(mutex);auto client=std::make_unique<Client>();client->connect();
    auto m=message("hello");xpc_dictionary_set_string(m,"role","control");auto r=client->request(m);xpc_release(m);auto s=finish(r);if(s)return s;
    auto id=nextConnection++;if(!id)id=nextConnection++;clients[id]=std::move(client);*connection=id;return 0;}
void cueClose(uint32_t c){std::lock_guard<std::mutex> lock(mutex);clients.erase(c);}
uint32_t cueSubscribe(uint32_t c){std::lock_guard<std::mutex> lock(mutex);return finish(call(c,"subscribe"));}
uint32_t cueSnapshot(uint32_t c,uint32_t after,CueValue* values,uint32_t* count,CueStatus* state){
    if(!values || !count || !state || *count>8192)return 0xe00002c2;std::lock_guard<std::mutex> lock(mutex);auto it=clients.find(c);if(it==clients.end())return 0xe00002d9;
    auto m=message("snapshot");xpc_dictionary_set_uint64(m,"after",after);auto r=it->second->request(m);xpc_release(m);uint32_t error=status(r);size_t n=0,s=0;
    if(!error){auto data=xpc_dictionary_get_data(r,"values",&n);auto metadata=xpc_dictionary_get_data(r,"state",&s);
        if(n%sizeof(CueValue) || n>size_t(*count)*sizeof(CueValue) || s!=sizeof(CueStatus))error=0xe00002eb;
        else{if(n)memcpy(values,data,n);*count=uint32_t(n/sizeof(CueValue));memcpy(state,metadata,s);}}
    if(error)*count=0;if(r)xpc_release(r);return error;
}
uint32_t cueEdit(uint32_t c,CueValue v,uint64_t* ticket){if(!ticket || !cueValid(v))return 0xe00002c2;std::lock_guard<std::mutex> lock(mutex);auto it=clients.find(c);if(it==clients.end())return 0xe00002d9;
    auto m=message("edit");xpc_dictionary_set_data(m,"value",&v,sizeof(v));auto r=it->second->request(m);xpc_release(m);auto s=status(r);if(!s)*ticket=xpc_dictionary_get_uint64(r,"ticket");if(r)xpc_release(r);return s;}
uint32_t cueMeters(uint32_t,float* p){if(!p)return 0xe00002c2;memset(p,0,62*sizeof(float));return 0;}
uint32_t cueDSPMeters(uint32_t c,float* peaks,uint64_t* generation,uint32_t* count){if(!peaks || !generation || !count)return 0xe00002c2;std::lock_guard<std::mutex> lock(mutex);auto r=call(c,"meters");auto error=status(r);
    if(!error){size_t size=0;auto data=xpc_dictionary_get_data(r,"values",&size);auto n=xpc_dictionary_get_uint64(r,"count");if(size!=400*sizeof(float) || n>400)error=0xe00002eb;
        else{memcpy(peaks,data,size);*generation=xpc_dictionary_get_uint64(r,"generation");*count=uint32_t(n);}}
    if(r)xpc_release(r);return error;
}
int cueValid(CueValue v){return motu::validDSPWrite({v.key,v.bits,v.kind,v.revision});}
