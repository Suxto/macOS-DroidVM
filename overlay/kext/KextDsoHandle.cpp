// SPDX-License-Identifier: BSD-2-Clause-Patent
// __dso_handle for a native kext: the kernel supplies __cxa_atexit but no
// dso token, and a driver with a C++ static initializer references one.
// The token is only an identity for the atexit registration, so a kext-local
// object works.
extern "C" {
void *__dso_handle = &__dso_handle;
}
