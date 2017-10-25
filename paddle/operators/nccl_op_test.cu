/* Copyright (c) 2016 PaddlePaddle Authors. All Rights Reserve.

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License. */

#define EIGEN_USE_GPU

#include <glog/logging.h>
#include <gtest/gtest.h>
#include <thrust/device_vector.h>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

#include "paddle/framework/block_desc.h"
#include "paddle/framework/op_desc.h"
#include "paddle/framework/program_desc.h"
#include "paddle/framework/var_desc.h"
#include "paddle/operators/nccl/nccl_gpu_common.h"
#include "paddle/platform/device_context.h"
#include "paddle/platform/enforce.h"
#include "paddle/platform/gpu_info.h"
#include "paddle/platform/place.h"

#include "paddle/framework/op_registry.h"

USE_NO_KERNEL_OP(ncclInit);
USE_GPU_ONLY_OP(ncclAllReduce);
USE_GPU_ONLY_OP(ncclReduce);
USE_GPU_ONLY_OP(ncclBcastSend);
USE_GPU_ONLY_OP(ncclBcastRecv);

namespace f = paddle::framework;
namespace p = paddle::platform;

static std::vector<int> gpu_list;

// ncclInitOp with desc
// TEST(NCCL, ncclInitOp) {
//   f::ProgramDescBind program;
//   f::BlockDescBind *block = program.Block(0);
//   f::OpDescBind *op_desc = block->AppendOp();

//   op_desc->SetType("ncclInit");
//   op_desc->SetOutput("Communicator", {"x1"});
//   op_desc->SetAttr("gpus", {gpu_list});
//   f::Scope g_scope;
//   p::DeviceContext *ctx =
//       new p::CPUDeviceContext(p::CPUPlace());

//   auto *var = g_scope.Var("x1");
//   var->GetMutable<p::Communicator>();

//   auto op = f::OpRegistry::CreateOp(*op_desc);
//   VLOG(1) << "invoke NCCLInitOp.";
//   op->Run(g_scope, *ctx);
//   VLOG(1) << "NCCLInitOp finished.";
// }

// test data amount
static const f::DDim kDims = {100, 100};
static std::vector<p::DeviceContext *> dev_ctxs;

void CreateContext() {
  for (size_t i = 0; i < gpu_list.size(); ++i) {
    p::GPUPlace place(i);
    VLOG(1) << "create devicecontext : " << i;
    dev_ctxs.emplace_back(new p::CUDADeviceContext(place));
  }
}

void DestroyContext() {
  for (size_t i = 0; i < gpu_list.size(); ++i) {
    delete dev_ctxs[i];
  }
}

// global scope
static f::Scope g_scope;
std::mutex mu;

template <class T>
void DeviceProgram(int gpu_id, const f::OpDescBind &op_desc, f::Scope *scope) {
  std::unique_lock<std::mutex> lk(mu);
  f::ProgramDescBind program;
  f::BlockDescBind *block = program.Block(0);
  f::OpDescBind *op1 = block->AppendOp();
  *op1 = op_desc;

  p::GPUPlace place(gpu_id);
  // p::DeviceContext *ctx =
  //     new p::CUDADeviceContext(place);
  p::DeviceContext *ctx = dev_ctxs.at(gpu_id);
  VLOG(1) << "device context : " << dev_ctxs.size() << " gpu_id " << gpu_id;

  // f::Scope &local_scope = g_scope.NewScope();

  auto *send_tensor = scope->Var("st")->GetMutable<f::LoDTensor>();
  auto *recv_tensor = scope->Var("rt")->GetMutable<f::LoDTensor>();
  send_tensor->Resize(kDims);
  send_tensor->mutable_data<T>(kDims, place);
  // recv_tensor->mutable_data<T>(kDims, place);

  std::vector<T> send_vector(f::product(kDims), gpu_id);
  send_tensor->CopyFromVector<T>(send_vector, *ctx);
  lk.unlock();
  PADDLE_ENFORCE(send_tensor->numel() == f::product(kDims),
                 "Tensor numel not match!");
  ctx->Wait();

  VLOG(1) << send_tensor->numel() << " element in send tensor";

  auto op = f::OpRegistry::CreateOp(*op1);
  VLOG(1) << "Device : " << gpu_id << " invoke " << op_desc.Type();
  op->Run(*scope, *ctx);
  VLOG(1) << "Device : " << gpu_id << " finished " << op_desc.Type();
}

// ncclAllReduceOp with desc
TEST(NCCL, ncclAllReduceOp) {
  f::ProgramDescBind program;
  f::BlockDescBind *block = program.Block(0);
  f::OpDescBind *op1 = block->AppendOp();

  p::DeviceContext *ctx = new p::CPUDeviceContext(p::CPUPlace());

  CreateContext();

  op1->SetType("ncclInit");
  op1->SetOutput("Communicator", {"comm"});
  op1->SetAttr("gpus", {gpu_list});

  auto *var = g_scope.Var("comm");
  var->GetMutable<p::Communicator>();

  auto op = f::OpRegistry::CreateOp(*op1);
  VLOG(1) << "invoke NCCLInitOp.";
  op->Run(g_scope, *ctx);
  VLOG(1) << "NCCLInitOp finished.";
  delete ctx;

  f::OpDescBind *op2 = new f::OpDescBind;
  op2->SetType("ncclAllReduce");
  op2->SetInput("X", {"st"});
  op2->SetInput("Communicator", {"comm"});
  op2->SetOutput("Out", {"rt"});

  std::vector<std::thread> ths;
  for (size_t i = 0; i < gpu_list.size(); ++i) {
    std::thread th(DeviceProgram<float>, gpu_list[i], *op2,
                   &g_scope.NewScope());
    // std::thread th([=](){
    //     VLOG(1) << "thread id created : " << i;
    //     return 1;});
    ths.emplace_back(std::move(th));
  }

  for (size_t i = 0; i < gpu_list.size(); ++i) {
    VLOG(1) << " thread joined! " << i;
    ths[i].join();
  }
  VLOG(1) << " main thread joined!";

  delete op2;
  g_scope.~Scope();
  DestroyContext();
  VLOG(1) << " destory contexts";
}

// ncclBcastOp with desc
// TEST(NCCL, ncclBcastOp) {
//   f::ProgramDescBind program;
//   f::BlockDescBind *block = program.Block(0);
//   f::OpDescBind *op1= block->AppendOp();

//   p::DeviceContext *ctx =
//     new p::CPUDeviceContext(p::CPUPlace());

//   op1->SetType("ncclInit");
//   op1->SetOutput("Communicator", {"comm"});
//   op1->SetAttr("gpus", {gpu_list});

//   auto *var = g_scope.Var("comm");
//   var->GetMutable<p::Communicator>();

//   auto op = f::OpRegistry::CreateOp(*op1);
//   VLOG(1) << "invoke NCCLInitOp.";
//   op->Run(g_scope, *ctx);
//   VLOG(1) << "NCCLInitOp finished.";

//   f::OpDescBind *op2 = new f::OpDescBind;
//   op2->SetType("ncclBcastSend");
//   op2->SetInput("X", {"st"});
//   op2->SetInput("Communicator", {"comm"});
//   op2->SetOutput("Out", {"rt"});

//   std::vector<std::thread> ths;
//   for (size_t i=0; i < gpu_list.size(); ++i) {
//     std::thread th(DeviceProgram<float>, gpu_list[i], *op2);
//     ths.emplace_back(std::move(th));
//   }

//   for (size_t i=0; i < gpu_list.size(); ++i) {
//     ths[i].join();
//   }
// }

int main(int argc, char **argv) {
  const int dev_count = p::GetCUDADeviceCount();
  if (dev_count <= 1) {
    LOG(WARNING)
        << "Cannot test multi-gpu nccl, because the CUDA device count is "
        << dev_count;
    return 0;
  }

  for (int i = 0; i < dev_count; ++i) {
    gpu_list.emplace_back(i);
  }
  testing::InitGoogleTest(&argc, argv);
  return RUN_ALL_TESTS();
}
