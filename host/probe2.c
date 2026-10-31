#include <stdio.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
int main(int argc,char**argv){
  const char*p=argv[1];
  int fd=open(p,O_RDONLY);
  printf("open(%s)=%d\n",p,fd);
  if(fd>=0) close(fd);
  void*h=dlopen(p,RTLD_NOW);
  printf("dlopen=%p err=%s\n",h,h?"":dlerror());
  return 0;
}
