// Minimal libc-less init for the kexec'd kernel's initrd: prints
// HELLO-FROM-KEXECD-INITRD to the console, then spins forever (the test
// harness kills qemu once it sees the marker).
const std = @import("std");
const linux = std.os.linux;

pub fn main() void {
    const msg = "HELLO-FROM-KEXECD-INITRD\n";
    _ = linux.write(1, msg, msg.len);

    // Never exit: the kernel panics if init dies, and the test harness
    // kills qemu once it has seen the marker.
    while (true) {}
}
