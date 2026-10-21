// Standalone macOS diagnostic; never linked into the app. See PrefillWarmupProbe.md.
// QWEN_METAL_ENTRY_NONCE renames generated MFA kernel entry points and their lookups,
// giving the probe fresh compiler-cache identities while preserving shader computations.
// Precompiled Metal libraries and non-MFA caches are unaffected.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <objc/runtime.h>
#import <mach/mach_time.h>
#include <stdatomic.h>
static _Atomic unsigned long long totals[3], counts[3];
static mach_timebase_info_data_t scale;
static id (*libraryIMP)(id,SEL,NSString*,MTLCompileOptions*,NSError**);
static id (*functionIMP)(id,SEL,NSString*);
static id (*specializedIMP)(id,SEL,NSString*,id,NSError**);
static char namesKey, constantsKey, shapeKey;
static char sourceKey, detailKey;
static _Atomic unsigned long long sourceCount;
static _Thread_local id activeNDArrayEncode;
static void (*ndArrayEncodeIMP)(id,SEL,id,id,id,id,id,id);
static NSDictionary *ndArrayShape(id value) {
  if (![value isKindOfClass:[MPSNDArray class]]) return @{@"class":value ? NSStringFromClass([value class]) : @"nil"};
  MPSNDArray *array=value;
  MPSNDArrayDescriptor *descriptor=array.descriptor;
  NSMutableArray *shape=[NSMutableArray array];
  for (NSUInteger i=0;i<descriptor.numberOfDimensions;i++) [shape addObject:@([descriptor lengthOfDimension:i])];
  return @{@"shape_fastest_first":shape,@"datatype":@(array.dataType)};
}
static void ndArrayEncode(id self,SEL cmd,id encoder,id buffer,id sources,id state,id destination,id dag) {
  id previous=activeNDArrayEncode;
  NSMutableArray *shapes=[NSMutableArray array];
  if ([sources isKindOfClass:[NSArray class]]) for (id source in sources) [shapes addObject:ndArrayShape(source)];
  activeNDArrayEncode=@{@"kernel_class":NSStringFromClass([self class]),@"sources":shapes,@"destination":ndArrayShape(destination)};
  ndArrayEncodeIMP(self,cmd,encoder,buffer,sources,state,destination,dag);
  activeNDArrayEncode=previous;
}
static void (*constantIMP)(id,SEL,const void*,MTLDataType,NSUInteger);
static void constant(id self,SEL cmd,const void *value,MTLDataType type,NSUInteger index) {
  NSNumber *number=nil;
  if (type==MTLDataTypeUInt) number=@(*(const uint32_t*)value);
  else if (type==MTLDataTypeInt) number=@(*(const int32_t*)value);
  else if (type==MTLDataTypeFloat) number=@(*(const float*)value);
  else if (type==MTLDataTypeBool) number=@(*(const bool*)value);
  else if (type==MTLDataTypeUShort) number=@(*(const uint16_t*)value);
  if (number) {
    NSMutableDictionary *values=objc_getAssociatedObject(self,&constantsKey);
    if (!values) { values=[NSMutableDictionary dictionary]; objc_setAssociatedObject(self,&constantsKey,values,OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    values[@(index)]=number;
  }
  constantIMP(self,cmd,value,type,index);
}
static NSString *renamed(id self,NSString *name) {
  NSSet *names=objc_getAssociatedObject(self,&namesKey);
  const char *nonce=getenv("QWEN_METAL_ENTRY_NONCE");
  return nonce && [names containsObject:name] ? [NSString stringWithFormat:@"dt_probe_%s_%@",nonce,name] : name;
}
static void attachDetail(id library,id function,NSString *name,id constants) {
  if (!function || !getenv("METAL_PROBE_DUMP_DIR")) return;
  NSMutableDictionary *values=[NSMutableDictionary dictionary];
  NSDictionary *captured=objc_getAssociatedObject(constants,&constantsKey);
  for (id key in captured) values[[key description]]=captured[key];
  NSDictionary *detail=@{@"name":name,@"constants":values,
    @"source":objc_getAssociatedObject(library,&sourceKey) ?: @"precompiled/unknown"};
  objc_setAssociatedObject(function,&detailKey,detail,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static id function(id self,SEL cmd,NSString *name) {
  id result=functionIMP(self,cmd,renamed(self,name)); attachDetail(self,result,name,nil); return result;
}
static id specialized(id self,SEL cmd,NSString *name,id constants,NSError **error) {
  id result=specializedIMP(self,cmd,renamed(self,name),constants,error);
  attachDetail(self,result,name,constants);
  NSDictionary *values=objc_getAssociatedObject(constants,&constantsKey);
  if (result && [name isEqualToString:@"int8_matmul"]) {
    NSString *shape=[NSString stringWithFormat:@"M=%@ N=%@ K=%@ strideA=%@ strideB=%@ strideC=%@ strideAScale=%@ stridePackedA=%@ leadingA=%@ leadingC=%@",values[@0],values[@1],values[@2],values[@15],values[@16],values[@17],values[@19],values[@21],values[@22],values[@23]];
    objc_setAssociatedObject(result,&shapeKey,shape,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return result;
}
static id (*pipelineIMP)(id,SEL,id,NSError**);
static id (*descriptorIMP)(id,SEL,id,MTLPipelineOption,id*,NSError**);
static void record(int kind, uint64_t start, const char *name) {
  uint64_t ns=(mach_absolute_time()-start)*scale.numer/scale.denom;
  atomic_fetch_add(&totals[kind],ns); atomic_fetch_add(&counts[kind],1);
  fprintf(stderr,"metal_compile kind=%d milliseconds=%.3f name=%s\n",kind,ns/1e6,name);
}
static id library(id self,SEL cmd,NSString *source,MTLCompileOptions *options,NSError **error) {
  NSString *sourcePath=nil;
  const char *dumpDirectory=getenv("METAL_PROBE_DUMP_DIR");
  if (dumpDirectory) {
    sourcePath=[NSString stringWithFormat:@"%s/library-%llu.metal",dumpDirectory,atomic_fetch_add(&sourceCount,1)];
    [source writeToFile:sourcePath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  }
  NSMutableSet *names=[NSMutableSet set];
  const char *entryNonce=getenv("QWEN_METAL_ENTRY_NONCE");
  if (entryNonce) {
    NSRegularExpression *regex=[NSRegularExpression regularExpressionWithPattern:@"\\bkernel\\s+void\\s+([A-Za-z_][A-Za-z0-9_]*)" options:0 error:nil];
    NSMutableString *prefix=[NSMutableString string];
    for (NSTextCheckingResult *match in [regex matchesInString:source options:0 range:NSMakeRange(0,source.length)]) {
      NSString *name=[source substringWithRange:[match rangeAtIndex:1]];
      if (![names containsObject:name]) [prefix appendFormat:@"#define %@ dt_probe_%s_%@\n",name,entryNonce,name];
      [names addObject:name];
    }
    source=[prefix stringByAppendingString:source];
  }
  uint64_t start=mach_absolute_time();
  id result=libraryIMP(self,cmd,source,options,error); record(0,start,"library");
  if (result && sourcePath) objc_setAssociatedObject(result,&sourceKey,sourcePath,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  if (result && entryNonce) {
    objc_setAssociatedObject(result,&namesKey,names,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      Method m=class_getInstanceMethod([result class],@selector(newFunctionWithName:));
      functionIMP=(void*)method_setImplementation(m,(IMP)function);
      m=class_getInstanceMethod([result class],@selector(newFunctionWithName:constantValues:error:));
      specializedIMP=(void*)method_setImplementation(m,(IMP)specialized);
    });
  }
  return result;
}
static void dumpDetail(id<MTLFunction> function) {
  if (!getenv("METAL_PROBE_DUMP_DIR")) return;
  NSDictionary *detail=objc_getAssociatedObject(function,&detailKey);
  NSString *name=detail[@"name"] ?: function.name;
  if (![name isEqualToString:@"strided_copy"] && ![name isEqualToString:@"swish_mul"] &&
      ![name isEqualToString:@"cmul"] &&
      ![name hasPrefix:@"dequantize_8i_rowwise_x_selected"] &&
      ![name isEqualToString:@"ndArrayIdentity"] && ![name hasPrefix:@"argmax_"] &&
      ![name hasPrefix:@"ccv_nnc_mfa_fast_fence"]) return;
  NSMutableDictionary *record=detail ? [detail mutableCopy] : [@{@"name":name} mutableCopy];
  NSArray *stack=[NSThread callStackSymbols];
  record[@"stack"]=[stack subarrayWithRange:NSMakeRange(0,MIN(stack.count,[name isEqualToString:@"ndArrayIdentity"] ? 64 : 18))];
  if (activeNDArrayEncode) record[@"ndarray_encode"]=activeNDArrayEncode;
  NSData *json=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:NULL];
  if (json) fprintf(stderr,"metal_pipeline_detail %.*s\n",(int)json.length,(const char*)json.bytes);
  [record release];
}
static id pipeline(id self,SEL cmd,id function,NSError **error) {
  uint64_t start=mach_absolute_time(); id result=pipelineIMP(self,cmd,function,error); record(1,start,[[(id<MTLFunction>)function name] UTF8String]); dumpDetail(function); return result;
}
static id descriptor(id self,SEL cmd,id desc,MTLPipelineOption options,id *reflection,NSError **error) {
  uint64_t start=mach_absolute_time(); id result=descriptorIMP(self,cmd,desc,options,reflection,error); record(2,start,[[(MTLComputePipelineDescriptor*)desc computeFunction].name UTF8String]);
  NSString *shape=objc_getAssociatedObject([(MTLComputePipelineDescriptor*)desc computeFunction],&shapeKey);
  if (shape) fprintf(stderr,"metal_matmul_shape %s\n",[shape UTF8String]);
  dumpDetail([(MTLComputePipelineDescriptor*)desc computeFunction]);
  return result;
}
__attribute__((constructor)) static void begin(void) {
  mach_timebase_info(&scale);
  @autoreleasepool {
    // Diagnostic-only hook, guarded for the current runtime's Objective-C ABI. It captures
    // logical array shapes while MPS constructs an otherwise opaque identity pipeline.
    if (getenv("METAL_PROBE_DUMP_DIR")) {
      SEL selector=NSSelectorFromString(@"encodeToMPSCommandEncoder:commandBuffer:sourceArrays:resultState:destinationArray:kernelDAGObject:");
      Method method=class_getInstanceMethod([MPSNDArrayMultiaryKernel class],selector);
      if (method && strcmp(method_getTypeEncoding(method),"v64@0:8@16@24@32@40@48@56")==0)
        ndArrayEncodeIMP=(void*)method_setImplementation(method,(IMP)ndArrayEncode);
    }
    id values=[MTLFunctionConstantValues new];
    Method cm=class_getInstanceMethod([values class],@selector(setConstantValue:type:atIndex:));
    constantIMP=(void*)method_setImplementation(cm,(IMP)constant);
    [values release];
    id device=MTLCreateSystemDefaultDevice(); Class cls=[device class];
    Method m=class_getInstanceMethod(cls,@selector(newLibraryWithSource:options:error:));
    libraryIMP=(void*)method_setImplementation(m,(IMP)library);
    m=class_getInstanceMethod(cls,@selector(newComputePipelineStateWithFunction:error:));
    pipelineIMP=(void*)method_setImplementation(m,(IMP)pipeline);
    m=class_getInstanceMethod(cls,@selector(newComputePipelineStateWithDescriptor:options:reflection:error:));
    descriptorIMP=(void*)method_setImplementation(m,(IMP)descriptor);
    fprintf(stderr,"metal_timing_device=%s\n",[[device name] UTF8String]);
    [device release];
  }
}
__attribute__((destructor)) static void finish(void) {
  for(int i=0;i<3;i++) fprintf(stderr,"metal_compile_total kind=%d count=%llu seconds=%.6f\n",i,atomic_load(&counts[i]),atomic_load(&totals[i])/1e9);
}
