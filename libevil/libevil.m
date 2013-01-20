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

    // This is six kinds of wrong; we're just rewriting any registers that match the si_addr, and
    // are pointed into now-dead pages. The danger here ought to be obvious.
    for (int i = 0; i < patch_count; i++) {
        struct patch *p = &patches[i];

        if ((uintptr_t) info->si_addr < p->orig_addr)
            continue;

        if ((uintptr_t) info->si_addr >= p->orig_addr + p->mapped_size)
            continue;

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


static BOOL macho_iterate_segments (const void *header, void (^block)(const char segname[16], vm_address_t vmaddr, vm_size_t vmsize, BOOL *cont)) {
    const struct mach_header *header32 = (const struct mach_header *) header;
    const struct mach_header_64 *header64 = (const struct mach_header_64 *) header;
    struct load_command *cmd;
    uint32_t ncmds;

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
            return false;
    }

    for (uint32_t i = 0; cmd != NULL && i < ncmds; i++) {
        BOOL cont = true;

        /* 32-bit text segment */
        if (cmd->cmd == LC_SEGMENT) {
            struct segment_command *segment = (struct segment_command *) cmd;
            block(segment->segname, segment->vmaddr, segment->vmsize, &cont);
        }
        
        /* 64-bit text segment */
        else if (cmd->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *segment = (struct segment_command_64 *) cmd;            
            block(segment->segname, segment->vmaddr, segment->vmsize, &cont);
        }
        
        cmd = (struct load_command *) ((uint8_t *) cmd + cmd->cmdsize);
        
        if (!cont)
            break;
    }

    return true;
}

extern void *_sigtramp;

// Replace 'function' with 'newImp', and return an address at 'originalRentry' that
// may be used to call the original function.
kern_return_t evil_override_ptr (void *function, const void *newFunction, void **originalRentry) {
    __block kern_return_t kt;
    
    vm_address_t page = trunc_page((vm_address_t) function);
    assert(page != trunc_page((vm_address_t) _sigtramp));

    /* Determine the Mach-O image and size. */
    Dl_info dlinfo;
    if (dladdr(function, &dlinfo) == 0) {
        NSLog(@"dladdr() failed: %s", dlerror());
        return KERN_FAILURE;
    }

    vm_address_t image_addr = (vm_address_t) dlinfo.dli_fbase;
    __block vm_address_t image_end = image_addr;
    __block intptr_t image_slide = 0x0;
    bool ret = macho_iterate_segments(dlinfo.dli_fbase, ^(const char segname[16], vm_address_t vmaddr, vm_size_t vmsize, BOOL *cont) {
        if (vmaddr + vmsize > image_end)
            image_end = vmaddr + vmsize;

        // compute the slide. we could also get this iterating the images via dyld, but whatever.
        if (strcmp(segname, SEG_TEXT) == 0) {
            if (vmaddr < image_addr)
                image_slide = image_addr - vmaddr;
            else
                image_slide = vmaddr - image_addr;
        }
            
    });
    vm_address_t image_size = image_end - image_addr;

    if (!ret) {
        NSLog(@"Failed parsing Mach-O header");
        return KERN_FAILURE;
    }

    /* Allocate a single contigious block large enough for our purposes */
    vm_address_t target = 0x0;
    kt = vm_allocate(mach_task_self(), &target, image_size, VM_FLAGS_ANYWHERE);
    if (kt != KERN_SUCCESS) {
        NSLog(@"Failed reserving sufficient space");
        return KERN_FAILURE;
    }

    /* Remap the segments into place */
    macho_iterate_segments(dlinfo.dli_fbase, ^(const char segname[16], vm_address_t vmaddr, vm_size_t vmsize, BOOL *cont) {
        if (vmsize == 0)
            return;

        vm_address_t seg_source = vmaddr + image_slide;
        vm_address_t seg_target = target + (seg_source - image_addr);

        vm_prot_t cprot, mprot;
        kt = vm_remap(mach_task_self(),
                      &seg_target,
                      vmsize,
                      0x0,
                      VM_FLAGS_FIXED|VM_FLAGS_OVERWRITE,
                      mach_task_self(),
                      seg_source,
                      false,
                      &cprot,
                      &mprot,
                      VM_INHERIT_SHARE);
        if (kt != KERN_SUCCESS) {
            *cont = false;
            return;
        }
    });

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
    // succeeds, but then doesn't do anything. So instead, we overwrite the
    // target with a dead page.
    // There's a race condition between the vm_allocate and vm_protect.
#if 1
    // vm_deallocate(mach_task_self(), page, PAGE_SIZE);

    kt = vm_allocate(mach_task_self(), &page, PAGE_SIZE, VM_FLAGS_FIXED|VM_FLAGS_OVERWRITE);
    if (kt != KERN_SUCCESS) {
        NSLog(@"Failed reserving sufficient space");
        return KERN_FAILURE;
    }
    vm_protect(mach_task_self(), page, PAGE_SIZE, true, VM_PROT_NONE);

#else
    if (mprotect(page, PAGE_SIZE, PROT_NONE) != 0) {
        perror("mprotect");
        return KERN_FAILURE;
    }
#endif

    if (originalRentry)
        *originalRentry = (void *) (p->new_addr + (p->orig_fptr - p->orig_addr));

    return KERN_SUCCESS;
}