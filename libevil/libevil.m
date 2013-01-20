/*
 * Author: Landon Fuller <landonf@bikemonkey.org>
 *
 * Copyright (c) 2013 Plausible Labs Cooperative, Inc.
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation
 * files (the "Software"), to deal in the Software without
 * restriction, including without limitation the rights to use,
 * copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following
 * conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 * OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 */

//
// Don't ever use this code.
// It's not thread-safe, async-safe, or child-safe. It will
// destroy the universe and all things in it. It's also a terrible
// idea, and I intentionally avoided worrying about effeciency or
// correctness.
//
// There are ways to make this vaguely reliable, but I'm not telling.
// Don't use this code unless you know how to fix it yourself,
// and probably not even then. I mean it.
//
// You've been warned.
//

#import <signal.h>
#import <unistd.h>
#import <dlfcn.h>

#import <sys/mman.h>

#import <sys/ucontext.h>

#import <mach/mach.h>
#import <mach-o/loader.h>


struct patch {
    vm_address_t orig_addr;
    vm_address_t new_addr;

    vm_size_t mapped_size;

    vm_address_t orig_fptr;
    vm_address_t orig_fptr_nthumb; // low-order bit masked
    vm_address_t new_fptr;
};

static struct patch patches[128];
static size_t patch_count = 0;

static void page_mapper (int signo, siginfo_t *info, void *uapVoid) {
    ucontext_t *uap = uapVoid;
    uintptr_t pc = uap->uc_mcontext->__ss.__pc;

#if 0
    NSLog(@"Freak out with address: %p", info->si_addr);
    
    for (int i = 0; i < 15; i++) {
        uintptr_t rv = uap->uc_mcontext->__ss.__r[i];
        NSLog(@"r%d = %p", i, (void *) rv);
    }
#endif
    
    if (pc == (uintptr_t) info->si_addr) {
        for (int i = 0; i < patch_count; i++) {
            if (patches[i].orig_fptr_nthumb == pc) {
                uap->uc_mcontext->__ss.__pc = (uintptr_t) patches[i].new_fptr;
                return;
            }
        }

        for (int i = 0; i < patch_count; i++) {
            struct patch *p = &patches[i];
            if (pc >= p->orig_addr && pc < (p->orig_addr + p->mapped_size)) {
                uap->uc_mcontext->__ss.__pc = p->new_addr + (pc - p->orig_addr);
                return;
            }
        }
    }

#if 1
    // This is six kinds of wrong; we're just rewriting any values that map the si_addr, and
    // are pointed at our remapped space. The danger here ought to be obvious.
    for (int i = 0; i < patch_count; i++) {
        struct patch *p = &patches[i];

        // Disabling this sanity check is a hail-mary pass until we can implement correct
        // segment remapping.
#if 0
        if ((uintptr_t) info->si_addr < p->orig_addr)
            continue;

        if ((uintptr_t) info->si_addr >= p->orig_addr + p->mapped_size)
            continue;
#endif

        // XXX we abuse the r[] array here.
        for (int i = 0; i < 15; i++) {
            uintptr_t rv = uap->uc_mcontext->__ss.__r[i];
            if (rv == (uintptr_t) info->si_addr) {
                if (p->new_addr > p->orig_addr)
                    uap->uc_mcontext->__ss.__r[i] -= p->new_addr - p->orig_addr;
                else
                    uap->uc_mcontext->__ss.__r[i] += p->orig_addr - p->new_addr;
#if 0
                NSLog(@"Rewrite: %p -> %p", info->si_addr, (void *) uap->uc_mcontext->__ss.__r[i]);
#endif
            }
        }

        uintptr_t rv = uap->uc_mcontext->__ss.__lr;
        if (rv == (uintptr_t) info->si_addr) {
            uap->uc_mcontext->__ss.__lr += p->new_addr - p->orig_addr;
            if (p->new_addr > p->orig_addr)
                uap->uc_mcontext->__ss.__lr -= p->new_addr - p->orig_addr;
            else
                uap->uc_mcontext->__ss.__lr += p->orig_addr - p->new_addr;
        }
    }
#endif

    return;
}

void evil_init (void) {
    struct sigaction act;
    memset(&act, 0, sizeof(act));
    act.sa_sigaction = page_mapper;
    act.sa_flags = SA_SIGINFO;

    if (sigaction(SIGSEGV, &act, NULL) < 0) {
        perror("sigaction");
    }
    
    if (sigaction(SIGBUS, &act, NULL) < 0) {
        perror("sigaction");
    }
}


static vm_size_t macho_size (const void *header) {
    const struct mach_header *header32 = (const struct mach_header *) header;
    const struct mach_header_64 *header64 = (const struct mach_header_64 *) header;
    struct load_command *cmd;
    uint32_t ncmds;
    vm_size_t total_size = 0;

    /* Check for 32-bit/64-bit header and extract required values */
    switch (header32->magic) {
            /* 32-bit */
        case MH_MAGIC:
        case MH_CIGAM:
            ncmds = header32->ncmds;
            cmd = (struct load_command *) (header32 + 1);
            break;
            
            /* 64-bit */
        case MH_MAGIC_64:
        case MH_CIGAM_64:
            ncmds = header64->ncmds;
            cmd = (struct load_command *) (header64 + 1);
            break;
            
        default:
            NSLog(@"Invalid Mach-O header magic value: %x", header32->magic);
            return 0;
    }

    // This is all kinds of wrong. We actually need to be remapping each segment
    // individually into place. Instead we're trying to treat the image as one
    // huge mapping. This will not work out well.
    for (uint32_t i = 0; cmd != NULL && i < ncmds; i++) {
        /* 32-bit text segment */
        if (cmd->cmd == LC_SEGMENT) {
            struct segment_command *segment = (struct segment_command *) cmd;
            total_size += segment->vmsize;
        }
        
        /* 64-bit text segment */
        else if (cmd->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *segment = (struct segment_command_64 *) cmd;            
            total_size += segment->vmsize;
        }
        
        cmd = (struct load_command *) ((uint8_t *) cmd + cmd->cmdsize);
    }

    return total_size;
}

extern void *_sigtramp;

// Replace 'function' with 'newImp', and return an address at 'originalRentry' that
// may be used to call the original function.
kern_return_t evil_override_ptr (void *function, const void *newFunction, void **originalRentry) {
    kern_return_t kt;
    
    vm_address_t page = trunc_page((vm_address_t) function);
    assert(page != trunc_page((vm_address_t) _sigtramp));

    /* Determine the Mach-O image and size. We'll remap the whole darn thing */
    Dl_info dlinfo;
    if (dladdr(function, &dlinfo) == 0) {
        NSLog(@"dladdr() failed: %s", dlerror());
        return KERN_FAILURE;
    }
    vm_address_t image_addr = (vm_address_t) dlinfo.dli_fbase;
    vm_address_t image_size = macho_size(dlinfo.dli_fbase);
    if (image_size == 0) {
        NSLog(@"Failed parsing Mach-O header");
        return KERN_FAILURE;
    }


    /* Remap page and +-1 page. This will handle direct PC-relative loads, but will
     * break on anything fancier. Uh oh! */
    vm_address_t target = 0x0;
    vm_prot_t cprot, mprot;
    kt = vm_remap(mach_task_self(),
                  &target,
                  image_size,
                  0x0,
                  VM_FLAGS_ANYWHERE,
                  mach_task_self(),
                  image_addr,
                  false,
                  &cprot,
                  &mprot,
                  VM_INHERIT_SHARE);
    if (kt != KERN_SUCCESS) {
        NSLog(@"Failed to remap pages: %x", kt);
        return kt;
    }
    
    struct patch *p = &patches[patch_count];
    p->orig_addr = image_addr;
    p->new_addr = target;
    p->mapped_size = image_size;

    p->orig_fptr = (uintptr_t) function;
    p->orig_fptr_nthumb = ((uintptr_t) function) & ~1;
    p->new_fptr = (vm_address_t) newFunction;

    patch_count++;

    // For whatever reason we can't just remove PROT_WRITE with mprotect. It
    // succeeds, but then doesn't do anything. So instead, we just deallocate
    // it. I guess we could also try mapping in a NULL page or something to
    // prevent something new being allocated in its place, but whatever.
#if 1
    vm_deallocate(mach_task_self(), page, PAGE_SIZE);
#endif
    
#if 0
    if (mprotect(page, PAGE_SIZE, PROT_NONE) != 0) {
        perror("mprotect");
        return KERN_FAILURE;
    }
#endif

    if (originalRentry)
        *originalRentry = (void *) (p->new_addr + (p->orig_fptr - p->orig_addr));

    return KERN_SUCCESS;
}