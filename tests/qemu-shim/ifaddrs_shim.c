/* TEST shim of the QEMU bench (never installed on the router), loaded through LD_PRELOAD.
 * Under qemu-user, musl getifaddrs() loops on the netlink answer translated by qemu: PJSIP
 * pj_init() hung there, which used to keep PJSIP out of the bench. We return a single
 * interface, lo 127.0.0.1: the bench SIP client goes through the loopback. */
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <stdlib.h>
#include <string.h>

struct blk { struct ifaddrs ifa; struct sockaddr_in a, m; char name[8]; };

int getifaddrs(struct ifaddrs **out)
{
	struct blk *b = calloc(1, sizeof *b);
	if (!b) return -1;
	strcpy(b->name, "lo");
	b->a.sin_family = AF_INET; b->a.sin_addr.s_addr = htonl(0x7f000001);
	b->m.sin_family = AF_INET; b->m.sin_addr.s_addr = htonl(0xff000000);
	b->ifa.ifa_name = b->name;
	b->ifa.ifa_flags = IFF_UP | IFF_RUNNING | IFF_LOOPBACK;
	b->ifa.ifa_addr = (struct sockaddr *)&b->a;
	b->ifa.ifa_netmask = (struct sockaddr *)&b->m;
	*out = &b->ifa;
	return 0;
}

void freeifaddrs(struct ifaddrs *p) { free(p); }
