#pragma once
#include "tokenizer/arctic_tokenizer.h"
#include "ort.h"
#include <chrono>
#include <cmath>
#include <memory>
#include <stdexcept>
#include <vector>
class EmbeddingEngine {
    const OrtApi *api=OrtGetApiBase()->GetApi(ORT_API_VERSION);
    OrtEnv *env=nullptr;
    OrtSessionOptions *opts=nullptr;
    OrtSession *session=nullptr;
    OrtMemoryInfo *mem=nullptr;
    std::unique_ptr<lc_arctic::Tokenizer> tokenizer;
    void check(OrtStatus *s,const char *stage) {
        if(s){api->ReleaseStatus(s);throw std::runtime_error(stage);}
    }
    void close() {
        if(mem) api->ReleaseMemoryInfo(mem);
        if(session) api->ReleaseSession(session);
        if(opts) api->ReleaseSessionOptions(opts);
        if(env) api->ReleaseEnv(env);
    }
    struct Outputs {
        const OrtApi *api;
        OrtValue *input[2]={}, *result=nullptr;
        OrtTensorTypeAndShapeInfo *info=nullptr;
        ~Outputs(){
            if(info) api->ReleaseTensorTypeAndShapeInfo(info);
            if(result) api->ReleaseValue(result);
            for(auto *v:input) if(v) api->ReleaseValue(v);
        }
    };
public:
    double tokenizerMs=0,sessionMs=0;
    explicit EmbeddingEngine(const std::string &root) {
        auto tick=std::chrono::steady_clock::now();
        tokenizer=lc_arctic::Tokenizer::loadJSON(root+"/tokenizer.json");
        if(!tokenizer) throw std::runtime_error("embedding_load");
        auto loaded=std::chrono::steady_clock::now();
        tokenizerMs=std::chrono::duration<double,std::milli>(loaded-tick).count();
        try {
            const char *stage="embedding_load";
            check(api->CreateEnv(ORT_LOGGING_LEVEL_FATAL,"embedding",&env),stage);
            check(api->CreateSessionOptions(&opts),stage);
            int threads=getenv("LC_ARCTIC_THREADS") && std::string(getenv("LC_ARCTIC_THREADS"))=="2"?2:4;
            check(api->SetIntraOpNumThreads(opts,threads),stage);
            check(api->SetInterOpNumThreads(opts,1),stage);
            check(api->SetSessionGraphOptimizationLevel(opts,ORT_ENABLE_ALL),stage);
            if(getenv("LC_ARCTIC_NO_ARENA")){
                check(api->DisableCpuMemArena(opts),stage);
                check(api->DisableMemPattern(opts),stage);
            }
            check(api->CreateSession(env,(root+"/ms-model_int8.onnx").c_str(),opts,&session),stage);
            check(api->CreateCpuMemoryInfo(OrtArenaAllocator,OrtMemTypeDefault,&mem),stage);
            sessionMs=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-loaded).count();
        }catch(...){close();throw;}
    }
    ~EmbeddingEngine(){close();}
    NSArray *embed(NSString *s, NSString *role) {
        if(![s isKindOfClass:NSString.class]) throw std::runtime_error("text_size");
        NSData *bytes=[s dataUsingEncoding:NSUTF8StringEncoding];
        if(!bytes.length || bytes.length>100000) throw std::runtime_error("text_size");
        std::string text((const char *)bytes.bytes,bytes.length);
        if([role isEqual:@"query"]){
            if(text.compare(0,7,"query: ")!=0)text.insert(0,"query: ");
        } else if(![role isEqual:@"document"]) throw std::runtime_error("embedding_decode");
        std::vector<int64_t> ids;
        if(tokenizer->encode(text,ids,8192)!=lc_arctic::Tokenizer::Result::ok)throw std::runtime_error("token_limit");
        std::vector<int64_t> mask(ids.size(),1);
        const int64_t shape[]={1,(int64_t)ids.size()};
        const char *names[]={"input_ids","attention_mask"},*output="token_embeddings";
        Outputs o{api};
        for(int i=0;i<2;i++)check(api->CreateTensorWithDataAsOrtValue(mem,i?mask.data():ids.data(),ids.size()*8,
            shape,2,ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64,&o.input[i]),"embedding_decode");
        check(api->Run(session,nullptr,names,o.input,2,&output,1,&o.result),"embedding_decode");
        check(api->GetTensorTypeAndShape(o.result,&o.info),"embedding_dimension");
        size_t rank; int64_t dims[3]; ONNXTensorElementDataType dtype;
        check(api->GetDimensionsCount(o.info,&rank),"embedding_dimension");
        if(rank!=3)throw std::runtime_error("embedding_dimension");
        check(api->GetDimensions(o.info,dims,3),"embedding_dimension");
        check(api->GetTensorElementType(o.info,&dtype),"embedding_dimension");
        if(dims[0]!=1 || dims[1]!=shape[1] || dims[2]!=768 || dtype!=ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
            throw std::runtime_error("embedding_dimension");
        float *v=nullptr;
        check(api->GetTensorMutableData(o.result,(void**)&v),"embedding_decode");
        double norm=0;
        for(int j=0;j<768;j++)norm+=double(v[j])*v[j];
        if(!std::isfinite(norm))throw std::runtime_error("embedding_finite");
        if(norm<=0)throw std::runtime_error("embedding_zero");
        norm=std::sqrt(norm);
        NSMutableArray *vec=[NSMutableArray arrayWithCapacity:768];
        for(int j=0;j<768;j++)[vec addObject:@(static_cast<float>(v[j]/norm))];
        return vec;
    }
};
