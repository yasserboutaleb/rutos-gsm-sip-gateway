/* Minimal ANSI/VT100 termcap replacing libncursesw.so.6 in the rut360gw embedded runtime.
 * libedit imports only these 6 functions from it, for the interactive "asterisk -r" console
 * (rut360gw-cli without arguments). The firmware has no terminfo database: even with the real
 * library, libedit falls back to a minimal terminal. The VT100 sequences below are enough. */
#include <stdio.h>
static const char *const T[][2] = {
	{"cl", "\033[H\033[2J"}, {"cm", "\033[%i%d;%dH"}, {"ce", "\033[K"}, {"cd", "\033[J"}, {"up", "\033[A"}, {"do", "\n"},
	{"nd", "\033[C"}, {"le", "\b"}, {"bl", "\a"}, {"cr", "\r"}, {"dc", "\033[P"}, {"ic", "\033[@"}, {"ho", "\033[H"},
	{"ku", "\033[A"}, {"kd", "\033[B"}, {"kl", "\033[D"}, {"kr", "\033[C"}, {"kh", "\033[1~"}, {"@7", "\033[4~"}, {"kD", "\033[3~"},
	{"DC", "\033[%dP"}, {"IC", "\033[%d@"}, {"UP", "\033[%dA"}, {"DO", "\033[%dB"}, {"LE", "\033[%dD"}, {"RI", "\033[%dC"},
	{"so", "\033[7m"}, {"se", "\033[27m"}, {"me", "\033[0m"}, {"md", "\033[1m"}, {0, 0}};
int tgetent(char *bp, const char *name) { (void)bp; (void)name; return 1; }
int tgetflag(const char *id) { return (id[0] == 'a' && id[1] == 'm') || (id[0] == 'x' && id[1] == 'n') || (id[0] == 'k' && id[1] == 'm'); }
int tgetnum(const char *id) { if (id[0] == 'c' && id[1] == 'o') return 80; if (id[0] == 'l' && id[1] == 'i') return 24; return -1; }
char *tgetstr(const char *id, char **area) {
	int i; (void)area;
	for (i = 0; T[i][0]; i++) if (T[i][0][0] == id[0] && T[i][0][1] == id[1]) return (char *)T[i][1];
	return 0;
}
char *tgoto(const char *cap, int col, int row) {
	static char buf[48]; char *o = buf; int a[2], n = 0, inc = 0; a[0] = row; a[1] = col;
	if (!cap) return 0;
	for (; *cap && o < buf + 36; cap++) {
		if (*cap != '%') { *o++ = *cap; continue; }
		cap++;
		if (*cap == 'i') inc = 1;
		else if (*cap == 'd') { o += sprintf(o, "%d", a[n < 2 ? n : 1] + inc); n++; }
		else if (*cap == '%') *o++ = '%';
		else if (!*cap) break;
	}
	*o = 0; return buf;
}
int tputs(const char *s, int affcnt, int (*putc_)(int)) {
	(void)affcnt; if (!s) return -1;
	while (*s >= '0' && *s <= '9') s++;  /* padding delay ignored */
	if (*s == '*') s++;
	while (*s) putc_((unsigned char)*s++);
	return 0;
}
