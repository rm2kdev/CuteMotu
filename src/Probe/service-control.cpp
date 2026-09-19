#include "Client.hpp"
#include <cstdio>
#include <string>
using namespace cute;
int main(int argc,const char** argv){Client c;const char* name=argc>2?argv[2]:serviceName;c.connect(name);auto r=c.call(argc>1?argv[1]:"status");if(status(r)){fprintf(stderr,"Service request failed: 0x%x\n",status(r));if(r)xpc_release(r);return 1;}
    char* text=xpc_copy_description(r);puts(text);free(text);xpc_release(r);return 0;}
