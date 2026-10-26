/* The GLX 1.4 entry points gex's guest GL driver does not have, so that a
 * program linking them (libplasma's window thumbnails: glXCreatePixmap) links
 * and runs. gex's X server has no GLX drawables other than windows, and no
 * pixmaps or pbuffers to render into: each creation answers None (as a GLX
 * implementation does when it cannot make one) and the rest do nothing. */
#include <GL/glx.h>

GLXPixmap glXCreateGLXPixmap(Display *dpy, XVisualInfo *vis, Pixmap pixmap) { return None; }
void glXDestroyGLXPixmap(Display *dpy, GLXPixmap pix) {}
void glXCopyContext(Display *dpy, GLXContext src, GLXContext dst, unsigned long mask) {}
void glXUseXFont(Font font, int first, int count, int list) {}
GLXWindow glXCreateWindow(Display *dpy, GLXFBConfig config, Window win, const int *attribList) { return None; }
void glXDestroyWindow(Display *dpy, GLXWindow window) {}
GLXPixmap glXCreatePixmap(Display *dpy, GLXFBConfig config, Pixmap pixmap, const int *attribList) { return None; }
void glXDestroyPixmap(Display *dpy, GLXPixmap pixmap) {}
GLXPbuffer glXCreatePbuffer(Display *dpy, GLXFBConfig config, const int *attribList) { return None; }
void glXDestroyPbuffer(Display *dpy, GLXPbuffer pbuf) {}
int glXQueryContext(Display *dpy, GLXContext ctx, int attribute, int *value) { return GLX_BAD_CONTEXT; }
void glXSelectEvent(Display *dpy, GLXDrawable drawable, unsigned long mask) {}
void glXGetSelectedEvent(Display *dpy, GLXDrawable drawable, unsigned long *mask) { if (mask) *mask = 0; }
