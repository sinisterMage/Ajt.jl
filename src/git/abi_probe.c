/*
 * The only C Ajt owns, and it exists to be doubted.
 *
 * `src/git/c.zig` describes libgit2's structs by hand rather than through
 * `@cImport`, because Ajt does not merely CALL libgit2 -- it DEFINES a
 * `git_stream`, whose second member is the bitfield
 *
 *     unsigned int encrypted : 1, proxy_support : 1;
 *
 * A bitfield Zig cannot spell directly, and one wrong guess at its storage
 * shifts every function pointer after it: libgit2 would then call `read` where
 * `connect` belongs. That is not a link error and not a crash; it is silent
 * memory corruption inside a TLS handshake.
 *
 * So the layout is not asserted in a comment, it is measured. This file is
 * compiled by the same `zig cc`, against the same headers, into the test binary
 * only (`build.zig`), and hands back the C compiler's own `sizeof`, `offsetof`
 * and enum values. `c.zig`'s tests compare them with Zig's `@sizeOf` and
 * `@offsetOf`. A libgit2 that moves a field fails the suite instead of the
 * fetch.
 *
 * Indexed rather than one symbol per fact: a table stays a table, and adding a
 * row costs one line on each side.
 */

#include <stddef.h>
#include <string.h>

#include <git2.h>
#include <git2/sys/stream.h>

long ajt_abi_probe(int which)
{
	switch (which) {
	/* git_stream -- the struct Ajt implements rather than merely calls. */
	case 0: return (long)sizeof(git_stream);
	case 1: return (long)_Alignof(git_stream);
	case 2: return (long)offsetof(git_stream, version);
	case 3: return (long)offsetof(git_stream, timeout);
	case 4: return (long)offsetof(git_stream, connect_timeout);
	case 5: return (long)offsetof(git_stream, connect);
	case 6: return (long)offsetof(git_stream, certificate);
	case 7: return (long)offsetof(git_stream, set_proxy);
	case 8: return (long)offsetof(git_stream, read);
	case 9: return (long)offsetof(git_stream, write);
	case 10: return (long)offsetof(git_stream, close);
	case 11: return (long)offsetof(git_stream, free);

	/* git_stream_registration -- what we hand git_stream_register. */
	case 12: return (long)sizeof(git_stream_registration);
	case 13: return (long)offsetof(git_stream_registration, version);
	case 14: return (long)offsetof(git_stream_registration, init);
	case 15: return (long)offsetof(git_stream_registration, wrap);

	/*
	 * git_oid. 20 raw bytes and nothing else: the `type` prefix exists only
	 * under GIT_EXPERIMENTAL_SHA256, which this build never defines. If that
	 * ever changed, every oid Ajt read would be off by one byte.
	 */
	case 16: return (long)sizeof(git_oid);
	case 17: return (long)_Alignof(git_oid);
	case 18: return (long)offsetof(git_oid, id);

	/* git_error, read on every failure path. */
	case 19: return (long)sizeof(git_error);
	case 20: return (long)offsetof(git_error, message);
	case 21: return (long)offsetof(git_error, klass);

	/* git_strarray -- how refspecs go in. */
	case 22: return (long)sizeof(git_strarray);
	case 23: return (long)offsetof(git_strarray, strings);
	case 24: return (long)offsetof(git_strarray, count);

	/* git_remote_head -- how `ls-remote` comes back. */
	case 25: return (long)sizeof(git_remote_head);
	case 26: return (long)offsetof(git_remote_head, local);
	case 27: return (long)offsetof(git_remote_head, oid);
	case 28: return (long)offsetof(git_remote_head, loid);
	case 29: return (long)offsetof(git_remote_head, name);
	case 30: return (long)offsetof(git_remote_head, symref_target);

	/* Enum values that c.zig spells as plain integers. */
	case 31: return GIT_STREAM_VERSION;
	case 32: return GIT_STREAM_TLS;
	case 33: return GIT_ENOTFOUND;
	case 34: return GIT_EEXISTS;
	case 35: return GIT_OPT_ENABLE_STRICT_HASH_VERIFICATION;
	case 36: return GIT_OPT_SET_SERVER_TIMEOUT;
	case 37: return GIT_OPT_SET_SERVER_CONNECT_TIMEOUT;
	case 38: return GIT_FEATURE_HTTPS;
	case 39: return GIT_FEATURE_SSH;
	case 40: return GIT_OBJECT_ANY;
	case 41: return GIT_OBJECT_COMMIT;
	case 42: return GIT_OBJECT_TREE;
	case 43: return GIT_OBJECT_BLOB;
	case 44: return GIT_OBJECT_TAG;
	case 45: return GIT_ERROR_NET;
	case 46: return GIT_ERROR_SSL;
	case 47: return GIT_DIRECTION_FETCH;
	case 49: return GIT_ERROR_NOMEMORY;

	/*
	 * git_filemode_t. What `materialise` switches on: get one of these wrong
	 * and a symlink is written as a regular file, or a submodule is written
	 * as an empty directory instead of being refused -- both of which produce
	 * a directory that does not hash to the tree it came from, several steps
	 * away from the cause.
	 */
	case 50: return GIT_FILEMODE_UNREADABLE;
	case 51: return GIT_FILEMODE_TREE;
	case 52: return GIT_FILEMODE_BLOB;
	case 53: return GIT_FILEMODE_BLOB_EXECUTABLE;
	case 54: return GIT_FILEMODE_LINK;
	case 55: return GIT_FILEMODE_COMMIT;

	/* The landmark: a fact the Zig side knows independently. */
	case 48: return (long)sizeof(size_t);

	default: return -0x7fffffffL;
	}
}

/*
 * The bitfield, which `offsetof` cannot reach.
 *
 * Zeroes a `git_stream`, sets the two one-bit members, and returns the first
 * eight bytes as an integer -- `version` and whatever storage unit the two bits
 * landed in. `c.zig` builds the same value from its own struct and compares, so
 * the test proves the WHOLE prefix agrees (offset, width, and which end of the
 * unit bit zero is on) rather than just that a field exists.
 */
unsigned long long ajt_abi_stream_prefix(int encrypted, int proxy_support)
{
	git_stream s;
	unsigned char *p = (unsigned char *)&s;
	unsigned long long v = 0;
	size_t i;

	memset(&s, 0, sizeof(s));
	s.encrypted = (unsigned int)encrypted;
	s.proxy_support = (unsigned int)proxy_support;

	for (i = 0; i < 8 && i < sizeof(s); i++)
		v |= ((unsigned long long)p[i]) << (8 * i);

	return v;
}
