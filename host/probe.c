#include <stdio.h>
#include <dlfcn.h>
int main(int argc,char**argv){
  const char*p = argv[1];
  void*h=dlopen(p,RTLD_NOW);
  printf("dlopen(%s) -> %p err=%s\n",p,h,h?"":dlerror());
  if(!h) return 1;
  const char*names[]={"CCDriverCreate","CCDriverCreateJobs","CCJobExecuteJob","CCSwiftCompilerJobExecute","CCSDKCreateWithDirectoryURL","CCDriverCopySysrootURL"};
  for(unsigned i=0;i<sizeof(names)/sizeof(*names);i++) printf("  %s = %p\n",names[i],dlsym(h,names[i]));
  return 0;
}
