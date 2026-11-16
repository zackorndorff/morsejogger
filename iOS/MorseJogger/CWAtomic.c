//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>

typedef struct { _Atomic(int64_t) value; } CWAtomicInt64;

void *cwAtomicInt64Create(int64_t initialValue) {
    CWAtomicInt64 *storage = malloc(sizeof(CWAtomicInt64));
    if (storage != NULL) atomic_init(&storage->value, initialValue);
    return storage;
}

void cwAtomicInt64Destroy(void *opaque) { free(opaque); }
int cwAtomicInt64IsLockFree(void *opaque) {
    return opaque != NULL && atomic_is_lock_free(&((CWAtomicInt64 *)opaque)->value);
}
int64_t cwAtomicInt64LoadRelaxed(void *opaque) {
    return atomic_load_explicit(&((CWAtomicInt64 *)opaque)->value, memory_order_relaxed);
}
int64_t cwAtomicInt64LoadAcquire(void *opaque) {
    return atomic_load_explicit(&((CWAtomicInt64 *)opaque)->value, memory_order_acquire);
}
void cwAtomicInt64StoreRelaxed(void *opaque, int64_t value) {
    atomic_store_explicit(&((CWAtomicInt64 *)opaque)->value, value, memory_order_relaxed);
}
void cwAtomicInt64StoreRelease(void *opaque, int64_t value) {
    atomic_store_explicit(&((CWAtomicInt64 *)opaque)->value, value, memory_order_release);
}
int64_t cwAtomicInt64FetchAddAcqRel(void *opaque, int64_t value) {
    return atomic_fetch_add_explicit(&((CWAtomicInt64 *)opaque)->value, value, memory_order_acq_rel);
}
int64_t cwAtomicInt64FetchAddRelease(void *opaque, int64_t value) {
    return atomic_fetch_add_explicit(&((CWAtomicInt64 *)opaque)->value, value, memory_order_release);
}
