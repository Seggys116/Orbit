//
//  OrbitEarlyMallocZone.c
//  Orbit
//
//  Reserves the process's default malloc zone slot before AppKit exists, so
//  that dlopen'ing "Orbit Framework" later cannot crash the browser.
//
//  PartitionAlloc's static constructor
//  (allocator_shim_override_apple_default_zone.h,
//  InitializeDefaultMallocZoneWithPartitionAlloc) has two paths. The safe one
//  runs only when the zone named "DelegatingDefaultZoneForPartitionAlloc" is
//  already the default zone; it then swaps that placeholder out for the
//  PartitionAlloc zone and never touches the system zone. The other path
//  does malloc_zone_unregister(system_default_zone) followed by
//  malloc_zone_register(system_default_zone), and Chromium's own comment on
//  those two lines says that any concurrent free() of a system-zone pointer
//  in between hits "no zone found" and kills the process -- which is exactly
//  the [FATAL:allocator_shim_apple.cc(61)] crash Orbit was taking from
//  SkyLight's threads while the first window was being built.
//
//  Chromium's answer is partition_alloc::EarlyMallocZoneRegistration(), run
//  from the executable's main() while the process is still single-threaded.
//  Orbit's helper stub already does that (Chromium/Embedder/app/
//  orbit_main_mac.cc); the browser process is an Xcode-built Swift binary
//  that cannot link //base, so this is that function, ported to C and run as
//  an image initializer of the Orbit and OrbitDemo executables.
//
//  Keep kOrbitDelegatingZoneName in step with allocator_shim::
//  kDelegatingZoneName in
//  partition_alloc/shim/early_zone_registration_utils_apple.h -- the name is
//  the entire handshake.
//

#include <mach/mach.h>
#include <malloc/malloc.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

extern void abort_report_np(const char *fmt, ...);

static const char kOrbitDelegatingZoneName[] =
    "DelegatingDefaultZoneForPartitionAlloc";
static const char kOrbitPartitionAllocZoneName[] = "PartitionAlloc";

// allocator_shim::kZoneVersion for a macOS 13+ SDK: try_free_default present.
enum { kOrbitZoneVersion = 13 };

// Static storage duration is required: raw pointers go to libsystem_malloc.
static malloc_zone_t g_delegating_zone;
static malloc_introspection_t g_delegating_zone_introspect;
static malloc_zone_t *g_default_zone;

static void OrbitZoneFatal(const char *message) __attribute__((noreturn));
static void OrbitZoneFatal(const char *message) {
    abort_report_np("%s", message);
    abort();
}

static unsigned int OrbitMallocZonesOrDie(malloc_zone_t ***out_zones) {
    vm_address_t *zones = NULL;
    unsigned int zone_count = 0;
    if (malloc_get_all_zones(mach_task_self(), NULL, &zones, &zone_count) !=
        KERN_SUCCESS) {
        OrbitZoneFatal("Orbit: cannot enumerate this process's malloc zones.");
    }
    *out_zones = (malloc_zone_t **)zones;
    return zone_count;
}

// malloc_default_zone() returns the initial zone, not the default one; the
// default is the first element of the zone array.
static malloc_zone_t *OrbitDefaultMallocZoneOrDie(void) {
    malloc_zone_t **zones = NULL;
    unsigned int zone_count = OrbitMallocZonesOrDie(&zones);
    if (zone_count == 0) {
        OrbitZoneFatal("Orbit: this process has no registered malloc zones.");
    }
    return zones[0];
}

static bool OrbitIsZoneRegistered(const char *name) {
    malloc_zone_t **zones = NULL;
    unsigned int zone_count = OrbitMallocZonesOrDie(&zones);
    for (unsigned int i = 0; i < zone_count; ++i) {
        const char *zone_name = zones[i]->zone_name;
        if (zone_name != NULL && strcmp(zone_name, name) == 0) {
            return true;
        }
    }
    return false;
}

static void *OrbitDelegatingMalloc(malloc_zone_t *zone, size_t size) {
    return g_default_zone->malloc(g_default_zone, size);
}

static void *OrbitDelegatingCalloc(malloc_zone_t *zone,
                                   size_t num_items,
                                   size_t size) {
    return g_default_zone->calloc(g_default_zone, num_items, size);
}

static void *OrbitDelegatingValloc(malloc_zone_t *zone, size_t size) {
    return g_default_zone->valloc(g_default_zone, size);
}

static void *OrbitDelegatingRealloc(malloc_zone_t *zone,
                                    void *ptr,
                                    size_t size) {
    return g_default_zone->realloc(g_default_zone, ptr, size);
}

static unsigned OrbitDelegatingBatchMalloc(malloc_zone_t *zone,
                                           size_t size,
                                           void **results,
                                           unsigned num_requested) {
    return g_default_zone->batch_malloc(g_default_zone, size, results,
                                        num_requested);
}

static void *OrbitDelegatingMemalign(malloc_zone_t *zone,
                                     size_t alignment,
                                     size_t size) {
    return g_default_zone->memalign(g_default_zone, alignment, size);
}

// Always 0: this zone owns nothing, so libsystem_malloc skips it in free().
static size_t OrbitDelegatingSize(malloc_zone_t *zone, const void *ptr) {
    return 0;
}

// Unreachable through size() -> free(), but CoreFoundation calls
// malloc_zone_free(zone, ptr) directly on the default zone, so forward rather
// than crash. Same reasoning for the rest of the free family.
static void OrbitDelegatingFree(malloc_zone_t *zone, void *ptr) {
    g_default_zone->free(g_default_zone, ptr);
}

static void OrbitDelegatingFreeDefiniteSize(malloc_zone_t *zone,
                                            void *ptr,
                                            size_t size) {
    g_default_zone->free_definite_size(g_default_zone, ptr, size);
}

static void OrbitDelegatingBatchFree(malloc_zone_t *zone,
                                     void **to_be_freed,
                                     unsigned num_to_be_freed) {
    g_default_zone->batch_free(g_default_zone, to_be_freed, num_to_be_freed);
}

static void OrbitDelegatingTryFreeDefault(malloc_zone_t *zone, void *ptr) {
    g_default_zone->try_free_default(g_default_zone, ptr);
}

static size_t OrbitDelegatingPressureRelief(malloc_zone_t *zone, size_t goal) {
    return 0;
}

static kern_return_t OrbitDelegatingEnumerator(task_t task,
                                               void *context,
                                               unsigned type_mask,
                                               vm_address_t zone_address,
                                               memory_reader_t reader,
                                               vm_range_recorder_t recorder) {
    return KERN_SUCCESS;
}

// Real implementation needed: callers size arrays with it.
static size_t OrbitDelegatingGoodSize(malloc_zone_t *zone, size_t size) {
    return g_default_zone->introspect->good_size(g_default_zone, size);
}

static boolean_t OrbitDelegatingCheck(malloc_zone_t *zone) {
    return true;
}

static void OrbitDelegatingPrint(malloc_zone_t *zone, boolean_t verbose) {}

static void OrbitDelegatingLog(malloc_zone_t *zone, void *address) {}

// Deliberately not forwarded: the real zone is still registered and is locked
// on its own before fork(), and this zone has no state to lock.
static void OrbitDelegatingForceLock(malloc_zone_t *zone) {}

static void OrbitDelegatingForceUnlock(malloc_zone_t *zone) {}

static void OrbitDelegatingReinitLock(malloc_zone_t *zone) {}

static void OrbitDelegatingStatistics(malloc_zone_t *zone,
                                      malloc_statistics_t *stats) {}

static boolean_t OrbitDelegatingZoneLocked(malloc_zone_t *zone) {
    return false;
}

static boolean_t OrbitDelegatingEnableDischargeChecking(malloc_zone_t *zone) {
    return false;
}

static void OrbitDelegatingDisableDischargeChecking(malloc_zone_t *zone) {}

static void OrbitDelegatingDischarge(malloc_zone_t *zone, void *memory) {}

__attribute__((constructor(101))) static void OrbitInstallEarlyMallocZone(void) {
    // Already the default zone: nothing to reserve. Registering a second
    // placeholder in front of a live PartitionAlloc zone would break every
    // allocation the engine has already made.
    if (OrbitIsZoneRegistered(kOrbitPartitionAllocZoneName) ||
        OrbitIsZoneRegistered(kOrbitDelegatingZoneName)) {
        return;
    }

    malloc_zone_t *purgeable_zone = malloc_default_purgeable_zone();
    g_default_zone = OrbitDefaultMallocZoneOrDie();

    g_delegating_zone.malloc = OrbitDelegatingMalloc;
    g_delegating_zone.calloc = OrbitDelegatingCalloc;
    g_delegating_zone.valloc = OrbitDelegatingValloc;
    g_delegating_zone.realloc = OrbitDelegatingRealloc;
    g_delegating_zone.batch_malloc = OrbitDelegatingBatchMalloc;
    g_delegating_zone.memalign = OrbitDelegatingMemalign;
    g_delegating_zone.size = OrbitDelegatingSize;
    g_delegating_zone.free = OrbitDelegatingFree;
    g_delegating_zone.free_definite_size = OrbitDelegatingFreeDefiniteSize;
    g_delegating_zone.batch_free = OrbitDelegatingBatchFree;
    if (g_default_zone->version >= 13 && g_default_zone->try_free_default) {
        g_delegating_zone.try_free_default = OrbitDelegatingTryFreeDefault;
    }
    g_delegating_zone.pressure_relief = OrbitDelegatingPressureRelief;

    g_delegating_zone_introspect.enumerator = OrbitDelegatingEnumerator;
    g_delegating_zone_introspect.good_size = OrbitDelegatingGoodSize;
    g_delegating_zone_introspect.check = OrbitDelegatingCheck;
    g_delegating_zone_introspect.print = OrbitDelegatingPrint;
    g_delegating_zone_introspect.log = OrbitDelegatingLog;
    g_delegating_zone_introspect.force_lock = OrbitDelegatingForceLock;
    g_delegating_zone_introspect.force_unlock = OrbitDelegatingForceUnlock;
    g_delegating_zone_introspect.reinit_lock = OrbitDelegatingReinitLock;
    g_delegating_zone_introspect.statistics = OrbitDelegatingStatistics;
    g_delegating_zone_introspect.zone_locked = OrbitDelegatingZoneLocked;
    g_delegating_zone_introspect.enable_discharge_checking =
        OrbitDelegatingEnableDischargeChecking;
    g_delegating_zone_introspect.disable_discharge_checking =
        OrbitDelegatingDisableDischargeChecking;
    g_delegating_zone_introspect.discharge = OrbitDelegatingDischarge;

    g_delegating_zone.version = kOrbitZoneVersion;
    g_delegating_zone.introspect = &g_delegating_zone_introspect;
    g_delegating_zone.zone_name = kOrbitDelegatingZoneName;

    // register appends, unregister swaps the victim with the last entry, so
    // this leaves |delegating|...|default|purgeable| with the system zone
    // continuously registered throughout.
    malloc_zone_register(&g_delegating_zone);
    malloc_zone_unregister(g_default_zone);
    malloc_zone_register(g_default_zone);
    malloc_zone_unregister(purgeable_zone);
    malloc_zone_register(purgeable_zone);

    if (OrbitDefaultMallocZoneOrDie() != &g_delegating_zone) {
        OrbitZoneFatal(
            "Orbit: failed to install the delegating default malloc zone.");
    }
}
