/* pi-keychain: store/retrieve Pi's credential blob in the iOS keychain, so
 * nothing with a long-lived secret has to sit in $HOME/.pi/agent/auth.json on
 * the preboot volume between runs.
 *
 *   pi-keychain set    read the blob (auth.json, whole file) on stdin, store it
 *   pi-keychain get    print the stored blob on stdout
 *   pi-keychain del    delete it (idempotent; missing item is not an error)
 *   pi-keychain probe  store/read/delete a throwaway item; "probe: ok"
 *
 * Item: kSecClassGenericPassword, service com.andi.pi-coding-agent.auth,
 * account "master", kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly. That
 * class is what buys the properties the plain-text file never had: the item is
 * wrapped in the device keybag, so "Erase All Content and Settings" destroys
 * it, it is excluded from backups and device-to-device restores, and it
 * survives iOS updates and jailbreak reinstalls (it lives on the data volume,
 * outside /var/jb and preboot).
 *
 * Unlike the sibling Claude Code port, Pi reads and writes auth.json itself,
 * so this helper does not own the credential -- the wrapper does the moving:
 * materialise the file from here before a run, store the file back here and
 * remove it after. The blob is the whole file, so every provider is covered at
 * once and this code stays provider-agnostic.
 *
 * Authorization comes from the signature: this binary is ldid-signed with the
 * package's entitlements.plist, whose keychain-access-groups entry names
 * com.andi.pi-coding-agent. Without that entry SecItemAdd returns -34018
 * (errSecMissingEntitlement). Measured on device (Dopamine, iOS 17.3): ad-hoc
 * binary -> -34018; entitled binary -> set/get/del clean; a second entitled
 * binary with a different cdhash reads the same item, which is what lets the
 * postinst probe (running as root) check the same item the wrapper (running as
 * mobile) keeps.
 *
 * Exit codes: 0 ok; 3 = no item stored; 1 = error (message on stderr).
 * Built like libshim.dylib -- macOS, iPhoneOS SDK, ldid with entitlements.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SERVICE "com.andi.pi-coding-agent.auth"
#define ACCOUNT "master"
#define PROBE_ACCOUNT "_probe"

static void die(const char *msg, OSStatus st) {
    if (st)
        fprintf(stderr, "keychain error %d: %s\n", (int)st, msg);
    else
        fprintf(stderr, "%s\n", msg);
    exit(1);
}

/* The named error people will actually hit: a rebuild forgotten its ldid
 * step, or a hand-rolled copy runs without the package's entitlements. */
static void die_status(OSStatus st, const char *what) {
    if (st == -34018) {
        fprintf(stderr,
                "keychain error -34018 (errSecMissingEntitlement) on %s: this "
                "binary is not signed with the package's entitlements.plist -- "
                "reinstall com.andi.pi-coding-agent, or re-sign with "
                "'ldid -S<libdir>/entitlements.plist <libdir>/pi-keychain'",
                what);
        exit(1);
    }
    fprintf(stderr, "keychain error %d on %s\n", (int)st, what);
    exit(1);
}

static char *read_stdin(size_t *out_len) {
    size_t cap = 4096, len = 0;
    char *buf = malloc(cap);
    if (!buf) die("out of memory", 0);
    for (;;) {
        if (len == cap) {
            cap *= 2;
            char *nb = realloc(buf, cap);
            if (!nb) die("out of memory", 0);
            buf = nb;
        }
        size_t n = fread(buf + len, 1, cap - len, stdin);
        len += n;
        if (n == 0) break;
    }
    *out_len = len;
    return buf;
}

static CFMutableDictionaryRef query_dict(const char *account) {
    CFMutableDictionaryRef q = CFDictionaryCreateMutable(
        NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionaryAddValue(q, kSecClass, kSecClassGenericPassword);
    CFDictionaryAddValue(q, kSecAttrService, CFSTR(SERVICE));
    CFStringRef acct = CFStringCreateWithCString(NULL, account, kCFStringEncodingUTF8);
    CFDictionaryAddValue(q, kSecAttrAccount, acct);
    CFRelease(acct);
    return q;
}

static int cmd_set(const char *account) {
    size_t len = 0;
    char *blob = read_stdin(&len);
    CFDataRef data = CFDataCreate(NULL, (const UInt8 *)blob, (CFIndex)len);
    free(blob);
    if (!data) die("out of memory", 0);

    CFMutableDictionaryRef add = query_dict(account);
    CFDictionaryAddValue(add, kSecValueData, data);
    CFDictionaryAddValue(add, kSecAttrAccessible,
                         kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly);

    OSStatus st = SecItemAdd(add, NULL);
    if (st == errSecDuplicateItem) {
        /* Update in place: no delete window in which a crash loses the
         * credential. Concurrent wrapper exits are last-writer-wins by
         * design; SecItemUpdate makes each write atomic. */
        CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(
            NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionaryAddValue(attrs, kSecValueData, data);
        CFDictionaryAddValue(attrs, kSecAttrAccessible,
                             kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly);
        CFMutableDictionaryRef q = query_dict(account);
        st = SecItemUpdate(q, attrs);
        CFRelease(q);
        CFRelease(attrs);
    }
    CFRelease(add);
    CFRelease(data);
    if (st != errSecSuccess) die_status(st, "set");
    return 0;
}

static int cmd_get(const char *account) {
    CFMutableDictionaryRef q = query_dict(account);
    CFDictionaryAddValue(q, kSecReturnData, kCFBooleanTrue);
    CFDictionaryAddValue(q, kSecMatchLimit, kSecMatchLimitOne);
    CFDataRef data = NULL;
    OSStatus st = SecItemCopyMatching(q, (CFTypeRef *)&data);
    CFRelease(q);
    if (st == errSecItemNotFound) return 3;
    if (st != errSecSuccess) die_status(st, "get");
    fwrite(CFDataGetBytePtr(data), 1, (size_t)CFDataGetLength(data), stdout);
    fflush(stdout);
    CFRelease(data);
    return 0;
}

static int cmd_del(const char *account) {
    CFMutableDictionaryRef q = query_dict(account);
    OSStatus st = SecItemDelete(q);
    CFRelease(q);
    if (st != errSecSuccess && st != errSecItemNotFound) die_status(st, "del");
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: pi-keychain set|get|del|probe\n");
        return 1;
    }
    const char *account = strcmp(argv[1], "probe") == 0 ? PROBE_ACCOUNT : ACCOUNT;

    if (strcmp(argv[1], "set") == 0)  return cmd_set(account);
    if (strcmp(argv[1], "get") == 0)  return cmd_get(account);
    if (strcmp(argv[1], "del") == 0)  return cmd_del(account);
    if (strcmp(argv[1], "probe") == 0) {
        /* A full round trip on a throwaway item. Used by the postinst to say
         * something honest about this device's keychain at install time. */
        const char *msg = "probe";
        CFDataRef data = CFDataCreate(NULL, (const UInt8 *)msg, 5);
        CFMutableDictionaryRef add = query_dict(account);
        CFDictionaryAddValue(add, kSecValueData, data);
        CFDictionaryAddValue(add, kSecAttrAccessible,
                             kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly);
        OSStatus st = SecItemAdd(add, NULL);
        if (st != errSecSuccess) die_status(st, "probe/set");
        CFRelease(add);
        CFRelease(data);
        if (cmd_del(account) != 0) die("probe cleanup failed", 0);
        printf("probe: ok\n");
        return 0;
    }
    fprintf(stderr, "usage: pi-keychain set|get|del|probe\n");
    return 1;
}
