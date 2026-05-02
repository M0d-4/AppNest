// Based on: https://blog.xpnsec.com/restoring-dyld-memory-loading
// https://github.com/xpn/DyldDeNeuralyzer/blob/main/DyldDeNeuralyzer/DyldPatch/dyldpatch.m

#import <Foundation/Foundation.h>

#include <dlfcn.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach-o/dyld.h>
#include <mach-o/dyld_images.h>
#include <sys/syscall.h>

#include "dyld_bypass_validation.h"
#include "utils.h"

extern void EKJITLessHook(void* _target, void* _replacement, void** orig);

#define ASM(...) __asm__(#__VA_ARGS__)
// ldr x8, value; br x8; value: .ascii "\x41\x42\x43\x44\x45\x46\x47\x48"
//static char patch[] = {0x88,0x00,0x00,0x58,0x00,0x01,0x1f,0xd6,0x1f,0x20,0x03,0xd5,0x1f,0x20,0x03,0xd5,0x41,0x41,0x41,0x41,0x41,0x41,0x41,0x41};

typedef int (*fcntl_p)(int fildes, int cmd, void* param);
typedef void* (*mmap_p)(void *addr, size_t len, int prot, int flags, int fd, off_t offset);

static fcntl_p orig_fcntl = 0;

extern void* __mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset);
extern int __fcntl(int fildes, int cmd, void* param);

// Originated from _kernelrpc_mach_vm_protect_trap
ASM(
.global _builtin_vm_protect \n
_builtin_vm_protect:     \n
    mov x16, #-0xe       \n
    svc #0x80            \n
    ret
);

static bool redirectFunction(char *name, void *patchAddr, void *target, void **orig) {
    EKJITLessHook(patchAddr, target, orig);

    NSLog(@"[DyldLVBypass] hook %s succeed!", name);
    return TRUE;
}

// mmap

static void* common_hooked_mmap(mmap_p orig, void *addr, size_t len, int prot, int flags, int fd, off_t offset) {
    void *map = orig(addr, len, prot, flags, fd, offset);
    if (map == MAP_FAILED && fd && (prot & PROT_EXEC)) {
        map = orig(addr, len, PROT_READ | PROT_WRITE, flags | MAP_PRIVATE | MAP_ANON, 0, 0);
        void *memoryLoadedFile = orig(NULL, len, PROT_READ, MAP_PRIVATE, fd, offset);
        memcpy(map, memoryLoadedFile, len);
        munmap(memoryLoadedFile, len);
        mprotect(map, len, prot);
    }
    return map;
}

static void* hooked_dyld_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset) {
    return common_hooked_mmap(__mmap, addr, len, prot, flags, fd, offset);
}

// fcntl

static int common_hooked_fcntl(fcntl_p orig, int fildes, int cmd, void *param) {
    if (cmd == F_ADDFILESIGS_RETURN) {
        char filePath[PATH_MAX];
        bzero(filePath, PATH_MAX);

        // Check if the file is our "in-memory" file
        if (orig(fildes, F_GETPATH, filePath) != -1) {
            const char *homeDir = getenv("LC_HOME_PATH") ?: getenv("HOME");
            if (!strncmp(filePath, homeDir, strlen(homeDir))) {
                fsignatures_t *fsig = (fsignatures_t*)param;
                // called to check that cert covers file.. so we'll make it cover everything ;)
                fsig->fs_file_start = 0xFFFFFFFF;
                return 0;
            }
        }
    }

    // Signature sanity check by dyld
    else if (cmd == F_CHECK_LV) {
        // Just say everything is fine
        return 0;
    }

    // If for another command or file, we pass through
    return orig(fildes, cmd, param);
}

static int hooked_dyld_fcntl(int fildes, int cmd, void *param) {
    return common_hooked_fcntl(orig_fcntl ? orig_fcntl : __fcntl, fildes, cmd, param);
}

char *searchDyldFunction(char *base, char *signature, int length) {
    char *patchAddr = NULL;
    for(int i=0; i < 0x80000; i+=4) {
        if (base[i] == signature[0] && memcmp(base+i, signature, length) == 0) {
            patchAddr = base + i;
            break;
        }
    }
    return patchAddr;
}

void init_bypassDyldLibValidation(void) {
    static BOOL bypassed;
    if (bypassed) return;
    bypassed = YES;

    NSLog(@"[DyldLVBypass] init");

    // Modifying exec page during execution may cause SIGBUS, so ignore it now
    // Only comment this out if only one thread (main) is running
    //signal(SIGBUS, SIG_IGN);

    searchDyldFunctions();
    redirectFunction("dyld_fcntl", orig_dyld_fcntl, hooked_dyld_fcntl, NULL);
    redirectFunction("dyld_mmap", orig_dyld_mmap, hooked_dyld_mmap, NULL);
}

void searchDyldFunctions(void) {
    if(orig_dyld_fcntl && orig_dyld_mmap) return;

    // TODO: cache offset and litehook_find_dsc_symbol
    char *dyldBase = (char *)_alt_dyld_get_all_image_infos()->dyldImageLoadAddress;
    orig_dyld_fcntl = (void *)searchDyldFunction(dyldBase, fcntlSig, sizeof(fcntlSig));
    orig_dyld_mmap = (void *)searchDyldFunction(dyldBase, mmapSig, sizeof(mmapSig));

    // dopamine already hooked it, try to find its hook instead
    if(!orig_dyld_fcntl) {
        char* fcntlAddr = 0;
        // search all syscalls and see if the the instruction before it is a branch instruction
        for(int i=0; i < 0x80000; i+=4) {
            if (dyldBase[i] == syscallSig[0] && memcmp(dyldBase+i, syscallSig, 4) == 0) {
                char* syscallAddr = dyldBase + i;
                uint32_t* prev = (uint32_t*)(syscallAddr - 4);
                if(*prev >> 26 == 0x5) {
                    fcntlAddr = (char*)prev;
                    break;
                }
            }
        }

        if(fcntlAddr) {
            uint32_t* inst = (uint32_t*)fcntlAddr;
            int32_t offset = ((int32_t)((*inst)<<6))>>4;
            NSLog(@"[DyldLVBypass] Dopamine hook offset = %x", offset);
            orig_fcntl = (void*)((char*)fcntlAddr + offset);
            orig_dyld_fcntl = (void *)fcntlAddr;
        } else {
            NSLog(@"[DyldLVBypass] Dopamine hook not found");
        }
    }
}
