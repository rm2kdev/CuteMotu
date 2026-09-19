#include "Client.hpp"
#include <mach/mach_time.h>
#include <sys/mman.h>
namespace cute {
Mapping::Mapping(xpc_object_t object){if(object && xpc_get_type(object)==XPC_TYPE_SHMEM){size=xpc_shmem_map(object,&address);if(!validate(address,size)){if(address && size)munmap(address,size);address=nullptr;size=0;}}}
Mapping::~Mapping(){if(address)munmap(address,size);}
bool MappingSlot::replace(std::unique_ptr<Mapping> next){collect();if(next && retired.size()>=8)return false;current.store(nullptr);if(owned)retired.push_back(std::move(owned));owned=std::move(next);current.store(owned.get());collect();return true;}
void MappingSlot::collect(){if(readers.load()==0)retired.clear();}
void Client::connect(const char* name){if(connection){xpc_connection_cancel(connection);xpc_release(connection);}if(queue)dispatch_release(queue);
    queue=dispatch_queue_create("org.cutemix.usbaudio.client",DISPATCH_QUEUE_SERIAL);
    connection=xpc_connection_create_mach_service(name,queue,0);xpc_connection_set_event_handler(connection,^(xpc_object_t){});xpc_connection_resume(connection);
}
Client::~Client(){if(connection){xpc_connection_cancel(connection);xpc_release(connection);}if(queue)dispatch_release(queue);}
xpc_object_t message(const char* op){auto m=xpc_dictionary_create(nullptr,nullptr,0);xpc_dictionary_set_uint64(m,"version",abiVersion);xpc_dictionary_set_string(m,"op",op);return m;}
struct Response {dispatch_semaphore_t semaphore=dispatch_semaphore_create(0);xpc_object_t reply=nullptr;~Response(){if(reply)xpc_release(reply);dispatch_release(semaphore);}};
xpc_object_t Client::request(xpc_object_t m,unsigned ms){if(!connection)return nullptr;auto result=std::make_shared<Response>();
    xpc_connection_send_message_with_reply(connection,m,queue,^(xpc_object_t r){if(xpc_get_type(r)==XPC_TYPE_DICTIONARY)result->reply=xpc_retain(r);dispatch_semaphore_signal(result->semaphore);});
    if(dispatch_semaphore_wait(result->semaphore,dispatch_time(DISPATCH_TIME_NOW,int64_t(ms)*NSEC_PER_MSEC)))return nullptr;
    return result->reply?xpc_retain(result->reply):nullptr;
}
xpc_object_t Client::call(const char* op,unsigned ms){auto m=message(op);auto r=request(m,ms);xpc_release(m);return r;}
uint32_t status(xpc_object_t r){if(!r || xpc_get_type(r)!=XPC_TYPE_DICTIONARY || xpc_dictionary_get_uint64(r,"version")!=abiVersion || !xpc_dictionary_get_value(r,"status"))return 0xe00002d9;return uint32_t(xpc_dictionary_get_uint64(r,"status"));}
double ticksPerSecond(){mach_timebase_info_data_t t{};mach_timebase_info(&t);return 1e9*double(t.denom)/t.numer;}
}
