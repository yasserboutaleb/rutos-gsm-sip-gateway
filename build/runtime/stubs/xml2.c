/* Stub libxml2.so.2 for the rut360gw embedded runtime.
 * The asterisk binary imports these 30 functions and the xmlFree variable, but only calls them
 * for the XML documentation (xmldoc), disabled at build time (--disable-xmldoc):
 * no .xml file is shipped. musl binds everything at load time: a missing symbol
 * prevents Asterisk from starting (closure check in build/runtime/assemble.py). */
#include <stdlib.h>
/* xmlFree is a VARIABLE (function pointer), copied into the executable (R_MIPS_COPY) */
void (*xmlFree)(void *) = free;
void xmlCheckVersion(int v) { (void)v; }
void xmlCleanupParser(void) {}
void xmlFreeDoc(void *d) { (void)d; }
void xmlFreeNode(void *n) { (void)n; }
void xmlXPathFreeContext(void *c) { (void)c; }
void xmlXPathFreeObject(void *o) { (void)o; }
void xmlNodeSetContent(void *n, const void *c) { (void)n; (void)c; }
void xmlNodeSetName(void *n, const void *c) { (void)n; (void)c; }
void xmlDocDumpFormatMemory(void *d, void **m, int *s, int f) { (void)d; (void)f; if (m) *m = 0; if (s) *s = 0; }
int xmlSubstituteEntitiesDefault(int v) { (void)v; return 0; }
long xmlXPathOrderDocElems(void *d) { (void)d; return 0; }
/* constructors and readers: clean failure (NULL) */
void *xmlAddChild(void) { return 0; }
void *xmlAddChildList(void) { return 0; }
void *xmlCopyNodeList(void) { return 0; }
void *xmlDocGetRootElement(void) { return 0; }
void *xmlDocSetRootElement(void) { return 0; }
void *xmlGetProp(void) { return 0; }
void *xmlNewChild(void) { return 0; }
void *xmlNewDoc(void) { return 0; }
void *xmlNewNode(void) { return 0; }
void *xmlNodeGetContent(void) { return 0; }
void *xmlParseMemory(void) { return 0; }
void *xmlReadFile(void) { return 0; }
void *xmlSearchNs(void) { return 0; }
void *xmlSetProp(void) { return 0; }
void *xmlXPathEvalExpression(void) { return 0; }
void *xmlXPathNewContext(void) { return 0; }
int xmlDocDump(void) { return -1; }
int xmlXIncludeProcess(void) { return -1; }
int xmlXPathRegisterNs(void) { return -1; }
