libevil
-----------

You should not use this code. Seriously.

libevil uses VM memory protection and remapping tricks to allow for patching arbitrary functions on iOS/ARM. This is similar in function to mach\_override, except that libevil has to work without the ability to write to executable pages.

This is achieved as follows:

* All mapped segments of the executable to be patched are remapped to a new address for preservation.
* The target page containing the function to be patched is set to PROT\_NONE, triggering a crash if one attempts to execute anything in that page.
* A custom signal handler interprets the crash:
    * If the IP of the crashed thread points at a patched function, thread state is rewritten to point at the new user-supplied function.
    * If the IP of the crash thread points at some other address in the patched page, it is rewritten to execute from the
      mirrored copy of the binary.
    * If the si\_addr of the crash is within the patched page, all registers containing that address are rewritten to point
      at the mirrored copy of the binary.

The entire binary is remapped as to 'correctly' handle PC-relative addressing that would otherwise fail. There are still
innumerable ways that this code can explode in your face. Remember how I said not to use it?

A fancier implementation would involve performing instruction interpretation from the crashed page, rather than
letting the CPU execute from remapped pages. This would involve actually implementing an ARM emulator, which seems
like drastic overkill for a massive hack.

The implementation only supports ARM, so you can only test it out on your iOS device.

Example Usage
-----------

Here's an example of how you might patch the NSLog() function. This patch will affect both your own usage, and any system
or library code that calls NSLog().

First, define your replacement function, as well as a function pointer to hold a reference
that may be used to call the original NSLog() implementation:
    
    void (*orig_NSLog)(NSString *fmt, ...) = NULL;
     
    void my_NSLog (NSString *fmt, ...) {
        orig_NSLog(@"I'm in your computers, patching your strings ...");
    
        NSString *newFmt = [NSString stringWithFormat: @"[PATCHED]: %@", fmt];
        
        va_list ap;
        va_start(ap, fmt);
        NSLogv(newFmt, ap);
        va_end(ap);
    }

To actually apply the patch:

    - (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
        evil_init();
        evil_override_ptr(NSLog, my_NSLog, (void **) &orig_NSLog);
        NSLog(@"Print a string");
    }

If you run this code, you should see something like the following. Note that the OS usage of NSLog() has been patched, too:

    Jan 20 10:09:02 Spyglass testEvil[309] <Warning>: I'm in your computers, patching your strings ...
    Jan 20 10:09:02 Spyglass testEvil[309] <Warning>: [PATCHED]: Print a string
    Jan 20 10:09:02 Spyglass testEvil[309] <Warning>: I'm in your computers, patching your strings ...
    Jan 20 10:09:02 Spyglass testEvil[309] <Warning>: [PATCHED]: Application windows are expected to have a root view controller at the end of application launch 

This works by catching and 'correcting' the crash, so don't try to run the code under the debugger using Xcode. It will just helpfully note that you crashed trying to execute NSLog().
