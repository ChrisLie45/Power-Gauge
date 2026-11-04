// The one thing Swift cannot do itself: make the kernel's diagnostic system call. See CDiag.c.
// scripts/build.sh gives this header to swiftc as its bridging header; Package.swift makes it
// a module, CDiag, for editors and `swift build`.

#ifndef CDIAG_H
#define CDIAG_H

// Makes diagnostic call `selector` with `buffer`, and returns what the kernel returns: 1 for a
// selector it handled. Returns -1 without calling on any processor but x86_64.
long powergauge_diag(long selector, void *buffer);

#endif
