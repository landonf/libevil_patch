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
// idea.
//

#import <signal.h>
#import <unistd.h>
#import <sys/ucontext.h>
#import <mach/mach.h>
#import <sys/mman.h>

struct patch {
    vm_address_t page_addr;
    vm_address_t new_page_addr;
    void *orig_fptr;
    void *new_fptr;
};

static struct patch patches[128];
static size_t patch_count = 0;

static void page_mapper (int signo, siginfo_t *info, void *uapVoid) {
    // SA_RESETHAND is broken on iOS
    // signal(SIGSEGV, SIG_DFL);
    // signal(SIGBUS, SIG_DFL);

    ucontext_t *uap = uapVoid;
    vm_address_t pc = uap->uc_mcontext->__ss.__pc;

    for (int i = 0; i < patch_count; i++) {
        if ((vm_address_t)patches[i].orig_fptr == pc) {
            uap->uc_mcontext->__ss.__pc = (uintptr_t) patches[i].new_fptr;
            return;
        }
    }

    for (int i = 0; i < patch_count; i++) {
        if (pc >= patches[i].page_addr && pc < (patches[i].page_addr + PAGE_SIZE)) {
            uap->uc_mcontext->__ss.__pc = patches[i].new_page_addr + (pc - patches[i].page_addr);
            return;
        }
    }

#if 0
    // This is six kinds of wrong; we're just rewriting any values that *look* like a pointer
    // into our remapped space, at the time of the crash.
    for (int i = 0; i < patch_count; i++) {
        for (int i = 0; i < 12; i++) {
            uintptr_t reg = uap->uc_mcontext->__ss.__r[i];
            if (reg >= patches[i].page_addr && reg < patches[i].page_addr + PAGE_SIZE) {
                uap->uc_mcontext->__ss.__r[i] = patches[i].new_page_addr + (reg - patches[i].page_addr);
            }
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



// Replace 'function' with 'newImp', and return an address at 'originalRentry' that
// may be used to call the original function.
kern_return_t evil_override_ptr (void *function, const void *newImp, void **originalRentry) {
    vm_address_t page = trunc_page(((uintptr_t)function));
    vm_address_t start = page - PAGE_SIZE;
    vm_address_t end = page + PAGE_SIZE;
    vm_address_t target = 0x0;
    vm_prot_t cprot, mprot;

    /* Remap page and +-1 page. This will handle direct PC-relative loads, but will
     * break on anything fancier. Uh oh! */
    kern_return_t kt;
    kt = vm_remap(mach_task_self(),
                  &target,
                  end-start,
                  0x0,
                  VM_FLAGS_ANYWHERE,
                  mach_task_self(),
                  start+PAGE_SIZE,
                  true,
                  &cprot,
                  &mprot,
                  VM_INHERIT_COPY);
    if (kt != KERN_SUCCESS) {
        NSLog(@"Failed to remap pages: %x", kt);
        return kt;
    }

    patches[patch_count].orig_fptr = (void *)(((uintptr_t)function) &~ 1);
    patches[patch_count].page_addr = page;
    patches[patch_count].new_fptr = newImp;
    patches[patch_count].new_page_addr = target + PAGE_SIZE;
    patch_count++;

#if 1
    vm_deallocate(mach_task_self(), page, PAGE_SIZE);
#endif
    
#if 0
    kt = vm_remap(mach_task_self(),
                  &page,
                  PAGE_SIZE,
                  0x0,
                  0,
                  mach_task_self(),
                  target,
                  false,
                  &cprot,
                  &mprot,
                  VM_INHERIT_COPY);
    if (kt != KERN_SUCCESS) {
        NSLog(@"Failed to remap NULL page: %x", kt);
        return kt;
    }
#endif
    
#if 0
    if (mprotect(page, PAGE_SIZE, PROT_NONE) != 0) {
        perror("mprotect");
        return KERN_FAILURE;
    }
#endif
    
#if 0
    vm_protect(mach_task_self(), page, PAGE_SIZE, true, VM_PROT_READ);
#endif

    *originalRentry = target + (function - page);

    return KERN_SUCCESS;
}