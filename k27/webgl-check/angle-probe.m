#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdio.h>
static BOOL (*oldFamily)(id,SEL,NSInteger);
static BOOL diagnosticFamily(id self,SEL cmd,NSInteger f) {return f==2002?YES:oldFamily(self,cmd,f);}
int main(int argc,char **argv) { @autoreleasepool {
 id<MTLDevice> d=MTLCreateSystemDefaultDevice();
 printf("device=%s registry=%llu\n",d.name.UTF8String,d.registryID);
 for(int f=1001;f<=1009;f++) printf("family %d=%d\n",f,[d supportsFamily:f]);
 for(int f=2001;f<=2002;f++) {
  printf("family %d=%d\n",f,[d supportsFamily:f]);
  SEL s=NSSelectorFromString(@"droidvmFamilyBlockers:");
  if([d respondsToSelector:s]) printf("blockers=%s\n",[(NSString *)((id(*)(id,SEL,NSInteger))objc_msgSend)(d,s,f) UTF8String]);
 }
 if(argc>1){Method m=class_getInstanceMethod(object_getClass(d),@selector(supportsFamily:));oldFamily=(void*)method_getImplementation(m);method_setImplementation(m,(IMP)diagnosticFamily);printf("DIAGNOSTIC Mac2 override enabled\n");}
 void *lib=dlopen("/System/Library/Frameworks/WebKit.framework/Versions/A/Frameworks/WebCore.framework/Versions/A/Frameworks/libANGLE-shared.dylib",RTLD_NOW);
 printf("ANGLE=%p error=%s\n",lib,lib?"":dlerror());
 if(!lib)return 1;
 void *(*getDisplay)(unsigned,void*,const intptr_t*)=dlsym(lib,"EGL_GetPlatformDisplay");
 unsigned (*init)(void*,int*,int*)=dlsym(lib,"EGL_Initialize");
 unsigned (*error)(void)=dlsym(lib,"EGL_GetError");
 const char *(*query)(void*,int)=dlsym(lib,"EGL_QueryString");
 if(!getDisplay||!init||!error||!query){printf("exports unavailable\n");return 2;}
 intptr_t attrs[]={0x3203,0x3489,0x3038};
 void *disp=getDisplay(0x3202,0,attrs); int major=0,minor=0;
 printf("display=%p error=%x\n",disp,error());
 unsigned ok=init(disp,&major,&minor);
 printf("initialize=%u EGL=%d.%d error=%x vendor=%s\n",ok,major,minor,error(),ok?query(disp,0x3053):"none");
 if(ok) {
  unsigned (*choose)(void*,const int*,void**,int,int*)=dlsym(lib,"EGL_ChooseConfig");
  unsigned (*bind)(unsigned)=dlsym(lib,"EGL_BindAPI");
  void *(*create)(void*,void*,void*,const int*)=dlsym(lib,"EGL_CreateContext");
  unsigned (*make)(void*,void*,void*,void*)=dlsym(lib,"EGL_MakeCurrent");
  const unsigned char *(*string)(unsigned)=dlsym(lib,"GL_GetString");
  void (*clearColor)(float,float,float,float)=dlsym(lib,"GL_ClearColor");
  void (*clear)(unsigned)=dlsym(lib,"GL_Clear");
  void (*read)(int,int,int,int,unsigned,unsigned,void*)=dlsym(lib,"GL_ReadPixels");
  unsigned (*glerr)(void)=dlsym(lib,"GL_GetError");
  int ca[]={0x3040,4,0x3024,8,0x3023,8,0x3022,8,0x3021,8,0x3038},n=0;void *config=0;
  choose(disp,ca,&config,1,&n);bind(0x30a0);
  int ctxa[]={0x3098,2,0x3038};void *ctx=create(disp,config,0,ctxa);
  printf("configs=%d context=%p error=%x\n",n,ctx,error());
  if(ctx&&make(disp,0,0,ctx))printf("GL version=%s renderer=%s\n",string(0x1f02),string(0x1f01));
  (void)clearColor;(void)clear;(void)read;(void)glerr;
 }
 return ok?0:3;
}}
